--------------------------------------------------------------------------------
-- NestSystem.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona los nidos de cada jugador: colocación de dragones, compra de slots,
-- boosts, prestige y sincronización con el cliente.
--
-- Depende de DragonService para iniciar/detener la producción de oro.
-- El balance de oro del jugador vive aquí; DragonService solo hace las
-- matemáticas de producción y llama CollectGold para acumular.
-- ⚠ Llama NestSystem.AddGold(player, amount) después de cada
--   DragonService.CollectGold() para reflejar el oro en el balance.
--
-- playerState[userId] = {
--     level          : number   -- nivel/prestige actual
--     gold           : number   -- balance de oro actual
--     prestigeScales : number   -- moneda especial de prestige
--     inventory      : { [dragonId] = count }
--     slots          : number   -- slots totales desbloqueados
--     nests          : {
--         [nestIndex] = {
--             dragonId        : string | nil
--             lockedUntil     : number | nil  (timestamp; boost activo hasta aquí)
--             boostMultiplier : number        (default 1)
--         }
--     }
-- }
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Módulos compartidos
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

-- Servicio de producción
local DragonService = require(ServerScriptService:WaitForChild("DragonService"))

local NESTS    = Constants.NESTS
local PRESTIGE = Constants.PRESTIGE
local LEVELS   = Constants.LEVELS
local RARITIES = Constants.RARITIES

--------------------------------------------------------------------------------
-- Orden de rareza para comparaciones (mayor índice = más raro)
--------------------------------------------------------------------------------

local RARITY_RANK = {}
for i, rarity in ipairs(RARITIES.Order) do
    RARITY_RANK[rarity] = i
end

--------------------------------------------------------------------------------
-- RemoteEvents y RemoteFunctions
-- Se crean si no existen; evita errores si se carga antes que el cliente.
--------------------------------------------------------------------------------

local remotesFolder do
    remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotesFolder then
        remotesFolder        = Instance.new("Folder")
        remotesFolder.Name   = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    end
end

local function obtenerOCrear(clase, nombre)
    local obj = remotesFolder:FindFirstChild(nombre)
    if not obj then
        obj        = Instance.new(clase)
        obj.Name   = nombre
        obj.Parent = remotesFolder
    end
    return obj
end

local NestUpdatedEvent       = obtenerOCrear("RemoteEvent",  "NestUpdated")
local GoldUpdatedEvent       = obtenerOCrear("RemoteEvent",  "GoldUpdated")
local PrestigeCompletedEvent = obtenerOCrear("RemoteEvent",  "PrestigeCompleted")

local PlaceDragonFunc          = obtenerOCrear("RemoteFunction", "RequestPlaceDragonInNest")
local RemoveDragonFunc         = obtenerOCrear("RemoteFunction", "RequestRemoveDragon")
local BuySlotFunc              = obtenerOCrear("RemoteFunction", "RequestBuySlot")
local PrestigeFunc             = obtenerOCrear("RemoteFunction", "RequestPrestige")
local RequestReemplazarDragonFunc = obtenerOCrear("RemoteFunction", "RequestReemplazarDragon")

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

local playerState = {}   -- playerState[userId] = { ... }

-- Crea los slots iniciales vacíos para un jugador nuevo.
local function crearSlotsVacios(cantidad)
    local t = {}
    for i = 1, cantidad do
        t[i] = { dragonId = nil, lockedUntil = nil, boostMultiplier = 1 }
    end
    return t
end

-- Determina si la rareza de un dragón está permitida para el nivel del jugador.
-- La tienda y los nidos comparten el mismo techo de rareza por nivel.
local function rarezaPermitida(nivel, rareza)
    local levelData = LEVELS[nivel]
    if not levelData then return false end
    local techo = levelData.shopMaxRarity
    return RARITY_RANK[rareza] <= RARITY_RANK[techo]
end

