--------------------------------------------------------------------------------
-- Constants.lua  ·  ModuleScript  ·  Dragon Roost
--
-- Fuente única de verdad para todos los valores configurables del juego.
-- Importar con:  local C = require(game.ReplicatedStorage.Shared.Constants)
--------------------------------------------------------------------------------

local Constants = {}

--------------------------------------------------------------------------------
-- NIDOS
-- NestSlots[nivel] → cantidad total de slots disponibles en ese nivel de nido
--   (niveles 1-15).
-- ExtraSlotCost[slotIndex] → costo en oro para desbloquear ese slot adicional.
--   El slot 1 de cada nido es gratis (incluido en el nivel 1).
--   Slots 2-20 cuestan oro. El costo parte en 500 y se duplica por slot.
--------------------------------------------------------------------------------

Constants.NIDOS = {

    -- Slots desbloqueados por nivel de nido (nivel 1 = 3, nivel 15 = 20).
    -- La curva suma 1 slot por nivel hasta el 8, luego 1-2 por nivel.
    SlotsDisponibles = {
        [1]  = 3,
        [2]  = 4,
        [3]  = 5,
        [4]  = 6,
        [5]  = 7,
        [6]  = 8,
        [7]  = 9,
        [8]  = 10,
        [9]  = 11,
        [10] = 13,
        [11] = 14,
        [12] = 16,
        [13] = 17,
        [14] = 19,
        [15] = 20,
    },

    -- Costo en oro para comprar cada slot adicional (índice = número de slot, 2-20).
    -- Fórmula: 500 * 2^(slotIndex - 2)   →  500, 1000, 2000, 4000 …
    CostoSlotExtra = {
        [2]  =       500,
        [3]  =     1_000,
        [4]  =     2_000,
        [5]  =     4_000,
        [6]  =     8_000,
        [7]  =    16_000,
        [8]  =    32_000,
        [9]  =    64_000,
        [10] =   128_000,
        [11] =   256_000,
        [12] =   512_000,
        [13] = 1_024_000,
        [14] = 2_048_000,
        [15] = 4_096_000,
        [16] = 8_192_000,
        [17] = 16_384_000,
        [18] = 32_768_000,
        [19] = 65_536_000,
        [20] = 131_072_000,
    },

    NivelMaximo = 15,
    MaxLevel    = 15,   -- alias para compatibilidad con NestSystem
}

-- Aliases de compatibilidad para código que aún use los nombres anteriores en inglés
Constants.NIDOS.NestSlots     = Constants.NIDOS.SlotsDisponibles
Constants.NIDOS.ExtraSlotCost = Constants.NIDOS.CostoSlotExtra
Constants.NIDOS.MaxLevel      = Constants.NIDOS.NivelMaximo
Constants.NESTS = Constants.NIDOS

--------------------------------------------------------------------------------
-- PRESTIGE
-- Requisitos para ALCANZAR cada nivel de prestige (indexado por nivel objetivo).
-- DragonRequirements: cantidad mínima de dragones poseídos por rareza (totales).
-- oroActualRequerido: oro actual que debe tener el jugador en ese momento
--   (no oro histórico — se verifica el balance actual y se resetea a 0 al prestige).
--------------------------------------------------------------------------------

