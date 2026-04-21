--------------------------------------------------------------------------------
-- BreedingSystem.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona el ciclo completo de breeding entre dos dragones del inventario.
--
-- FLUJO:
--   StartBreeding → reserva ambos padres (sin quitarlos del inventario)
--   loop 10 s     → detecta timer completado → CompleteBreeding
--   CompleteBreeding → libera reserva, genera hijo, lo añade al inventario
--   CancelBreeding   → libera reserva, sin hijo
--
-- RESERVAS:
--   Los padres se marcan en reserved[userId][dragonId] = count durante el
--   breeding. No se eliminan del inventario; "liberar" = quitar de reserved.
--   Esto asegura que no se usen en nidos ni en otro breeding simultáneo.
--
-- RECETAS DE ELEMENTO:
--   La tabla RECIPES mapea pares de elementos (ordenados alfabéticamente) a un
--   dragón resultado existente en DragonData. Si el jugador desbloqueó la
--   receta (knownRecipes[key] = true) la probabilidad sube de base a desbloqueada.
--
-- NOTA: Constants.LEVELS tiene breedingUnlocked = true desde nivel 7,
--   no desde nivel 5 como indica el spec. Se usa el flag de Constants.
--
-- EggService se importa según el spec; en esta versión el resultado va
-- directo a inventario (AddDragonToInventory). Si en el futuro el breeding
-- produce huevos primero, EggService.StartEggTimer se usaría aquí.
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Módulos compartidos
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

-- Servicios de datos
local DataStore  = require(ServerScriptService:WaitForChild("DataStore"))
local EggService = require(ServerScriptService:WaitForChild("EggService"))  -- spec requirement

local RARITIES = Constants.RARITIES
local LEVELS   = Constants.LEVELS

-- Rank numérico por rareza
local RARITY_RANK = {}
for i, r in ipairs(RARITIES.Order) do RARITY_RANK[r] = i end

-- Costo en gemas para acelerar el breeding
local SPEEDUP_COST_GEMS = 20

--------------------------------------------------------------------------------
-- Tabla de recetas de breeding por combinación de elementos
-- Clave = elementos ordenados alfabéticamente con "_" como separador.
-- Resultado mapeado al ID de dragon más cercano existente en DragonData.
-- chanceUnlocked = probabilidad si el jugador tiene la receta desbloqueada.
-- chanceBase     = probabilidad sin receta.
--------------------------------------------------------------------------------