-- Cuenta cuántos dragones tiene el jugador por rareza
-- considerando nidos activos + inventario.
local function contarDragonsPorRareza(state)
    local conteo = {}
    -- Desde el inventario
    for dragonId, cantidad in pairs(state.inventory) do
        local dragon = DragonData.GetDragonById(dragonId)
        if dragon and cantidad > 0 then
            conteo[dragon.rarity] = (conteo[dragon.rarity] or 0) + cantidad
        end
    end
    -- Desde nidos activos
    for _, nido in pairs(state.nests) do
        if nido.dragonId then
            local dragon = DragonData.GetDragonById(nido.dragonId)
            if dragon then
                conteo[dragon.rarity] = (conteo[dragon.rarity] or 0) + 1
            end
        end
    end
    return conteo
end


--------------------------------------------------------------------------------
-- NestSystem
--------------------------------------------------------------------------------

local NestSystem = {}

--------------------------------------------------------------------------------
-- NestSystem.InitPlayer(player, savedData)
--
-- Inicializa el estado de nidos al unirse el jugador.
-- Si hay savedData (cargado desde DataStore) lo restaura; si no, crea un
-- estado vacío con 3 slots. Llama StartProduction por cada nido con dragón.
--------------------------------------------------------------------------------
function NestSystem.InitPlayer(player, savedData)
    local uid = player.UserId

    if savedData then
        -- Restaurar desde datos guardados
        playerState[uid] = {
            level          = savedData.level          or 1,
            gold           = savedData.gold           or 0,
            prestigeScales = savedData.prestigeScales or 0,
            inventory      = savedData.inventory      or {},
            slots          = savedData.slots          or 3,
            nests          = savedData.nests          or crearSlotsVacios(3),
        }

        -- Asegurar que todos los slots tienen la estructura correcta
        for i = 1, playerState[uid].slots do
            if not playerState[uid].nests[i] then
                playerState[uid].nests[i] = {
                    dragonId        = nil,
                    lockedUntil     = nil,
                    boostMultiplier = 1,
                }
            else
                -- Garantizar campo boostMultiplier al migrar datos viejos
                playerState[uid].nests[i].boostMultiplier =
                    playerState[uid].nests[i].boostMultiplier or 1
            end
        end
    else
        -- Jugador nuevo
        playerState[uid] = {
            level          = 1,
            gold           = 0,
            prestigeScales = 0,
            inventory      = {},
            slots          = 3,
            nests          = crearSlotsVacios(3),
        }
    end

    -- Reanudar producción en todos los nidos que ya tienen dragón asignado
    local state = playerState[uid]
    for nestIndex, nido in pairs(state.nests) do
        if nido.dragonId then
            DragonService.StartProduction(player, nestIndex, nido.dragonId)
        end
    end
end

--------------------------------------------------------------------------------
-- NestSystem.AddGold(player, amount)
--
-- Añade oro al balance actual del jugador.
-- Debe llamarse externamente después de cada DragonService.CollectGold().
--------------------------------------------------------------------------------
function NestSystem.AddGold(player, amount)
    local state = playerState[player.UserId]
    if not state then return end
    state.gold = state.gold + amount
    GoldUpdatedEvent:FireClient(player, {
        currentGold = state.gold,
    })
end

