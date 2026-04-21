--------------------------------------------------------------------------------
-- DragonData.lua  ·  ModuleScript  ·  Dragon Roost
--
-- Exporta:
--   DragonData.Dragons             → array con todas las definiciones de dragones
--   DragonData.GetDragonById       → function(id: string) → dragón | nil
--   DragonData.GetDragonsByElement → function(elemento: string) → dragón[]
--   DragonData.GetDragonsByRarity  → function(rareza: string) → dragón[]
--
-- NOTA: Los IDs de dragones (ej: "fire_rare") son claves internas únicas y NO
--   se traducen, para mantener compatibilidad con datos guardados en DataStore.
--   Los valores de campo `element` y `rarity` SÍ están en español.
--------------------------------------------------------------------------------

local DragonData = {}

-- ---------------------------------------------------------------------------
-- Constantes compartidas usadas al construir la tabla
-- ---------------------------------------------------------------------------

-- Oro por segundo según rareza
local OPS = {
    comun      =   2,
    poco_comun =   6,
    raro       =  20,
    epico      =  65,
    legendario = 200,
    mitico     = 800,
}

-- Tiempo de huevo en segundos según rareza
local HUEVO = {
    comun      =    300,
    poco_comun =    900,
    raro       =   2700,
    epico      =   7200,
    legendario =  21600,
    mitico     =  86400,
}

-- La incubación es siempre la mitad del timer del huevo
local function incub(rareza) return HUEVO[rareza] / 2 end

-- Escala del modelo según rareza
local ESCALA = {
    comun      = 1.0,
    poco_comun = 1.2,
    raro       = 1.5,
    epico      = 2.0,
    legendario = 2.5,
    mitico     = 3.0,
}

-- Colores de partícula por elemento
local CE = {
    fuego       = Color3.fromRGB(255,  90,  20),
    agua        = Color3.fromRGB( 30, 130, 255),
    hielo       = Color3.fromRGB(180, 230, 255),
    trueno      = Color3.fromRGB(255, 240,  50),
    naturaleza  = Color3.fromRGB( 50, 200,  80),
    sombra      = Color3.fromRGB(100,  20, 180),
    celestial   = Color3.fromRGB(255, 220, 100),
    vacio       = Color3.fromRGB( 50,   0, 100),
}

-- ---------------------------------------------------------------------------
-- Tabla de dragones
-- ---------------------------------------------------------------------------

