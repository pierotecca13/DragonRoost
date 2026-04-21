--------------------------------------------------------------------------------
-- ServerManager.lua  ·  Módulo de servidor  ·  Dragon Roost
--
-- Gestiona los 8 slots de jugador dentro de UNA instancia de servidor.
-- Roblox crea instancias separadas automáticamente (máx. 8 jugadores/servidor).
-- Este módulo no tiene conocimiento de otras instancias.
--
-- GRID DE POSICIONES:
--   8 slots distribuidos en una cuadrícula 4×2.
--   Cada isla ocupa 60×60 studs; separación de 120 studs entre centros.
--   Origen: (0, 0, 0). Las islas se numeran de izquierda a derecha, fila a fila.
--
--     Slot 1  Slot 2  Slot 3  Slot 4
--     Slot 5  Slot 6  Slot 7  Slot 8
--
-- CICLO DE VIDA:
--   · PlayerAdded  → AsignarSlot(player)
--   · PlayerRemoving → LiberarSlot(player)
--   · BroadcastEstado() → loop cada 5 s → RemoteEvent "EstadoServidorActualizado"
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DataStore     = require(ServerScriptService:WaitForChild("DataStore"))
local NestSystem    = require(ServerScriptService:WaitForChild("NestSystem"))
local DragonService = require(ServerScriptService:WaitForChild("DragonService"))

--------------------------------------------------------------------------------
-- Configuración del grid
--------------------------------------------------------------------------------

local COLUMNAS       = 4
local FILAS          = 2
local MAX_SLOTS      = COLUMNAS * FILAS   -- 8
local SEPARACION     = 120               -- studs entre centros de islas
local ORIGEN         = Vector3.new(0, 0, 0)

-- Mensaje de kick cuando el servidor está lleno
local MENSAJE_LLENO = "Servidor lleno (8/8 jugadores).\nIntenta conectarte en otro servidor."

-- Intervalo del loop de broadcast
local INTERVALO_BROADCAST = 5  -- segundos

--------------------------------------------------------------------------------
-- RemoteEvents
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

local EstadoServidorActualizadoEvent = obtenerOCrear("RemoteEvent", "EstadoServidorActualizado")

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

-- slots[i] = { slotIndex=i, player=nil, posicion=Vector3, islaActiva=false }
local slots = {}

-- Mapa rápido userId → slotIndex
local slotDeJugador = {}

--------------------------------------------------------------------------------
-- ServerManager
--------------------------------------------------------------------------------

local ServerManager = {}

--------------------------------------------------------------------------------
-- ServerManager.Init()
--
-- Crea las 8 entradas de slots con sus posiciones en el grid.
-- Conecta los eventos de ciclo de vida de jugadores.
-- Arranca el loop de broadcast.
--------------------------------------------------------------------------------
function ServerManager.Init()
    -- Calcular posiciones del grid
    for fila = 1, FILAS do
        for col = 1, COLUMNAS do
            local i   = (fila - 1) * COLUMNAS + col
            local posX = ORIGEN.X + (col - 1) * SEPARACION
            local posZ = ORIGEN.Z + (fila - 1) * SEPARACION
            slots[i] = {
                slotIndex  = i,
                player     = nil,
                posicion   = Vector3.new(posX, ORIGEN.Y, posZ),
                islaActiva = false,
            }
        end
    end

    -- Conectar eventos de jugadores
    Players.PlayerAdded:Connect(function(player)
        ServerManager.AsignarSlot(player)
    end)

    Players.PlayerRemoving:Connect(function(player)
        ServerManager.LiberarSlot(player)
    end)

    -- Asignar slots a jugadores que ya están en sesión al cargar este módulo
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(function()
            ServerManager.AsignarSlot(player)
        end)
    end

    -- Arrancar loop de broadcast
    task.spawn(function()
        while true do
            task.wait(INTERVALO_BROADCAST)
            ServerManager.BroadcastEstado()
        end
    end)

    print(("[ServerManager] Iniciado con %d slots. Grid %d×%d, separación %d studs."):format(
        MAX_SLOTS, COLUMNAS, FILAS, SEPARACION))