--------------------------------------------------------------------------------
-- NestSystem.PlaceDragon(player, nestIndex, dragonId)
--
-- Coloca un dragón en un nido vacío del jugador.
-- Validaciones (todas en servidor):
--   · El nido existe (índice dentro de slots desbloqueados)
--   · El nido está vacío
--   · El jugador tiene el dragón en su inventario
--   · La rareza del dragón está permitida para el nivel del jugador
-- Si todo ok: descuenta el dragón del inventario, arranca producción y
-- notifica al cliente con NestUpdated.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function NestSystem.PlaceDragon(player, nestIndex, dragonId)
    local state = playerState[player.UserId]
    if not state then
        return false, "Estado del jugador no encontrado."
    end

    -- Validar que el índice es un número entero positivo
    if type(nestIndex) ~= "number" or nestIndex < 1
        or nestIndex ~= math.floor(nestIndex) then
        return false, "Índice de nido inválido."
    end

    -- Validar que el slot existe (está desbloqueado)
    if nestIndex > state.slots then
        return false, "Ese slot no está desbloqueado todavía."
    end

    local nido = state.nests[nestIndex]
    if not nido then
        return false, "Nido no encontrado."
    end

    -- Validar que el nido está vacío
    if nido.dragonId ~= nil then
        return false, "El nido ya tiene un dragón asignado."
    end

    -- Validar que el dragonId es una cadena no vacía
    if type(dragonId) ~= "string" or dragonId == "" then
        return false, "ID de dragón inválido."
    end

    -- Validar que el dragón existe en el catálogo
    local dragon = DragonData.GetDragonById(dragonId)
    if not dragon then
        return false, "Ese dragón no existe en el catálogo."
    end

    -- Validar que el jugador tiene el dragón en su inventario
    local cantInventario = state.inventory[dragonId] or 0
    if cantInventario <= 0 then
        return false, "No tienes ese dragón en tu inventario."
    end

    -- Validar que la rareza está permitida para el nivel del jugador
    if not rarezaPermitida(state.level, dragon.rarity) then
        local techo = LEVELS[state.level] and LEVELS[state.level].shopMaxRarity or "?"
        return false, ("Necesitas nivel superior para colocar dragones de rareza %s. "
            .. "Tu techo actual es: %s."):format(dragon.rarity, techo)
    end

    -- ✅ Todas las validaciones pasaron — ejecutar la acción
    state.inventory[dragonId] = cantInventario - 1
    if state.inventory[dragonId] == 0 then
        state.inventory[dragonId] = nil
    end

    nido.dragonId        = dragonId
    nido.boostMultiplier = 1
    nido.lockedUntil     = nil

    DragonService.StartProduction(player, nestIndex, dragonId)

    NestUpdatedEvent:FireClient(player, NestSystem.GetNestData(player))
    if NestSystem.OnNestChanged then NestSystem.OnNestChanged(player, nestIndex) end
    return true, "Dragón colocado correctamente."
end

--------------------------------------------------------------------------------
-- NestSystem.RemoveDragon(player, nestIndex)
--
-- Quita el dragón de un nido y lo devuelve al inventario del jugador.
-- Detiene la producción en DragonService.
-- ⚠ No recolecta el oro pendiente; llama CollectGold antes si el diseño lo requiere.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function NestSystem.RemoveDragon(player, nestIndex)
    local state = playerState[player.UserId]
    if not state then
        return false, "Estado del jugador no encontrado."
    end

    if type(nestIndex) ~= "number" or nestIndex < 1
        or nestIndex ~= math.floor(nestIndex) then
        return false, "Índice de nido inválido."
    end

    if nestIndex > state.slots then
        return false, "Ese slot no está desbloqueado."
    end

    local nido = state.nests[nestIndex]
    if not nido or nido.dragonId == nil then
        return false, "Ese nido no tiene ningún dragón."
    end

    local dragonId = nido.dragonId

    -- Detener producción en DragonService
    DragonService.StopProduction(player, nestIndex)

    -- Devolver el dragón al inventario
    state.inventory[dragonId] = (state.inventory[dragonId] or 0) + 1

    -- Limpiar el slot
    nido.dragonId        = nil
    nido.lockedUntil     = nil
    nido.boostMultiplier = 1

    NestUpdatedEvent:FireClient(player, NestSystem.GetNestData(player))
    if NestSystem.OnNestChanged then NestSystem.OnNestChanged(player, nestIndex) end
    return true, "Dragón retirado al inventario."
end

--------------------------------------------------------------------------------
-- NestSystem.GetSlotCost(player)
--
-- Devuelve el costo en oro del siguiente slot adicional según cuántos
-- slots tiene actualmente el jugador, usando Constants.NESTS.ExtraSlotCost.
-- Devuelve nil si ya alcanzó el máximo de slots para su nivel.
--------------------------------------------------------------------------------
function NestSystem.GetSlotCost(player)
    local state = playerState[player.UserId]
    if not state then return nil end

    local nivelData   = LEVELS[state.level]
    local maxPermitido = nivelData and NESTS.NestSlots[state.level] or NESTS.NestSlots[1]

    -- El jugador ya tiene el máximo permitido para su nivel
    if state.slots >= maxPermitido then
        return nil
    end

    -- El siguiente slot a comprar es state.slots + 1
    local siguienteSlot = state.slots + 1
    return NESTS.ExtraSlotCost[siguienteSlot]
