--------------------------------------------------------------------------------
-- BoostSystem.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona los boosts de producción por nido/granja para los jugadores.
-- Los boosts se adquieren en la Tienda Especial y se almacenan en data.boosts.
-- Al aplicarse, modifican el multiplicador de oro en DragonService.
--
-- Estructura de data.boosts (tabla plana, igual que el resto del ShopService):
--   data.boosts[boostId] = count   ← inventario (escrito por ShopService)
--   data.boosts._activos = {       ← estado activo (escrito por BoostSystem)
--       [nestIndex] = { boostId, expiraEn, multiplicador }
--   }
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants     = require(ReplicatedStorage:WaitForChild("Constants"))
local NestSystem    = require(ServerScriptService:WaitForChild("NestSystem"))
local DragonService = require(ServerScriptService:WaitForChild("DragonService"))

local BOOST_TYPES   = Constants.BOOST_TYPES

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

local BoostAplicadoEvent           = obtenerOCrear("RemoteEvent",    "BoostAplicado")
local BoostExpiradoEvent           = obtenerOCrear("RemoteEvent",    "BoostExpirado")
local RequestAplicarBoostFunc      = obtenerOCrear("RemoteFunction", "RequestAplicarBoost")
local RequestAplicarBoostAutoFunc  = obtenerOCrear("RemoteFunction", "RequestAplicarBoostAuto")
local RequestBoostInventarioFunc   = obtenerOCrear("RemoteFunction", "RequestBoostInventario")

--------------------------------------------------------------------------------
-- Estado interno — referencia a data.boosts de cada jugador
--------------------------------------------------------------------------------

local boostRefs = {}   -- boostRefs[userId] = referencia a data.boosts del jugador

local function getBoosts(player)
    return boostRefs[player.UserId]
end

--------------------------------------------------------------------------------
-- BoostSystem.InitPlayer(player, savedBoosts)
--
-- Llamado por DataStore.LoadPlayer después de NestSystem.InitPlayer.
-- Guarda referencia a data.boosts y restaura boosts activos que no hayan expirado.
--------------------------------------------------------------------------------
local BoostSystem = {}

function BoostSystem.InitPlayer(player, savedBoosts)
    local uid = player.UserId
    savedBoosts = savedBoosts or {}
    savedBoosts._activos = savedBoosts._activos or {}
    boostRefs[uid] = savedBoosts

    -- Restaurar boosts activos que siguen vigentes
    local ahora = os.time()
    for nestIndex, entrada in pairs(savedBoosts._activos) do
        if entrada.expiraEn > ahora then
            NestSystem.ApplyBoost(player, nestIndex, entrada.boostId, entrada.multiplicador, entrada.expiraEn)
            DragonService.SetMultiplier(player, nestIndex, entrada.multiplicador)
        else
            -- Expiró mientras el jugador estuvo fuera; limpiar sin efecto secundario
            savedBoosts._activos[nestIndex] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Función interna para boost de alcance "granja"
-- Aplica el boost a todos los nidos con dragón que no tengan ya un boost activo.
-- Devuelve (ok, mensaje).
--------------------------------------------------------------------------------
local function aplicarBoostGranja(player, boostId, boostDef)
    local bs    = getBoosts(player)
    if not bs then return false, "Estado de boost no encontrado." end

    if (bs[boostId] or 0) < 1 then
        return false, "No tienes ese boost en el inventario."
    end

    local nestData = NestSystem.GetNestData(player)
    if not nestData then return false, "No se pudieron obtener los nidos." end

    local ahora     = os.time()
    local expiraEn  = ahora + boostDef.duracionSeg
    local aplicados = 0

    for nestIndex = 1, nestData.slots do
        local nido = nestData.nests[nestIndex]
        if nido and nido.dragonId then
            local activo = bs._activos[nestIndex]
            -- Solo aplicar si no hay boost activo en ese nido
            if not activo or activo.expiraEn <= ahora then
                bs._activos[nestIndex] = {
                    boostId       = boostId,
                    expiraEn      = expiraEn,
                    multiplicador = boostDef.multiplicador,
                }
                NestSystem.ApplyBoost(player, nestIndex, boostId, boostDef.multiplicador, expiraEn)
                aplicados += 1
            end
        end
    end

    if aplicados == 0 then
        return false, "No hay nidos disponibles (vacíos o ya tienen boost activo)."
    end

    -- Descontar del inventario una sola vez
    bs[boostId] = bs[boostId] - 1
    if bs[boostId] <= 0 then bs[boostId] = nil end

    BoostAplicadoEvent:FireClient(player, {
        boostId       = boostId,
        alcance       = "granja",
        expiraEn      = expiraEn,
        multiplicador = boostDef.multiplicador,
        nidosAfectados = aplicados,
    })

    return true, ("¡%s aplicada a %d nidos!"):format(boostDef.nombre, aplicados)