Constants.PRESTIGE = {

    -- [nivelObjetivo] = { DragonRequirements = { rareza = cantidad }, oroActualRequerido = n }
    [2] = {
        DragonRequirements  = { comun = 2, poco_comun = 1 },
        oroActualRequerido  = 1_000,
    },
    [3] = {
        DragonRequirements  = { comun = 5, poco_comun = 3, raro = 1 },
        oroActualRequerido  = 4_000,
    },
    [4] = {
        DragonRequirements  = { comun = 8, poco_comun = 5, raro = 2 },
        oroActualRequerido  = 15_000,
    },
    [5] = {
        DragonRequirements  = { comun = 12, poco_comun = 8, raro = 4, epico = 1 },
        oroActualRequerido  = 60_000,
    },
    [6] = {
        DragonRequirements  = { comun = 16, poco_comun = 12, raro = 6, epico = 2 },
        oroActualRequerido  = 200_000,
    },
    [7] = {
        DragonRequirements  = { comun = 20, poco_comun = 15, raro = 8, epico = 4 },
        oroActualRequerido  = 800_000,
    },
    [8] = {
        DragonRequirements  = { comun = 25, poco_comun = 18, raro = 10, epico = 6, legendario = 1 },
        oroActualRequerido  = 3_000_000,
    },
    [9] = {
        DragonRequirements  = { comun = 30, poco_comun = 22, raro = 14, epico = 8, legendario = 2 },
        oroActualRequerido  = 12_000_000,
    },
    [10] = {
        DragonRequirements  = { comun = 36, poco_comun = 26, raro = 18, epico = 10, legendario = 3 },
        oroActualRequerido  = 50_000_000,
    },
    [11] = {
        DragonRequirements  = { comun = 42, poco_comun = 30, raro = 22, epico = 14, legendario = 5, mitico = 1 },
        oroActualRequerido  = 200_000_000,
    },
    [12] = {
        DragonRequirements  = { comun = 50, poco_comun = 35, raro = 26, epico = 18, legendario = 7, mitico = 2 },
        oroActualRequerido  = 800_000_000,
    },
    [13] = {
        DragonRequirements  = { comun = 58, poco_comun = 40, raro = 30, epico = 22, legendario = 10, mitico = 3 },
        oroActualRequerido  = 3_000_000_000,
    },
    [14] = {
        DragonRequirements  = { comun = 68, poco_comun = 48, raro = 36, epico = 28, legendario = 14, mitico = 5 },
        oroActualRequerido  = 15_000_000_000,
    },
    [15] = {
        DragonRequirements  = { comun = 80, poco_comun = 56, raro = 42, epico = 35, legendario = 20, mitico = 8 },
        oroActualRequerido  = 100_000_000_000,
    },

    NivelMaximo = 15,
    MaxLevel    = 15,   -- alias para compatibilidad con NestSystem
}

--------------------------------------------------------------------------------
-- TIENDAS
-- El juego tiene DOS tiendas con lógicas y timers independientes.
--
-- TIENDA_RAPIDA  — solo dragones y huevos, rota cada 3 minutos.
-- TIENDA_ESPECIAL — nunca dragones, solo ítems especiales, rota cada 10 minutos.
--------------------------------------------------------------------------------

Constants.TIENDA_RAPIDA = {
    SegundosRotacion = 180,          -- 3 minutos entre rotaciones automáticas
    ConteoSlots      = 6,            -- slots de dragones/huevos visibles
    StockMax         = 3,            -- máximo de copias por slot por rotación
    SoloTipos        = { "dragon", "huevo" },
}

Constants.TIENDA_ESPECIAL = {
    SegundosRotacion = 600,          -- 10 minutos entre rotaciones automáticas
    ConteoSlots      = 4,            -- slots de ítems especiales
    StockMax         = 1,            -- 1 unidad por slot (más exclusivo)
    NuncaDragones    = true,         -- nunca incluye dragones ni huevos
    -- Tipos posibles: mejora_nido, potenciador, evento_climatico, receta_cria, cosmetico, vacio
}

-- Alias de compatibilidad para código heredado que use Constants.SHOP
Constants.SHOP = {
    RotationSeconds   = Constants.TIENDA_RAPIDA.SegundosRotacion,
    ManualRefreshGems = 3,
    SlotCount         = Constants.TIENDA_RAPIDA.ConteoSlots,
    MaxStock          = Constants.TIENDA_RAPIDA.StockMax,
}

--------------------------------------------------------------------------------
-- ECONOMÍA
-- El oro pasivo se acumula mientras el jugador está desconectado.
-- Si no se recoge a tiempo, una parte se evapora para incentivar sesiones regulares.
--------------------------------------------------------------------------------