DragonData.Dragons = {

    ----------------------------------------------------------------------------
    -- FUEGO
    ----------------------------------------------------------------------------
    {
        id                = "fire_common",
        name              = "Drake Brasa",
        element           = "fuego",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.fuego,
        description       = "La punta de su cola nunca deja de brillar con un tenue resplandor anaranjado.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "fire_uncommon",
        name              = "Víbora Ceniza",
        element           = "fuego",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.fuego,
        description       = "Deja una estela de ascuas brillantes flotando tras sus alas.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "fire_rare",
        name              = "Dragón Crestafuego",
        element           = "fuego",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.fuego,
        description       = "Una corona de llamas eternas arde sobre su orgullosa cabeza.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "fire_epic",
        name              = "Alafuego",
        element           = "fuego",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.fuego,
        description       = "Sus alas, forjadas de fuego puro, chamuscan el cielo con cada aleteo.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "fire_legendary",
        name              = "Infernalis",
        element           = "fuego",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.fuego,
        description       = "Un señor del fuego ancestral cuyo rugido puede incendiar bosques enteros.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "fire_mythic",
        name              = "Infernus",
        element           = "fuego",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.fuego,
        description       = "La encarnación viviente de la furia volcánica; nacido de una estrella agonizante.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- AGUA
    ----------------------------------------------------------------------------
    {
        id                = "water_common",
        name              = "Serpiente de Arroyo",
        element           = "agua",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.agua,
        description       = "Una serpiente apacible que juega en riachuelos cristalinos poco profundos.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "water_uncommon",
        name              = "Drake Mareal",
        element           = "agua",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.agua,
        description       = "Cabalga las olas del océano con una gracia fluida e inigualable.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "water_rare",
        name              = "Dragón Coral",
        element           = "agua",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.agua,
        description       = "Formaciones de coral vivo crecen naturalmente a lo largo de su lomo.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "water_epic",
        name              = "Víbora Tormenta-Marea",
        element           = "agua",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.agua,
        description       = "Domina las corrientes marinas y convoca remolinos a voluntad.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "water_legendary",
        name              = "Drake Abisal",
        element           = "agua",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.agua,
        description       = "Emerge de las fosas oceánicas más profundas una vez por siglo.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "water_mythic",
        name              = "Leviatán",
        element           = "agua",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.agua,
        description       = "El gran dragón marino de la leyenda; su aliento inunda continentes enteros.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- HIELO
    ----------------------------------------------------------------------------
    {
        id                = "ice_common",
        name              = "Cría de Escarcha",
        element           = "hielo",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.hielo,
        description       = "Deja diminutos y perfectos cristales de hielo en cada lugar que pisa.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "ice_uncommon",
        name              = "Drake Glacioala",
        element           = "hielo",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.hielo,
        description       = "Sus alas son láminas translúcidas de reluciente hielo glaciar.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "ice_rare",
        name              = "Dragón Permafrost",
        element           = "hielo",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.hielo,
        description       = "Envuelve todo lo que toca en una capa de escarcha instantánea.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "ice_epic",
        name              = "Víbora Ventisca",
        element           = "hielo",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.hielo,
        description       = "Invoca tormentas de nieve cegadoras con un único y lento exhalido.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "ice_legendary",
        name              = "Drake Avalancha",
        element           = "hielo",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.hielo,
        description       = "Su rugido derrumba montañas enteras de nieve hacia los valles.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "ice_mythic",
        name              = "Glacius Rex",
        element           = "hielo",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.hielo,
        description       = "El rey inmortal de los páramos helados; más antiguo que el propio invierno.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- TRUENO
    ----------------------------------------------------------------------------
    {
        id                = "thunder_common",
        name              = "Drake Chispa",
        element           = "trueno",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.trueno,
        description       = "Crepita con chispas inofensivas cada vez que se emociona.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "thunder_uncommon",
        name              = "Ala de Tormenta",
        element           = "trueno",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.trueno,
        description       = "Cada aleteo genera una carga estática que eriza el vello de quien se acerca.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "thunder_rare",
        name              = "Dragón Crestacero",
        element           = "trueno",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.trueno,
        description       = "Una cresta de minirayos recorre toda la longitud de su lomo.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "thunder_epic",
        name              = "Víbora Voltaica",
        element           = "trueno",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.trueno,
        description       = "Electrifica el aire a kilómetros a la redonda con electricidad cruda y pura.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "thunder_legendary",
        name              = "Drake Tempestad",
        element           = "trueno",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.trueno,
        description       = "Nacido dentro de una tormenta; controla el rayo como derecho de nacimiento.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "thunder_mythic",
        name              = "Fulminaris",
        element           = "trueno",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.trueno,
        description       = "La tormenta hecha carne; su grito divide el cielo de horizonte a horizonte.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- NATURALEZA
    ----------------------------------------------------------------------------
    {
        id                = "nature_common",
        name              = "Drake Hoja",
        element           = "naturaleza",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.naturaleza,
        description       = "Pequeñas plantas brotan durante la noche en cada lugar donde ha caído su sombra.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "nature_uncommon",
        name              = "Víbora Espinazo",
        element           = "naturaleza",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.naturaleza,
        description       = "Las hileras de afiladas espinas en su lomo hacen que los abrazos sean desaconsejables.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "nature_rare",
        name              = "Dragón Verdor",
        element           = "naturaleza",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.naturaleza,
        description       = "Flores silvestres y enredaderas florecen espontáneamente sobre sus escamas.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "nature_epic",
        name              = "Drake Dosel",
        element           = "naturaleza",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.naturaleza,
        description       = "Planea tan lentamente que los pájaros anidan en sus anchas alas extendidas.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "nature_legendary",
        name              = "Víbora Bosque Anciano",
        element           = "naturaleza",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.naturaleza,
        description       = "Tan antiguo como el árbol más viejo; sus escamas de corteza albergan ecosistemas enteros.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "nature_mythic",
        name              = "Sylvanus",
        element           = "naturaleza",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.naturaleza,
        description       = "El espíritu del primer bosque del mundo, encarnado en forma dracónica.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- SOMBRA
    ----------------------------------------------------------------------------
    {
        id                = "shadow_common",
        name              = "Sprite Crepúsculo",
        element           = "sombra",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.sombra,
        description       = "Un espectro travieso que se oculta en las sombras más largas del atardecer.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "shadow_uncommon",
        name              = "Drake Ala Nocturna",
        element           = "sombra",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.sombra,
        description       = "Sus escamas mate-negro lo vuelven invisible contra un cielo sin luna.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "shadow_rare",
        name              = "Dragón Umbral",
        element           = "sombra",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.sombra,
        description       = "Absorbe la luz ambiental, dejando tras de sí una oscuridad antinatural.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "shadow_epic",
        name              = "Víbora Vacío-Sombra",
        element           = "sombra",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.sombra,
        description       = "Su forma parpadea constantemente entre este mundo y el siguiente.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "shadow_legendary",
        name              = "Drake Eclipse",
        element           = "sombra",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.sombra,
        description       = "Su envergadura oscurece brevemente el sol, anunciando oscuridad total.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "shadow_mythic",
        name              = "Tenebris",
        element           = "sombra",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.sombra,
        description       = "La oscuridad primordial anterior a la creación, encarnada en forma dracónica.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- CELESTIAL
    ----------------------------------------------------------------------------
    {
        id                = "celestial_common",
        name              = "Drake Estelar",
        element           = "celestial",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.celestial,
        description       = "Una tenue luz estelar se aferra a sus escamas doradas a toda hora.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "celestial_uncommon",
        name              = "Ala de Luna",
        element           = "celestial",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.celestial,
        description       = "Sus amplias alas reflejan la luz de la luna como un par de espejos plateados.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "celestial_rare",
        name              = "Dragón Aurora",
        element           = "celestial",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.celestial,
        description       = "Deja cintas de luz de aurora centelleante a su paso.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "celestial_epic",
        name              = "Víbora Solaris",
        element           = "celestial",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.celestial,
        description       = "Irradia suficiente luz para iluminar un valle entero a medianoche.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "celestial_legendary",
        name              = "Drake Celestino",
        element           = "celestial",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.celestial,
        description       = "Desciende de los cielos más allá de las nubes solo para posarse al amanecer.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "celestial_mythic",
        name              = "Astraeus",
        element           = "celestial",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.celestial,
        description       = "El dragón estelar; los eruditos creen que existía antes que el propio sol.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- VACÍO
    ----------------------------------------------------------------------------
    {
        id                = "void_common",
        name              = "Sprite Hueco",
        element           = "vacio",
        rarity            = "comun",
        goldPerSecond     = OPS.comun,
        eggTimerSeconds   = HUEVO.comun,
        incubationSeconds = incub("comun"),
        scale             = ESCALA.comun,
        particleColor     = CE.vacio,
        description       = "Un drake tranquilo, de ojos vacíos, que se desplaza en silencio absoluto.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "void_uncommon",
        name              = "Drake Grieta",
        element           = "vacio",
        rarity            = "poco_comun",
        goldPerSecond     = OPS.poco_comun,
        eggTimerSeconds   = HUEVO.poco_comun,
        incubationSeconds = incub("poco_comun"),
        scale             = ESCALA.poco_comun,
        particleColor     = CE.vacio,
        description       = "Desgarra pequeñas e inofensivas grietas en el espacio mientras serpentea por el aire.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "void_rare",
        name              = "Dragón Nacido del Nulo",
        element           = "vacio",
        rarity            = "raro",
        goldPerSecond     = OPS.raro,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = CE.vacio,
        description       = "Eclosionado desde un bolsillo dimensional que colapsó en las profundidades.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "void_epic",
        name              = "Víbora Abisal del Vacío",
        element           = "vacio",
        rarity            = "epico",
        goldPerSecond     = OPS.epico,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = CE.vacio,
        description       = "Su rugido abre brevemente ventanas a la nada absoluta.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "void_legendary",
        name              = "Drake Caminante del Vacío",
        element           = "vacio",
        rarity            = "legendario",
        goldPerSecond     = OPS.legendario,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = CE.vacio,
        description       = "Se mueve entre la realidad y la nada a voluntad, sin estar jamás del todo presente.",
        soloCria          = false,
        soloEvento        = false,
    },
    {
        id                = "void_mythic",
        name              = "Nihilus",
        element           = "vacio",
        rarity            = "mitico",
        goldPerSecond     = OPS.mitico,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = CE.vacio,
        description       = "Una singularidad andante — el dragón que deshace todo lo que toca.",
        soloCria          = false,
        soloEvento        = false,
    },

    ----------------------------------------------------------------------------
    -- DRAGONES SOLO DE CRÍA  (16 en total)
    -- soloCria indica que solo se obtiene mediante cría.
    -- breedingCombo lista los dos IDs de dragones padres requeridos.
    -- goldPerSecond refleja el nivel de rareza implícita del dragón.
    ----------------------------------------------------------------------------

    -- 1 · fuego + naturaleza → híbrido épico
    {
        id                = "magma_dragon",
        name              = "Bruto Magma",
        element           = "fuego",
        rarity            = "epico",
        goldPerSecond     = 90,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = Color3.fromRGB(200, 80, 10),
        description       = "Nacido del fuego y la tierra; su piel corre con ríos de roca fundida.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "fire_rare", "nature_rare" },
    },

    -- 2 · fuego + agua → híbrido raro
    {
        id                = "steam_wyrm",
        name              = "Wyrm de Vapor",
        element           = "agua",
        rarity            = "raro",
        goldPerSecond     = 30,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = Color3.fromRGB(210, 200, 220),
        description       = "Donde el fuego encuentra el agua, este wyrm envuelto en vapor surge a la existencia.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "fire_uncommon", "water_uncommon" },
    },

    -- 3 · agua + trueno → híbrido legendario
    {
        id                = "storm_leviathan",
        name              = "Leviatán de Tormenta",
        element           = "agua",
        rarity            = "legendario",
        goldPerSecond     = 350,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = Color3.fromRGB(30, 160, 230),
        description       = "Una vasta serpiente marina envuelta en arcos crepitantes de relámpago.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "water_epic", "thunder_epic" },
    },

    -- 4 · fuego + hielo → híbrido épico
    {
        id                = "frostfire_drake",
        name              = "Drake Helagma",
        element           = "fuego",
        rarity            = "epico",
        goldPerSecond     = 85,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = Color3.fromRGB(200, 120, 200),
        description       = "Su lado izquierdo arde eternamente; su lado derecho congela. No toques ninguno.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "fire_rare", "ice_rare" },
    },

    -- 5 · trueno + agua → híbrido raro
    {
        id                = "thunder_serpent",
        name              = "Serpiente Trueno",
        element           = "trueno",
        rarity            = "raro",
        goldPerSecond     = 28,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = Color3.fromRGB(80, 190, 210),
        description       = "Nada por las nubes de tormenta con la misma facilidad que por las profundidades del océano.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "thunder_uncommon", "water_rare" },
    },

    -- 6 · naturaleza + sombra → híbrido raro
    {
        id                = "vineshade_dragon",
        name              = "Dragón Viñasombra",
        element           = "naturaleza",
        rarity            = "raro",
        goldPerSecond     = 25,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = Color3.fromRGB(40, 100, 50),
        description       = "Acecha en las sombras del bosque, indistinguible del oscuro dosel.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "nature_rare", "shadow_uncommon" },
    },

    -- 7 · celestial + vacío → híbrido legendario
    {
        id                = "nebula_dragon",
        name              = "Dragón Nebulosa",
        element           = "celestial",
        rarity            = "legendario",
        goldPerSecond     = 400,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = Color3.fromRGB(150, 90, 210),
        description       = "Una galaxia arremolinada brilla en las profundidades violetas de sus escamas oscuras.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "celestial_epic", "void_epic" },
    },

    -- 8 · sombra + vacío → híbrido épico
    {
        id                = "phantom_wraith",
        name              = "Espectro Fantasmal",
        element           = "sombra",
        rarity            = "epico",
        goldPerSecond     = 100,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = Color3.fromRGB(70, 10, 140),
        description       = "Acecha en el límite entre la sombra y el abismo absoluto.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "shadow_rare", "void_rare" },
    },

    -- 9 · hielo + celestial → híbrido legendario
    {
        id                = "aurora_serpent",
        name              = "Serpiente Aurora",
        element           = "hielo",
        rarity            = "legendario",
        goldPerSecond     = 450,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = Color3.fromRGB(160, 235, 210),
        description       = "Su vuelo pinta auroras centelleantes sobre el cielo invernal.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "ice_legendary", "celestial_epic" },
    },

    -- 10 · fuego + vacío → híbrido legendario
    {
        id                = "lava_titan",
        name              = "Titán de Lava",
        element           = "fuego",
        rarity            = "legendario",
        goldPerSecond     = 380,
        eggTimerSeconds   = HUEVO.legendario,
        incubationSeconds = incub("legendario"),
        scale             = ESCALA.legendario,
        particleColor     = Color3.fromRGB(180, 40, 20),
        description       = "Furia volcánica retorcida a través de una grieta dimensional en forma dracónica.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "fire_legendary", "void_rare" },
    },

    -- 11 · trueno + hielo → híbrido raro
    {
        id                = "glacial_thunderwing",
        name              = "Ala de Trueno Glacial",
        element           = "trueno",
        rarity            = "raro",
        goldPerSecond     = 32,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = Color3.fromRGB(140, 220, 255),
        description       = "Rayo congelado con alas; su rugido crepita y hiela al mismo tiempo.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "thunder_rare", "ice_rare" },
    },

    -- 12 · fuego + celestial → híbrido mítico
    {
        id                = "solar_phoenix",
        name              = "Fénix Solar",
        element           = "fuego",
        rarity            = "mitico",
        goldPerSecond     = 1500,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = Color3.fromRGB(255, 200, 70),
        description       = "Renacido del fuego estelar; a la vez dragón, estrella y mito viviente.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "fire_mythic", "celestial_legendary" },
    },

    -- 13 · sombra + fuego → híbrido épico
    {
        id                = "darkember_drake",
        name              = "Drake Brasa Oscura",
        element           = "sombra",
        rarity            = "epico",
        goldPerSecond     = 110,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = Color3.fromRGB(150, 45, 20),
        description       = "Brasas humeantes ascienden desde sus escamas y se desvanecen en la oscuridad.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "shadow_rare", "fire_epic" },
    },

    -- 14 · agua + sombra → híbrido raro
    {
        id                = "tidespecter",
        name              = "Espectro Mareal",
        element           = "agua",
        rarity            = "raro",
        goldPerSecond     = 27,
        eggTimerSeconds   = HUEVO.raro,
        incubationSeconds = incub("raro"),
        scale             = ESCALA.raro,
        particleColor     = Color3.fromRGB(20, 60, 120),
        description       = "Se desliza invisible bajo las aguas oscuras, un fantasma que acecha las profundidades.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "water_rare", "shadow_rare" },
    },

    -- 15 · naturaleza + vacío → híbrido épico
    {
        id                = "verdant_void",
        name              = "Dragón del Vacío Verdor",
        element           = "naturaleza",
        rarity            = "epico",
        goldPerSecond     = 95,
        eggTimerSeconds   = HUEVO.epico,
        incubationSeconds = incub("epico"),
        scale             = ESCALA.epico,
        particleColor     = Color3.fromRGB(20, 80, 40),
        description       = "La vida florece donde debería reinar la nada — una paradoja viviente.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "nature_epic", "void_rare" },
    },

    -- 16 · celestial + naturaleza → híbrido mítico
    {
        id                = "prismatic_dragon",
        name              = "Dragón Prismático",
        element           = "celestial",
        rarity            = "mitico",
        goldPerSecond     = 2000,
        eggTimerSeconds   = HUEVO.mitico,
        incubationSeconds = incub("mitico"),
        scale             = ESCALA.mitico,
        particleColor     = Color3.fromRGB(200, 235, 150),
        description       = "Todos los colores de la creación fluyen sobre sus impresionantes escamas iridiscentes.",
        soloCria          = true,
        soloEvento        = false,
        breedingCombo     = { "celestial_mythic", "nature_legendary" },
    },
}

-- ---------------------------------------------------------------------------
-- Construcción del índice de búsqueda (se construye una vez, se reutiliza)
-- ---------------------------------------------------------------------------

local _porId = {}
for _, dragon in ipairs(DragonData.Dragons) do
    _porId[dragon.id] = dragon
end

-- ---------------------------------------------------------------------------
-- GetDragonById(id: string) → definición de dragón | nil
-- ---------------------------------------------------------------------------
function DragonData.GetDragonById(id)
    return _porId[id]
end

-- ---------------------------------------------------------------------------
-- GetDragonsByElement(elemento: string) → { definición de dragón }
-- Devuelve un nuevo array; seguro para iterar o mutar sin afectar la fuente.
-- ---------------------------------------------------------------------------
function DragonData.GetDragonsByElement(elemento)
    local resultado = {}
    for _, dragon in ipairs(DragonData.Dragons) do
        if dragon.element == elemento then
            resultado[#resultado + 1] = dragon
        end
    end
    return resultado
end

-- ---------------------------------------------------------------------------
-- GetDragonsByRarity(rareza: string) → { definición de dragón }
-- Devuelve todos los dragones de la rareza indicada.
-- ---------------------------------------------------------------------------
function DragonData.GetDragonsByRarity(rareza)
    local resultado = {}
    for _, dragon in ipairs(DragonData.Dragons) do
        if dragon.rarity == rareza then
            resultado[#resultado + 1] = dragon
        end
    end
    return resultado
end

return DragonData
