--------------------------------------------------------------------------------
-- WeatherSystem.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona el ciclo de eventos climáticos aleatorios:
--   1. Espera un tiempo de cooldown aleatorio
--   2. Elige un evento al azar (sin repetir el anterior)
--   3. Activa el evento: notifica clientes y aplica efectos
--   4. Cada WEATHER_BONUS_TICK segundos otorga el oro extra del multiplicador
--   5. 30 s antes de terminar: avisa a los jugadores beneficiados
--   6. Al terminar: revierte efectos y reinicia el ciclo
--
-- NOTA SOBRE MULTIPLICADORES:
--   DragonService calcula producción base sin soporte de multiplicadores externos.
--   WeatherSystem compensa aplicando el delta de oro vía DataStore.AddGold en un
--   tick periódico: bonus = gps × TICK × (multiplier - 1) por nido afectado.
--   Las penalizaciones negativas son solo informativas (no se resta oro: UX friendly).
--
-- DEPENDENCIAS ADICIONALES:
--   · NestSystem  — para iterar nidos y conocer el elemento de cada dragón
--   · EggService  — para efectos especiales instant_egg y eggSpeedMultiplier
--   Ambos se requieren con WaitForChild para tolerar cualquier orden de carga.
--
-- IDs de eventos (coinciden exactamente con Constants.EVENTS.WeatherProbabilities):
--   sol_dorado, lluvia_magica, erupcion_volcanica,
--   tormenta_electrica, noche_eterna, rift_dimensional
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Módulos compartidos
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))

-- Servicios de gameplay
local DragonService = require(ServerScriptService:WaitForChild("DragonService"))
local DataStore     = require(ServerScriptService:WaitForChild("DataStore"))

-- Dependencias adicionales cargadas de forma diferida para tolerar orden arbitrario
local NestSystem, EggService
task.defer(function()
    NestSystem = require(ServerScriptService:WaitForChild("NestSystem"))
    EggService = require(ServerScriptService:WaitForChild("EggService"))
end)

local EVENTS = Constants.EVENTS

--------------------------------------------------------------------------------
-- Definición de los 6 eventos climáticos
-- Las claves coinciden exactamente con los IDs de Constants.EVENTS.WeatherProbabilities.
-- Los elementos afectados usan nombres en español (fuego, agua, hielo, trueno,
-- naturaleza, sombra, celestial, vacio).
--------------------------------------------------------------------------------

local EVENTOS_CLIMA = {

    sol_dorado = {
        id                 = "sol_dorado",
        name               = "Sol Dorado",
        -- Todos los elementos reciben bonus bajo el sol dorado
        affectedElements   = { "fuego","agua","hielo","trueno","naturaleza","sombra","celestial","vacio" },
        multiplier         = 1.5,
        negativeElements   = nil,
        negativeMultiplier = nil,
        eggSpeedMultiplier = nil,
        specialEffect      = nil,
        isBeneficial       = true,
    },

    lluvia_magica = {
        id                 = "lluvia_magica",
        name               = "Lluvia Mágica",
        affectedElements   = { "agua", "hielo" },
        multiplier         = 3.0,
        negativeElements   = nil,
        negativeMultiplier = nil,
        eggSpeedMultiplier = nil,
        specialEffect      = nil,
        isBeneficial       = true,
    },

    erupcion_volcanica = {
        id                 = "erupcion_volcanica",
        name               = "Erupción Volcánica",
        affectedElements   = { "fuego" },
        multiplier         = 3.0,
        negativeElements   = { "naturaleza", "hielo" },
        negativeMultiplier = 0.8,
        eggSpeedMultiplier = nil,
        specialEffect      = nil,
        isBeneficial       = true,   -- beneficioso para fuego, penaliza naturaleza/hielo
    },

    tormenta_electrica = {
        id                 = "tormenta_electrica",
        name               = "Tormenta Eléctrica",
        affectedElements   = { "trueno" },
        multiplier         = 4.0,
        negativeElements   = nil,
        negativeMultiplier = nil,
        eggSpeedMultiplier = 2.0,    -- timers de huevo trueno al doble de velocidad
        specialEffect      = nil,
        isBeneficial       = true,
    },

    noche_eterna = {
        id                 = "noche_eterna",
        name               = "Noche Eterna",
        affectedElements   = { "sombra" },
        multiplier         = 5.0,
        negativeElements   = { "celestial" },
        negativeMultiplier = 0.5,
        eggSpeedMultiplier = nil,
        specialEffect      = nil,
        isBeneficial       = true,
    },

    rift_dimensional = {
        id                 = "rift_dimensional",
        name               = "Rift Dimensional",
        affectedElements   = { "vacio" },
        multiplier         = 2.0,
        negativeElements   = nil,
        negativeMultiplier = nil,
        eggSpeedMultiplier = nil,
        specialEffect      = "instant_egg",  -- huevos de dragones vacío listos de inmediato
        isBeneficial       = true,
    },
}

