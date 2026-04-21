--------------------------------------------------------------------------------
-- ShopService.lua  ·  Módulo de servidor  ·  Dragon Roost
--
-- Gestiona dos tiendas independientes con rotación automática:
--
--   TIENDA RÁPIDA  — 6 slots, rota cada 180 s. Solo dragones y huevos.
--                    Stock 1-3 por slot. Filtrada por nivel del jugador.
--
--   TIENDA ESPECIAL — 4 slots, rota cada 600 s. Nunca dragones.
--                     Stock 1 por slot. Items especiales (mejoras, boosts,
--                     recetas, eventos climáticos, cosméticos).
--
-- ARQUITECTURA:
--   · Los items de tienda se generan en el servidor al rotar. Se guardan en
--     tablas locales y se envían a todos los clientes via RemoteEvents.
--   · Las compras se validan en servidor; el cliente solo solicita.
--   · Al rotar, el tiempo de siguiente rotación se transmite para que el
--     cliente muestre un countdown preciso.
--   · "Evento climático" comprado → el jugador recibe un activable en sus datos.
--     Al usarlo, RequestActivarEvento llama WeatherSystem.ActivarEvento().
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants     = require(ReplicatedStorage:WaitForChild("Constants"))
local DragonData    = require(ReplicatedStorage:WaitForChild("DragonData"))
local DataStore     = require(ServerScriptService:WaitForChild("DataStore"))
local WeatherSystem = require(ServerScriptService:WaitForChild("WeatherSystem"))

local TIENDA_RAPIDA   = Constants.TIENDA_RAPIDA
local TIENDA_ESPECIAL = Constants.TIENDA_ESPECIAL
local RARIDADES       = Constants.RARIDADES
local LEVELS          = Constants.LEVELS

--------------------------------------------------------------------------------
-- Configuración de precios base por rareza (Tienda Rápida)
--------------------------------------------------------------------------------

local PRECIOS_RAREZA = {
    comun         = 500,
    poco_comun    = 1_500,
    raro          = 5_000,
    epico         = 20_000,
    legendario    = 80_000,
    mitico        = 300_000,
}

local PRECIO_HUEVO_BASE = 2_500  -- huevo misterioso

--------------------------------------------------------------------------------
-- Pool de items para Tienda Especial
--------------------------------------------------------------------------------

