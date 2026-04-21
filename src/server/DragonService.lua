--------------------------------------------------------------------------------
-- DragonService.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona toda la producción de oro de los dragones asignados a nidos.
-- NO usa DataStore; la persistencia es responsabilidad de DataStore.lua.
--
-- playerData[userId] = {
--     level : number   -- nivel actual del jugador
--     nests = {
--         [nestIndex] = {
--             dragonId      : string  -- id del dragón asignado
--             lastCollected : number  -- timestamp os.time() de última recolección
--             evapWarnSent  : boolean -- ya se envió el aviso de evaporación
--         }
--     }
-- }
--------------------------------------------------------------------------------

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")

-- Módulos compartidos
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local ECONOMY = Constants.ECONOMY  -- MaxIdleSeconds, GoldEvaporationRate

--------------------------------------------------------------------------------
-- RemoteEvents — se crean si no existen en ReplicatedStorage
--------------------------------------------------------------------------------

local remotesFolder do
    remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotesFolder then
        remotesFolder        = Instance.new("Folder")
        remotesFolder.Name   = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    end
end

local function obtenerOCrearEvento(nombre)
    local evento = remotesFolder:FindFirstChild(nombre)
    if not evento then
        evento        = Instance.new("RemoteEvent")
        evento.Name   = nombre
        evento.Parent = remotesFolder
    end
    return evento
end

local GoldCollectedEvent  = obtenerOCrearEvento("GoldCollected")
local StatsUpdatedEvent   = obtenerOCrearEvento("StatsUpdated")
local GoldEvaporatingEvent = obtenerOCrearEvento("GoldEvaporating")

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

local playerData         = {}   -- playerData[userId] = { ... }
local nestMultipliers    = {}   -- nestMultipliers[userId][nestIndex] = number
local weatherMultipliers = {}   -- weatherMultipliers[elemento] = multiplicador

-- Garantiza que existe la entrada del jugador en playerData.
local function asegurarDatos(player)
    local uid = player.UserId
    if not playerData[uid] then
        playerData[uid] = {
            level = 1,
            nests = {},
        }
    end
    return playerData[uid]
end

-- Devuelve los datos del nido o nil si no hay dragón asignado.
local function obtenerNido(player, nestIndex)
    local datos = playerData[player.UserId]
    if not datos then return nil end
    return datos.nests[nestIndex]
end

--------------------------------------------------------------------------------
-- DragonService
--------------------------------------------------------------------------------

local DragonService = {}

-- Registra el inicio de producción de un dragón en un nido del jugador.
-- Guarda el timestamp actual como punto de referencia para calcular oro pendiente.
function DragonService.StartProduction(player, nestIndex, dragonId)
    -- Verificar que el dragón existe en el catálogo
    local dragon = DragonData.GetDragonById(dragonId)
    if not dragon then
        warn(("[DragonService] Dragón no encontrado: %s (jugador %s)"):format(
            tostring(dragonId), player.Name))
        return false
    end

    local datos = asegurarDatos(player)
    local ahora = os.time()

    datos.nests[nestIndex] = {
        dragonId      = dragonId,
        lastCollected = ahora,
        evapWarnSent  = false,
    }

    return true
end

-- Establece el multiplicador de producción de un nido (llamado por BoostSystem).
function DragonService.SetMultiplier(player, nestIndex, value)
    local uid = player.UserId
    if not nestMultipliers[uid] then nestMultipliers[uid] = {} end
    nestMultipliers[uid][nestIndex] = value or 1
end

-- Limpia el multiplicador de un nido al expirar o quitar un boost.
function DragonService.ClearMultiplier(player, nestIndex)
    local uid = player.UserId
    if nestMultipliers[uid] then
        nestMultipliers[uid][nestIndex] = nil
    end
end

-- Recibe la tabla de multiplicadores climáticos activos { [elemento] = mult }.
-- Llamado por WeatherSystem al iniciar un evento.
function DragonService.SetWeatherMultipliers(mults)
    weatherMultipliers = type(mults) == "table" and mults or {}
end

-- Limpia todos los multiplicadores climáticos al terminar el evento.
function DragonService.ClearWeatherMultipliers()
    weatherMultipliers = {}
end

-- Devuelve el multiplicador climático activo para un elemento (1.0 si ninguno).
function DragonService.GetWeatherMultiplier(elemento)
    return weatherMultipliers[elemento] or 1.0
end

-- Detiene la producción del nido especificado sin recolectar el oro pendiente.
-- El oro acumulado se pierde; usa CollectGold antes si quieres conservarlo.
function DragonService.StopProduction(player, nestIndex)
    local datos = playerData[player.UserId]
    if datos then
        datos.nests[nestIndex] = nil
    end
end

