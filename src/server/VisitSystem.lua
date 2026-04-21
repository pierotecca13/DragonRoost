--------------------------------------------------------------------------------
-- VisitSystem.lua  ·  Módulo de servidor  ·  Dragon Roost
--
-- Permite a un jugador visitar la granja de otro dentro del mismo servidor.
-- El visitante entra en modo lectura: puede ver la granja del anfitrión pero
-- no puede interactuar con sus nidos. Puede proponer un intercambio.
--
-- FLUJO:
--   1. El visitante llama RequestVisitar(slotIndex).
--   2. VisitSystem.IniciarVisita registra la visita y notifica al visitante
--      con los datos de la granja (RemoteEvent "VisitaIniciada").
--   3. El visitante puede llamar RequestDatosGranja(slotIndex) para refrescar.
--   4. Al salir, RequestTerminarVisita limpia el estado.
--
-- RESTRICCIONES:
--   · Un jugador solo puede visitar una granja a la vez.
--   · No se puede visitar la propia granja.
--   · El slot destino debe estar activo.
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DataStore     = require(ServerScriptService:WaitForChild("DataStore"))
local NestSystem    = require(ServerScriptService:WaitForChild("NestSystem"))
local ServerManager = require(ServerScriptService:WaitForChild("ServerManager"))

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

local VisitaIniciadaEvent   = obtenerOCrear("RemoteEvent",   "VisitaIniciada")
local VisitaTerminadaEvent  = obtenerOCrear("RemoteEvent",   "VisitaTerminada")
local RequestVisitarFunc    = obtenerOCrear("RemoteFunction", "RequestVisitar")
local RequestDatosGranjaFunc = obtenerOCrear("RemoteFunction", "RequestDatosGranja")
local RequestTerminarVisitaFunc = obtenerOCrear("RemoteFunction", "RequestTerminarVisita")

--------------------------------------------------------------------------------
-- Estado interno
-- visitas[userId] = { slotIndex, anfitrionName }
--------------------------------------------------------------------------------

local visitas = {}

--------------------------------------------------------------------------------
-- VisitSystem
--------------------------------------------------------------------------------

local VisitSystem = {}

--------------------------------------------------------------------------------
-- VisitSystem.GetDatosGranja(slotIndex) → tabla o nil
--
-- Construye los datos públicos de la granja del slot indicado.
-- Usado al iniciar la visita y para refrescar.
--------------------------------------------------------------------------------
function VisitSystem.GetDatosGranja(slotIndex)
    local estado = ServerManager.GetEstadoServidor()
    local slot   = estado[slotIndex]

    if not slot or not slot.activo or not slot.jugador then
        return nil
    end

    -- Encontrar el objeto player por nombre
    local anfitrion = nil
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Name == slot.jugador then
            anfitrion = player
            break
        end
    end

    if not anfitrion then return nil end

    -- Construir lista de dragones en nidos
    local nestData = NestSystem.GetNestData(anfitrion)
    local dragones = {}
    if nestData and nestData.nests then
        for _, nido in pairs(nestData.nests) do
            if nido.dragonId then
                table.insert(dragones, {
                    id    = nido.dragonId,
                    rareza = nido.rareza or "?",
                })
            end
        end
    end

    -- Contar nidos vacíos
    local totalSlots  = nestData and nestData.slots or 0
    local nidosActivos = nestData and nestData.nestCount or #dragones
    local nidosVacios  = math.max(0, totalSlots - nidosActivos)

    return {
        slotIndex      = slotIndex,
        nombreJugador  = anfitrion.Name,
        nivel          = slot.nivel,
        oroPorSegundo  = slot.oroPorSegundo,
        dragones       = dragones,
        nidosVacios    = nidosVacios,
        posicion       = slot.posicion,
    }
end