-- Lista ordenada de IDs para iteración determinista
local ORDEN_EVENTOS = {
    "sol_dorado", "lluvia_magica", "erupcion_volcanica",
    "tormenta_electrica", "noche_eterna", "rift_dimensional",
}

--------------------------------------------------------------------------------
-- Constantes de comportamiento
--------------------------------------------------------------------------------

local WEATHER_BONUS_TICK  = 10      -- segundos entre cada distribución de bonus
local WARN_BEFORE_END_SEC = 30      -- segundos antes de terminar que se avisa
local COOLDOWN_MIN = EVENTS.MinCooldownSeconds
local COOLDOWN_MAX = EVENTS.MinCooldownSeconds * 2

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

local function obtenerOCrear(nombre)
    local obj = remotesFolder:FindFirstChild(nombre)
    if not obj then
        obj        = Instance.new("RemoteEvent")
        obj.Name   = nombre
        obj.Parent = remotesFolder
    end
    return obj
end

local ClimaIniciadoEvent = obtenerOCrear("WeatherStarted")
local ClimaTerminadoEvent = obtenerOCrear("WeatherEnded")
local ClimaTerminandoEvent = obtenerOCrear("WeatherEnding")

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

-- Evento activo actual: { eventId, startedAt, endsAt, duration } | nil
local eventoActivo = nil

-- ID del último evento disparado (para evitar repetición inmediata)
local ultimoEventoId = nil

-- Generación actual: se incrementa con cada TriggerEvent para que
-- los task.delay programados puedan verificar si siguen siendo válidos.
local generacionEvento = 0

-- Multiplicadores activos por elemento: { [elemento] = multiplicador }
local multiplicadoresActivos = {}

--------------------------------------------------------------------------------
-- Helpers internos
--------------------------------------------------------------------------------

-- Verifica si un elemento está en la lista proporcionada.
local function elementoEnLista(elemento, lista)
    if not lista then return false end
    for _, e in ipairs(lista) do
        if e == elemento then return true end
    end
    return false
end

-- Calcula el multiplicador efectivo para un elemento dado el evento activo.
-- Devuelve 1.0 si no hay efecto.
local function multiplicadorEfectivo(elemento, evento)
    if elementoEnLista(elemento, evento.affectedElements) then
        return evento.multiplier
    end
    if evento.negativeElements and elementoEnLista(elemento, evento.negativeElements) then
        return evento.negativeMultiplier
    end
    return 1.0
end

-- Itera los nidos activos de un jugador y ejecuta callback(player, nestIndex, dragon).
local function iterarNidosConDragon(player, callback)
    if not NestSystem then return end
    local nestData = NestSystem.GetNestData(player)
    if not nestData then return end
    for nestIndex, nido in pairs(nestData.nests) do
        if nido.dragonId then
            local dragon = DragonData.GetDragonById(nido.dragonId)
            if dragon then
                callback(player, nestIndex, dragon)
            end
        end
    end
end

-- El bonus climático está integrado en DragonService.CalculatePending
-- (multiplica gps × WeatherSystem.GetElementMultiplier), por lo que
-- no se necesita aplicar aquí como burst periódico.
local function aplicarBonusPeriodico(_evento)
    -- no-op: bonus ya incluido en CalculatePending
end

--------------------------------------------------------------------------------
-- WeatherSystem
--------------------------------------------------------------------------------

local WeatherSystem = {}

--------------------------------------------------------------------------------
-- WeatherSystem.GetElementMultiplier(elemento)
--
-- Devuelve el multiplicador activo para un elemento dado (en español).
-- 1.0 si no hay evento activo o si el elemento no está afectado.
--------------------------------------------------------------------------------
function WeatherSystem.GetElementMultiplier(elemento)
    if not eventoActivo then return 1.0 end
    local evento = EVENTOS_CLIMA[eventoActivo.eventId]
    if not evento then return 1.0 end
    return multiplicadorEfectivo(elemento, evento)
end

--------------------------------------------------------------------------------
-- WeatherSystem.GetActiveEvent()
--
-- Devuelve el evento activo actualmente, o nil si no hay ninguno.
--------------------------------------------------------------------------------
function WeatherSystem.GetActiveEvent()
    if not eventoActivo then return nil end
    local ahora = os.time()
    return {
        eventId     = eventoActivo.eventId,
        name        = EVENTOS_CLIMA[eventoActivo.eventId] and EVENTOS_CLIMA[eventoActivo.eventId].name,
        secondsLeft = math.max(0, eventoActivo.endsAt - ahora),
        endsAt      = eventoActivo.endsAt,
    }