local ITEMS_ESPECIALES = {
    -- Mejoras de nido
    { tipo = "mejora_nido", variante = "10",  nombre = "Mejora de Nido +10%",    descripcion = "Aumenta la producción de todos tus nidos un 10% durante 24 h.", precio = 50,  moneda = "gemas" },
    { tipo = "mejora_nido", variante = "25",  nombre = "Mejora de Nido +25%",    descripcion = "Aumenta la producción de todos tus nidos un 25% durante 24 h.", precio = 120, moneda = "gemas" },
    { tipo = "mejora_nido", variante = "50",  nombre = "Mejora de Nido +50%",    descripcion = "Aumenta la producción de todos tus nidos durante 24 h.",        precio = 250, moneda = "gemas" },
    -- Potenciadores de tiempo limitado
    { tipo = "boost", variante = "x2_1h",    nombre = "Potenciador ×2 (1 h)",    descripcion = "Duplica tu producción de oro durante 1 hora.",             precio = 30,  moneda = "gemas" },
    { tipo = "boost", variante = "x3_30min", nombre = "Potenciador ×3 (30 min)", descripcion = "Triplica tu producción de oro durante 30 minutos.",         precio = 45,  moneda = "gemas" },
    -- Activables de evento climático
    { tipo = "evento_clima", variante = "sol_dorado",         nombre = "Sol Dorado",          descripcion = "Activa el Sol Dorado: bonus a fuego y naturaleza.",    precio = 80,  moneda = "gemas" },
    { tipo = "evento_clima", variante = "lluvia_magica",      nombre = "Lluvia Mágica",       descripcion = "Activa la Lluvia Mágica: bonus a agua y hielo.",        precio = 80,  moneda = "gemas" },
    { tipo = "evento_clima", variante = "erupcion_volcanica", nombre = "Erupción Volcánica",  descripcion = "Activa la Erupción Volcánica: gran bonus a fuego.",     precio = 100, moneda = "gemas" },
    { tipo = "evento_clima", variante = "tormenta_electrica", nombre = "Tormenta Eléctrica",  descripcion = "Activa la Tormenta Eléctrica: bonus a trueno.",          precio = 100, moneda = "gemas" },
    { tipo = "evento_clima", variante = "noche_eterna",       nombre = "Noche Eterna",        descripcion = "Activa la Noche Eterna: bonus a sombra y celestial.",   precio = 120, moneda = "gemas" },
    { tipo = "evento_clima", variante = "rift_dimensional",   nombre = "Rift Dimensional",    descripcion = "Activa el Rift Dimensional: bonus masivo a todos.",       precio = 150, moneda = "gemas" },
    -- Recetas de breeding
    { tipo = "receta", variante = "agua_fuego",        nombre = "Receta: Agua+Fuego",        descripcion = "Desbloquea la receta agua+fuego en el Breeding Pen.",        precio = 200, moneda = "gemas" },
    { tipo = "receta", variante = "agua_hielo",        nombre = "Receta: Agua+Hielo",        descripcion = "Desbloquea la receta agua+hielo en el Breeding Pen.",        precio = 200, moneda = "gemas" },
    { tipo = "receta", variante = "naturaleza_trueno", nombre = "Receta: Naturaleza+Trueno", descripcion = "Desbloquea la receta naturaleza+trueno en el Breeding Pen.", precio = 200, moneda = "gemas" },
    { tipo = "receta", variante = "fuego_vacio",       nombre = "Receta: Fuego+Vacío",       descripcion = "Desbloquea la receta fuego+vacío en el Breeding Pen.",       precio = 200, moneda = "gemas" },
    { tipo = "receta", variante = "celestial_hielo",   nombre = "Receta: Celestial+Hielo",   descripcion = "Desbloquea la receta celestial+hielo en el Breeding Pen.",   precio = 250, moneda = "gemas" },
    { tipo = "receta", variante = "celestial_sombra",  nombre = "Receta: Celestial+Sombra",  descripcion = "Desbloquea la receta celestial+sombra en el Breeding Pen.",  precio = 300, moneda = "gemas" },
    -- Cosméticos de nido
    { tipo = "cosmetico", variante = "nido_dorado",  nombre = "Nido Dorado",    descripcion = "Cambia la apariencia de tus nidos al estilo dorado.",  precio = 500, moneda = "gemas" },
    { tipo = "cosmetico", variante = "nido_cristal", nombre = "Nido de Cristal", descripcion = "Cambia la apariencia de tus nidos al estilo cristal.", precio = 700, moneda = "gemas" },
    -- Boosts de dragón (van al inventario; se aplican manualmente desde la UI)
    { tipo = "boost_dragon", variante = "festin",    nombre = "Festín",    descripcion = "×1.5 producción en un nido durante 30 min.", precio = 3,  moneda = "gemas" },
    { tipo = "boost_dragon", variante = "cristal",   nombre = "Cristal",   descripcion = "×2.0 producción en un nido durante 1 hora.", precio = 8,  moneda = "gemas" },
    { tipo = "boost_dragon", variante = "runa",      nombre = "Runa",      descripcion = "×3.0 producción en un nido durante 15 min.", precio = 15, moneda = "gemas" },
    { tipo = "boost_dragon", variante = "bendicion", nombre = "Bendición", descripcion = "×1.25 producción en toda la granja durante 1 hora.", precio = 20, moneda = "gemas" },
    { tipo = "boost_dragon", variante = "corona",    nombre = "Corona",    descripcion = "×5.0 producción en un nido durante 10 min.", precio = 30, moneda = "gemas" },
}

--------------------------------------------------------------------------------
-- Estado de las tiendas
--------------------------------------------------------------------------------

local slotsRapida         = {}   -- { tipo, dragonId, nombre, rareza, precio, moneda, stock, stockMax }
local slotsEspecial       = {}   -- { tipo, variante, nombre, descripcion, precio, moneda, stock, stockMax }

local proximaRotacionRapida   = 0
local proximaRotacionEspecial = 0

-- stockCompradoRapida[slotIndex][userId]   = cantidadComprada
-- stockCompradoEspecial[slotIndex][userId] = cantidadComprada
local stockCompradoRapida   = {}
local stockCompradoEspecial = {}