--------------------------------------------------------------------------------
-- VisitSystem.IniciarVisita(visitor, targetSlot)
--
-- Registra la visita y notifica al visitante con los datos de la granja.
-- Devuelve: (éxito, datos o mensaje)
--------------------------------------------------------------------------------
function VisitSystem.IniciarVisita(visitor, targetSlot)
    if type(targetSlot) ~= "number" then
        return false, "Slot inválido."
    end

    local uid = visitor.UserId

    -- Verificar que no está ya visitando
    if visitas[uid] then
        return false, ("Ya estás visitando la granja de %s. Termina tu visita primero."):format(
            visitas[uid].anfitrionName)
    end

    -- Verificar que no es su propia granja
    local slotPropio = ServerManager.GetSlotDeJugador(visitor)
    if slotPropio == targetSlot then
        return false, "No puedes visitar tu propia granja."
    end

    -- Obtener datos de la granja destino
    local datos = VisitSystem.GetDatosGranja(targetSlot)
    if not datos then
        return false, "La granja que intentas visitar no está activa."
    end

    -- Registrar visita
    visitas[uid] = {
        slotIndex      = targetSlot,
        anfitrionName  = datos.nombreJugador,
    }

    -- Notificar al visitante
    VisitaIniciadaEvent:FireClient(visitor, datos)

    print(("[VisitSystem] %s inició visita al slot %d (%s)."):format(
        visitor.Name, targetSlot, datos.nombreJugador))

    return true, datos
end

--------------------------------------------------------------------------------
-- VisitSystem.TerminarVisita(visitor)
--
-- Limpia el registro de visita y notifica al visitante.
-- Devuelve: (éxito, mensaje)
--------------------------------------------------------------------------------
function VisitSystem.TerminarVisita(visitor)
    local uid = visitor.UserId

    if not visitas[uid] then
        return false, "No estás visitando ninguna granja."
    end

    local info = visitas[uid]
    visitas[uid] = nil

    VisitaTerminadaEvent:FireClient(visitor, {
        slotIndex     = info.slotIndex,
        anfitrionName = info.anfitrionName,
    })

    print(("[VisitSystem] %s terminó visita al slot %d."):format(visitor.Name, info.slotIndex))
    return true, ("Visita a la granja de %s terminada."):format(info.anfitrionName)
end

--------------------------------------------------------------------------------
-- VisitSystem.ProponeIntercambio(visitor, targetSlot)
--
-- Valida que el visitante esté en ese slot y delega a TradeSystem.
-- Devuelve: (éxito, mensaje)
--------------------------------------------------------------------------------
function VisitSystem.ProponeIntercambio(visitor, targetSlot)
    local uid  = visitor.UserId
    local info = visitas[uid]

    if not info or info.slotIndex ~= targetSlot then
        return false, "Debes estar visitando la granja para proponer un intercambio."
    end

    -- Encontrar al anfitrión
    local anfitrion = nil
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Name == info.anfitrionName then
            anfitrion = player
            break
        end
    end

    if not anfitrion then
        return false, "El jugador anfitrión ya no está en el servidor."
    end

    -- Intentar llamar a TradeSystem si existe
    local TradeSystem = ServerScriptService:FindFirstChild("TradeSystem")
    if TradeSystem then
        local ok, TradeModule = pcall(require, TradeSystem)
        if ok and TradeModule and TradeModule.ProponerIntercambio then
            return TradeModule.ProponerIntercambio(visitor, anfitrion)
        end
    end

    return false, "El sistema de intercambio no está disponible en este momento."
end

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
--------------------------------------------------------------------------------

RequestVisitarFunc.OnServerInvoke = function(visitor, targetSlot)
    return VisitSystem.IniciarVisita(visitor, targetSlot)
end

RequestDatosGranjaFunc.OnServerInvoke = function(visitor, targetSlot)
    local datos = VisitSystem.GetDatosGranja(targetSlot)
    if datos then
        return true, datos
    else
        return false, "Granja no disponible."
    end
end

RequestTerminarVisitaFunc.OnServerInvoke = function(visitor)
    return VisitSystem.TerminarVisita(visitor)
end

--------------------------------------------------------------------------------
-- Limpieza al desconectarse
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
    -- Si el jugador que salió era anfitrión, terminar visitas pendientes
    local nombre = player.Name
    for uid, info in pairs(visitas) do
        if info.anfitrionName == nombre then
            local visitor = Players:GetPlayerByUserId(uid)
            if visitor then
                VisitSystem.TerminarVisita(visitor)
            else
                visitas[uid] = nil
            end
        end
    end

    -- Limpiar la propia visita del jugador que salió
    visitas[player.UserId] = nil
end)

--------------------------------------------------------------------------------

return VisitSystem