end

--------------------------------------------------------------------------------
-- NestSystem.BuySlot(player)
--
-- Compra el siguiente slot de nido.
-- Validaciones:
--   · No supera el máximo de slots para el nivel actual
--   · El jugador tiene suficiente oro
-- Descuenta el oro, añade el slot y notifica al cliente.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function NestSystem.BuySlot(player)
    local state = playerState[player.UserId]
    if not state then
        return false, "Estado del jugador no encontrado."
    end

    local costo = NestSystem.GetSlotCost(player)
    if costo == nil then
        local maxPermitido = NESTS.NestSlots[state.level] or 3
        if state.slots >= maxPermitido then
            return false, ("Has alcanzado el máximo de %d slots para tu nivel %d.")
                :format(maxPermitido, state.level)
        end
        return false, "No se puede comprar más slots en este momento."
    end

    -- Validar balance de oro (nunca confiar en el cliente)
    if state.gold < costo then
        return false, ("Necesitas %d de oro, pero solo tienes %d.")
            :format(costo, state.gold)
    end

    -- ✅ Ejecutar compra
    state.gold  = state.gold - costo
    state.slots = state.slots + 1

    -- Crear el nuevo slot vacío
    state.nests[state.slots] = {
        dragonId        = nil,
        lockedUntil     = nil,
        boostMultiplier = 1,
    }

    NestUpdatedEvent:FireClient(player, NestSystem.GetNestData(player))
    return true, ("Slot desbloqueado. Te quedan %d de oro."):format(state.gold)
end

--------------------------------------------------------------------------------
-- NestSystem.ApplyBoost(player, nestIndex, boostId, multiplicador, expiraEn)
--
-- Setter puro: aplica un multiplicador y timestamp de expiración al nido.
-- Las validaciones de negocio las hace BoostSystem antes de llamar aquí.
-- Devuelve: boolean
--------------------------------------------------------------------------------
function NestSystem.ApplyBoost(player, nestIndex, boostId, multiplicador, expiraEn)
    local state = playerState[player.UserId]
    if not state then return false end
    local nido = state.nests[nestIndex]
    if not nido or not nido.dragonId then return false end

    nido.boostMultiplier = multiplicador
    nido.lockedUntil     = expiraEn
    nido.boostId         = boostId
    DragonService.SetMultiplier(player, nestIndex, multiplicador)
    DragonService.StopProduction(player, nestIndex)
    DragonService.StartProduction(player, nestIndex, nido.dragonId)
    NestUpdatedEvent:FireClient(player, NestSystem.GetNestData(player))
    return true
end

--------------------------------------------------------------------------------
-- NestSystem.ClearBoost(player, nestIndex)
--
-- Revierte el boost de un nido al expirar. Llamado por BoostSystem.
--------------------------------------------------------------------------------
function NestSystem.ClearBoost(player, nestIndex)
    local state = playerState[player.UserId]
    if not state then return end
    local nido = state.nests[nestIndex]
    if not nido then return end

    nido.boostMultiplier = 1
    nido.lockedUntil     = nil
    nido.boostId         = nil
    DragonService.ClearMultiplier(player, nestIndex)
    DragonService.StopProduction(player, nestIndex)
    if nido.dragonId then
        DragonService.StartProduction(player, nestIndex, nido.dragonId)
    end
    NestUpdatedEvent:FireClient(player, NestSystem.GetNestData(player))
end