end

--------------------------------------------------------------------------------
-- WeatherSystem.GetRandomEvent()
--
-- Elige un evento aleatorio usando las probabilidades de Constants.EVENTS.
-- Los IDs del evento coinciden directamente con las claves de WeatherProbabilities.
-- Garantiza que no se repite el mismo evento dos veces seguidas.
--------------------------------------------------------------------------------
function WeatherSystem.GetRandomEvent()
    local opciones   = {}
    local pesoTotal  = 0

    for _, eventId in ipairs(ORDEN_EVENTOS) do
        if eventId ~= ultimoEventoId then
            -- El ID del evento coincide directamente con la clave de probabilidad
            local prob = EVENTS.WeatherProbabilities[eventId] or 0
            if prob > 0 then
                table.insert(opciones, { id = eventId, peso = prob })
                pesoTotal = pesoTotal + prob
            end
        end
    end

    -- Sorteo por ruleta ponderada
    local roll      = math.random() * pesoTotal
    local acumulado = 0

    for _, opcion in ipairs(opciones) do
        acumulado = acumulado + opcion.peso
        if roll <= acumulado then
            return opcion.id
        end
    end

    -- Fallback: primer evento que no sea el último
    for _, eventId in ipairs(ORDEN_EVENTOS) do
        if eventId ~= ultimoEventoId then return eventId end
    end
    return ORDEN_EVENTOS[1]
end