end

--------------------------------------------------------------------------------
-- ServerManager.AsignarSlot(player)
--
-- Busca el primer slot libre y lo asigna al jugador.
-- Si no hay slots disponibles, kickea al jugador con un mensaje claro.
--------------------------------------------------------------------------------
function ServerManager.AsignarSlot(player)
    -- Verificar que el jugador no tenga ya un slot asignado
    if slotDeJugador[player.UserId] then return end

    for i = 1, MAX_SLOTS do
        if not slots[i].player then
            slots[i].player     = player
            slots[i].islaActiva = true
            slotDeJugador[player.UserId] = i

            print(("[ServerManager] %s → slot %d en %s"):format(
                player.Name, i, tostring(slots[i].posicion)))

            -- Broadcast inmediato para reflejar el cambio
            ServerManager.BroadcastEstado()
            return
        end
    end

    -- No hay slots libres
    warn(("[ServerManager] Servidor lleno. Kickeando a %s."):format(player.Name))
    player:Kick(MENSAJE_LLENO)
end

--------------------------------------------------------------------------------
-- ServerManager.LiberarSlot(player)
--
-- Libera el slot del jugador al desconectarse.
--------------------------------------------------------------------------------
function ServerManager.LiberarSlot(player)
    local i = slotDeJugador[player.UserId]
    if not i then return end

    slots[i].player     = nil
    slots[i].islaActiva = false
    slotDeJugador[player.UserId] = nil

    print(("[ServerManager] Slot %d liberado (%s salió)."):format(i, player.Name))
    ServerManager.BroadcastEstado()
end

--------------------------------------------------------------------------------
-- ServerManager.GetPosicionGranja(slotIndex) → Vector3
--
-- Devuelve la posición en el mundo de la isla del slot dado.
--------------------------------------------------------------------------------
function ServerManager.GetPosicionGranja(slotIndex)
    local s = slots[slotIndex]
    return s and s.posicion or ORIGEN
end

--------------------------------------------------------------------------------
-- ServerManager.GetSlotDeJugador(player) → número o nil
--
-- Devuelve el índice de slot asignado al jugador, o nil si no tiene.
--------------------------------------------------------------------------------
function ServerManager.GetSlotDeJugador(player)
    return slotDeJugador[player.UserId]
end

--------------------------------------------------------------------------------
-- ServerManager.GetEstadoServidor() → tabla de 8 entradas
--
-- Construye una tabla con el estado público de cada slot para el minimapa
-- y el ranking del servidor.
-- Campos por slot: slotIndex, jugador (nombre o nil), nivel, oroPorSegundo, activo, posicion.
--------------------------------------------------------------------------------
function ServerManager.GetEstadoServidor()
    local estado = {}
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if s.player and s.islaActiva then
            local datos     = DataStore.GetPlayerData(s.player)
            local farmStats = DragonService.GetFarmStats(s.player)
            local nivel     = datos and datos.level or 1
            local oroPorSeg = farmStats and farmStats.gpsTotal or 0
            table.insert(estado, {
                slotIndex    = i,
                jugador      = s.player.Name,
                nivel        = nivel,
                oroPorSegundo = oroPorSeg,
                activo       = true,
                posicion     = { x = s.posicion.X, y = s.posicion.Y, z = s.posicion.Z },
            })
        else
            table.insert(estado, {
                slotIndex    = i,
                jugador      = nil,
                nivel        = 0,
                oroPorSegundo = 0,
                activo       = false,
                posicion     = { x = s.posicion.X, y = s.posicion.Y, z = s.posicion.Z },
            })
        end
    end
    return estado
end

--------------------------------------------------------------------------------
-- ServerManager.BroadcastEstado()
--
-- Envía el estado del servidor a todos los jugadores conectados.
-- Llamado por el loop interno y tras cada cambio de slot.
--------------------------------------------------------------------------------
function ServerManager.BroadcastEstado()
    local estado = ServerManager.GetEstadoServidor()
    EstadoServidorActualizadoEvent:FireAllClients(estado)
end

--------------------------------------------------------------------------------

return ServerManager