--------------------------------------------------------------------------------
-- NestSystem.GetNestData(player)
--
-- Devuelve el estado completo de los nidos para sincronizar con el cliente.
-- Incluye: slots totales, datos de cada nido, nivel, oro y coste del próximo slot.
--------------------------------------------------------------------------------
function NestSystem.GetNestData(player)
    local state = playerState[player.UserId]
    if not state then return nil end

    local ahora     = os.time()
    local nestsCopy = {}

    for i = 1, state.slots do
        local nido = state.nests[i]
        if nido then
            -- Calcular si el boost sigue activo
            local boostActivo = nido.lockedUntil and nido.lockedUntil > ahora

            nestsCopy[i] = {
                dragonId         = nido.dragonId,
                boostMultiplier  = boostActivo and nido.boostMultiplier or 1,
                boostSecondsLeft = boostActivo and (nido.lockedUntil - ahora) or 0,
                boostId          = boostActivo and nido.boostId or nil,
                oroPendiente     = DragonService.CalculatePending(player, i),
            }
        end
    end

    return {
        slots         = state.slots,
        nests         = nestsCopy,
        level         = state.level,
        gold          = state.gold,
        prestigeScales = state.prestigeScales,
        costoSiguienteSlot = NestSystem.GetSlotCost(player),
    }
end

---------------------------------------------------------------------------------
-- NestSystem.GetPrestigeData(player)
--
-- Devuelve los datos de prestige estructurados para el panel del HUD:
--   { canPrestige, nivelObjetivo, dragons = { [rareza]={required,current,met} },
--     oroActualRequerido = { required, current, met } }
--------------------------------------------------------------------------------
function NestSystem.GetPrestigeData(player)
    local state = playerState[player.UserId]
    if not state then
        return { canPrestige = false, nivelObjetivo = 2, dragons = {}, oroActualRequerido = { required = 0, current = 0, met = false } }
    end

    local nivelObjetivo = state.level + 1
    local req = PRESTIGE[nivelObjetivo]
    if not req then
        return { canPrestige = false, nivelObjetivo = nivelObjetivo, dragons = {}, oroActualRequerido = { required = 0, current = 0, met = true } }
    end

    local conteo   = contarDragonsPorRareza(state)
    local dragons  = {}
    local cumplido = true

    if req.DragonRequirements then
        for rareza, necesarios in pairs(req.DragonRequirements) do
            local tiene = conteo[rareza] or 0
            local met   = tiene >= necesarios
            dragons[rareza] = { required = necesarios, current = tiene, met = met }
            if not met then cumplido = false end
        end
    end

    local oroActual  = state.gold
    local oroReq     = req.oroActualRequerido or 0
    local oroMet     = oroActual >= oroReq
    if not oroMet then cumplido = false end

    return {
        canPrestige        = cumplido,
        nivelObjetivo      = nivelObjetivo,
        dragons            = dragons,
        oroActualRequerido = { required = oroReq, current = oroActual, met = oroMet },
    }
end

---------------------------------------------------------------------------------
-- NestSystem.CheckPrestigeRequirements(player)
--
-- Revisa si el jugador cumple todos los requisitos para subir al siguiente
-- nivel de prestige según Constants.PRESTIGE.
-- Devuelve:
--   { canPrestige = true/false, missing = { dragons = {}, goldEarned = n } }
--------------------------------------------------------------------------------
function NestSystem.CheckPrestigeRequirements(player)
    local state = playerState[player.UserId]
    if not state then
        return { canPrestige = false, missing = {} }
    end

    local nivelObjetivo = state.level + 1
    if nivelObjetivo > PRESTIGE.MaxLevel then
        return { canPrestige = false, missing = {}, razon = "Ya estás en el nivel máximo." }
    end

    local req = PRESTIGE[nivelObjetivo]
    if not req then
        return { canPrestige = false, missing = {}, razon = "No hay requisitos definidos." }
    end

    local cumplido = true
    local faltaDragones = {}
    local faltaOro     = 0

    -- Contar dragones del jugador (nidos + inventario)
    local conteo = contarDragonsPorRareza(state)

    -- Comparar con los requisitos de dragones por rareza
    for rareza, necesarios in pairs(req.DragonRequirements) do
        local tiene = conteo[rareza] or 0
        if tiene < necesarios then
            faltaDragones[rareza] = necesarios - tiene
            cumplido = false
        end
    end

    -- Comparar con el oro ACTUAL del jugador en ese momento
    local oroActual = state.gold
    if oroActual < req.oroActualRequerido then
        faltaOro = req.oroActualRequerido - oroActual
        cumplido = false
    end

    return {
        canPrestige = cumplido,
        missing = {
            dragons            = faltaDragones,
            oroActualRequerido = faltaOro,
        },
        nivelObjetivo = nivelObjetivo,
    }