Constants.ECONOMIA = {
    -- Tras MaxSegundosIdle, se pierde GoldEvaporationRate del oro acumulado.
    MaxSegundosIdle      = 600,   -- 10 minutos de inactividad antes de evaporación
    TasaEvaporacion      = 0.25,  -- 25% del oro sin recoger desaparece
}

-- Alias de compatibilidad
Constants.ECONOMY = {
    MaxIdleSeconds      = Constants.ECONOMIA.MaxSegundosIdle,
    GoldEvaporationRate = Constants.ECONOMIA.TasaEvaporacion,
}

--------------------------------------------------------------------------------
-- EVENTOS  (eventos climáticos / del mundo)
-- Seis eventos climáticos se activan aleatoriamente mientras corre el juego.
-- Las probabilidades deben sumar 1.0.
-- Los IDs de evento coinciden exactamente con los definidos en WeatherSystem.
--------------------------------------------------------------------------------

Constants.EVENTS = {
    MinDurationSeconds  = 180,   -- duración mínima de un evento climático
    MaxDurationSeconds  = 480,   -- duración máxima de un evento climático
    MinCooldownSeconds  = 300,   -- tiempo mínimo entre eventos consecutivos

    -- Probabilidades de aparición de cada evento (deben sumar 1.0)
    WeatherProbabilities = {
        sol_dorado         = 0.30,   -- bonus de oro para dragones de fuego
        lluvia_magica      = 0.20,   -- bonus de oro para dragones de agua y hielo
        erupcion_volcanica = 0.15,   -- bonus de oro para dragones de fuego, penaliza naturaleza/hielo
        tormenta_electrica = 0.15,   -- bonus de oro para dragones de trueno
        noche_eterna       = 0.12,   -- bonus de oro para dragones de sombra, penaliza celestial
        rift_dimensional   = 0.08,   -- bonus de oro para dragones del vacío (raro, alta recompensa)
    },

    -- Multiplicador de oro principal que aplica cada evento
    WeatherBonusMultiplier = {
        sol_dorado         = 1.5,
        lluvia_magica      = 3.0,
        erupcion_volcanica = 3.0,
        tormenta_electrica = 4.0,
        noche_eterna       = 5.0,
        rift_dimensional   = 2.0,
    },
}

--------------------------------------------------------------------------------
-- POTENCIADORES
-- Multiplicadores temporales comprables con gemas.
-- Cada entrada: id, nombre, descripción, duración, multiplicador, costo en gemas.
--------------------------------------------------------------------------------

Constants.BOOSTS = {
    {
        id          = "gold_rush",
        name        = "Torbellino de Oro",
        description = "Todos los dragones producen el doble de oro.",
        duration    = 300,    -- 5 minutos
        multiplier  = 2.0,
        gemCost     = 5,
    },
    {
        id          = "hatch_fever",
        name        = "Fiebre de Eclosión",
        description = "Los tiempos de incubación de huevos corren al triple de velocidad.",
        duration    = 600,    -- 10 minutos
        multiplier  = 3.0,    -- aplicado a la velocidad de incubación
        gemCost     = 8,
    },
    {
        id          = "golden_hour",
        name        = "Hora Dorada",
        description = "Gana 3× oro durante un período extendido.",
        duration    = 3_600,  -- 1 hora
        multiplier  = 3.0,
        gemCost     = 20,
    },
    {
        id          = "lucky_egg",
        name        = "Huevo de la Suerte",
        description = "Las probabilidades de rareza suben un nivel para todos los huevos.",
        duration    = 900,    -- 15 minutos
        multiplier  = 1.0,    -- la lógica de rareza maneja el cambio de nivel
        gemCost     = 15,
    },
    {
        id          = "breeding_boost",
        name        = "Impulso de Cría",
        description = "Los tiempos de cría se reducen a la mitad y las combinaciones raras son más probables.",
        duration    = 1_200,  -- 20 minutos
        multiplier  = 2.0,    -- multiplicador de velocidad del timer
        gemCost     = 12,
    },
    {
        id          = "mega_gold",
        name        = "Mega Oro",
        description = "Un estallido legendario de 5× oro durante una breve ventana.",
        duration    = 120,    -- 2 minutos
        multiplier  = 5.0,
        gemCost     = 10,
    },
}