end

--------------------------------------------------------------------------------
-- BoostSystem.AplicarBoost(player, boostId, nestIndex)
--
-- Aplica un boost de alcance "dragon" a un nido específico.
-- Valida inventario, estado del nido y boost activo.
-- Devuelve (ok: boolean, mensaje: string).
--------------------------------------------------------------------------------
function BoostSystem.AplicarBoost(player, boostId, nestIndex)
    local boostDef = BOOST_TYPES[boostId]
    if not boostDef then
        return false, "Boost desconocido: " .. tostring(boostId)
    end

    -- Delegar boosts de granja
    if boostDef.alcance == "granja" then
        return aplicarBoostGranja(player, boostId, boostDef)
    end

    -- Validar nestIndex
    if type(nestIndex) ~= "number" or nestIndex < 1
        or nestIndex ~= math.floor(nestIndex) then
        return false, "Índice de nido inválido."
    end

    local nestData = NestSystem.GetNestData(player)
    if not nestData then return false, "No se pudieron obtener los nidos." end

    if nestIndex > nestData.slots then
        return false, "Ese nido no está desbloqueado."
    end

    local nido = nestData.nests[nestIndex]
    if not nido or not nido.dragonId then
        return false, "El nido no tiene ningún dragón."
    end

    local bs = getBoosts(player)
    if not bs then return false, "Estado de boost no encontrado." end

    if (bs[boostId] or 0) < 1 then
        return false, "No tienes ese boost en el inventario."
    end

    -- Verificar que no hay boost activo
    local ahora  = os.time()
    local activo = bs._activos[nestIndex]
    if activo and activo.expiraEn > ahora then
        local restante = activo.expiraEn - ahora
        return false, ("Ya hay un boost activo en este nido. Expira en %ds."):format(restante)
    end

    -- ✅ Aplicar
    local expiraEn = ahora + boostDef.duracionSeg
    bs[boostId] = bs[boostId] - 1
    if bs[boostId] <= 0 then bs[boostId] = nil end

    bs._activos[nestIndex] = {
        boostId       = boostId,
        expiraEn      = expiraEn,
        multiplicador = boostDef.multiplicador,
    }

    NestSystem.ApplyBoost(player, nestIndex, boostId, boostDef.multiplicador, expiraEn)

    BoostAplicadoEvent:FireClient(player, {
        boostId       = boostId,
        nestIndex     = nestIndex,
        expiraEn      = expiraEn,
        multiplicador = boostDef.multiplicador,
    })

    return true, ("¡%s aplicado al nido %d durante %ds!"):format(
        boostDef.nombre, nestIndex, boostDef.duracionSeg)
end

--------------------------------------------------------------------------------
-- BoostSystem.AplicarBoostAutomatico(player, boostId)
--
-- Aplica el boost al nido sin boost activo con mayor goldPerSecond base.
-- Para alcance "granja" delega a AplicarBoost (que delega internamente).
-- Devuelve (ok: boolean, mensaje: string).
--------------------------------------------------------------------------------
function BoostSystem.AplicarBoostAutomatico(player, boostId)
    local boostDef = BOOST_TYPES[boostId]
    if not boostDef then
        return false, "Boost desconocido: " .. tostring(boostId)
    end

    -- Los boosts de granja no necesitan selección de nido
    if boostDef.alcance == "granja" then
        return aplicarBoostGranja(player, boostId, boostDef)
    end

    local bs = getBoosts(player)
    if not bs then return false, "Estado de boost no encontrado." end

    if (bs[boostId] or 0) < 1 then
        return false, "No tienes ese boost en el inventario."
    end

    local nestData = NestSystem.GetNestData(player)
    if not nestData then return false, "No se pudieron obtener los nidos." end

    local stats   = DragonService.GetFarmStats(player)
    local ahora   = os.time()
    local mejorNido = nil
    local mejorGps  = -1

    for nestIndex = 1, nestData.slots do
        local nido = nestData.nests[nestIndex]
        if nido and nido.dragonId then
            local activo = bs._activos[nestIndex]
            if not activo or activo.expiraEn <= ahora then
                local gps = (stats.gpsPorNido and stats.gpsPorNido[nestIndex]) or 0
                if gps > mejorGps then
                    mejorGps  = gps
                    mejorNido = nestIndex
                end
            end
        end
    end

    if not mejorNido then
        return false, "No hay nidos disponibles sin boost activo."
    end

    return BoostSystem.AplicarBoost(player, boostId, mejorNido)