end

--------------------------------------------------------------------------------
-- NestSystem.Prestige(player)
--
-- Ejecuta el prestige del jugador si cumple los requisitos:
--   · Resetea el balance de oro a 0 (los dragones en nidos se conservan)
--   · Sube el nivel de prestige
--   · Otorga 1 Escama de Prestige (prestigeScales)
--   · Desbloquea la zona del nuevo nivel (se envía al cliente para que la abra)
-- Dispara RemoteEvent "PrestigeCompleted" con el nuevo estado.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function NestSystem.Prestige(player)
    local check = NestSystem.CheckPrestigeRequirements(player)

    if not check.canPrestige then
        -- Devolver un mensaje detallado de qué falta
        local partes = {}

        if next(check.missing.dragons) then
            for rareza, cant in pairs(check.missing.dragons) do
                table.insert(partes, ("%d %s"):format(cant, rareza))
            end
        end
        if check.missing.oroActualRequerido and check.missing.oroActualRequerido > 0 then
            table.insert(partes, ("%d de oro en tu balance"):format(check.missing.oroActualRequerido))
        end

        local detalle = #partes > 0
            and ("Falta: " .. table.concat(partes, ", ") .. ".")
            or (check.razon or "No cumples los requisitos.")

        return false, detalle
    end

    local state = playerState[player.UserId]

    -- Subir nivel
    state.level          = state.level + 1
    state.gold           = 0          -- resetear balance de oro
    state.prestigeScales = state.prestigeScales + 1   -- recompensa

    -- Los nidos y su contenido se conservan intactos
    -- Los dragones del inventario también se conservan

    -- Obtener la nueva zona desbloqueada para informar al cliente
    local nuevaZona = LEVELS[state.level] and LEVELS[state.level].zone or "desconocida"

    PrestigeCompletedEvent:FireClient(player, {
        nuevoNivel     = state.level,
        prestigeScales = state.prestigeScales,
        zonaDesbloqueada = nuevaZona,
        nestData       = NestSystem.GetNestData(player),
    })

    return true, ("¡Prestige completado! Ahora eres nivel %d. Zona desbloqueada: %s.")
        :format(state.level, nuevaZona)
end


--------------------------------------------------------------------------------
-- NestSystem.ReemplazarDragon(player, nestIndex, nuevoDragonId)
--
-- Reemplaza el dragón de un nido con otro del inventario del jugador.
-- El dragón actual vuelve al inventario antes de colocar el nuevo,
-- por lo que el límite de inventario no es un obstáculo.
-- Si el nido tenía boost activo, se limpia al hacer el cambio.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function NestSystem.ReemplazarDragon(player, nestIndex, nuevoDragonId)
    local state = playerState[player.UserId]
    if not state then
        return false, "Estado del jugador no encontrado."
    end

    if type(nestIndex) ~= "number" or nestIndex < 1
        or nestIndex ~= math.floor(nestIndex) then
        return false, "Índice de nido inválido."
    end

    if nestIndex > state.slots then
        return false, "Ese nido no está desbloqueado."
    end

    local nido = state.nests[nestIndex]
    if not nido or not nido.dragonId then
        return false, "El nido está vacío. Usa 'Colocar' en su lugar."
    end

    if type(nuevoDragonId) ~= "string" or nuevoDragonId == "" then
        return false, "ID de dragón inválido."
    end

    if not DragonData.GetDragonById(nuevoDragonId) then
        return false, "Ese dragón no existe en el catálogo."
    end

    -- El inventario es la referencia compartida con DataStore, así que
    -- leer state.inventory es equivalente a leer localData[uid].inventory.
    if (state.inventory[nuevoDragonId] or 0) < 1 then
        return false, "No tienes ese dragón en el inventario."
    end

    -- Quitar el dragón actual (vuelve al inventario automáticamente)
    -- Esto recarga NestUpdated internamente; lo volveremos a disparar al final.
    DragonService.StopProduction(player, nestIndex)
    local dragonAnterior   = nido.dragonId
    state.inventory[dragonAnterior] = (state.inventory[dragonAnterior] or 0) + 1

    -- Limpiar boost si lo había
    if nido.lockedUntil then
        nido.boostMultiplier = 1
        nido.lockedUntil     = nil
        nido.boostId         = nil
        DragonService.ClearMultiplier(player, nestIndex)
    end

    -- Colocar el nuevo dragón (descontar del inventario)
    state.inventory[nuevoDragonId] = state.inventory[nuevoDragonId] - 1
    if state.inventory[nuevoDragonId] <= 0 then
        state.inventory[nuevoDragonId] = nil
    end

    nido.dragonId        = nuevoDragonId
    nido.boostMultiplier = 1

    DragonService.StartProduction(player, nestIndex, nuevoDragonId)
    NestUpdatedEvent:FireClient(player, NestSystem.GetNestData(player))
    if NestSystem.OnNestChanged then NestSystem.OnNestChanged(player, nestIndex) end
    return true, "¡Dragón reemplazado!"