--------------------------------------------------------------------------------
-- WeatherSystem.HandleSpecialEffect(eventId, player)
--
-- Maneja efectos especiales de eventos para un jugador específico.
--   "instant_egg" (rift_dimensional): huevos de dragones vacío listos de inmediato.
--   eggSpeedMultiplier (tormenta_electrica): reduce timers de huevos trueno.
--------------------------------------------------------------------------------
function WeatherSystem.HandleSpecialEffect(eventId, player)
    local evento = EVENTOS_CLIMA[eventId]
    if not evento then return end

    if evento.specialEffect == "instant_egg" then
        iterarNidosConDragon(player, function(_, nestIndex, dragon)
            if dragon.element == "vacio" then
                if EggService then
                    if EggService.ForceCompleteEgg then
                        EggService.ForceCompleteEgg(player, nestIndex)
                    else
                        EggService.ApplyIncubationBoost(player, nestIndex)
                    end
                end
            end
        end)
    end

    if evento.eggSpeedMultiplier then
        iterarNidosConDragon(player, function(_, nestIndex, dragon)
            if dragon.element == "trueno" then
                if EggService then
                    if EggService.ReduceEggTimerByFactor then
                        EggService.ReduceEggTimerByFactor(player, nestIndex, evento.eggSpeedMultiplier)
                    else
                        EggService.ApplyIncubationBoost(player, nestIndex)
                    end
                end
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- WeatherSystem.TriggerEvent(eventId)
--
-- Activa un evento climático específico.
-- Usado internamente por el loop automático y también por ActivarEvento()
-- cuando un jugador activa un evento desde la Tienda Especial.
--------------------------------------------------------------------------------
function WeatherSystem.TriggerEvent(eventId)
    if eventoActivo then
        WeatherSystem.EndEvent(eventoActivo.eventId)
    end

    local evento = EVENTOS_CLIMA[eventId]
    if not evento then
        warn(("[WeatherSystem] TriggerEvent: evento desconocido '%s'"):format(tostring(eventId)))
        return
    end

    local duracion = math.random(EVENTS.MinDurationSeconds, EVENTS.MaxDurationSeconds)
    local ahora    = os.time()

    eventoActivo = {
        eventId   = eventId,
        startedAt = ahora,
        endsAt    = ahora + duracion,
        duration  = duracion,
    }
    ultimoEventoId = eventId

    -- Actualizar multiplicadores activos por elemento
    multiplicadoresActivos = {}
    if evento.affectedElements then
        for _, elem in ipairs(evento.affectedElements) do
            multiplicadoresActivos[elem] = evento.multiplier
        end
    end
    if evento.negativeElements then
        for _, elem in ipairs(evento.negativeElements) do
            multiplicadoresActivos[elem] = evento.negativeMultiplier
        end
    end

    -- Notificar a DragonService para que CalculatePending use el multiplicador correcto
    DragonService.SetWeatherMultipliers(multiplicadoresActivos)

    print(("[WeatherSystem] ▶ Evento '%s' (%s) durante %d s")
        :format(evento.name, eventId, duracion))

    -- Notificar a todos los clientes
    ClimaIniciadoEvent:FireAllClients({
        eventId            = eventId,
        name               = evento.name,
        duration           = duracion,
        endsAt             = eventoActivo.endsAt,
        affectedElements   = evento.affectedElements,
        multiplier         = evento.multiplier,
        negativeElements   = evento.negativeElements,
        negativeMultiplier = evento.negativeMultiplier,
        eggSpeedMultiplier = evento.eggSpeedMultiplier,
        specialEffect      = evento.specialEffect,
    })

    -- Aplicar efectos especiales por jugador
    if evento.specialEffect or evento.eggSpeedMultiplier then
        for _, player in ipairs(Players:GetPlayers()) do
            task.spawn(WeatherSystem.HandleSpecialEffect, eventId, player)
        end
    end

    -- Capturar generación para validar task.delay diferidos
    generacionEvento = generacionEvento + 1
    local gen = generacionEvento

    -- Aviso 30 s antes del final
    if duracion > WARN_BEFORE_END_SEC then
        task.delay(duracion - WARN_BEFORE_END_SEC, function()
            if generacionEvento ~= gen then return end
            ClimaTerminandoEvent:FireAllClients({
                eventId          = eventId,
                name             = evento.name,
                secondsRemaining = WARN_BEFORE_END_SEC,
                affectedElements = evento.affectedElements,
                multiplier       = evento.multiplier,
            })
        end)
    end

    -- Programar finalización del evento
    task.delay(duracion, function()
        if generacionEvento ~= gen then return end
        WeatherSystem.EndEvent(eventId)
    end)

    -- Loop de bonus periódico mientras el evento esté activo
    task.spawn(function()
        while eventoActivo and eventoActivo.eventId == eventId do
            task.wait(WEATHER_BONUS_TICK)
            if not eventoActivo or eventoActivo.eventId ~= eventId then break end
            aplicarBonusPeriodico(evento)
        end
    end)
end

--------------------------------------------------------------------------------
-- WeatherSystem.ActivarEvento(tipoEvento)
--
-- Función pública para que la Tienda Especial pueda activar un evento climático
-- cuando un jugador compra y usa un "evento climático activable".
-- Valida que el tipoEvento sea uno de los 6 IDs válidos.
-- Devuelve true si se activó correctamente, false si el ID no es válido.
--------------------------------------------------------------------------------
function WeatherSystem.ActivarEvento(tipoEvento)
    if not EVENTOS_CLIMA[tipoEvento] then
        warn(("[WeatherSystem] ActivarEvento: ID de evento inválido '%s'"):format(tostring(tipoEvento)))
        return false
    end
    WeatherSystem.TriggerEvent(tipoEvento)
    return true
end

--------------------------------------------------------------------------------
-- WeatherSystem.EndEvent(eventId)
--
-- Finaliza el evento activo, limpia el estado y notifica a los clientes.
--------------------------------------------------------------------------------
function WeatherSystem.EndEvent(eventId)
    if not eventoActivo or eventoActivo.eventId ~= eventId then return end

    local evento = EVENTOS_CLIMA[eventId]
    local nombre = evento and evento.name or eventId

    print(("[WeatherSystem] ■ Evento '%s' terminado"):format(nombre))

    eventoActivo         = nil
    multiplicadoresActivos = {}
    DragonService.ClearWeatherMultipliers()

    ClimaTerminadoEvent:FireAllClients({
        eventId = eventId,
        name    = nombre,
    })
end

--------------------------------------------------------------------------------
-- WeatherSystem.Start()
--
-- Inicia el loop principal de eventos climáticos automáticos.
-- Espera un retraso inicial antes del primer evento.
--------------------------------------------------------------------------------
function WeatherSystem.Start()
    task.spawn(function()
        local retrasoInicial = math.random(COOLDOWN_MIN, COOLDOWN_MAX)
        print(("[WeatherSystem] Sistema iniciado. Primer evento en %d s."):format(retrasoInicial))
        task.wait(retrasoInicial)

        while true do
            local eventId = WeatherSystem.GetRandomEvent()
            WeatherSystem.TriggerEvent(eventId)

            local duracion = eventoActivo and eventoActivo.duration or EVENTS.MaxDurationSeconds
            task.wait(duracion + 1)

            local cooldown = math.random(COOLDOWN_MIN, COOLDOWN_MAX)
            print(("[WeatherSystem] Cooldown: próximo evento en %d s."):format(cooldown))
            task.wait(cooldown)
        end
    end)
end

--------------------------------------------------------------------------------
-- Iniciar el sistema al cargar el script
--------------------------------------------------------------------------------

WeatherSystem.Start()

--------------------------------------------------------------------------------

return WeatherSystem