end

--------------------------------------------------------------------------------
-- BoostSystem.GetBoostsActivos(player)
--
-- Devuelve el estado de boosts activos con tiempo restante por nido.
-- Usado por el cliente (UI) y por DataStore al serializar.
-- Devuelve: { [nestIndex] = { boostId, expiraEn, multiplicador, tiempoRestante } }
--------------------------------------------------------------------------------
function BoostSystem.GetBoostsActivos(player)
    local bs = getBoosts(player)
    if not bs then return {} end

    local ahora   = os.time()
    local activos = {}
    for nestIndex, entrada in pairs(bs._activos or {}) do
        local restante = entrada.expiraEn - ahora
        if restante > 0 then
            activos[nestIndex] = {
                boostId        = entrada.boostId,
                expiraEn       = entrada.expiraEn,
                multiplicador  = entrada.multiplicador,
                tiempoRestante = restante,
            }
        end
    end
    return activos
end

--------------------------------------------------------------------------------
-- BoostSystem.ExpirarBoosts(player)
--
-- Revisa todos los boosts activos del jugador y expira los vencidos.
-- Llamado por el loop principal cada 30 segundos.
--------------------------------------------------------------------------------
function BoostSystem.ExpirarBoosts(player)
    local bs = getBoosts(player)
    if not bs or not bs._activos then return end

    local ahora = os.time()
    for nestIndex, entrada in pairs(bs._activos) do
        if entrada.expiraEn <= ahora then
            bs._activos[nestIndex] = nil
            NestSystem.ClearBoost(player, nestIndex)
            DragonService.ClearMultiplier(player, nestIndex)
            BoostExpiradoEvent:FireClient(player, {
                boostId   = entrada.boostId,
                nestIndex = nestIndex,
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Loop principal — cada 30 segundos expira boosts vencidos de todos los jugadores
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(1)
        for _, player in ipairs(Players:GetPlayers()) do
            local ok, err = pcall(BoostSystem.ExpirarBoosts, player)
            if not ok then
                warn("[BoostSystem] Error expirando boosts de "
                    .. player.Name .. ": " .. tostring(err))
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- RemoteFunction handlers
--------------------------------------------------------------------------------

RequestAplicarBoostFunc.OnServerInvoke = function(player, boostId, nestIndex)
    if type(boostId) ~= "string" then
        return { ok = false, error = "boostId inválido." }
    end
    if type(nestIndex) ~= "number" then
        return { ok = false, error = "nestIndex inválido." }
    end
    local ok, msg = BoostSystem.AplicarBoost(player, boostId, math.floor(nestIndex))
    return { ok = ok, message = msg }
end

RequestAplicarBoostAutoFunc.OnServerInvoke = function(player, boostId)
    if type(boostId) ~= "string" then
        return { ok = false, error = "boostId inválido." }
    end
    local ok, msg = BoostSystem.AplicarBoostAutomatico(player, boostId)
    return { ok = ok, message = msg }
end

RequestBoostInventarioFunc.OnServerInvoke = function(player)
    local bs = getBoosts(player)
    if not bs then return {} end
    local inventario = {}
    for boostId, count in pairs(bs) do
        if boostId ~= "_activos" and type(count) == "number" and count > 0 then
            inventario[boostId] = count
        end
    end
    return inventario
end

--------------------------------------------------------------------------------
-- Cleanup al salir
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
    boostRefs[player.UserId] = nil
end)

--------------------------------------------------------------------------------

return BoostSystem