end

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
-- El servidor valida y responde; el cliente nunca toma decisiones de estado.
--------------------------------------------------------------------------------

-- Colocar dragón en nido
PlaceDragonFunc.OnServerInvoke = function(player, dragonId, nestIndex)
    -- El cliente envía (dragonId, nestIndex) — sanitizar antes de pasar
    if type(nestIndex) ~= "number" or type(dragonId) ~= "string" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    local ok, msg = NestSystem.PlaceDragon(player, nestIndex, dragonId)
    return { ok = ok, message = msg }
end

-- Quitar dragón del nido
RemoveDragonFunc.OnServerInvoke = function(player, nestIndex)
    if type(nestIndex) ~= "number" then
        return false, "Parámetros inválidos."
    end
    return NestSystem.RemoveDragon(player, nestIndex)
end

-- Comprar slot adicional
BuySlotFunc.OnServerInvoke = function(player)
    return NestSystem.BuySlot(player)
end

-- Solicitar prestige
PrestigeFunc.OnServerInvoke = function(player)
    return NestSystem.Prestige(player)
end

-- Reemplazar dragón en un nido con otro del inventario
RequestReemplazarDragonFunc.OnServerInvoke = function(player, nestIndex, nuevoDragonId)
    if type(nestIndex) ~= "number" or type(nuevoDragonId) ~= "string" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    local ok, msg = NestSystem.ReemplazarDragon(player, math.floor(nestIndex), nuevoDragonId)
    return { ok = ok, message = msg }
end

-- Solicitar datos de prestige para el panel del HUD
local RequestPrestigeDataFunc = obtenerOCrear("RemoteFunction", "RequestPrestigeData")
RequestPrestigeDataFunc.OnServerInvoke = function(player)
    return NestSystem.GetPrestigeData(player)
end

-- Solicitar estado completo de los nidos (para el InventoryGUI)
local RequestNestDataFunc = obtenerOCrear("RemoteFunction", "RequestNestData")
RequestNestDataFunc.OnServerInvoke = function(player)
    return NestSystem.GetNestData(player)
end

--------------------------------------------------------------------------------
-- Ciclo de vida de jugadores
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
    -- DataStore.lua debe llamar NestSystem.InitPlayer con los datos guardados.
    -- Si carga antes que DataStore, inicializamos vacío como fallback.
    if not playerState[player.UserId] then
        NestSystem.InitPlayer(player, nil)
    end
end)

Players.PlayerRemoving:Connect(function(player)
    -- DataStore.lua debe haber guardado el estado antes de este punto.
    playerState[player.UserId] = nil
end)

-- Inicializar jugadores que ya estaban en sesión al cargar este script
for _, player in ipairs(Players:GetPlayers()) do
    if not playerState[player.UserId] then
        NestSystem.InitPlayer(player, nil)
    end
end

--------------------------------------------------------------------------------
-- NestSystem.OnNestChanged
-- Callback opcional que se llama cada vez que un dragón se coloca o retira.
-- Uso: NestSystem.OnNestChanged = function(player, nestIndex) ... end
--------------------------------------------------------------------------------
NestSystem.OnNestChanged = nil

return NestSystem