--------------------------------------------------------------------------------
-- Índice de rareza
--------------------------------------------------------------------------------

local RARITY_RANK = {}
for i, r in ipairs(RARIDADES.Orden) do RARITY_RANK[r] = i end

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

local TiendaRapidaActualizadaEvent   = obtenerOCrear("RemoteEvent",   "TiendaRapidaActualizada")
local TiendaEspecialActualizadaEvent = obtenerOCrear("RemoteEvent",   "TiendaEspecialActualizada")
local PurchaseCompletedEvent         = obtenerOCrear("RemoteEvent",   "PurchaseCompleted")
local ComprarRapidaFunc              = obtenerOCrear("RemoteFunction", "RequestComprarTiendaRapida")
local ComprarEspecialFunc            = obtenerOCrear("RemoteFunction", "RequestComprarTiendaEspecial")
local ActivarEventoFunc              = obtenerOCrear("RemoteFunction", "RequestActivarEvento")

--------------------------------------------------------------------------------
-- Helpers de generación
--------------------------------------------------------------------------------

-- Rareza máxima habilitada para el nivel del jugador.
local function rarezaMaxParaNivel(nivel)
    local levelData = LEVELS[nivel]
    return levelData and levelData.shopMaxRarity or "comun"
end

-- Dragones disponibles para la tienda filtrados por rareza máxima.
local function elegirDragonParaTienda(rarezaMax)
    local maxRank    = RARITY_RANK[rarezaMax] or 1
    local candidatos = {}
    for _, d in ipairs(DragonData.Dragons) do
        local rango = RARITY_RANK[d.rarity] or 1
        if rango <= maxRank and not d.soloCria and not d.soloEvento then
            table.insert(candidatos, d)
        end
    end
    if #candidatos == 0 then return nil end
    return candidatos[math.random(#candidatos)]
end

-- Genera un slot de tienda rápida (70 % dragón, 30 % huevo).
-- rarezaMax = rareza máxima del pool (puede ser "mitico" para generar todo y filtrar al entregar).
local function generarSlotRapido(rarezaMax)
    if math.random() < 0.70 then
        local d = elegirDragonParaTienda(rarezaMax)
        if not d then return nil end
        local stockMax = math.random(1, TIENDA_RAPIDA.StockMax)
        return {
            tipo     = "dragon",
            dragonId = d.id,
            nombre   = d.name,
            rareza   = d.rarity,
            elemento = d.element,
            precio   = PRECIOS_RAREZA[d.rarity] or PRECIOS_RAREZA["comun"],
            moneda   = "oro",
            stock    = stockMax,
            stockMax = stockMax,
        }
    else
        local stockMax = math.random(1, TIENDA_RAPIDA.StockMax)
        return {
            tipo     = "huevo",
            nombre   = "Huevo Misterioso",
            rareza   = nil,
            precio   = PRECIO_HUEVO_BASE,
            moneda   = "oro",
            stock    = stockMax,
            stockMax = stockMax,
        }
    end
end

-- Selecciona ConteoSlots items aleatorios del pool especial (sin repetir variante).
local function generarSlotsEspeciales()
    -- Copiar y mezclar el pool
    local pool = {}
    for _, item in ipairs(ITEMS_ESPECIALES) do
        table.insert(pool, item)
    end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    local slots = {}
    for i = 1, math.min(TIENDA_ESPECIAL.ConteoSlots, #pool) do
        local item = pool[i]
        table.insert(slots, {
            tipo        = item.tipo,
            variante    = item.variante,
            nombre      = item.nombre,
            descripcion = item.descripcion,
            precio      = item.precio,
            moneda      = item.moneda,
            stock       = TIENDA_ESPECIAL.StockMax,
            stockMax    = TIENDA_ESPECIAL.StockMax,
        })
    end
    return slots
end

-- Construye el payload de tienda rápida filtrado por el nivel del jugador.
local function payloadRapidaParaJugador(player)
    local uid       = player.UserId
    local datos     = DataStore.GetPlayerData(player)
    local nivel     = datos and datos.level or 1
    local rarezaMax = rarezaMaxParaNivel(nivel)
    local maxRank   = RARITY_RANK[rarezaMax] or 1

    local slotsVisibles = {}
    for i, slot in ipairs(slotsRapida) do
        local rango = slot.rareza and (RARITY_RANK[slot.rareza] or 1) or 1
        if rango <= maxRank or slot.tipo == "huevo" then
            local comprado = (stockCompradoRapida[i] and stockCompradoRapida[i][uid]) or 0
            local copia    = {}
            for k, v in pairs(slot) do copia[k] = v end
            copia.slotIndex       = i
            copia.stockDisponible = math.max(0, slot.stock - comprado)
            table.insert(slotsVisibles, copia)
        end
    end

    return {
        slots             = slotsVisibles,
        proximaRotacion   = proximaRotacionRapida,
        segundosRestantes = math.max(0, proximaRotacionRapida - os.time()),
    }
end

-- Payload de tienda especial (igual para todos los jugadores).
local function payloadEspecialParaJugador(player)
    local uid   = player.UserId
    local slots = {}
    for i, slot in ipairs(slotsEspecial) do
        local comprado = (stockCompradoEspecial[i] and stockCompradoEspecial[i][uid]) or 0
        local copia    = {}
        for k, v in pairs(slot) do copia[k] = v end
        copia.slotIndex       = i
        copia.stockDisponible = math.max(0, slot.stock - comprado)
        table.insert(slots, copia)
    end
    return {
        slots             = slots,
        proximaRotacion   = proximaRotacionEspecial,
        segundosRestantes = math.max(0, proximaRotacionEspecial - os.time()),
    }
end

--------------------------------------------------------------------------------
-- Rotación de tiendas
--------------------------------------------------------------------------------

local function rotarTiendaRapida()
    slotsRapida         = {}
    stockCompradoRapida = {}

    for i = 1, TIENDA_RAPIDA.ConteoSlots do
        -- Generamos con rareza máxima; el filtro por nivel se aplica al entregar
        local slot = generarSlotRapido("mitico")
        if slot then
            slotsRapida[i]         = slot
            stockCompradoRapida[i] = {}
        end
    end

    -- Garantizar al menos 1 dragón de rareza "comun" visible para todos los niveles
    local hayDragonComun = false
    for i = 1, TIENDA_RAPIDA.ConteoSlots do
        local s = slotsRapida[i]
        if s and s.tipo == "dragon" and s.rareza == "comun" then hayDragonComun = true; break end
    end
    if not hayDragonComun then
        -- Forzar un dragón común en el slot 1; "comun" pasa el filtro de todos los niveles
        local d = elegirDragonParaTienda("comun")
        if d then
            slotsRapida[1] = {
                tipo     = "dragon",
                dragonId = d.id,
                nombre   = d.name,
                rareza   = d.rarity,
                elemento = d.element,
                precio   = PRECIOS_RAREZA[d.rarity] or PRECIOS_RAREZA["comun"],
                moneda   = "oro",
                stock    = 1,
                stockMax = 1,
            }
            stockCompradoRapida[1] = {}
        end
    end

    proximaRotacionRapida = os.time() + TIENDA_RAPIDA.SegundosRotacion

    -- Enviar a cada jugador su payload filtrado
    for _, player in ipairs(Players:GetPlayers()) do
        TiendaRapidaActualizadaEvent:FireClient(player, payloadRapidaParaJugador(player))
    end

    print(("[ShopService] Tienda Rápida rotada. Próxima en %d s."):format(TIENDA_RAPIDA.SegundosRotacion))
end

local function rotarTiendaEspecial()
    slotsEspecial         = generarSlotsEspeciales()
    stockCompradoEspecial = {}
    for i = 1, #slotsEspecial do
        stockCompradoEspecial[i] = {}
    end

    proximaRotacionEspecial = os.time() + TIENDA_ESPECIAL.SegundosRotacion

    local payload = {
        slots             = slotsEspecial,
        proximaRotacion   = proximaRotacionEspecial,
        segundosRestantes = 0,  -- recién rotó
    }
    TiendaEspecialActualizadaEvent:FireAllClients(payload)

    print(("[ShopService] Tienda Especial rotada. Próxima en %d s."):format(TIENDA_ESPECIAL.SegundosRotacion))
end

--------------------------------------------------------------------------------
-- Lógica de compra — Tienda Rápida
--------------------------------------------------------------------------------

local function procesarCompraRapida(player, slotIndex)
    if type(slotIndex) ~= "number" then
        return false, "Parámetros inválidos."
    end

    local slot = slotsRapida[slotIndex]
    if not slot then
        return false, "Slot no disponible."
    end

    -- Verificar stock global del slot
    local compradoGlobal = 0
    if stockCompradoRapida[slotIndex] then
        for _, c in pairs(stockCompradoRapida[slotIndex]) do
            compradoGlobal = compradoGlobal + c
        end
    end
    if compradoGlobal >= slot.stock then
        return false, "Este item está agotado."
    end

    -- Validar rareza según nivel del jugador
    local datos = DataStore.GetPlayerData(player)
    if not datos then return false, "No se pudieron leer tus datos." end

    if slot.rareza then
        local nivel     = datos.level or 1
        local rarezaMax = rarezaMaxParaNivel(nivel)
        if (RARITY_RANK[slot.rareza] or 1) > (RARITY_RANK[rarezaMax] or 1) then
            return false, ("Tu nivel de prestige no permite comprar rareza '%s'."):format(slot.rareza)
        end
    end

    -- Verificar espacio en inventario antes de cobrar
    if slot.tipo == "dragon" and DataStore.IsInventoryFull(player) then
        return false, "Inventario lleno — vendé o colocá dragones en nidos para hacer espacio."
    end

    -- Cobrar
    if slot.moneda == "oro" then
        if not DataStore.SpendGold(player, slot.precio) then
            return false, ("Necesitas %d de oro."):format(slot.precio)
        end
    elseif slot.moneda == "gemas" then
        if not DataStore.SpendGems(player, slot.precio) then
            return false, ("Necesitas %d gemas."):format(slot.precio)
        end
    end

    -- Registrar compra
    local uid = player.UserId
    stockCompradoRapida[slotIndex]      = stockCompradoRapida[slotIndex] or {}
    stockCompradoRapida[slotIndex][uid] = (stockCompradoRapida[slotIndex][uid] or 0) + 1

    -- Entregar
    if slot.tipo == "dragon" then
        DataStore.AddDragonToInventory(player, slot.dragonId)
        PurchaseCompletedEvent:FireClient(player, { tipo = "dragon", dragonId = slot.dragonId, rareza = slot.rareza, nombre = slot.nombre })
        return true, { mensaje = ("¡Compraste a %s!"):format(slot.nombre), tipo = "dragon", dragonId = slot.dragonId }
    elseif slot.tipo == "huevo" then
        local datosLive = DataStore.GetPlayerData(player)
        if datosLive then
            datosLive.boosts                       = datosLive.boosts or {}
            datosLive.boosts["huevo_pendiente"]    = (datosLive.boosts["huevo_pendiente"] or 0) + 1
        end
        return true, { mensaje = "¡Compraste un Huevo Misterioso!", tipo = "huevo" }
    end

    return false, "Tipo de item desconocido."
end

--------------------------------------------------------------------------------
-- Lógica de compra — Tienda Especial
--------------------------------------------------------------------------------

local function procesarCompraEspecial(player, slotIndex)
    if type(slotIndex) ~= "number" then
        return false, "Parámetros inválidos."
    end

    local slot = slotsEspecial[slotIndex]
    if not slot then
        return false, "Slot no disponible."
    end

    local uid       = player.UserId
    local comprado  = (stockCompradoEspecial[slotIndex] and stockCompradoEspecial[slotIndex][uid]) or 0
    if comprado >= slot.stockMax then
        return false, "Ya compraste este item en esta rotación."
    end

    -- Cobrar gemas
    if not DataStore.SpendGems(player, slot.precio) then
        return false, ("Necesitas %d gemas para '%s'."):format(slot.precio, slot.nombre)
    end

    stockCompradoEspecial[slotIndex]      = stockCompradoEspecial[slotIndex] or {}
    stockCompradoEspecial[slotIndex][uid] = comprado + 1

    local datos = DataStore.GetPlayerData(player)
    if not datos then return false, "No se pudieron aplicar los datos." end
    datos.boosts = datos.boosts or {}

    if slot.tipo == "mejora_nido" then
        local clave = "mejora_nido_" .. slot.variante
        datos.boosts[clave] = (datos.boosts[clave] or 0) + 1
        return true, { mensaje = ("¡%s aplicada!"):format(slot.nombre), tipo = "mejora_nido" }

    elseif slot.tipo == "boost" then
        datos.boosts[slot.variante] = (datos.boosts[slot.variante] or 0) + 1
        return true, { mensaje = ("¡%s activado!"):format(slot.nombre), tipo = "boost" }

    elseif slot.tipo == "evento_clima" then
        local clave = "evento_activable_" .. slot.variante
        datos.boosts[clave] = (datos.boosts[clave] or 0) + 1
        return true, {
            mensaje  = ("¡Obtuviste un activable: %s!"):format(slot.nombre),
            tipo     = "evento_clima",
            variante = slot.variante,
        }

    elseif slot.tipo == "receta" then
        datos.knownRecipes                = datos.knownRecipes or {}
        datos.knownRecipes[slot.variante] = true
        return true, { mensaje = ("¡Receta '%s' desbloqueada!"):format(slot.nombre), tipo = "receta" }

    elseif slot.tipo == "cosmetico" then
        datos.boosts["cosmetico_" .. slot.variante] = true
        return true, { mensaje = ("¡Cosmético '%s' desbloqueado!"):format(slot.nombre), tipo = "cosmetico" }

    elseif slot.tipo == "boost_dragon" then
        datos.boosts[slot.variante] = (datos.boosts[slot.variante] or 0) + 1
        return true, {
            mensaje  = ("¡%s añadida al inventario! Aplícala desde un nido."):format(slot.nombre),
            tipo     = "boost_dragon",
            variante = slot.variante,
        }
    end

    return false, "Tipo de item especial desconocido."
end

--------------------------------------------------------------------------------
-- Lógica de activar evento climático
--------------------------------------------------------------------------------

local function procesarActivarEvento(player, tipoEvento)
    if type(tipoEvento) ~= "string" then
        return false, "Tipo de evento inválido."
    end

    local datos = DataStore.GetPlayerData(player)
    if not datos then return false, "No se pudieron leer tus datos." end

    local clave    = "evento_activable_" .. tipoEvento
    local cantidad = (datos.boosts and datos.boosts[clave]) or 0

    if cantidad <= 0 then
        return false, ("No tienes ningún activable de '%s'."):format(tipoEvento)
    end

    local exito = WeatherSystem.ActivarEvento(tipoEvento)
    if not exito then
        return false, ("No se pudo activar '%s'. Puede que haya otro evento activo."):format(tipoEvento)
    end

    datos.boosts[clave] = cantidad - 1
    return true, { mensaje = ("¡Evento '%s' activado!"):format(tipoEvento) }
end

--------------------------------------------------------------------------------
-- ShopService
--------------------------------------------------------------------------------

local ShopService = {}

function ShopService.GetTiendaRapida(player)
    return payloadRapidaParaJugador(player)
end

function ShopService.GetTiendaEspecial(player)
    return payloadEspecialParaJugador(player)
end

--------------------------------------------------------------------------------
-- ShopService.Init() — inicializa ambas tiendas y arranca los loops
--------------------------------------------------------------------------------
function ShopService.Init()
    rotarTiendaRapida()
    rotarTiendaEspecial()

    task.spawn(function()
        while true do
            task.wait(TIENDA_RAPIDA.SegundosRotacion)
            rotarTiendaRapida()
        end
    end)

    task.spawn(function()
        while true do
            task.wait(TIENDA_ESPECIAL.SegundosRotacion)
            rotarTiendaEspecial()
        end
    end)

    print("[ShopService] Tiendas inicializadas.")
end

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
--------------------------------------------------------------------------------

ComprarRapidaFunc.OnServerInvoke = function(player, slotIndex)
    return procesarCompraRapida(player, slotIndex)
end

ComprarEspecialFunc.OnServerInvoke = function(player, slotIndex)
    return procesarCompraEspecial(player, slotIndex)
end

ActivarEventoFunc.OnServerInvoke = function(player, tipoEvento)
    return procesarActivarEvento(player, tipoEvento)
end

--------------------------------------------------------------------------------
-- Enviar estado inicial al jugador al conectarse
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
    task.delay(2, function()
        if not player.Parent then return end
        TiendaRapidaActualizadaEvent:FireClient(player, payloadRapidaParaJugador(player))
        TiendaEspecialActualizadaEvent:FireClient(player, payloadEspecialParaJugador(player))
    end)
end)

--------------------------------------------------------------------------------

return ShopService
