--------------------------------------------------------------------------------
-- EggService.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona el ciclo completo de huevos:
--   1. Timer de nido   → el dragón pone el huevo (eggTimerSeconds)
--   2. Inventario      → el jugador recolecta el huevo listo
--   3. Incubación      → el jugador elige incubar; se resuelve la rareza y el dragón
--   4. Venta           → alternativa: vender el huevo por oro
--
-- Estado en memoria:
--   eggs[userId][nestIndex]   → timer activo por nido
--   eggInventory[userId]      → huevos recolectados pendientes de incubar/vender
--
-- NOTA SOBRE guaranteed:
--   El campo guaranteed del huevo se activa cuando el boost "lucky_egg" está
--   activo al iniciar el timer. Eleva la rareza mínima garantizada del resultado.
--   El mapa RARITY_MINIMUM_SHIFT define de qué rareza actúa como piso según nivel.
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Módulos compartidos
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

-- Servicio de datos
local DataStore   = require(ServerScriptService:WaitForChild("DataStore"))
local NestSystem  = require(ServerScriptService:WaitForChild("NestSystem"))

local RARITIES = Constants.RARITIES
local BOOSTS   = Constants.BOOSTS

--------------------------------------------------------------------------------
-- Tablas de apoyo
--------------------------------------------------------------------------------

-- Orden de rareza con su índice numérico para comparaciones
local RARITY_RANK = {}
for i, r in ipairs(RARITIES.Order) do
    RARITY_RANK[r] = i
end

-- Valor de venta base multiplicador: 30% de (gps * 100)
local SELL_MULTIPLIER = 0.30
local SELL_BASE_FACTOR = 100

-- Boost de reducción de timer: ID del boost que consume ApplyIncubationBoost
local BOOST_ID_INCUBATION = "hatch_fever"

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

-- eggs[userId] = { [nestIndex] = { readyAt, dragonId, guaranteed } }
local eggs = {}

-- eggInventory[userId] = { [eggIndex] = { dragonId, guaranteed, collectedAt } }
local eggInventory = {}

-- Siguiente índice único por jugador para eggInventory (evita colisiones)
local eggNextIndex = {}

--------------------------------------------------------------------------------
-- RemoteEvents y RemoteFunctions
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

local EggStartedEvent   = obtenerOCrear("RemoteEvent",    "EggStarted")
local EggReadyEvent     = obtenerOCrear("RemoteEvent",    "EggReady")
local EggIncubatedEvent = obtenerOCrear("RemoteEvent",    "EggIncubated")

local CollectEggFunc              = obtenerOCrear("RemoteFunction", "RequestCollectEgg")
local StartIncubationFunc         = obtenerOCrear("RemoteFunction", "RequestStartIncubation")
local SellEggFunc                 = obtenerOCrear("RemoteFunction", "RequestSellEgg")
local SpeedUpIncubationFunc       = obtenerOCrear("RemoteFunction", "RequestSpeedUpIncubation")
local GetNestStatusFunc           = obtenerOCrear("RemoteFunction", "RequestGetNestStatus")
local CancelIncubationFunc        = obtenerOCrear("RemoteFunction", "RequestCancelIncubation")
local SaveToInventoryFunc         = obtenerOCrear("RemoteFunction", "RequestSaveDragonToInventory")
local GetAllEggStatusesFunc       = obtenerOCrear("RemoteFunction", "RequestGetAllEggStatuses")

--------------------------------------------------------------------------------
-- Helpers internos
--------------------------------------------------------------------------------

-- Garantiza que existen las tablas del jugador en memoria.
local function asegurarEstado(userId)
    if not eggs[userId]         then eggs[userId]         = {} end
    if not eggInventory[userId] then eggInventory[userId] = {} end
    if not eggNextIndex[userId] then eggNextIndex[userId] = 1  end
end