-- Nota: las claves se generan con claveReceta(elem1, elem2) → ordenados alfabéticamente.
-- Con elementos en español el orden es: agua < celestial < fuego < hielo < naturaleza < sombra < trueno < vacio
local RECIPES = {
    -- fuego + agua
    agua_fuego          = { resultId = "steam_wyrm",          chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- naturaleza + trueno
    naturaleza_trueno   = { resultId = "verdant_void",         chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- hielo + agua
    agua_hielo          = { resultId = "frostfire_drake",      chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- fuego + vacio
    fuego_vacio         = { resultId = "lava_titan",           chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- celestial + hielo
    celestial_hielo     = { resultId = "aurora_serpent",       chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- celestial + sombra
    celestial_sombra    = { resultId = "nebula_dragon",        chanceUnlocked = 0.40, chanceBase = 0.02 },
    -- naturaleza + sombra
    naturaleza_sombra   = { resultId = "vineshade_dragon",     chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- agua + trueno
    agua_trueno         = { resultId = "storm_leviathan",      chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- sombra + vacio
    sombra_vacio        = { resultId = "phantom_wraith",       chanceUnlocked = 0.40, chanceBase = 0.02 },
    -- fuego + trueno
    fuego_trueno        = { resultId = "darkember_drake",      chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- agua + naturaleza
    agua_naturaleza     = { resultId = "tidespecter",          chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- celestial + vacio
    celestial_vacio     = { resultId = "nebula_dragon",        chanceUnlocked = 0.40, chanceBase = 0.02 },
    -- trueno + vacio
    trueno_vacio        = { resultId = "glacial_thunderwing",  chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- celestial + naturaleza
    celestial_naturaleza = { resultId = "prismatic_dragon",    chanceUnlocked = 0.60, chanceBase = 0.05 },
    -- agua + vacio
    agua_vacio          = { resultId = "tidespecter",          chanceUnlocked = 0.40, chanceBase = 0.02 },
}

--------------------------------------------------------------------------------
-- Tabla de resultados de rareza según las rarezas de los dos padres
-- Clave = rareza menor "_" rareza mayor (ordenado por RARITY_RANK).
-- Valores deben sumar 1.0.
--------------------------------------------------------------------------------

local RARITY_OUTCOMES = {
    comun_comun           = { comun=0.80, poco_comun=0.20 },
    comun_poco_comun      = { comun=0.35, poco_comun=0.60, raro=0.05 },
    poco_comun_poco_comun = { comun=0.15, poco_comun=0.50, raro=0.35 },
    poco_comun_raro       = { poco_comun=0.35, raro=0.50, epico=0.15 },   -- poco_comun+raro
    raro_raro             = { poco_comun=0.20, raro=0.45, epico=0.35 },
    epico_raro            = { raro=0.30, epico=0.50, legendario=0.20 },   -- raro+epico
    epico_epico           = { raro=0.20, epico=0.45, legendario=0.35 },
    epico_legendario      = { epico=0.35, legendario=0.50, mitico=0.15 }, -- epico+legendario
    legendario_legendario = { epico=0.25, legendario=0.40, mitico=0.35 },
    legendario_mitico     = { epico=0.15, legendario=0.35, mitico=0.50 },
    mitico_mitico         = { legendario=0.30, mitico=0.70 },
}

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

-- breedingData[userId][breedingId] = { dragonId1, dragonId2, startedAt,
--                                       completesAt, duration }
local breedingData = {}

-- reserved[userId][dragonId] = count — cuántas copias están en breeding
local reserved = {}

-- Contador incremental para IDs únicos de breeding
local breedingCounter = 0

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

local BreedingStartedEvent   = obtenerOCrear("RemoteEvent",    "BreedingStarted")
local BreedingCompletedEvent = obtenerOCrear("RemoteEvent",    "BreedingCompleted")
local BreedingCancelledEvent = obtenerOCrear("RemoteEvent",    "BreedingCancelled")

local StartBreedingFunc   = obtenerOCrear("RemoteFunction", "RequestStartBreeding")
local CancelBreedingFunc  = obtenerOCrear("RemoteFunction", "RequestCancelBreeding")
local PreviewBreedingFunc = obtenerOCrear("RemoteFunction", "RequestGetBreedingPreview")
local SpeedUpBreedingFunc = obtenerOCrear("RemoteFunction", "RequestSpeedUpBreeding")

--------------------------------------------------------------------------------
-- Helpers internos
--------------------------------------------------------------------------------

-- Genera la clave de receta para dos elementos (ordenados alfabéticamente).
local function claveReceta(elem1, elem2)
    if elem1 > elem2 then elem1, elem2 = elem2, elem1 end
    return elem1 .. "_" .. elem2
end

-- Genera la clave de outcome de rareza (la menor rareza primero por rank).
local function claveRareza(r1, r2)
    if RARITY_RANK[r1] > RARITY_RANK[r2] then r1, r2 = r2, r1 end
    return r1 .. "_" .. r2
end

-- Asegura que existen las tablas del jugador en memoria.
local function asegurarEstado(uid)
    if not breedingData[uid] then breedingData[uid] = {} end
    if not reserved[uid]     then reserved[uid]     = {} end
end

-- Devuelve cuántas copias disponibles (no reservadas) tiene el jugador.
local function disponibles(playerData, uid, dragonId)
    local total     = (playerData.inventory and playerData.inventory[dragonId]) or 0
    local enUso     = (reserved[uid] and reserved[uid][dragonId]) or 0
    return total - enUso
end

-- Reserva un dragón del inventario del jugador.
local function reservar(uid, dragonId)
    reserved[uid]            = reserved[uid] or {}
    reserved[uid][dragonId]  = (reserved[uid][dragonId] or 0) + 1
end

-- Libera la reserva de un dragón (lo devuelve al uso normal).
local function liberar(uid, dragonId)
    if not reserved[uid] then return end
    local count = (reserved[uid][dragonId] or 0) - 1
    reserved[uid][dragonId] = count > 0 and count or nil
end

-- Sorteo ponderado sobre tabla { rareza = probabilidad }.
-- Devuelve la rareza elegida.
local function sortearRareza(probs)
    local roll = math.random()
    local acum = 0
    for _, rareza in ipairs(RARITIES.Order) do
        local prob = probs[rareza] or 0
        acum = acum + prob
        if roll <= acum then return rareza end
    end
    -- fallback: rareza más alta con prob > 0
    for i = #RARITIES.Order, 1, -1 do
        if (probs[RARITIES.Order[i]] or 0) > 0 then
            return RARITIES.Order[i]
        end
    end
    return "comun"
end

-- Elige un dragón aleatorio de DragonData que coincida con elemento y rareza.
-- Excluye soloCria y soloEvento. Si no hay candidatos en el elemento,
-- amplía la búsqueda a cualquier elemento.
local function elegirDragonResultado(elemento, rareza)
    local candidatos = {}
    -- Primera pasada: mismo elemento
    for _, d in ipairs(DragonData.Dragons) do
        if d.element == elemento and d.rarity == rareza
            and not d.soloCria and not d.soloEvento then
            table.insert(candidatos, d.id)
        end
    end
    -- Segunda pasada: cualquier elemento
    if #candidatos == 0 then
        for _, d in ipairs(DragonData.Dragons) do
            if d.rarity == rareza
                and not d.soloCria and not d.soloEvento then
                table.insert(candidatos, d.id)
            end
        end
    end
    if #candidatos == 0 then return nil end
    return candidatos[math.random(#candidatos)]
end

-- Calcula las probabilidades efectivas de rareza teniendo en cuenta la
-- posible activación de una receta (que consume parte de la probabilidad base).
-- Devuelve: probRareza (tabla ajustada), recetaChance (prob efectiva de receta).
local function calcularProbabilidades(rareza1, rareza2, receta, tieneReceta)
    local base = RARITY_OUTCOMES[claveRareza(rareza1, rareza2)]
    if not base then
        base = RARITY_OUTCOMES["comun_comun"]  -- fallback
    end

    local recetaChance = 0
    if receta then
        recetaChance = tieneReceta and receta.chanceUnlocked or receta.chanceBase
    end

    -- Redistribuir las probabilidades base para que sumen (1 - recetaChance)
    local probAjustadas = {}
    for rareza, prob in pairs(base) do
        probAjustadas[rareza] = prob * (1 - recetaChance)
    end

    return probAjustadas, recetaChance
end

-- Genera un ID único de breeding para el jugador.
local function nuevoBreedingId(uid)
    breedingCounter = breedingCounter + 1
    return tostring(uid) .. "_" .. tostring(breedingCounter)
end

--------------------------------------------------------------------------------
-- BreedingSystem
--------------------------------------------------------------------------------

local BreedingSystem = {}

--------------------------------------------------------------------------------
-- BreedingSystem.GetUnlockedRecipes(player)
--
-- Devuelve el conjunto de recetas desbloqueadas del jugador
-- (tabla { [recipeKey] = true }).
--------------------------------------------------------------------------------
function BreedingSystem.GetUnlockedRecipes(player)
    local datos = DataStore.GetPlayerData(player)
    if not datos then return {} end
    return datos.knownRecipes or {}
end

--------------------------------------------------------------------------------
-- BreedingSystem.UnlockRecipe(player, recipeKey)
--
-- Desbloquea una receta de breeding para el jugador.
-- recipeKey = elementos ordenados alfabéticamente: p.ej. "fire_water".
-- Se consigue en tienda (ShopService) o eventos.
-- Devuelve: (éxito, mensaje)
--------------------------------------------------------------------------------
function BreedingSystem.UnlockRecipe(player, recipeKey)
    if type(recipeKey) ~= "string" then return false, "Parámetros inválidos." end

    if not RECIPES[recipeKey] then
        return false, ("Receta '%s' no existe en el catálogo."):format(recipeKey)
    end

    local datos = DataStore.GetPlayerData(player)
    if not datos then return false, "No se pudieron leer tus datos." end

    datos.knownRecipes              = datos.knownRecipes or {}
    datos.knownRecipes[recipeKey]   = true

    return true, ("¡Receta '%s' desbloqueada!"):format(recipeKey)
end

--------------------------------------------------------------------------------
-- BreedingSystem.GetBreedingResult(dragonId1, dragonId2, player)
--
-- Calcula TODAS las posibilidades de resultado sin ejecutarlas.
-- Usado por la UI para mostrar probabilidades antes de confirmar el breeding.
-- player es opcional: si se pasa se comprueba si tiene la receta desbloqueada.
-- Devuelve una tabla con toda la información necesaria para la UI.
--------------------------------------------------------------------------------
function BreedingSystem.GetBreedingResult(dragonId1, dragonId2, player)
    local d1 = DragonData.GetDragonById(dragonId1)
    local d2 = DragonData.GetDragonById(dragonId2)
    if not d1 or not d2 then return nil end

    -- Receta aplicable a este par de elementos
    local key    = claveReceta(d1.element, d2.element)
    local receta = RECIPES[key]

    -- Revisar si el jugador tiene la receta desbloqueada
    local tieneReceta = false
    if receta and player then
        local unlocked = BreedingSystem.GetUnlockedRecipes(player)
        tieneReceta    = unlocked[key] == true
    end

    local probRareza, recetaChance = calcularProbabilidades(
        d1.rarity, d2.rarity, receta, tieneReceta)

    -- Tiempo de breeding: doble del incubationSeconds del dragón más lento
    local duracion = 2 * math.max(d1.incubationSeconds, d2.incubationSeconds)

    -- Construir probabilidades detalladas por rareza para la UI
    local desglosePorRareza = {}
    for rareza, prob in pairs(probRareza) do
        if prob > 0 then
            desglosePorRareza[rareza] = prob
        end
    end

    -- Información de receta para mostrar en UI
    local infoReceta = nil
    if receta then
        local dragonReceta = DragonData.GetDragonById(receta.resultId)
        infoReceta = {
            key             = key,
            resultId        = receta.resultId,
            nombre          = dragonReceta and dragonReceta.name or receta.resultId,
            probabilidad    = recetaChance,
            tieneReceta     = tieneReceta,
            chanceBase      = receta.chanceBase,
            chanceUnlocked  = receta.chanceUnlocked,
        }
    end

    return {
        padre1 = {
            id       = d1.id,
            nombre   = d1.name,
            rareza   = d1.rarity,
            elemento = d1.element,
        },
        padre2 = {
            id       = d2.id,
            nombre   = d2.name,
            rareza   = d2.rarity,
            elemento = d2.element,
        },
        posiblesElementos    = { d1.element, d2.element },  -- 50/50
        probabilidadesRareza = desglosePorRareza,           -- prob base × (1 - recetaChance)
        receta               = infoReceta,                  -- nil si no hay receta
        tiempoBreeding       = duracion,
        descripcion          = ("Combinando %s y %s…"):format(d1.name, d2.name),
    }
end

--------------------------------------------------------------------------------
-- BreedingSystem.GetBreedingStatus(player)
--
-- Devuelve el estado actual de todos los breedings activos del jugador:
--   { breedingId, dragonId1, dragonId2, completesAt, secondsLeft }
-- Incluye recetas desbloqueadas del jugador.
--------------------------------------------------------------------------------
function BreedingSystem.GetBreedingStatus(player)
    local uid    = player.UserId
    local ahora  = os.time()
    local activos = {}

    if breedingData[uid] then
        for breedingId, b in pairs(breedingData[uid]) do
            local d1 = DragonData.GetDragonById(b.dragonId1)
            local d2 = DragonData.GetDragonById(b.dragonId2)
            table.insert(activos, {
                breedingId   = breedingId,
                dragonId1    = b.dragonId1,
                nombre1      = d1 and d1.name or b.dragonId1,
                dragonId2    = b.dragonId2,
                nombre2      = d2 and d2.name or b.dragonId2,
                completesAt  = b.completesAt,
                secondsLeft  = math.max(0, b.completesAt - ahora),
                isReady      = ahora >= b.completesAt,
            })
        end
    end

    return {
        activos          = activos,
        hayBreeding      = #activos > 0,
        recetasDesbloq   = BreedingSystem.GetUnlockedRecipes(player),
    }
end

--------------------------------------------------------------------------------
-- BreedingSystem.StartBreeding(player, dragonId1, dragonId2)
--
-- Inicia el proceso de breeding entre dos dragones del inventario.
-- Validaciones:
--   · El jugador tiene breeding desbloqueado (nivel suficiente).
--   · Ambos dragones existen en el catálogo.
--   · El jugador tiene ambos dragones disponibles (no reservados, no en nido).
--   · Si son el mismo dragonId, necesita al menos 2 copias disponibles.
-- Reserva los padres y programa el timer.
-- Dispara RemoteEvent "BreedingStarted" con tiempo estimado y preview.
-- Devuelve: (éxito, { breedingId, tiempoBreeding } o mensaje)
--------------------------------------------------------------------------------
function BreedingSystem.StartBreeding(player, dragonId1, dragonId2)
    if type(dragonId1) ~= "string" or type(dragonId2) ~= "string" then
        return false, "Parámetros inválidos."
    end

    local uid   = player.UserId
    asegurarEstado(uid)

    local datos = DataStore.GetPlayerData(player)
    if not datos then return false, "No se pudieron leer tus datos." end

    -- Validar nivel: breeding se desbloquea según Constants.LEVELS
    local nivelData = LEVELS[datos.level or 1]
    if not nivelData or not nivelData.breedingUnlocked then
        return false, ("El Breeding Pen no está disponible todavía. "
            .. "Alcanza el nivel de prestige requerido.")
    end

    -- Validar que los dragones existen
    local d1 = DragonData.GetDragonById(dragonId1)
    local d2 = DragonData.GetDragonById(dragonId2)
    if not d1 then return false, ("Dragón desconocido: '%s'."):format(dragonId1) end
    if not d2 then return false, ("Dragón desconocido: '%s'."):format(dragonId2) end

    -- Validar disponibilidad en inventario (descontando reservas activas)
    if dragonId1 == dragonId2 then
        if disponibles(datos, uid, dragonId1) < 2 then
            return false, ("Necesitas 2 copias de '%s' disponibles "
                .. "(sin estar en nido ni en breeding)."):format(d1.name)
        end
    else
        if disponibles(datos, uid, dragonId1) < 1 then
            return false, ("'%s' no está disponible (está en nido o en breeding).")
                :format(d1.name)
        end
        if disponibles(datos, uid, dragonId2) < 1 then
            return false, ("'%s' no está disponible (está en nido o en breeding).")
                :format(d2.name)
        end
    end

    -- Calcular duración del breeding: 2 × incubationSeconds del más lento
    local duracion  = 2 * math.max(d1.incubationSeconds, d2.incubationSeconds)
    local ahora     = os.time()
    local breedingId = nuevoBreedingId(uid)

    -- Registrar breeding activo
    breedingData[uid][breedingId] = {
        dragonId1   = dragonId1,
        dragonId2   = dragonId2,
        startedAt   = ahora,
        completesAt = ahora + duracion,
        duration    = duracion,
    }

    -- Reservar ambos padres
    reservar(uid, dragonId1)
    reservar(uid, dragonId2)

    -- Preparar preview para el cliente
    local preview = BreedingSystem.GetBreedingResult(dragonId1, dragonId2, player)

    BreedingStartedEvent:FireClient(player, {
        breedingId   = breedingId,
        dragonId1    = dragonId1,
        nombre1      = d1.name,
        dragonId2    = dragonId2,
        nombre2      = d2.name,
        completesAt  = ahora + duracion,
        tiempoBreeding = duracion,
        preview      = preview,
    })

    return true, { breedingId = breedingId, tiempoBreeding = duracion }
end

--------------------------------------------------------------------------------
-- BreedingSystem.CompleteBreeding(player, breedingId)
--
-- Completa el breeding cuando el timer termina (o se acelera con gemas).
-- Calcula el resultado usando tablas de rareza y recetas.
-- Libera los padres (quita reserva). Añade el hijo al inventario.
-- Dispara RemoteEvent "BreedingCompleted" con resultado completo.
-- Devuelve: (éxito, datos del resultado o mensaje)
--------------------------------------------------------------------------------
function BreedingSystem.CompleteBreeding(player, breedingId)
    local uid     = player.UserId
    local datos   = breedingData[uid] and breedingData[uid][breedingId]

    if not datos then
        return false, "Breeding no encontrado o ya completado."
    end

    local d1 = DragonData.GetDragonById(datos.dragonId1)
    local d2 = DragonData.GetDragonById(datos.dragonId2)

    -- Fallback si un dragón padre fue eliminado del catálogo
    if not d1 or not d2 then
        breedingData[uid][breedingId] = nil
        liberar(uid, datos.dragonId1)
        liberar(uid, datos.dragonId2)
        return false, "Datos de breeding corruptos; padres liberados."
    end

    -- Receta aplicable
    local key    = claveReceta(d1.element, d2.element)
    local receta = RECIPES[key]

    local playerData  = DataStore.GetPlayerData(player)
    local tieneReceta = false
    if receta and playerData then
        tieneReceta = (playerData.knownRecipes or {})[key] == true
    end

    local probRareza, recetaChance = calcularProbabilidades(
        d1.rarity, d2.rarity, receta, tieneReceta)

    -- Determinar si activa la receta
    local esFueReceta   = false
    local dragonHijoId  = nil

    if receta and math.random() < recetaChance then
        -- ¡La receta se activó!
        esFueReceta  = true
        dragonHijoId = receta.resultId
    else
        -- Resultado normal: sortear rareza y luego elegir dragón
        local rarezaSorteada = sortearRareza(probRareza)
        -- Elemento: 50 % del padre 1 o 50 % del padre 2
        local elementoBase = math.random() < 0.5 and d1.element or d2.element
        dragonHijoId = elegirDragonResultado(elementoBase, rarezaSorteada)
        if not dragonHijoId then
            -- Fallback extremo: dar un dragón comun de cualquier elemento
            dragonHijoId = elegirDragonResultado("fuego", "comun") or "fire_common"
        end
    end

    local dragonHijo = DragonData.GetDragonById(dragonHijoId)

    -- Liberar padres (se devuelven al inventario disponible)
    liberar(uid, datos.dragonId1)
    liberar(uid, datos.dragonId2)

    -- Eliminar del registro de breedings activos
    breedingData[uid][breedingId] = nil

    -- Añadir el hijo al inventario del jugador
    DataStore.AddDragonToInventory(player, dragonHijoId)

    -- Construir tabla de probabilidades que se usó (para transparencia en UI)
    local probUsadas = {}
    for k, v in pairs(probRareza) do probUsadas[k] = v end
    if receta then
        probUsadas["_receta"] = recetaChance
    end

    BreedingCompletedEvent:FireClient(player, {
        breedingId     = breedingId,
        dragonId       = dragonHijoId,
        nombre         = dragonHijo and dragonHijo.name or dragonHijoId,
        rareza         = dragonHijo and dragonHijo.rarity or "?",
        elemento       = dragonHijo and dragonHijo.element or "?",
        fueReceta      = esFueReceta,
        recetaKey      = esFueReceta and key or nil,
        padre1         = datos.dragonId1,
        padre2         = datos.dragonId2,
        probabilidades = probUsadas,  -- tabla completa para la UI
    })

    return true, { dragonId = dragonHijoId, fueReceta = esFueReceta }
end

--------------------------------------------------------------------------------
-- BreedingSystem.CancelBreeding(player, breedingId)
--
-- Cancela el breeding en progreso.
-- Libera los padres (sin penalización de inventario).
-- No se devuelve el tiempo invertido.
-- Dispara RemoteEvent "BreedingCancelled".
-- Devuelve: (éxito, mensaje)
--------------------------------------------------------------------------------
function BreedingSystem.CancelBreeding(player, breedingId)
    local uid   = player.UserId
    local datos = breedingData[uid] and breedingData[uid][breedingId]

    if not datos then
        return false, "Breeding no encontrado o ya completado."
    end

    -- Liberar padres
    liberar(uid, datos.dragonId1)
    liberar(uid, datos.dragonId2)

    breedingData[uid][breedingId] = nil

    local d1 = DragonData.GetDragonById(datos.dragonId1)
    local d2 = DragonData.GetDragonById(datos.dragonId2)

    BreedingCancelledEvent:FireClient(player, {
        breedingId = breedingId,
        dragonId1  = datos.dragonId1,
        nombre1    = d1 and d1.name or datos.dragonId1,
        dragonId2  = datos.dragonId2,
        nombre2    = d2 and d2.name or datos.dragonId2,
    })

    return true, "Breeding cancelado. Tus dragones están de vuelta."
end

--------------------------------------------------------------------------------
-- BreedingSystem.SpeedUpBreeding(player, breedingId)
--
-- Gasta SPEEDUP_COST_GEMS gemas para completar el breeding instantáneamente.
-- Valida que el breeding existe y el jugador tiene las gemas.
-- Devuelve: (éxito, resultado del breeding o mensaje)
--------------------------------------------------------------------------------
function BreedingSystem.SpeedUpBreeding(player, breedingId)
    if type(breedingId) ~= "string" then return false, "Parámetros inválidos." end

    local uid   = player.UserId
    local datos = breedingData[uid] and breedingData[uid][breedingId]

    if not datos then
        return false, "Breeding no encontrado o ya completado."
    end

    local ok = DataStore.SpendGems(player, SPEEDUP_COST_GEMS)
    if not ok then
        return false, ("Necesitas %d gemas para acelerar el breeding.")
            :format(SPEEDUP_COST_GEMS)
    end

    -- Marcar como completado inmediatamente y resolver
    datos.completesAt = os.time()
    return BreedingSystem.CompleteBreeding(player, breedingId)
end

--------------------------------------------------------------------------------
-- Loop principal — revisa breedings cada 10 segundos
--
-- Si el timer de un breeding completó, llama CompleteBreeding automáticamente.
-- Si el jugador ya no está en el servidor, limpia el estado sin completar.
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(10)
        local ahora = os.time()

        for uid, breedings in pairs(breedingData) do
            for breedingId, datos in pairs(breedings) do
                if ahora >= datos.completesAt then
                    local player = Players:GetPlayerByUserId(tonumber(uid) or uid)
                    if player then
                        task.spawn(function()
                            BreedingSystem.CompleteBreeding(player, breedingId)
                        end)
                    else
                        -- El jugador se fue antes de que completara: limpiar reservas
                        liberar(uid, datos.dragonId1)
                        liberar(uid, datos.dragonId2)
                        breedings[breedingId] = nil
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
--------------------------------------------------------------------------------

StartBreedingFunc.OnServerInvoke = function(player, dragonId1, dragonId2)
    if type(dragonId1) ~= "string" or type(dragonId2) ~= "string" then
        return false, "Parámetros inválidos."
    end
    return BreedingSystem.StartBreeding(player, dragonId1, dragonId2)
end

CancelBreedingFunc.OnServerInvoke = function(player, breedingId)
    if type(breedingId) ~= "string" then return false, "Parámetros inválidos." end
    return BreedingSystem.CancelBreeding(player, breedingId)
end

PreviewBreedingFunc.OnServerInvoke = function(player, dragonId1, dragonId2)
    if type(dragonId1) ~= "string" or type(dragonId2) ~= "string" then
        return false, "Parámetros inválidos."
    end
    -- Incluir player para que el preview refleje recetas desbloqueadas del jugador
    local result = BreedingSystem.GetBreedingResult(dragonId1, dragonId2, player)
    if not result then return false, "Dragones inválidos." end
    return true, result
end

SpeedUpBreedingFunc.OnServerInvoke = function(player, breedingId)
    if type(breedingId) ~= "string" then return false, "Parámetros inválidos." end
    return BreedingSystem.SpeedUpBreeding(player, breedingId)
end

--------------------------------------------------------------------------------
-- Ciclo de vida de jugadores
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
    local uid = player.UserId
    -- Liberar todas las reservas (los breedings se cancelan implícitamente al salir)
    if breedingData[uid] then
        for _, datos in pairs(breedingData[uid]) do
            liberar(uid, datos.dragonId1)
            liberar(uid, datos.dragonId2)
        end
    end
    breedingData[uid] = nil
    reserved[uid]     = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
    asegurarEstado(player.UserId)
end

--------------------------------------------------------------------------------

return BreedingSystem