-- Calcula el oro listo para recolectar en un nido.
-- Aplica el cap de evaporación si el jugador tardó demasiado en recolectar:
--   · El oro se acumula normalmente hasta MaxIdleSeconds.
--   · Si se supera ese umbral, el total acumulado se penaliza con GoldEvaporationRate.
function DragonService.CalculatePending(player, nestIndex)
    local nido = obtenerNido(player, nestIndex)
    if not nido then return 0 end

    local dragon = DragonData.GetDragonById(nido.dragonId)
    if not dragon then return 0 end

    local ahora     = os.time()
    local transcurrido = ahora - nido.lastCollected

    -- Multiplicador de boost activo en este nido (1 si no hay boost)
    local uid  = player.UserId
    local mult = (nestMultipliers[uid] and nestMultipliers[uid][nestIndex]) or 1

    -- Multiplicador de evento climático según el elemento del dragón
    local weatherMult = weatherMultipliers[dragon.element] or 1.0

    -- Oro bruto: tiempo × GPS × boost × clima
    local gps      = dragon.goldPerSecond * mult * weatherMult
    local oroBruto

    -- Cap: si se supera el tiempo máximo de inactividad, se aplica la penalización
    if transcurrido > ECONOMY.MaxIdleSeconds then
        local oroMaximo = ECONOMY.MaxIdleSeconds * gps
        oroBruto = oroMaximo * (1 - ECONOMY.GoldEvaporationRate)
    else
        oroBruto = transcurrido * gps
    end

    return math.floor(oroBruto)
end

-- El jugador toca el nido para recolectar todo el oro pendiente.
-- Actualiza lastCollected y avisa al cliente con la cantidad recibida.
-- Devuelve el oro recibido (0 si el nido está vacío).
function DragonService.CollectGold(player, nestIndex)
    local nido = obtenerNido(player, nestIndex)
    if not nido then return 0 end

    local oro = DragonService.CalculatePending(player, nestIndex)

    -- Resetear el contador de tiempo y el aviso de evaporación
    nido.lastCollected = os.time()
    nido.evapWarnSent  = false

    if oro > 0 then
        -- Notificar al cliente: cantidad recibida y qué nido la generó
        GoldCollectedEvent:FireClient(player, {
            amount    = oro,
            nestIndex = nestIndex,
        })
    end

    return oro
end

-- Devuelve un resumen de la granja del jugador:
--   · gpsTotal        → producción total combinada de todos los nidos activos
--   · gpsPorNido      → tabla [nestIndex] = goldPerSecond individual
--   · oroPendienteTotal → suma del oro recolectable ahora mismo
--   · nivel           → nivel actual del jugador
function DragonService.GetFarmStats(player)
    local datos = asegurarDatos(player)

    local gpsTotal          = 0
    local gpsPorNido        = {}
    local oroPendienteTotal = 0

    for nestIndex, nido in pairs(datos.nests) do
        local dragon = DragonData.GetDragonById(nido.dragonId)
        if dragon then
            local uid         = player.UserId
            local boostMult   = (nestMultipliers[uid] and nestMultipliers[uid][nestIndex]) or 1
            local weatherMult = weatherMultipliers[dragon.element] or 1.0
            local gps         = dragon.goldPerSecond * boostMult * weatherMult
            gpsTotal               += gps
            gpsPorNido[nestIndex]   = gps
            oroPendienteTotal      += DragonService.CalculatePending(player, nestIndex)
        end
    end

    return {
        gpsTotal          = gpsTotal,
        gpsPorNido        = gpsPorNido,
        oroPendienteTotal = oroPendienteTotal,
        nivel             = datos.level,
    }
end

--------------------------------------------------------------------------------
-- Ciclo de vida de jugadores
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
    asegurarDatos(player)
end)

Players.PlayerRemoving:Connect(function(player)
    -- Limpiamos la entrada en memoria; DataStore.lua es responsable
    -- de persistir los datos antes de que esto ocurra.
    local uid = player.UserId
    playerData[uid]      = nil
    nestMultipliers[uid] = nil
end)

-- Inicializar datos para jugadores que ya estaban en la sesión al cargar el script
for _, player in ipairs(Players:GetPlayers()) do
    asegurarDatos(player)
end

--------------------------------------------------------------------------------
-- Loop principal  —  se ejecuta cada 1 segundo
--
-- Para cada jugador activo:
--   1. Detecta nidos que se acercan o superan el umbral de evaporación y avisa.
--   2. Dispara StatsUpdated con los stats actualizados para que el HUD se refresque.
--------------------------------------------------------------------------------

task.spawn(function()
    local TICK_RATE          = 1      -- segundos entre cada iteración
    local EVAP_WARN_UMBRAL   = 60     -- segundos antes del cap en los que se avisa

    while true do
        task.wait(TICK_RATE)

        for _, player in ipairs(Players:GetPlayers()) do
            local datos = playerData[player.UserId]
            if not datos then continue end

            local ahora = os.time()

            -- Revisar cada nido activo
            for nestIndex, nido in pairs(datos.nests) do
                local transcurrido  = ahora - nido.lastCollected
                local tiempoRestante = ECONOMY.MaxIdleSeconds - transcurrido

                -- Aviso de evaporación: 60 s antes del cap, una sola vez por ciclo
                if tiempoRestante <= EVAP_WARN_UMBRAL
                    and tiempoRestante > 0
                    and not nido.evapWarnSent
                then
                    nido.evapWarnSent = true
                    GoldEvaporatingEvent:FireClient(player, {
                        nestIndex        = nestIndex,
                        secondsRemaining = math.ceil(tiempoRestante),
                        evaporationPct   = ECONOMY.GoldEvaporationRate * 100,
                    })
                end
            end

            -- Enviar stats actualizados al HUD del jugador
            local stats = DragonService.GetFarmStats(player)
            StatsUpdatedEvent:FireClient(player, stats)
        end
    end
end)

--------------------------------------------------------------------------------

return DragonService