--------------------------------------------------------------------------------
-- BOOST_TYPES
-- Boosts de producción vendidos en la Tienda Especial.
-- Diccionario keyed por boostId para acceso O(1).
-- alcance "dragon" → un nido específico; "granja" → todos los nidos con dragón.
--------------------------------------------------------------------------------

Constants.BOOST_TYPES = {
    festin    = { nombre = "Festín",            multiplicador = 1.5, duracionSeg = 1800, alcance = "dragon" },
    cristal   = { nombre = "Cristal",           multiplicador = 2.0, duracionSeg = 3600, alcance = "dragon" },
    runa      = { nombre = "Runa",              multiplicador = 3.0, duracionSeg = 900,  alcance = "dragon" },
    bendicion = { nombre = "Bendición",         multiplicador = 1.25,duracionSeg = 3600, alcance = "granja" },
    corona    = { nombre = "Corona",            multiplicador = 5.0, duracionSeg = 600,  alcance = "dragon" },
    x2_1h     = { nombre = "Potenciador ×2 (1 h)",    multiplicador = 2.0, duracionSeg = 3600, alcance = "granja" },
    x3_30min  = { nombre = "Potenciador ×3 (30 min)", multiplicador = 3.0, duracionSeg = 1800, alcance = "granja" },
}

--------------------------------------------------------------------------------
-- INVENTORY_LIMITS
-- Límite de inventario compartido (dragones + huevos) por nivel de prestige.
-- El jugador no puede tener más de este número de dragones + huevos combinados.
--------------------------------------------------------------------------------

Constants.INVENTORY_LIMITS = {
    [1]  = 5,  [2]  = 6,  [3]  = 7,  [4]  = 8,  [5]  = 9,
    [6]  = 10, [7]  = 10, [8]  = 11, [9]  = 11,
    [10] = 12, [11] = 12, [12] = 13, [13] = 13,
    [14] = 14, [15] = 15,
}

--------------------------------------------------------------------------------
-- RAREZAS
-- Probabilidades de eclosión basadas en la rareza del dragón PADRE utilizado.
-- Cada sub-tabla debe sumar 1.0 en todas las claves de rareza.
-- Padres de mayor rareza desplazan la distribución hacia mejores resultados.
--
-- Uso: Constants.RARIDADES.ChancesEclosion["epico"]["legendario"]
--      → probabilidad de eclosionar un legendario desde un padre épico
--------------------------------------------------------------------------------

Constants.RARIDADES = {

    -- Orden base de rareza para visualización / ordenamiento (menor índice = más común)
    Orden = { "comun", "poco_comun", "raro", "epico", "legendario", "mitico" },

    ChancesEclosion = {
        comun = {
            comun      = 0.650,
            poco_comun = 0.250,
            raro       = 0.075,
            epico      = 0.020,
            legendario = 0.004,
            mitico     = 0.001,
        },
        poco_comun = {
            comun      = 0.450,
            poco_comun = 0.340,
            raro       = 0.140,
            epico      = 0.050,
            legendario = 0.015,
            mitico     = 0.005,
        },
        raro = {
            comun      = 0.250,
            poco_comun = 0.340,
            raro       = 0.250,
            epico      = 0.110,
            legendario = 0.040,
            mitico     = 0.010,
        },
        epico = {
            comun      = 0.100,
            poco_comun = 0.200,
            raro       = 0.330,
            epico      = 0.240,
            legendario = 0.100,
            mitico     = 0.030,
        },
        legendario = {
            comun      = 0.040,
            poco_comun = 0.100,
            raro       = 0.200,
            epico      = 0.330,
            legendario = 0.240,
            mitico     = 0.090,
        },
        mitico = {
            comun      = 0.010,
            poco_comun = 0.040,
            raro       = 0.100,
            epico      = 0.200,
            legendario = 0.350,
            mitico     = 0.300,
        },
    },
}