-- Añade un huevo al inventario del jugador y devuelve el índice asignado.
local function agregarAlInventario(userId, dragonId, guaranteed)
    asegurarEstado(userId)
    local idx = eggNextIndex[userId]
    eggInventory[userId][idx] = {
        dragonId    = dragonId,
        guaranteed  = guaranteed,
        collectedAt = os.time(),
    }
    eggNextIndex[userId] = idx + 1
    return idx
end

-- Calcula las probabilidades de rareza ajustadas con la garantía mínima y
-- devuelve: (tabla ajustada, suma de probabilidades original restante)
-- Si guaranteed es nil no se altera nada.
local function ajustarProbabilidades(parentRarity, guaranteed)
    local base = RARITIES.HatchChances[parentRarity]
    if not base then
        -- Fallback si la rareza padre es desconocida
        base = RARITIES.HatchChances["comun"]
    end

    -- Copia mutable de las probabilidades base
    local ajustadas = {}
    for rareza, prob in pairs(base) do
        ajustadas[rareza] = prob
    end

    -- Aplicar piso de rareza garantizada: zerear todo lo que esté por debajo
    if guaranteed and RARITY_RANK[guaranteed] then
        local pisoRank = RARITY_RANK[guaranteed]
        local sumEliminada = 0

        for rareza, prob in pairs(ajustadas) do
            if RARITY_RANK[rareza] < pisoRank then
                sumEliminada       = sumEliminada + prob
                ajustadas[rareza]  = 0
            end
        end

        -- Redistribuir la probabilidad eliminada proporcionalmente entre
        -- las rarezas que quedan (mantiene las proporciones relativas)
        if sumEliminada > 0 then
            local sumRestante = 0
            for rareza, prob in pairs(ajustadas) do
                if prob > 0 then sumRestante = sumRestante + prob end
            end
            if sumRestante > 0 then
                local factor = (sumRestante + sumEliminada) / sumRestante
                for rareza, prob in pairs(ajustadas) do
                    if prob > 0 then
                        ajustadas[rareza] = prob * factor
                    end
                end
            end
        end
    end

    return ajustadas
end

-- Selecciona una rareza al azar usando las probabilidades ajustadas.
-- Devuelve la rareza elegida como string.
local function sortearRareza(probabilidades)
    local roll       = math.random()
    local acumulado  = 0

    -- Iterar en orden canónico para determinismo
    for _, rareza in ipairs(RARITIES.Order) do
        local prob = probabilidades[rareza] or 0
        acumulado  = acumulado + prob
        if roll <= acumulado then
            return rareza
        end
    end

    -- Fallback: devolver la rareza más alta con probabilidad > 0
    for i = #RARITIES.Order, 1, -1 do
        local r = RARITIES.Order[i]
        if (probabilidades[r] or 0) > 0 then
            return r
        end
    end
    return "comun"
end

-- Elige un dragón aleatorio del elemento y rareza dados.
-- Excluye breedingOnly y eventOnly.
-- Si no hay ninguno en ese elemento, amplía la búsqueda a cualquier elemento.
local function elegirDragon(elemento, rareza)
    local candidatos = {}

    -- Primera pasada: mismo elemento
    for _, dragon in ipairs(DragonData.Dragons) do
        if dragon.element == elemento
            and dragon.rarity == rareza
            and not dragon.soloCria
            and not dragon.soloEvento
        then
            table.insert(candidatos, dragon.id)
        end
    end

    -- Segunda pasada: cualquier elemento si no hay candidatos en el elemento padre
    if #candidatos == 0 then
        for _, dragon in ipairs(DragonData.Dragons) do
            if dragon.rarity == rareza
                and not dragon.soloCria
                and not dragon.soloEvento
            then
                table.insert(candidatos, dragon.id)
            end
        end
    end

    if #candidatos == 0 then return nil end
    return candidatos[math.random(#candidatos)]
end

-- Devuelve la rareza del boost "lucky_egg" activo para el jugador, o nil.
-- La rareza garantizada sube al siguiente tier de la rareza del padre.
local function obtenerGarantia(player, parentRarity)
    local datos = DataStore.GetPlayerData(player)
    if not datos then return nil end

    -- Verificar si el jugador tiene lucky_egg en su inventario de boosts
    local cantBoost = datos.boosts and datos.boosts["lucky_egg"] or 0
    if cantBoost <= 0 then return nil end

    -- La garantía es la siguiente rareza por encima de la del padre
    local rank = RARITY_RANK[parentRarity] or 1
    local nextRank = math.min(rank + 1, #RARITIES.Order)
    return RARITIES.Order[nextRank]
end

--------------------------------------------------------------------------------
-- EggService
--------------------------------------------------------------------------------

local EggService = {}

--------------------------------------------------------------------------------
-- EggService.GetEggCount(player [, dragonId])
--
-- Si se proporciona dragonId: cuenta los huevos de ese tipo de dragón padre.
-- Sin dragonId: cuenta todos los huevos del inventario del jugador.
-- Usado por DataStore.IsInventoryFull (sin dragonId) y TradeSystem (con dragonId).
--------------------------------------------------------------------------------
function EggService.GetEggCount(player, dragonId)
    local uid = player.UserId
    local inv = eggInventory[uid]
    if not inv then return 0 end
    local count = 0
    if dragonId then
        -- Contar solo huevos cuyo padre sea dragonId
        for _, entry in pairs(inv) do
            if entry.dragonId == dragonId then
                count += 1
            end
        end
    else
        -- Contar todos los huevos
        for _ in pairs(inv) do count += 1 end
    end
    return count
end

--------------------------------------------------------------------------------
-- EggService.SerializeInventory(player)
--
-- Devuelve una lista serializable de los huevos en el inventario del jugador.
-- Llamado por DataStore.construirPayload antes de cada guardado.
--------------------------------------------------------------------------------
function EggService.SerializeInventory(player)
    local uid  = player.UserId
    local inv  = eggInventory[uid] or {}
    local lista = {}
    for idx, entry in pairs(inv) do
        lista[#lista + 1] = {
            idx         = idx,
            dragonId    = entry.dragonId,
            guaranteed  = entry.guaranteed,
            collectedAt = entry.collectedAt,
        }
    end
    return lista
end

--------------------------------------------------------------------------------
-- EggService.LoadInventory(player, savedEggs)
--
-- Restaura el inventario de huevos desde los datos guardados en DataStore.
-- Llamado por DataStore.LoadPlayer después de inicializar el resto del estado.
--------------------------------------------------------------------------------
function EggService.LoadInventory(player, savedEggs)
    if not savedEggs or #savedEggs == 0 then return end
    local uid = player.UserId
    asegurarEstado(uid)
    for _, entry in ipairs(savedEggs) do
        local idx = entry.idx or eggNextIndex[uid]
        eggInventory[uid][idx] = {
            dragonId    = entry.dragonId,
            guaranteed  = entry.guaranteed,
            collectedAt = entry.collectedAt,
        }
        if idx >= eggNextIndex[uid] then
            eggNextIndex[uid] = idx + 1
        end
    end
end

--------------------------------------------------------------------------------
-- EggService.StartEggTimer(player, nestIndex, dragonId)
--
-- Inicia el contador de huevo para un nido específico.
-- Usa dragon.eggTimerSeconds para calcular cuándo estará listo.
-- Si ya hay un huevo activo en ese nido, no hace nada (idempotente).
-- Verifica si hay boost "lucky_egg" activo y establece la rareza garantizada.
-- Dispara RemoteEvent "EggStarted" al cliente con el tiempo restante.
--------------------------------------------------------------------------------
function EggService.StartEggTimer(player, nestIndex, dragonId)
    local uid = player.UserId
    asegurarEstado(uid)

    -- No iniciar si ya hay un huevo pendiente en ese nido
    if eggs[uid][nestIndex] then return false end

    local dragon = DragonData.GetDragonById(dragonId)
    if not dragon then
        warn(("[EggService] Dragón padre desconocido: %s"):format(tostring(dragonId)))
        return false
    end

    local ahora     = os.time()
    local readyAt   = ahora + dragon.eggTimerSeconds
    local guaranteed = obtenerGarantia(player, dragon.rarity)

    -- Si se usó el lucky_egg, consumir 1 unidad del boost
    if guaranteed then
        local datos = DataStore.GetPlayerData(player)
        if datos and datos.boosts then
            datos.boosts["lucky_egg"] = math.max(0, (datos.boosts["lucky_egg"] or 0) - 1)
            if datos.boosts["lucky_egg"] == 0 then
                datos.boosts["lucky_egg"] = nil
            end
        end
    end

    eggs[uid][nestIndex] = {
        readyAt    = readyAt,
        dragonId   = dragonId,
        guaranteed = guaranteed,
    }

    EggStartedEvent:FireClient(player, {
        nestIndex      = nestIndex,
        dragonId       = dragonId,
        readyAt        = readyAt,
        secondsLeft    = dragon.eggTimerSeconds,
        guaranteed     = guaranteed,
    })

    return true
end

--------------------------------------------------------------------------------
-- EggService.GetEggStatus(player, nestIndex)
--
-- Devuelve el estado del huevo en ese nido:
--   { hasEgg, secondsLeft, isReady, dragonId, guaranteed }
-- secondsLeft será 0 (no negativo) si ya está listo.
--------------------------------------------------------------------------------
function EggService.GetEggStatus(player, nestIndex)
    local uid  = player.UserId
    local nido = eggs[uid] and eggs[uid][nestIndex]

    if not nido then
        return { hasEgg = false }
    end

    local ahora      = os.time()
    local secondsLeft = math.max(0, nido.readyAt - ahora)

    return {
        hasEgg      = true,
        secondsLeft = secondsLeft,
        isReady     = secondsLeft == 0,
        dragonId    = nido.dragonId,
        guaranteed  = nido.guaranteed,
        readyAt     = nido.readyAt,
    }
end

--------------------------------------------------------------------------------
-- EggService.CollectEgg(player, nestIndex)
--
-- El jugador toca el huevo listo para recogerlo.
-- Valida que readyAt <= os.time() (el servidor siempre confirma).
-- Mueve el huevo al inventario del jugador (eggInventory).
-- Inicia automáticamente el siguiente timer en el mismo nido.
-- Dispara RemoteEvent "EggReady" con el índice del huevo en inventario.
-- Devuelve: (éxito, datos del huevo recolectado o mensaje de error)
--------------------------------------------------------------------------------
function EggService.CollectEgg(player, nestIndex)
    local uid  = player.UserId
    local nido = eggs[uid] and eggs[uid][nestIndex]

    if not nido then
        return false, "No hay ningún huevo en ese nido."
    end

    -- Validar en el servidor; no confiar en el timestamp del cliente
    if os.time() < nido.readyAt then
        local restante = nido.readyAt - os.time()
        return false, ("El huevo aún no está listo. Faltan %d segundos."):format(restante)
    end

    -- Verificar límite de inventario antes de agregar el huevo
    if DataStore.IsInventoryFull(player) then
        return false, "Inventario lleno — vendé o usá dragones para hacer espacio."
    end

    local dragonId   = nido.dragonId
    local guaranteed = nido.guaranteed

    -- Registrar en el inventario de huevos del jugador
    local eggIdx = agregarAlInventario(uid, dragonId, guaranteed)

    -- Liberar el slot en el nido
    eggs[uid][nestIndex] = nil

    -- Iniciar automáticamente el siguiente ciclo de producción de huevo
    EggService.StartEggTimer(player, nestIndex, dragonId)

    -- Notificar al cliente
    EggReadyEvent:FireClient(player, {
        nestIndex  = nestIndex,
        eggIndex   = eggIdx,
        dragonId   = dragonId,
        guaranteed = guaranteed,
        collected  = true,
    })

    local parentDragon   = DragonData.GetDragonById(dragonId)
    local incubSeconds   = parentDragon and parentDragon.incubationSeconds or 300
    local sellVal        = parentDragon
        and math.floor(parentDragon.goldPerSecond * SELL_BASE_FACTOR * SELL_MULTIPLIER)
        or 0

    return {
        ok                = true,
        eggIndex          = eggIdx,
        dragonId          = dragonId,
        guaranteed        = guaranteed,
        incubationSeconds = incubSeconds,
        garantiaRareza    = guaranteed,
        sellValue         = sellVal,
    }
end

--------------------------------------------------------------------------------
-- EggService.IncubateEgg(player, eggIndex)
--
-- El jugador incuba un huevo de su inventario.
-- Proceso:
--   1. Validar que el huevo existe en el inventario del jugador.
--   2. Calcular las probabilidades ajustadas (con guaranteed si aplica).
--   3. Sortear rareza mediante weighted random.
--   4. Elegir dragón aleatorio del elemento del padre y la rareza sorteada.
--   5. Registrar el dragón en DataStore.
--   6. Disparar "EggIncubated" con el resultado Y la tabla de probabilidades completa
--      (para que la UI pueda mostrarla de forma transparente antes de incubar).
-- Devuelve: (éxito, { dragonId, rareza, probabilidades } o mensaje de error)
--------------------------------------------------------------------------------
function EggService.IncubateEgg(player, eggIndex)
    local uid      = player.UserId
    local inventario = eggInventory[uid]

    if not inventario then
        return false, "No tienes huevos en tu inventario."
    end

    local huevo = inventario[eggIndex]
    if not huevo then
        return false, "Ese huevo no existe en tu inventario."
    end

    local parentDragon = DragonData.GetDragonById(huevo.dragonId)
    if not parentDragon then
        -- Dato corrupto: eliminar el huevo y reportar
        inventario[eggIndex] = nil
        return false, "El huevo tenía datos inválidos y fue descartado."
    end

    -- Calcular probabilidades ajustadas para esta incubación
    local probabilidades = ajustarProbabilidades(parentDragon.rarity, huevo.guaranteed)

    -- Sortear rareza del hijo
    local rarezaResultado = sortearRareza(probabilidades)

    -- Elegir dragón del mismo elemento que el padre
    local dragonResultadoId = elegirDragon(parentDragon.element, rarezaResultado)

    if not dragonResultadoId then
        -- Situación muy improbable: no hay dragón de esa rareza+elemento
        -- Intentar con cualquier elemento como fallback de emergencia
        warn(("[EggService] Sin candidatos para elemento=%s rareza=%s — usando fallback")
            :format(parentDragon.element, rarezaResultado))
        dragonResultadoId = elegirDragon("fuego", rarezaResultado) or "fire_common"
    end

    -- Consumir el huevo del inventario ANTES de otorgar el dragón
    inventario[eggIndex] = nil

    -- Registrar el dragón nuevo en DataStore (inventario + catálogo)
    DataStore.AddDragonToInventory(player, dragonResultadoId)

    local dragonResultado = DragonData.GetDragonById(dragonResultadoId)

    -- Notificar al cliente con resultado completo y tabla de probabilidades
    -- (transparencia: el jugador puede ver qué chances tuvo antes y después)
    EggIncubatedEvent:FireClient(player, {
        dragonId          = dragonResultadoId,
        dragonName        = dragonResultado and dragonResultado.name or dragonResultadoId,
        rareza            = rarezaResultado,
        elemento          = dragonResultado and dragonResultado.element or parentDragon.element,
        parentDragonId    = huevo.dragonId,
        parentRareza      = parentDragon.rarity,
        guaranteed        = huevo.guaranteed,
        -- Tabla completa de probabilidades usada (para UI de transparencia)
        probabilidades    = probabilidades,
        -- Probabilidades base sin ajuste (para mostrar diferencia cuando hay guaranteed)
        probabilidadesBase = RARITIES.HatchChances[parentDragon.rarity],
    })

    return true, {
        dragonId       = dragonResultadoId,
        rareza         = rarezaResultado,
        probabilidades = probabilidades,
    }
end

--------------------------------------------------------------------------------
-- EggService.SellEgg(player, eggIndex)
--
-- El jugador vende un huevo de su inventario sin incubarlo.
-- Valor = floor( gps del dragón padre × SELL_BASE_FACTOR × SELL_MULTIPLIER )
-- Llama DataStore.AddGold con el valor calculado.
-- Devuelve: (éxito, { oroGanado } o mensaje de error)
--------------------------------------------------------------------------------
function EggService.SellEgg(player, eggIndex)
    local uid      = player.UserId
    local inventario = eggInventory[uid]

    if not inventario then
        return false, "No tienes huevos en tu inventario."
    end

    local huevo = inventario[eggIndex]
    if not huevo then
        return false, "Ese huevo no existe en tu inventario."
    end

    local parentDragon = DragonData.GetDragonById(huevo.dragonId)
    if not parentDragon then
        inventario[eggIndex] = nil
        return false, "El huevo tenía datos inválidos y fue descartado."
    end

    -- Calcular valor de venta
    local oroGanado = math.floor(parentDragon.goldPerSecond * SELL_BASE_FACTOR * SELL_MULTIPLIER)

    -- Consumir el huevo del inventario
    inventario[eggIndex] = nil

    -- Acreditar oro al jugador
    DataStore.AddGold(player, oroGanado)

    return true, { oroGanado = oroGanado }
end

--------------------------------------------------------------------------------
-- EggService.ApplyIncubationBoost(player, nestIndex)
--
-- Reduce el tiempo restante del huevo en ese nido a la mitad.
-- Consume 1 unidad del boost BOOST_ID_INCUBATION ("hatch_fever") del jugador.
-- No hace nada si:
--   · No hay huevo activo en ese nido.
--   · El huevo ya está listo.
--   · El jugador no tiene el boost en su inventario.
-- Devuelve: (éxito, { nuevoReadyAt, secondsLeft } o mensaje de error)
--------------------------------------------------------------------------------
function EggService.ApplyIncubationBoost(player, nestIndex)
    local uid  = player.UserId
    local nido = eggs[uid] and eggs[uid][nestIndex]

    if not nido then
        return false, "No hay ningún huevo en ese nido."
    end

    local ahora = os.time()
    if ahora >= nido.readyAt then
        return false, "El huevo ya está listo; recógelo primero."
    end

    -- Verificar que el jugador tiene el boost en su inventario
    local datos = DataStore.GetPlayerData(player)
    if not datos then
        return false, "No se pudieron leer tus datos."
    end

    local cantBoost = datos.boosts and datos.boosts[BOOST_ID_INCUBATION] or 0
    if cantBoost <= 0 then
        return false, ("No tienes ningún '%s' en tu inventario de boosts."):format(BOOST_ID_INCUBATION)
    end

    -- Consumir el boost
    datos.boosts[BOOST_ID_INCUBATION] = cantBoost - 1
    if datos.boosts[BOOST_ID_INCUBATION] == 0 then
        datos.boosts[BOOST_ID_INCUBATION] = nil
    end

    -- Reducir el tiempo restante a la mitad (redondeando hacia abajo)
    local restante      = nido.readyAt - ahora
    local nuevoRestante = math.max(0, math.floor(restante / 2))
    nido.readyAt        = ahora + nuevoRestante

    -- Si el boost lo dejó en 0, marcar como listo ya
    local isReady = nuevoRestante == 0

    if isReady then
        -- Avisar inmediatamente al cliente que está listo
        EggReadyEvent:FireClient(player, {
            nestIndex   = nestIndex,
            dragonId    = nido.dragonId,
            guaranteed  = nido.guaranteed,
            collected   = false,   -- el jugador aún debe recogerlo
        })
    end

    return true, {
        nuevoReadyAt = nido.readyAt,
        secondsLeft  = nuevoRestante,
        isReady      = isReady,
    }
end

--------------------------------------------------------------------------------
-- EggService.GetAllEggStatuses(player)
--
-- Devuelve el estado completo de todos los huevos activos en nidos
-- y todos los huevos en el inventario del jugador.
-- Se llama al cargar para sincronizar el cliente con el estado del servidor.
--------------------------------------------------------------------------------
function EggService.GetAllEggStatuses(player)
    local uid   = player.UserId
    local ahora = os.time()

    -- Huevos activos en nidos
    local nidosActivos = {}
    if eggs[uid] then
        for nestIndex, nido in pairs(eggs[uid]) do
            nidosActivos[nestIndex] = {
                dragonId    = nido.dragonId,
                readyAt     = nido.readyAt,
                secondsLeft = math.max(0, nido.readyAt - ahora),
                isReady     = ahora >= nido.readyAt,
                guaranteed  = nido.guaranteed,
            }
        end
    end

    -- Huevos en inventario (pendientes de incubar o vender)
    local inventarioResumen = {}
    if eggInventory[uid] then
        for eggIndex, huevo in pairs(eggInventory[uid]) do
            local parentDragon = DragonData.GetDragonById(huevo.dragonId)
            inventarioResumen[eggIndex] = {
                dragonId    = huevo.dragonId,
                dragonName  = parentDragon and parentDragon.name or huevo.dragonId,
                element     = parentDragon and parentDragon.element or "?",
                parentRareza = parentDragon and parentDragon.rarity or "?",
                guaranteed  = huevo.guaranteed,
                collectedAt = huevo.collectedAt,
                -- Tabla de probabilidades precalculada para la UI
                probabilidades = ajustarProbabilidades(
                    parentDragon and parentDragon.rarity or "comun",
                    huevo.guaranteed
                ),
            }
        end
    end

    return {
        nidos      = nidosActivos,
        inventario = inventarioResumen,
    }
end

--------------------------------------------------------------------------------
-- Loop principal — revisa huevos listos cada 5 segundos
--
-- Cuando un huevo llega a readyAt, dispara "EggReady" al cliente para que
-- muestre la notificación. El jugador aún debe tocar el nido para recogerlo
-- (CollectEgg). El loop NO recolecta automáticamente.
--------------------------------------------------------------------------------

task.spawn(function()
    local TICK_RATE = 5

    while true do
        task.wait(TICK_RATE)

        local ahora = os.time()

        for _, player in ipairs(Players:GetPlayers()) do
            local uid = player.UserId
            if eggs[uid] then
                for nestIndex, nido in pairs(eggs[uid]) do
                    if ahora >= nido.readyAt then
                        -- Notificar al cliente que puede recoger el huevo
                        EggReadyEvent:FireClient(player, {
                            nestIndex   = nestIndex,
                            dragonId    = nido.dragonId,
                            guaranteed  = nido.guaranteed,
                            collected   = false,
                        })
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- EggService.GetNestStatus(player)
-- Devuelve { [nestIndex] = dragonId | nil } para todos los slots del jugador.
-- Usado por el cliente para seleccionar un nido vacío tras el reveal.
--------------------------------------------------------------------------------
function EggService.GetNestStatus(player)
    local nestData = NestSystem.GetNestData(player)
    if not nestData then return {} end
    local status = {}
    -- Incluir todos los slots, usando false para los vacíos (nil no se serializa)
    for i = 1, nestData.slots do
        local nido = nestData.nests[i]
        status[i] = (nido and nido.dragonId) or false
    end
    return status
end

--------------------------------------------------------------------------------
-- EggService.CancelEggTimer(player, nestIndex)
-- Cancela el timer de huevo activo en un nido.
-- Devuelve: { ok, message }
--------------------------------------------------------------------------------
function EggService.CancelEggTimer(player, nestIndex)
    local uid = player.UserId
    if not (eggs[uid] and eggs[uid][nestIndex]) then
        return { ok = false, error = "No hay huevo activo en ese nido." }
    end
    eggs[uid][nestIndex] = nil
    return { ok = true }
end

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
-- El servidor valida SIEMPRE; el cliente solo informa qué quiere hacer.
--------------------------------------------------------------------------------

-- Recoger un huevo listo del nido
CollectEggFunc.OnServerInvoke = function(player, nestIndex)
    if type(nestIndex) ~= "number" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    local result = EggService.CollectEgg(player, nestIndex)
    -- CollectEgg ya retorna un solo table con ok=true/false
    if type(result) == "table" then return result end
    return { ok = false, error = tostring(result) }
end

-- Iniciar incubación de un huevo del inventario
StartIncubationFunc.OnServerInvoke = function(player, eggIndex)
    if type(eggIndex) ~= "number" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    local ok, data = EggService.IncubateEgg(player, eggIndex)
    if ok then
        return { ok = true, dragonId = data.dragonId, rareza = data.rareza,
                 probabilidades = data.probabilidades }
    end
    return { ok = false, error = tostring(data) }
end

-- Vender un huevo (desde el nido o desde el inventario)
SellEggFunc.OnServerInvoke = function(player, index)
    if type(index) ~= "number" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    -- Intentar vender desde nido primero (index = nestIndex)
    local uid = player.UserId
    if eggs[uid] and eggs[uid][index] then
        local nido = eggs[uid][index]
        local parentDragon = DragonData.GetDragonById(nido.dragonId)
        if not parentDragon then
            eggs[uid][index] = nil
            return { ok = false, error = "Huevo con datos inválidos descartado." }
        end
        local goldGained = math.floor(parentDragon.goldPerSecond * SELL_BASE_FACTOR * SELL_MULTIPLIER)
        eggs[uid][index] = nil
        DataStore.AddGold(player, goldGained)
        EggService.StartEggTimer(player, index, nido.dragonId)
        return { ok = true, goldGained = goldGained }
    end
    -- Fallback: vender desde inventario (index = eggIndex)
    local ok, data = EggService.SellEgg(player, index)
    if ok then
        return { ok = true, goldGained = data.oroGanado }
    end
    return { ok = false, error = tostring(data) }
end

-- Acelerar el timer del huevo en un nido con boost
SpeedUpIncubationFunc.OnServerInvoke = function(player, nestIndex)
    if type(nestIndex) ~= "number" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    local ok, data = EggService.ApplyIncubationBoost(player, nestIndex)
    if ok then
        return { ok = true, nuevoReadyAt = data.nuevoReadyAt, secondsLeft = data.secondsLeft }
    end
    return { ok = false, error = tostring(data) }
end

-- Estado de ocupación de todos los nidos
GetNestStatusFunc.OnServerInvoke = function(player)
    return EggService.GetNestStatus(player)
end

-- Cancelar timer de huevo en un nido
CancelIncubationFunc.OnServerInvoke = function(player, nestIndex)
    if type(nestIndex) ~= "number" then
        return { ok = false, error = "Parámetros inválidos." }
    end
    return EggService.CancelEggTimer(player, nestIndex)
end

-- Confirmar guardado en inventario (el dragón ya fue agregado por IncubateEgg)
SaveToInventoryFunc.OnServerInvoke = function(player, _dragonId)
    return { ok = true }
end

-- Estado completo de huevos (nidos activos + inventario) para el InventoryGUI
GetAllEggStatusesFunc.OnServerInvoke = function(player)
    return EggService.GetAllEggStatuses(player)
end

--------------------------------------------------------------------------------
-- Ciclo de vida de jugadores
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
    asegurarEstado(player.UserId)
end)

Players.PlayerRemoving:Connect(function(player)
    local uid = player.UserId
    eggs[uid]         = nil
    eggInventory[uid] = nil
    eggNextIndex[uid] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
    asegurarEstado(player.UserId)
end

--------------------------------------------------------------------------------

return EggService