-- Alias de compatibilidad para código heredado que use Constants.RARITIES
Constants.RARITIES = {
    Order        = Constants.RARIDADES.Orden,
    HatchChances = Constants.RARIDADES.ChancesEclosion,
}

--------------------------------------------------------------------------------
-- NIVELES  (progresión del jugador)
-- Indexado por nivel de jugador. Cada entrada describe qué se desbloquea.
-- zone             → clave de zona del mundo (identificador, no se traduce)
-- shopMaxRarity    → rareza máxima que puede aparecer en la tienda en ese nivel
-- breedingUnlocked → si la pluma de cría está disponible
--------------------------------------------------------------------------------

Constants.LEVELS = {

    [1] = {
        zone             = "starter_meadow",
        shopMaxRarity    = "comun",
        breedingUnlocked = false,
        description      = "La Pradera Inicial — tu primer nido te espera.",
    },
    [2] = {
        zone             = "starter_meadow",
        shopMaxRarity    = "comun",
        breedingUnlocked = false,
        description      = "Un segundo slot de nido se abre en la Pradera.",
    },
    [3] = {
        zone             = "ember_hills",
        shopMaxRarity    = "poco_comun",
        breedingUnlocked = false,
        description      = "Las Colinas Brasas se desbloquean — dragones de fuego y naturaleza rondan aquí.",
    },
    [4] = {
        zone             = "ember_hills",
        shopMaxRarity    = "poco_comun",
        breedingUnlocked = false,
        description      = "La tienda ahora ofrece dragones Poco Comunes.",
    },
    [5] = {
        zone             = "frosted_peaks",
        shopMaxRarity    = "poco_comun",
        breedingUnlocked = false,
        description      = "Las Cimas Heladas — hogar de dragones de hielo y trueno.",
    },
    [6] = {
        zone             = "frosted_peaks",
        shopMaxRarity    = "raro",
        breedingUnlocked = false,
        description      = "Los dragones Raros comienzan a aparecer en la tienda.",
    },
    [7] = {
        zone             = "shadow_vale",
        shopMaxRarity    = "raro",
        breedingUnlocked = true,    -- ← LA CRÍA SE DESBLOQUEA AQUÍ
        description      = "El Valle de Sombra abre sus puertas y la Pluma de Cría se construye.",
    },
    [8] = {
        zone             = "shadow_vale",
        shopMaxRarity    = "raro",
        breedingUnlocked = true,
        description      = "Un rincón más profundo del Valle de Sombra se vuelve accesible.",
    },
    [9] = {
        zone             = "celestial_spire",
        shopMaxRarity    = "epico",
        breedingUnlocked = true,
        description      = "La Aguja Celestial — dragones Épicos surcan los cielos aquí.",
    },
    [10] = {
        zone             = "celestial_spire",
        shopMaxRarity    = "epico",
        breedingUnlocked = true,
        description      = "Los dragones Épicos aparecen ahora en la tienda.",
    },
    [11] = {
        zone             = "void_rift",
        shopMaxRarity    = "epico",
        breedingUnlocked = true,
        description      = "La Grieta del Vacío se abre — los dragones del vacío emergen de la oscuridad.",
    },
    [12] = {
        zone             = "void_rift",
        shopMaxRarity    = "legendario",
        breedingUnlocked = true,
        description      = "Se rumorea que los dragones Legendarios aparecen en la tienda.",
    },
    [13] = {
        zone             = "ancient_summit",
        shopMaxRarity    = "legendario",
        breedingUnlocked = true,
        description      = "La Cima Antigua — donde los dragones Legendarios construyen sus eyries.",
    },
    [14] = {
        zone             = "ancient_summit",
        shopMaxRarity    = "legendario",
        breedingUnlocked = true,
        description      = "Toda la cima se vuelve explorable.",
    },
    [15] = {
        zone             = "mythic_sanctum",
        shopMaxRarity    = "mitico",
        breedingUnlocked = true,
        description      = "El Santuario Mítico — los dragones más raros de la existencia aguardan aquí.",
    },

    MaxLevel = 15,
}

return Constants
