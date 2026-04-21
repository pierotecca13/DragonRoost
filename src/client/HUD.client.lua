--------------------------------------------------------------------------------
-- HUD.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Gestiona toda la interfaz de stats en tiempo real.
-- Crea todos los elementos UI vía código (sin depender de Studio).
--
-- PANELES:
--   StatsPanel     — esquina superior izquierda: oro, gps, gemas, nivel
--   NestPanel      — debajo de stats: scroll por nido, color por estado
--   WeatherBanner  — centro superior: aparece/desaparece con animación
--   PrestigePanel  — esquina inferior derecha: requisitos + botón
--   Notificaciones — esquina superior derecha: mensajes temporales apilados
--
-- DATOS RECIBIDOS DEL SERVIDOR:
--   GoldUpdated      → { currentGold }
--   StatsUpdated     → { gpsTotal, gpsPorNido, oroPendienteTotal, nivel }
--   NestUpdated      → NestSystem.GetNestData() completo
--   WeatherStarted   → { eventId, name, endsAt, affectedElements, multiplier, ... }
--   WeatherEnded     → { eventId, name }
--   WeatherEnding    → { secondsRemaining, affectedElements, ... }
--   EggReady         → { nestIndex, dragonId, readyAt, guaranteed, collected? }
--   EggStarted       → { nestIndex, dragonId, readyAt, secondsLeft, guaranteed }
--   GoldEvaporating  → { nestIndex, secondsRemaining, evaporationPct }
--   PrestigeCompleted→ { nuevoNivel, prestigeScales, zonaDesbloqueada, nestData }
--------------------------------------------------------------------------------
print("Ejecutando HUD")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Módulos compartidos
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))

-- Referencias al jugador local
local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Paletas de color
--------------------------------------------------------------------------------

-- Color por rareza (texto e indicadores de dragón)
local RARITY_COLORS = {
    comun         = Color3.fromRGB(180, 180, 180),
    poco_comun    = Color3.fromRGB( 80, 200,  80),
    raro          = Color3.fromRGB( 80, 130, 220),
    epico         = Color3.fromRGB(160,  80, 220),
    legendario    = Color3.fromRGB(255, 165,   0),
    mitico        = Color3.fromRGB(255,  50,  50),
}

-- Emoji por elemento (los elementos están en español en DragonData)
local ELEMENT_EMOJI = {
    fuego      = "🔥",
    agua       = "💧",
    hielo      = "❄️",
    trueno     = "⚡",
    naturaleza = "🌿",
    sombra     = "🌑",
    celestial  = "✨",
    vacio      = "🌀",
    ["vacío"]  = "🌀",
}

-- Color de partícula por elemento (mismo que DragonData.EC)
local ELEMENT_COLORS = {
    fire      = Color3.fromRGB(255,  90,  20),
    water     = Color3.fromRGB( 30, 130, 255),
    ice       = Color3.fromRGB(180, 230, 255),
    thunder   = Color3.fromRGB(255, 240,  50),
    nature    = Color3.fromRGB( 50, 200,  80),
    shadow    = Color3.fromRGB(130,  50, 200),
    celestial = Color3.fromRGB(255, 220, 100),
    void      = Color3.fromRGB( 80,  20, 160),
}

-- Color principal por evento climático (para el banner y el tinte del icono)
local WEATHER_BANNER_COLORS = {
    sol_dorado         = Color3.fromRGB(255, 160,  30),
    lluvia_magica      = Color3.fromRGB( 30, 130, 255),
    erupcion_volcanica = Color3.fromRGB(255,  70,  20),
    tormenta_electrica = Color3.fromRGB(220, 220,  50),
    noche_eterna       = Color3.fromRGB( 90,  30, 180),
    rift_dimensional   = Color3.fromRGB(180,  80, 255),
}

-- Colores de estado de nidos (fondo de fila)
local NEST_COLOR_NORMAL = Color3.fromRGB( 30,  22,  48)
local NEST_COLOR_BOOST  = Color3.fromRGB( 20,  50,  25)   -- verde oscuro
local NEST_COLOR_EVAP   = Color3.fromRGB( 55,  15,  15)   -- rojo oscuro

-- Colores generales del estilo medieval/fantasy
local PANEL_BG     = Color3.fromRGB( 15,  10,  25)
local BORDER_COLOR = Color3.fromRGB(200, 160,  50)         -- dorado
local TEXT_PRIMARY = Color3.fromRGB(255, 240, 200)         -- blanco cálido
local TEXT_HEADER  = Color3.fromRGB(255, 215,  80)         -- dorado brillante
local TEXT_DIM     = Color3.fromRGB(160, 148, 120)         -- gris cálido

-- Tipos de notificación → colores de acento
local NOTIF_COLORS = {
    success = Color3.fromRGB( 30, 180,  80),
    warning = Color3.fromRGB(220, 160,  20),
    error   = Color3.fromRGB(200,  40,  40),
    event   = Color3.fromRGB( 30, 120, 240),
}

--------------------------------------------------------------------------------
-- Configuración de animaciones (TweenInfo reutilizables)
--------------------------------------------------------------------------------

local TWEEN_FAST   = TweenInfo.new(0.20, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TWEEN_SLIDE  = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_BOUNCE = TweenInfo.new(0.45, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TWEEN_GOLD   = TweenInfo.new(0.60, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)

-- Posiciones del banner climático (Y en píxeles)
local BANNER_POS_HIDDEN  = UDim2.new(0.5, -165, 0, -90)
local BANNER_POS_VISIBLE = UDim2.new(0.5, -165, 0,   4)

--------------------------------------------------------------------------------
-- Estado interno del HUD
-- Toda la información recibida del servidor se almacena aquí para que el
-- tick loop y las funciones de actualización puedan acceder al estado actual.
--------------------------------------------------------------------------------

local state = {
    gold            = 0,
    gems            = 0,
    level           = 1,
    gpsTotal        = 0,
    gpsPorNido      = {},   -- [nestIndex] = gps
    nests           = {},   -- [nestIndex] = {dragonId, boostSecondsLeft, boostMultiplier, ...}
    eggStatus       = {},   -- [nestIndex] = {isReady, readyAt, dragonId}
    evaporating     = {},   -- [nestIndex] = secondsRemaining
    boostExpiry     = {},   -- [nestIndex] = {expiraEn, nombre}
    weather         = nil,  -- datos del evento activo (nil si no hay evento)
    weatherEnding   = false,
    prestigeReqs    = nil,  -- última data de requisitos recibida
    estadoServidor  = {},   -- última tabla de EstadoServidorActualizado
    huevoListo      = false,  -- badge notif huevo
    tiendaRotada    = false,  -- badge notif tienda
    inventarioItems = false,  -- badge notif inventario
}

-- Referencias a elementos UI (se populan en HUD.Init)
local ui = {
    screenGui          = nil,
    statsPanel         = nil,
    goldLabel          = nil,
    gpsLabel           = nil,
    gemsLabel          = nil,
    levelLabel         = nil,
    nestScrollFrame    = nil,
    nestRows           = {},   -- [nestIndex] = {frame, infoLbl, eggLbl, boostLbl}
    weatherBanner      = nil,
    weatherNameLbl     = nil,
    weatherEffectLbl   = nil,
    weatherCountLbl    = nil,
    prestigePanel      = nil,
    prestigeReqList    = nil,
    prestigeButton     = nil,
    notifContainer     = nil,
    -- Barra de navegación inferior
    navBar             = nil,
    badgeHuevo         = nil,  -- punto rojo sobre botón Huevos
    badgeTienda        = nil,  -- punto rojo sobre botón Tienda
    badgeInventario    = nil,  -- punto rojo sobre botón Inventario
    -- Panel de ranking del servidor (esquina superior derecha)
    rankingPanel       = nil,
    rankingRows        = {},
}

-- NumberValue que TweenService anima para el contador de oro suave
local goldDisplayValue    = Instance.new("NumberValue")
goldDisplayValue.Value    = 0
local goldTween           = nil    -- referencia al tween activo de oro

-- Control del pulso del botón de prestige
local prestigePulseActive = false

--------------------------------------------------------------------------------
-- Helpers de formato de texto
--------------------------------------------------------------------------------

-- Formatea un número entero con separadores de miles.
-- Para valores >= 100.000 usa sufijos K/M por legibilidad.
local function formatNumber(n)
    n = math.floor(n or 0)
    if n >= 1_000_000 then
        return ("%.2fM"):format(n / 1_000_000)
    elseif n >= 10_000 then
        return ("%.1fK"):format(n / 1_000)
    end
    -- Insertar coma cada tres dígitos
    local s      = tostring(n)
    local result = ""
    local len    = #s
    for i = 1, len do
        local digPos = len - i + 1
        if i > 1 and (digPos) % 3 == 0 then
            result = result .. ","
        end
        result = result .. s:sub(i, i)
    end
    return result
end

-- Formatea segundos en MM:SS (o HH:MM:SS si >= 1 hora).
local function formatTime(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return ("%d:%02d:%02d"):format(h, m, s)
    end
    return ("%02d:%02d"):format(m, s)
end

-- Primera letra en mayúscula (para nombres de rareza).
local function capitalize(str)
    if not str or str == "" then return "?" end
    return str:sub(1,1):upper() .. str:sub(2)
end

--------------------------------------------------------------------------------
-- Helpers de creación de UI
-- Todas las funciones creadoras aplican el estilo medieval/fantasy:
-- fondos oscuros semitransparentes, bordes dorados, esquinas redondeadas.
--------------------------------------------------------------------------------

-- Crea un Frame con estilo de panel: fondo oscuro + borde dorado + esquinas.
local function crearPanel(nombre, tamano, posicion, padre, transp)
    local frame = Instance.new("Frame")
    frame.Name                   = nombre
    frame.Size                   = tamano
    frame.Position               = posicion
    frame.BackgroundColor3       = PANEL_BG
    frame.BackgroundTransparency = transp or 0.15
    frame.BorderSizePixel        = 0
    frame.Parent                 = padre

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent       = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color     = BORDER_COLOR
    stroke.Thickness = 1.5
    stroke.Parent    = frame

    return frame
end

-- Crea un TextLabel con los parámetros dados.
local function crearLabel(texto, tamano, posicion, padre, fuente, color, alinX)
    local lbl = Instance.new("TextLabel")
    lbl.Name                   = "Lbl"
    lbl.Text                   = texto
    lbl.Size                   = tamano
    lbl.Position               = posicion
    lbl.BackgroundTransparency = 1
    lbl.Font                   = fuente or Enum.Font.Gotham
    lbl.TextSize               = 14
    lbl.TextColor3             = color or TEXT_PRIMARY
    lbl.TextXAlignment         = alinX or Enum.TextXAlignment.Left
    lbl.TextTruncate           = Enum.TextTruncate.AtEnd
    lbl.Parent                 = padre
    return lbl
end

-- Crea un TextButton con estilo medieval y efectos hover.
local function crearBoton(texto, tamano, posicion, padre, colorFondo)
    local colorBase  = colorFondo or Color3.fromRGB(160, 110, 20)
    local colorHover = Color3.fromRGB(200, 145, 30)

    local btn = Instance.new("TextButton")
    btn.Name             = "Btn"
    btn.Text             = texto
    btn.Size             = tamano
    btn.Position         = posicion
    btn.BackgroundColor3 = colorBase
    btn.BorderSizePixel  = 0
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 14
    btn.TextColor3       = Color3.fromRGB(255, 245, 200)
    btn.AutoButtonColor  = false
    btn.Parent           = padre

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent       = btn

    local stroke = Instance.new("UIStroke")
    stroke.Color     = Color3.fromRGB(255, 200, 80)
    stroke.Thickness = 1
    stroke.Parent    = btn

    -- Hover visual
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TWEEN_FAST, { BackgroundColor3 = colorHover }):Play()
    end)
    btn.MouseLeave:Connect(function()
        if btn ~= ui.prestigeButton or not prestigePulseActive then
            TweenService:Create(btn, TWEEN_FAST, { BackgroundColor3 = colorBase }):Play()
        end
    end)

    return btn
end

-- Aplica UIPadding uniforme a un Frame.
local function aplicarPadding(frame, px)
    local pad = Instance.new("UIPadding")
    pad.PaddingTop    = UDim.new(0, px)
    pad.PaddingBottom = UDim.new(0, px)
    pad.PaddingLeft   = UDim.new(0, px)
    pad.PaddingRight  = UDim.new(0, px)
    pad.Parent        = frame
end

--------------------------------------------------------------------------------
-- Filas de nidos
-- Cada fila tiene dos líneas de texto:
--   infoLbl : "🐉 Nido N: NombreDragon  X.X/s"
--   eggLbl  : "  🥚 estado del huevo"
--------------------------------------------------------------------------------

-- Crea y registra una fila de nido si no existe todavía para ese índice.
local function crearFilaNido(nestIndex)
    if ui.nestRows[nestIndex] then return ui.nestRows[nestIndex] end

    local rowFrame = Instance.new("Frame")
    rowFrame.Name                   = "NestRow_" .. nestIndex
    rowFrame.Size                   = UDim2.new(1, -8, 0, 82)
    rowFrame.BackgroundColor3       = NEST_COLOR_NORMAL
    rowFrame.BackgroundTransparency = 0.3
    rowFrame.BorderSizePixel        = 0
    rowFrame.LayoutOrder            = nestIndex
    rowFrame.Parent                 = ui.nestScrollFrame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 5)
    corner.Parent       = rowFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color       = BORDER_COLOR
    stroke.Thickness   = 0.8
    stroke.Transparency = 0.5
    stroke.Parent      = rowFrame

    aplicarPadding(rowFrame, 6)

    -- Línea 1: ícono de dragón + número de nido + nombre + gps
    local infoLbl = Instance.new("TextLabel")
    infoLbl.Name                   = "InfoLbl"
    infoLbl.Size                   = UDim2.new(1, 0, 0, 22)
    infoLbl.Position               = UDim2.new(0, 0, 0, 0)
    infoLbl.BackgroundTransparency = 1
    infoLbl.Font                   = Enum.Font.GothamBold
    infoLbl.TextSize               = 13
    infoLbl.TextColor3             = TEXT_PRIMARY
    infoLbl.TextXAlignment         = Enum.TextXAlignment.Left
    infoLbl.TextTruncate           = Enum.TextTruncate.AtEnd
    infoLbl.Text                   = ("🐉 Nido %d: —"):format(nestIndex)
    infoLbl.Parent                 = rowFrame

    -- Línea 2: estado del huevo o advertencia de evaporación
    local eggLbl = Instance.new("TextLabel")
    eggLbl.Name                    = "EggLbl"
    eggLbl.Size                    = UDim2.new(1, 0, 0, 18)
    eggLbl.Position                = UDim2.new(0, 8, 0, 24)
    eggLbl.BackgroundTransparency  = 1
    eggLbl.Font                    = Enum.Font.Gotham
    eggLbl.TextSize                = 12
    eggLbl.TextColor3              = TEXT_DIM
    eggLbl.TextXAlignment          = Enum.TextXAlignment.Left
    eggLbl.Text                    = ""
    eggLbl.Parent                  = rowFrame

    -- Línea 3: indicador de boost activo con countdown
    local boostLbl = Instance.new("TextLabel")
    boostLbl.Name                   = "BoostLbl"
    boostLbl.Size                   = UDim2.new(1, 0, 0, 16)
    boostLbl.Position               = UDim2.new(0, 8, 0, 44)
    boostLbl.BackgroundTransparency = 1
    boostLbl.Font                   = Enum.Font.GothamBold
    boostLbl.TextSize               = 11
    boostLbl.TextColor3             = Color3.fromRGB(255, 210, 60)
    boostLbl.TextXAlignment         = Enum.TextXAlignment.Left
    boostLbl.Text                   = ""
    boostLbl.Parent                 = rowFrame

    local row = { frame = rowFrame, infoLbl = infoLbl, eggLbl = eggLbl, boostLbl = boostLbl }
    ui.nestRows[nestIndex] = row
    return row
end

-- Actualiza el color de fondo de la fila según el estado actual del nido.
-- Verde = boost activo   Rojo = evaporando   Oscuro/neutro = normal
local function colorearFila(nestIndex, boosted, evaporating)
    local row = ui.nestRows[nestIndex]
    if not row then return end

    local bgColor   = evaporating and NEST_COLOR_EVAP
        or boosted and NEST_COLOR_BOOST
        or NEST_COLOR_NORMAL
    local textColor = evaporating and Color3.fromRGB(255, 140, 100)
        or boosted and Color3.fromRGB(130, 255, 160)
        or TEXT_PRIMARY

    TweenService:Create(row.frame, TWEEN_FAST, { BackgroundColor3 = bgColor }):Play()
    row.infoLbl.TextColor3 = textColor
end

--------------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------------

local HUD = {}

--------------------------------------------------------------------------------
-- HUD.Init()
--
-- Construye todos los paneles y elementos UI mediante Instance.new.
-- Aplica estilo medieval/fantasy: fondos oscuros, bordes dorados, GothamBold.
-- Conecta todos los RemoteEvents del servidor al final.
-- Inicia el tick loop de cliente para countdowns.
-- Debe llamarse una sola vez al iniciar el LocalScript.
--------------------------------------------------------------------------------
function HUD.Init()

    -- ── ScreenGui principal ────────────────────────────────────────────────
    local sg = Instance.new("ScreenGui")
    sg.Name             = "DragonRoostHUD"
    sg.ResetOnSpawn     = false
    sg.IgnoreGuiInset   = false
    sg.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
    sg.Parent           = playerGui
    ui.screenGui        = sg

    -- ── Panel Stats (esquina superior izquierda) ──────────────────────────
    -- Muestra: oro (contador animado), gps total, gemas, nivel actual.
    local statsPanel = crearPanel("StatsPanel",
        UDim2.new(0, 240, 0, 116),
        UDim2.new(0, 12, 0, 12),
        sg)
    ui.statsPanel = statsPanel
    aplicarPadding(statsPanel, 10)

    -- UIListLayout para apilar las 4 líneas de stats verticalmente
    local statsLayout = Instance.new("UIListLayout")
    statsLayout.SortOrder  = Enum.SortOrder.LayoutOrder
    statsLayout.Padding    = UDim.new(0, 5)
    statsLayout.Parent     = statsPanel

    -- Línea 1 — Oro (fuente grande, GothamBold)
    ui.goldLabel = crearLabel("🪙 0 oro",
        UDim2.new(1, 0, 0, 22),
        UDim2.new(0, 0, 0, 0),
        statsPanel, Enum.Font.GothamBold, TEXT_PRIMARY)
    ui.goldLabel.TextSize   = 16
    ui.goldLabel.LayoutOrder = 1

    -- Línea 2 — Gps total
    ui.gpsLabel = crearLabel("⚡ 0 oro/seg",
        UDim2.new(1, 0, 0, 18),
        UDim2.new(0, 0, 0, 0),
        statsPanel, Enum.Font.Gotham, TEXT_DIM)
    ui.gpsLabel.LayoutOrder = 2

    -- Línea 3 — Gemas
    ui.gemsLabel = crearLabel("💎 0 gemas",
        UDim2.new(1, 0, 0, 18),
        UDim2.new(0, 0, 0, 0),
        statsPanel, Enum.Font.Gotham, Color3.fromRGB(150, 200, 255))
    ui.gemsLabel.LayoutOrder = 3

    -- Línea 4 — Nivel
    ui.levelLabel = crearLabel("⭐ Nivel 1",
        UDim2.new(1, 0, 0, 18),
        UDim2.new(0, 0, 0, 0),
        statsPanel, Enum.Font.GothamBold, TEXT_HEADER)
    ui.levelLabel.LayoutOrder = 4

    -- El NumberValue tween controla la animación del oro en pantalla
    goldDisplayValue.Changed:Connect(function(valor)
        ui.goldLabel.Text = "🪙 " .. formatNumber(math.floor(valor)) .. " oro"
    end)

    -- ── Panel Nidos (debajo de stats, scrollable) ─────────────────────────
    -- Cada nido activo tiene su propia fila con nombre, rareza, gps y huevo.
    local nestPanel = crearPanel("NestPanel",
        UDim2.new(0, 240, 0, 200),
        UDim2.new(0, 12, 0, 140),
        sg)
    aplicarPadding(nestPanel, 0)

    -- Título del panel de nidos
    local nestTitle = Instance.new("TextLabel")
    nestTitle.Name                   = "NestTitle"
    nestTitle.Size                   = UDim2.new(1, 0, 0, 28)
    nestTitle.Position               = UDim2.new(0, 0, 0, 0)
    nestTitle.BackgroundTransparency = 1
    nestTitle.Font                   = Enum.Font.GothamBold
    nestTitle.TextSize               = 13
    nestTitle.TextColor3             = TEXT_HEADER
    nestTitle.TextXAlignment         = Enum.TextXAlignment.Center
    nestTitle.Text                   = "NIDOS ACTIVOS"
    nestTitle.Parent                 = nestPanel

    -- Línea divisoria decorativa bajo el título
    local divider = Instance.new("Frame")
    divider.Size                = UDim2.new(1, -16, 0, 1)
    divider.Position            = UDim2.new(0, 8, 0, 30)
    divider.BackgroundColor3    = BORDER_COLOR
    divider.BackgroundTransparency = 0.45
    divider.BorderSizePixel     = 0
    divider.Parent              = nestPanel

    -- ScrollingFrame para nidos (auto-altura del canvas por UIListLayout)
    local sf = Instance.new("ScrollingFrame")
    sf.Name                    = "NestScroll"
    sf.Size                    = UDim2.new(1, -4, 1, -34)
    sf.Position                = UDim2.new(0, 2, 0, 33)
    sf.BackgroundTransparency  = 1
    sf.BorderSizePixel         = 0
    sf.ScrollBarThickness      = 4
    sf.ScrollBarImageColor3    = BORDER_COLOR
    sf.CanvasSize              = UDim2.new(0, 0, 0, 0)
    sf.AutomaticCanvasSize     = Enum.AutomaticSize.Y
    sf.Parent                  = nestPanel
    ui.nestScrollFrame         = sf

    local sfLayout = Instance.new("UIListLayout")
    sfLayout.SortOrder   = Enum.SortOrder.LayoutOrder
    sfLayout.Padding     = UDim.new(0, 4)
    sfLayout.Parent      = sf
    aplicarPadding(sf, 4)

    -- ── Banner Climático (centro superior, oculto al inicio) ─────────────
    -- Aparece y desaparece con animación slide desde/hacia arriba.
    local banner = crearPanel("WeatherBanner",
        UDim2.new(0, 330, 0, 76),
        BANNER_POS_HIDDEN,
        sg)
    banner.ZIndex        = 10
    banner.Visible       = false
    ui.weatherBanner     = banner
    aplicarPadding(banner, 8)

    local bannerLayout = Instance.new("UIListLayout")
    bannerLayout.SortOrder    = Enum.SortOrder.LayoutOrder
    bannerLayout.Padding      = UDim.new(0, 3)
    bannerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    bannerLayout.Parent       = banner

    -- Nombre del evento
    ui.weatherNameLbl = crearLabel("⚡ EVENTO CLIMÁTICO",
        UDim2.new(1, 0, 0, 22),
        UDim2.new(0, 0, 0, 0),
        banner, Enum.Font.GothamBold, TEXT_HEADER,
        Enum.TextXAlignment.Center)
    ui.weatherNameLbl.TextSize    = 14
    ui.weatherNameLbl.TextTruncate = Enum.TextTruncate.None
    ui.weatherNameLbl.TextScaled   = true
    ui.weatherNameLbl.LayoutOrder = 1

    -- Descripción del efecto
    ui.weatherEffectLbl = crearLabel("",
        UDim2.new(1, 0, 0, 16),
        UDim2.new(0, 0, 0, 0),
        banner, Enum.Font.Gotham, TEXT_PRIMARY,
        Enum.TextXAlignment.Center)
    ui.weatherEffectLbl.TextSize    = 12
    ui.weatherEffectLbl.TextTruncate = Enum.TextTruncate.None
    ui.weatherEffectLbl.TextScaled   = true
    ui.weatherEffectLbl.LayoutOrder = 2

    -- Countdown del evento
    ui.weatherCountLbl = crearLabel("",
        UDim2.new(1, 0, 0, 14),
        UDim2.new(0, 0, 0, 0),
        banner, Enum.Font.Gotham, TEXT_DIM,
        Enum.TextXAlignment.Center)
    ui.weatherCountLbl.TextSize    = 11
    ui.weatherCountLbl.LayoutOrder = 3

    -- ── Panel Prestige (esquina inferior derecha) ─────────────────────────
    -- Muestra los requisitos del siguiente nivel con checkmarks y el botón.
    local prestPanel = crearPanel("PrestigePanel",
        UDim2.new(0, 240, 0, 0),
        UDim2.new(1, -252, 1, -230),
        sg)
    prestPanel.AutomaticSize = Enum.AutomaticSize.Y
    aplicarPadding(prestPanel, 10)
    ui.prestigePanel = prestPanel

    local prestLayout = Instance.new("UIListLayout")
    prestLayout.SortOrder = Enum.SortOrder.LayoutOrder
    prestLayout.Padding   = UDim.new(0, 6)
    prestLayout.Parent    = prestPanel

    -- Título del panel
    local prestTitle = crearLabel("PRÓXIMO NIVEL",
        UDim2.new(1, 0, 0, 22),
        UDim2.new(0, 0, 0, 0),
        prestPanel, Enum.Font.GothamBold, TEXT_HEADER,
        Enum.TextXAlignment.Center)
    prestTitle.LayoutOrder = 0

    -- Contenedor de requisitos (filas dinámicas)
    local reqList = Instance.new("Frame")
    reqList.Name                   = "ReqList"
    reqList.Size                   = UDim2.new(1, 0, 0, 0)
    reqList.AutomaticSize          = Enum.AutomaticSize.Y
    reqList.BackgroundTransparency = 1
    reqList.LayoutOrder            = 1
    reqList.Parent                 = prestPanel
    ui.prestigeReqList = reqList

    local reqLayout = Instance.new("UIListLayout")
    reqLayout.SortOrder = Enum.SortOrder.LayoutOrder
    reqLayout.Padding   = UDim.new(0, 3)
    reqLayout.Parent    = reqList

    -- Botón de prestige
    local prestBtn = crearBoton("[ SUBIR NIVEL ]",
        UDim2.new(1, 0, 0, 36),
        UDim2.new(0, 0, 0, 0),
        prestPanel,
        Color3.fromRGB(70, 50, 8))
    prestBtn.LayoutOrder   = 2
    prestBtn.TextSize      = 14
    prestBtn.TextColor3    = Color3.fromRGB(160, 130, 60)
    ui.prestigeButton = prestBtn

    -- Al hacer clic llama RequestPrestige en el servidor
    prestBtn.Activated:Connect(function()
        local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
        local rf = Remotes and Remotes:FindFirstChild("RequestPrestige")
        if not rf then
            HUD.ShowNotification("Sistema de prestige no disponible.", "error")
            return
        end
        -- Feedback visual inmediato mientras espera la respuesta del servidor
        TweenService:Create(prestBtn, TWEEN_FAST,
            { BackgroundColor3 = Color3.fromRGB(30, 20, 5) }):Play()
        local ok, mensaje = rf:InvokeServer()
        if ok then
            HUD.ShowNotification("¡Prestige completado! 🎉", "success")
        else
            HUD.ShowNotification(tostring(mensaje or "No cumples los requisitos."), "warning")
            TweenService:Create(prestBtn, TWEEN_FAST,
                { BackgroundColor3 = Color3.fromRGB(70, 50, 8) }):Play()
        end
    end)

    -- Poblar el panel con los requisitos del nivel 2 (estado inicial)
    HUD.UpdatePrestigePanel({
        canPrestige        = false,
        nivelObjetivo      = 2,
        dragons            = {},
        oroActualRequerido = {
            required = Constants.PRESTIGE[2] and Constants.PRESTIGE[2].oroActualRequerido or 1000,
            current  = 0, met = false
        },
    })

    -- ── Contenedor de Notificaciones (bajo el ranking) ───────────────────
    local notifCont = Instance.new("Frame")
    notifCont.Name                   = "NotifContainer"
    notifCont.Size                   = UDim2.new(0, 240, 1, -200)
    notifCont.Position               = UDim2.new(1, -252, 0, 190)
    notifCont.BackgroundTransparency = 1
    notifCont.BorderSizePixel        = 0
    notifCont.Parent                 = sg
    ui.notifContainer = notifCont

    local notifLayout = Instance.new("UIListLayout")
    notifLayout.SortOrder         = Enum.SortOrder.LayoutOrder
    notifLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    notifLayout.Padding           = UDim.new(0, 5)
    notifLayout.Parent            = notifCont

    -- ── Panel de Ranking del servidor (esquina superior derecha) ────────
    -- Muestra hasta 8 jugadores con su oro/seg, ordenados de mayor a menor.
    -- Se actualiza con RemoteEvent "EstadoServidorActualizado".
    -- Anchored desde el borde derecho para no solaparse con nestPanel.
    local rankPanel = crearPanel("RankingPanel",
        UDim2.new(0, 240, 0, 0),
        UDim2.new(1, -252, 0, 12),
        sg)
    rankPanel.AutomaticSize = Enum.AutomaticSize.Y
    aplicarPadding(rankPanel, 8)
    ui.rankingPanel = rankPanel

    local rankLayout = Instance.new("UIListLayout")
    rankLayout.SortOrder = Enum.SortOrder.LayoutOrder
    rankLayout.Padding   = UDim.new(0, 3)
    rankLayout.Parent    = rankPanel

    local rankTitle = crearLabel("🏆 JUGADORES EN EL SERVIDOR",
        UDim2.new(1, 0, 0, 20),
        UDim2.new(0, 0, 0, 0),
        rankPanel, Enum.Font.GothamBold, TEXT_HEADER,
        Enum.TextXAlignment.Center)
    rankTitle.TextScaled  = true
    rankTitle.TextTruncate = Enum.TextTruncate.None
    rankTitle.LayoutOrder = 0

    -- Filas del ranking (precreadas, se ocultan si no hay jugador)
    for i = 1, 8 do
        local rowFr = Instance.new("Frame")
        rowFr.Name                   = "RankRow_" .. i
        rowFr.Size                   = UDim2.new(1, 0, 0, 18)
        rowFr.BackgroundTransparency = 1
        rowFr.LayoutOrder            = i
        rowFr.Visible                = false
        rowFr.Parent                 = rankPanel

        local rowLbl = Instance.new("TextLabel")
        rowLbl.Size                   = UDim2.new(1, 0, 1, 0)
        rowLbl.BackgroundTransparency = 1
        rowLbl.Font                   = Enum.Font.Gotham
        rowLbl.TextSize               = 11
        rowLbl.TextColor3             = TEXT_PRIMARY
        rowLbl.TextXAlignment         = Enum.TextXAlignment.Left
        rowLbl.TextTruncate           = Enum.TextTruncate.AtEnd
        rowLbl.Parent                 = rowFr

        ui.rankingRows[i] = { frame = rowFr, label = rowLbl }
    end

    -- ── Barra de navegación inferior (mobile-friendly) ───────────────────
    -- 5 botones de 70×70 px centrados en la parte inferior de la pantalla.
    local NAV_BUTTONS = {
        { label = "🏪",  texto = "Tienda",      evento = "AbrirTienda",     badge = "tienda" },
        { label = "🎒",  texto = "Inventario",  evento = "AbrirInventario", badge = "inventario" },
        { label = "📖",  texto = "Catálogo",    evento = "AbrirCatalogo",   badge = nil },
        { label = "🥚",  texto = "Huevos",      evento = "AbrirHuevos",     badge = "huevo" },
        { label = "🧬",  texto = "Breeding",    evento = "AbrirBreeding",   badge = nil },
        { label = "🔄",  texto = "Intercambio", evento = "AbrirIntercambio",badge = nil },
    }
    local N_NAV = #NAV_BUTTONS
    local BTN_SIZE = 70
    local BTN_GAP  = 10
    local BAR_W    = N_NAV * BTN_SIZE + (N_NAV - 1) * BTN_GAP

    local navBar = Instance.new("Frame")
    navBar.Name                   = "NavBar"
    navBar.Size                   = UDim2.new(0, BAR_W + 20, 0, BTN_SIZE + 16)
    navBar.Position               = UDim2.new(0.5, -math.floor((BAR_W + 20) / 2), 1, -(BTN_SIZE + 24))
    navBar.BackgroundColor3       = PANEL_BG
    navBar.BackgroundTransparency = 0.10
    navBar.BorderSizePixel        = 0
    navBar.Parent                 = sg
    ui.navBar = navBar

    local navCorner = Instance.new("UICorner")
    navCorner.CornerRadius = UDim.new(0, 12)
    navCorner.Parent       = navBar

    local navStroke = Instance.new("UIStroke")
    navStroke.Color     = BORDER_COLOR
    navStroke.Thickness = 1.5
    navStroke.Parent    = navBar

    -- Crear un BindableEvent para que los GUIs externos escuchen las navegaciones
    local NavEvent = Instance.new("BindableEvent")
    NavEvent.Name   = "NavBarClicked"
    NavEvent.Parent = sg

    for idx, info in ipairs(NAV_BUTTONS) do
        local xOff = 10 + (idx - 1) * (BTN_SIZE + BTN_GAP)

        local btnFr = Instance.new("Frame")
        btnFr.Name            = "NavBtn_" .. idx
        btnFr.Size            = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)
        btnFr.Position        = UDim2.new(0, xOff, 0.5, -math.floor(BTN_SIZE / 2))
        btnFr.BackgroundColor3 = Color3.fromRGB(25, 18, 40)
        btnFr.BackgroundTransparency = 0.3
        btnFr.BorderSizePixel = 0
        btnFr.Parent          = navBar

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 8)
        btnCorner.Parent       = btnFr

        -- Ícono (emoji grande)
        local iconLbl = Instance.new("TextLabel")
        iconLbl.Size                   = UDim2.new(1, 0, 0, 38)
        iconLbl.Position               = UDim2.new(0, 0, 0, 6)
        iconLbl.BackgroundTransparency = 1
        iconLbl.Font                   = Enum.Font.GothamBold
        iconLbl.TextSize               = 26
        iconLbl.TextColor3             = TEXT_PRIMARY
        iconLbl.TextXAlignment         = Enum.TextXAlignment.Center
        iconLbl.Text                   = info.label
        iconLbl.Parent                 = btnFr

        -- Etiqueta de texto bajo el ícono
        local textLbl = Instance.new("TextLabel")
        textLbl.Size                   = UDim2.new(1, 0, 0, 16)
        textLbl.Position               = UDim2.new(0, 0, 0, 46)
        textLbl.BackgroundTransparency = 1
        textLbl.Font                   = Enum.Font.Gotham
        textLbl.TextSize               = 9
        textLbl.TextColor3             = TEXT_DIM
        textLbl.TextXAlignment         = Enum.TextXAlignment.Center
        textLbl.Text                   = info.texto
        textLbl.Parent                 = btnFr

        -- Badge de notificación (punto rojo, oculto por defecto)
        local badge = Instance.new("Frame")
        badge.Name                   = "Badge"
        badge.Size                   = UDim2.new(0, 12, 0, 12)
        badge.Position               = UDim2.new(1, -14, 0, 2)
        badge.BackgroundColor3       = Color3.fromRGB(220, 40, 40)
        badge.BorderSizePixel        = 0
        badge.Visible                = false
        badge.Parent                 = btnFr
        local badgeCorner = Instance.new("UICorner")
        badgeCorner.CornerRadius = UDim.new(0.5, 0)
        badgeCorner.Parent       = badge

        if info.badge == "huevo" then
            ui.badgeHuevo      = badge
        elseif info.badge == "tienda" then
            ui.badgeTienda     = badge
        elseif info.badge == "inventario" then
            ui.badgeInventario = badge
        end

        -- Botón invisible encima de todo para capturar clics
        local clickBtn = Instance.new("TextButton")
        clickBtn.Size                   = UDim2.new(1, 0, 1, 0)
        clickBtn.BackgroundTransparency = 1
        clickBtn.Text                   = ""
        clickBtn.ZIndex                 = 5
        clickBtn.Parent                 = btnFr

        local eventoCapturado = info.evento
        clickBtn.Activated:Connect(function()
            -- Animar el botón (feedback táctil)
            TweenService:Create(btnFr, TWEEN_FAST,
                { BackgroundColor3 = Color3.fromRGB(50, 35, 75) }):Play()
            task.delay(0.15, function()
                TweenService:Create(btnFr, TWEEN_FAST,
                    { BackgroundColor3 = Color3.fromRGB(25, 18, 40) }):Play()
            end)
            -- Limpiar badge si aplica
            if info.badge == "huevo" and ui.badgeHuevo then
                ui.badgeHuevo.Visible   = false
                state.huevoListo        = false
            elseif info.badge == "tienda" and ui.badgeTienda then
                ui.badgeTienda.Visible  = false
                state.tiendaRotada      = false
            elseif info.badge == "inventario" and ui.badgeInventario then
                ui.badgeInventario.Visible = false
                state.inventarioItems      = false
            end
            NavEvent:Fire(eventoCapturado)
        end)
    end

    -- ── Conexión de RemoteEvents del servidor ─────────────────────────────

    -- Helper para conectar eventos con manejo seguro de eventos no encontrados
    local function conectar(nombre, callback)
        local Remotes = ReplicatedStorage:WaitForChild("Remotes", 12)
        local ev = Remotes and Remotes:WaitForChild(nombre, 12)
        if ev then
            ev.OnClientEvent:Connect(callback)
        else
            warn(("[HUD] RemoteEvent '%s' no encontrado en 12 s."):format(nombre))
        end
    end

    -- Recolección manual de oro al presionar E en el nido
    conectar("GoldCollected", function(data)
        -- data llega como tabla {amount=N, nestIndex=N} desde DragonService
        local oro = type(data) == "table" and (data.amount or 0) or (tonumber(data) or 0)
        HUD.ShowNotification("💰 +" .. formatNumber(math.floor(oro)) .. " oro", "success")
    end)

    -- Oro actualizado (DataStore.AddGold / SpendGold)
    conectar("GoldUpdated", function(data)
        HUD.UpdateGold(data)
        -- Refrescar panel de prestige con datos actualizados del servidor
        task.spawn(function()
            local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
            local rf = Remotes and Remotes:FindFirstChild("RequestPrestigeData")
            if rf then
                local ok, prestigeData = pcall(function() return rf:InvokeServer() end)
                if ok and prestigeData then
                    HUD.UpdatePrestigePanel(prestigeData)
                end
            end
        end)
    end)

    -- Stats de producción (DragonService, cada 1 segundo)
    conectar("StatsUpdated", function(stats)
        HUD.UpdateGoldPerSecond(stats)
    end)

    -- Nidos actualizados (PlaceDragon, RemoveDragon, BuySlot, ApplyBoost, etc.)
    conectar("NestUpdated", function(nestData)
        HUD.UpdateNestPanel(nestData)
    end)

    -- Boost aplicado a un nido
    conectar("BoostAplicado", function(data)
        if not data then return end
        -- NestUpdated llega a continuación del servidor; solo mostrar notificación
        local nombre = data.boostId
        if Constants.BOOST_TYPES and Constants.BOOST_TYPES[data.boostId] then
            nombre = Constants.BOOST_TYPES[data.boostId].nombre
        end
        if data.alcance == "granja" then
            HUD.ShowNotification(("⚡ %s activa en toda la granja"):format(nombre), "success")
        else
            HUD.ShowNotification(
                ("⚡ %s activo en nido %d"):format(nombre, data.nestIndex or 0), "success")
        end
    end)

    -- Boost expirado en un nido
    conectar("BoostExpirado", function(data)
        if not data then return end
        local ni  = data.nestIndex
        local row = ui.nestRows[ni]
        state.boostExpiry[ni] = nil
        if row and row.boostLbl then
            row.boostLbl.Text = ""
        end
        colorearFila(ni, false, state.evaporating[ni] ~= nil)
        local nombre = data.boostId
        if Constants.BOOST_TYPES and Constants.BOOST_TYPES[data.boostId] then
            nombre = Constants.BOOST_TYPES[data.boostId].nombre
        end
        HUD.ShowNotification(("⏱️ %s expiró en nido %d"):format(nombre, ni), "warning")
    end)

    -- Gemas actualizadas
    conectar("GemsUpdated", function(data)
        if data and data.gems then
            state.gems        = data.gems
            ui.gemsLabel.Text = "💎 " .. formatNumber(data.gems) .. " gemas"
        end
    end)

    -- Evento climático iniciado
    conectar("WeatherStarted", function(eventData)
        HUD.ShowWeatherBanner(eventData)
    end)

    -- Evento climático terminado
    conectar("WeatherEnded", function(_data)
        HUD.HideWeatherBanner()
    end)

    -- Aviso de 30 s antes del fin del evento
    conectar("WeatherEnding", function(data)
        HUD.ShowWeatherWarning(data.secondsRemaining or 30)
    end)

    -- Huevo listo para recoger (loop de 5 s de EggService)
    conectar("EggReady", function(data)
        if data.collected then return end   -- notificación de recolección ya hecha
        local ni = data.nestIndex
        if not ni then return end
        state.eggStatus[ni] = { isReady = true, readyAt = data.readyAt, dragonId = data.dragonId }
        local row = ui.nestRows[ni]
        if row then
            row.eggLbl.Text       = "  🥚 ¡Listo! ← toca aquí"
            row.eggLbl.TextColor3 = Color3.fromRGB(255, 220, 50)
        end
    end)

    -- Huevo iniciado (EggService.StartEggTimer)
    conectar("EggStarted", function(data)
        local ni = data.nestIndex
        if not ni then return end
        state.eggStatus[ni] = { isReady = false, readyAt = data.readyAt, dragonId = data.dragonId }
    end)

    -- Aviso de evaporación de oro en un nido específico
    conectar("GoldEvaporating", function(data)
        local ni = data.nestIndex
        if not ni then return end
        state.evaporating[ni] = data.secondsRemaining
        colorearFila(ni, false, true)
        local row = ui.nestRows[ni]
        if row then
            local m = math.floor(data.secondsRemaining / 60)
            local s = data.secondsRemaining % 60
            row.eggLbl.Text       = ("  ⚠️ Oro evaporando en %d:%02d"):format(m, s)
            row.eggLbl.TextColor3 = Color3.fromRGB(255, 160, 60)
        end
        HUD.ShowNotification(
            ("¡Nido %d evaporando en %ds!"):format(ni, data.secondsRemaining),
            "warning")
    end)

    -- Tienda Rápida rotó
    conectar("TiendaRapidaActualizada", function(_payload)
        HUD.ShowNotification("⚡ ¡La Tienda Rápida se ha renovado!", "event")
    end)

    -- Tienda Especial rotó
    conectar("TiendaEspecialActualizada", function(_payload)
        HUD.ShowNotification("✨ ¡La Tienda Especial se ha renovado!", "event")
    end)

    -- Prestige completado (servidor confirmó el nivel nuevo)
    conectar("PrestigeCompleted", function(data)
        local nuevoNivel = data.nuevoNivel or state.level
        state.level         = nuevoNivel
        ui.levelLabel.Text  = "⭐ Nivel " .. nuevoNivel

        if data.nestData then
            HUD.UpdateNestPanel(data.nestData)
        end

        HUD.ShowNotification(
            ("🎉 ¡Nivel %d! Zona: %s"):format(nuevoNivel, data.zonaDesbloqueada or "?"),
            "event")

        -- Animación de flash en el panel de stats (celebración)
        task.spawn(function()
            for _ = 1, 3 do
                TweenService:Create(statsPanel, TweenInfo.new(0.12),
                    { BackgroundColor3 = Color3.fromRGB(70, 50, 10) }):Play()
                task.wait(0.25)
                TweenService:Create(statsPanel, TweenInfo.new(0.12),
                    { BackgroundColor3 = PANEL_BG }):Play()
                task.wait(0.25)
            end
        end)

        -- Actualizar panel para mostrar requisitos del nuevo siguiente nivel
        local reqSig = Constants.PRESTIGE[nuevoNivel + 1]
        HUD.UpdatePrestigePanel({
            canPrestige           = false,
            nivelObjetivo         = nuevoNivel + 1,
            dragons               = {},
            oroActualRequerido    = {
                required = reqSig and reqSig.oroActualRequerido or 0,
                current  = state.gold,
                met      = false,
            },
        })
    end)

    -- Estado del servidor (ranking y minimapa)
    conectar("EstadoServidorActualizado", function(estadoServidor)
        state.estadoServidor = estadoServidor or {}
        HUD.UpdateRankingPanel(estadoServidor)
    end)

    -- Tienda rotada → activar badge de notificación
    conectar("TiendaRapidaActualizada", function(_payload)
        if ui.badgeTienda then
            state.tiendaRotada     = true
            ui.badgeTienda.Visible = true
        end
    end)

    -- ── Tick loop de cliente (cada 1 segundo) ─────────────────────────────
    -- Actualiza todos los countdowns: huevos, evento climático, evaporación.
    task.spawn(function()
        while sg.Parent do
            task.wait(1)
            local ahora = os.time()

            -- Countdowns de huevos
            for ni, egg in pairs(state.eggStatus) do
                local row = ui.nestRows[ni]
                if row and egg.readyAt and not egg.isReady then
                    local secsLeft = math.max(0, egg.readyAt - ahora)
                    if secsLeft == 0 then
                        egg.isReady           = true
                        row.eggLbl.Text       = "  🥚 ¡Listo! ← toca aquí"
                        row.eggLbl.TextColor3 = Color3.fromRGB(255, 220, 50)
                        -- Activar badge de notificación en botón Huevos
                        if not state.huevoListo and ui.badgeHuevo then
                            state.huevoListo       = true
                            ui.badgeHuevo.Visible  = true
                        end
                    else
                        row.eggLbl.Text       = ("  🥚 %s restante"):format(formatTime(secsLeft))
                        row.eggLbl.TextColor3 = TEXT_DIM
                    end
                end
            end

            -- Countdown del banner climático
            if state.weather and state.weather.endsAt and ui.weatherCountLbl then
                local secsLeft = math.max(0, state.weather.endsAt - ahora)
                ui.weatherCountLbl.Text = ("Termina en: %s"):format(formatTime(secsLeft))
                if secsLeft == 0 then
                    HUD.HideWeatherBanner()
                end
            end

            -- Countdown de boosts activos por nido
            for ni, entry in pairs(state.boostExpiry) do
                local secsLeft = math.max(0, entry.expiraEn - ahora)
                local row = ui.nestRows[ni]
                if row and row.boostLbl then
                    if secsLeft > 0 then
                        local m, s = math.floor(secsLeft / 60), secsLeft % 60
                        row.boostLbl.Text = ("  ⚡ %s · termina en %d:%02d"):format(entry.nombre, m, s)
                    else
                        row.boostLbl.Text       = ""
                        state.boostExpiry[ni]   = nil
                        colorearFila(ni, false, state.evaporating[ni] ~= nil)
                    end
                end
            end

            -- Decremento local del temporizador de evaporación
            for ni, secs in pairs(state.evaporating) do
                local nuevo = secs - 1
                state.evaporating[ni] = nuevo
                if nuevo <= 0 then
                    state.evaporating[ni] = nil
                    colorearFila(ni, false, false)
                    local row = ui.nestRows[ni]
                    if row then
                        -- Limpiar el mensaje de evaporación solo si no hay estado de huevo
                        local egg = state.eggStatus[ni]
                        if not egg then
                            row.eggLbl.Text = ""
                        end
                    end
                end
            end
        end
    end)

    print("[HUD] Interfaz de Dragon Roost inicializada.")
end

--------------------------------------------------------------------------------
-- HUD.UpdateGold(data)
--
-- Actualiza el display de oro con animación de contador suave.
-- Usa TweenService sobre un NumberValue; el evento Changed actualiza el label.
-- data = { currentGold: number }
--------------------------------------------------------------------------------
function HUD.UpdateGold(data)
    if type(data) ~= "table" then return end

    local nuevoOro = data.currentGold or 0
    state.gold     = nuevoOro

    -- Cancelar el tween anterior para no interferir
    if goldTween then goldTween:Cancel() end

    -- Tween desde el valor actualmente visible hacia el nuevo valor
    goldTween = TweenService:Create(goldDisplayValue, TWEEN_GOLD, { Value = nuevoOro })
    goldTween:Play()
end

--------------------------------------------------------------------------------
-- HUD.UpdateGoldPerSecond(stats)
--
-- Actualiza el label de producción total y refresca las filas de nidos con su
-- valor de gps actualizado. Colorea cada fila según su estado:
--   Verde  = boost activo    Rojo = evaporando    Blanco = normal
-- stats = { gpsTotal, gpsPorNido = {[nestIndex]=gps}, nivel }
--------------------------------------------------------------------------------
function HUD.UpdateGoldPerSecond(stats)
    if type(stats) ~= "table" then return end

    -- Actualizar label de gps total
    if stats.gpsTotal ~= nil then
        state.gpsTotal    = stats.gpsTotal
        ui.gpsLabel.Text  = ("⚡ %.1f oro/seg"):format(stats.gpsTotal)
    end

    -- Actualizar nivel si cambió
    if stats.nivel and stats.nivel ~= state.level then
        state.level        = stats.nivel
        ui.levelLabel.Text = "⭐ Nivel " .. stats.nivel
    end

    -- Actualizar la parte de gps en el texto de cada fila activa
    if stats.gpsPorNido then
        for nestIndex, gps in pairs(stats.gpsPorNido) do
            state.gpsPorNido[nestIndex] = gps
            local row  = ui.nestRows[nestIndex]
            local nest = state.nests[nestIndex]
            if row and nest and nest.dragonId then
                local dragon   = DragonData.GetDragonById(nest.dragonId)
                local nombre   = dragon and dragon.name    or nest.dragonId
                local rareza   = dragon and dragon.rarity  or "comun"
                local elemento = dragon and dragon.element or ""
                local boostActivo = nest.boostSecondsLeft and nest.boostSecondsLeft > 0
                local boostTxt = boostActivo
                    and (" ✨×%.1f"):format(nest.boostMultiplier or 1)
                    or ""
                -- Verificar si el elemento de este dragón está afectado por el clima activo
                local weatherActivo = false
                local weatherMult   = 1.0
                if state.weather and state.weather.affectedElements then
                    for _, affElem in ipairs(state.weather.affectedElements) do
                        if affElem == elemento then
                            weatherActivo = true
                            weatherMult   = state.weather.multiplier or 1.0
                            break
                        end
                    end
                end
                -- Línea 1: nombre + gps + boost manual (sin ⚡ aquí para evitar truncado)
                row.infoLbl.Text       = ("🐉 Nido %d: %s  %.1f/s%s")
                    :format(nestIndex, nombre, gps, boostTxt)
                row.infoLbl.TextColor3 = RARITY_COLORS[rareza] or TEXT_PRIMARY
                -- Línea 2: elemento · rareza · ⚡ clima (si aplica a este elemento)
                if not state.eggStatus[nestIndex] and not state.evaporating[nestIndex] then
                    local emoji      = ELEMENT_EMOJI[elemento] or "🐲"
                    local climaTxt   = weatherActivo
                        and ("  ⚡×%.1f"):format(weatherMult)
                        or ""
                    row.eggLbl.Text       = ("  %s %s  ·  %s%s"):format(
                        emoji, capitalize(elemento), capitalize(rareza), climaTxt)
                    row.eggLbl.TextColor3 = weatherActivo
                        and Color3.fromRGB(255, 210, 60)
                        or (RARITY_COLORS[rareza] or TEXT_PRIMARY)
                end
                colorearFila(nestIndex, boostActivo, state.evaporating[nestIndex] ~= nil)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- HUD.UpdateNestPanel(nestData)
--
-- Recibe los datos de NestSystem.GetNestData y reconstruye el panel de nidos.
-- Para cada nido activo muestra:
--   · Nombre del dragón coloreado por rareza
--   · Gps con indicador de boost si está activo
--   · Estado del huevo (countdown o "listo")
-- nestData = { slots, nests = { [i] = { dragonId, boostMultiplier,
--              boostSecondsLeft, oroPendiente } }, level, gold, ... }
--------------------------------------------------------------------------------
function HUD.UpdateNestPanel(nestData)
    if type(nestData) ~= "table" then return end

    -- Sincronizar campos de estado local
    if nestData.level then
        state.level        = nestData.level
        ui.levelLabel.Text = "⭐ Nivel " .. nestData.level
    end
    if nestData.gold then
        HUD.UpdateGold({ currentGold = nestData.gold })
    end
    if nestData.nests then
        state.nests = nestData.nests
    end

    -- Ocultar todas las filas existentes antes de redibujar
    for _, row in pairs(ui.nestRows) do
        row.frame.Visible = false
    end

    local totalSlots  = nestData.slots or 3
    local hayDragones = false

    for nestIndex = 1, totalSlots do
        local nido = nestData.nests and nestData.nests[nestIndex]
        if nido and nido.dragonId then
            hayDragones = true
            local row  = crearFilaNido(nestIndex)
            row.frame.Visible = true

            -- Datos del dragón desde DragonData
            local dragon      = DragonData.GetDragonById(nido.dragonId)
            local nombre      = dragon and dragon.name    or nido.dragonId
            local rareza      = dragon and dragon.rarity  or "comun"
            local elemento    = dragon and dragon.element or ""
            local gps         = state.gpsPorNido[nestIndex]
                or (dragon and dragon.goldPerSecond or 0)
            local colorRareza = RARITY_COLORS[rareza] or TEXT_PRIMARY
            local boostActivo = nido.boostSecondsLeft and nido.boostSecondsLeft > 0

            -- Línea principal: nombre + gps
            local boostTxt = boostActivo
                and (" ✨×%.2g"):format(nido.boostMultiplier or 1)
                or ""
            row.infoLbl.Text       = ("🐉 Nido %d: %s  %.1f/s%s")
                :format(nestIndex, nombre, gps, boostTxt)
            row.infoLbl.TextColor3 = colorRareza

            -- Línea de boost: nombre + countdown (se actualiza en tick loop)
            if boostActivo and nido.boostId then
                local boostDef = Constants.BOOST_TYPES and Constants.BOOST_TYPES[nido.boostId]
                local boostNombre = boostDef and boostDef.nombre or nido.boostId
                state.boostExpiry[nestIndex] = {
                    expiraEn = os.time() + (nido.boostSecondsLeft or 0),
                    nombre   = boostNombre,
                }
                local secsLeft = nido.boostSecondsLeft or 0
                local m, s = math.floor(secsLeft / 60), secsLeft % 60
                row.boostLbl.Text = ("  ⚡ %s · termina en %d:%02d"):format(boostNombre, m, s)
            else
                state.boostExpiry[nestIndex] = nil
                row.boostLbl.Text = ""
            end

            -- Estado del huevo (usa state.eggStatus si hay data local más fresca)
            local egg = state.eggStatus[nestIndex]
            if state.evaporating[nestIndex] then
                -- La advertencia de evaporación tiene prioridad visual
                local secs = state.evaporating[nestIndex]
                local m, s = math.floor(secs / 60), secs % 60
                row.eggLbl.Text       = ("  ⚠️ Oro evaporando en %d:%02d"):format(m, s)
                row.eggLbl.TextColor3 = Color3.fromRGB(255, 160, 60)
            elseif egg then
                if egg.isReady then
                    row.eggLbl.Text       = "  🥚 ¡Listo! ← toca aquí"
                    row.eggLbl.TextColor3 = Color3.fromRGB(255, 220, 50)
                elseif egg.readyAt then
                    local secsLeft = math.max(0, egg.readyAt - os.time())
                    row.eggLbl.Text       = ("  🥚 %s restante"):format(formatTime(secsLeft))
                    row.eggLbl.TextColor3 = TEXT_DIM
                end
            else
                -- Sin huevo: mostrar elemento + rareza en línea 2
                local emoji = ELEMENT_EMOJI[elemento] or "🐲"
                row.eggLbl.Text       = ("  %s %s  ·  %s"):format(
                    emoji, capitalize(elemento), capitalize(rareza))
                row.eggLbl.TextColor3 = colorRareza
            end

            colorearFila(nestIndex, boostActivo, state.evaporating[nestIndex] ~= nil)
        end
    end

    -- Si no hay ningún dragón, mostrar mensaje de placeholder
    if not hayDragones then
        local row = crearFilaNido(1)
        row.frame.Visible     = true
        row.infoLbl.Text      = "🐉 Coloca dragones en tus nidos"
        row.infoLbl.TextColor3 = TEXT_DIM
        row.eggLbl.Text       = ""
    end
end

--------------------------------------------------------------------------------
-- HUD.ShowWeatherBanner(eventData)
--
-- Muestra el banner de evento con animación slide-in desde arriba.
-- El fondo y el nombre se colorean según el elemento afectado.
-- Inicia el countdown visible en el tick loop.
-- eventData = { eventId, name, endsAt, affectedElements, multiplier, ... }
--------------------------------------------------------------------------------
function HUD.ShowWeatherBanner(eventData)
    if type(eventData) ~= "table" then return end

    state.weather      = eventData
    state.weatherEnding = false

    -- Determinar color del banner por primer elemento afectado o por eventId
    local elements = eventData.affectedElements or {}
    local elemColor = elements[1] and ELEMENT_COLORS[elements[1]]
        or WEATHER_BANNER_COLORS[eventData.eventId]
        or Color3.fromRGB(80, 50, 150)

    -- Tinte del fondo mezclando el color del elemento con el oscuro del panel
    local bg = Color3.fromRGB(
        math.clamp(math.floor(elemColor.R * 255 * 0.12 + PANEL_BG.R * 255 * 0.88), 0, 255),
        math.clamp(math.floor(elemColor.G * 255 * 0.12 + PANEL_BG.G * 255 * 0.88), 0, 255),
        math.clamp(math.floor(elemColor.B * 255 * 0.12 + PANEL_BG.B * 255 * 0.88), 0, 255))

    -- Construcción del texto de efecto
    local elemTxt = #elements > 0 and table.concat(elements, "/") or "todos"
    local multStr = (eventData.multiplier and eventData.multiplier > 1)
        and ("Dragones %s: ×%.1f oro/seg"):format(elemTxt, eventData.multiplier)
        or ""

    -- Actualizar contenido del banner
    ui.weatherNameLbl.Text       = ("⚡ %s"):format((eventData.name or "EVENTO"):upper())
    ui.weatherNameLbl.TextColor3 = elemColor
    ui.weatherEffectLbl.Text     = multStr
    ui.weatherCountLbl.Text      = ""

    -- Animar fondo del banner al nuevo tinte
    TweenService:Create(ui.weatherBanner, TWEEN_FAST,
        { BackgroundColor3 = bg }):Play()

    -- Slide-in: mover de oculto (Y=-115) a visible (Y=10)
    ui.weatherBanner.Position = BANNER_POS_HIDDEN
    ui.weatherBanner.Visible  = true
    TweenService:Create(ui.weatherBanner, TWEEN_SLIDE,
        { Position = BANNER_POS_VISIBLE }):Play()

    -- Notificación lateral
    HUD.ShowNotification(("⚡ %s"):format(eventData.name or "Evento climático"), "event")
end

--------------------------------------------------------------------------------
-- HUD.HideWeatherBanner()
--
-- Oculta el banner de evento con animación slide-out hacia arriba.
-- Limpia el estado de weather para detener el countdown.
--------------------------------------------------------------------------------
function HUD.HideWeatherBanner()
    state.weather       = nil
    state.weatherEnding = false

    if not ui.weatherBanner or not ui.weatherBanner.Visible then return end

    local hideTween = TweenService:Create(ui.weatherBanner, TWEEN_SLIDE,
        { Position = BANNER_POS_HIDDEN })
    hideTween:Play()
    hideTween.Completed:Connect(function()
        if ui.weatherBanner then
            ui.weatherBanner.Visible = false
        end
    end)
end

--------------------------------------------------------------------------------
-- HUD.ShowWeatherWarning(secondsLeft)
--
-- Se activa cuando quedan ~30 segundos del evento.
-- Hace parpadear el banner en naranja para alertar al jugador.
-- secondsLeft: segundos restantes del evento.
--------------------------------------------------------------------------------
function HUD.ShowWeatherWarning(secondsLeft)
    state.weatherEnding = true

    if not ui.weatherBanner or not ui.weatherBanner.Visible then return end

    local colorAlerta = Color3.fromRGB(55, 25, 5)
    local colorNormal = ui.weatherBanner.BackgroundColor3

    -- Parpadeo: 3 ciclos de alterna entre normal y naranja
    task.spawn(function()
        for _ = 1, 3 do
            if not state.weatherEnding then break end
            TweenService:Create(ui.weatherBanner, TweenInfo.new(0.28),
                { BackgroundColor3 = colorAlerta }):Play()
            task.wait(0.32)
            TweenService:Create(ui.weatherBanner, TweenInfo.new(0.28),
                { BackgroundColor3 = colorNormal }):Play()
            task.wait(0.32)
        end
        -- Dejar en naranja sutil después del parpadeo
        if state.weatherEnding then
            TweenService:Create(ui.weatherBanner, TWEEN_FAST,
                { BackgroundColor3 = colorAlerta }):Play()
            ui.weatherNameLbl.TextColor3 = Color3.fromRGB(255, 165, 40)
        end
    end)

    HUD.ShowNotification(
        ("⚠️ Evento termina en %s"):format(formatTime(secondsLeft)),
        "warning")
end

--------------------------------------------------------------------------------
-- HUD.UpdatePrestigePanel(requirements)
--
-- Reconstruye la lista de requisitos del panel de prestige.
-- Muestra ✅ en verde para requisitos cumplidos y 🔴 en rojo para los faltantes.
-- Si canPrestige = true, activa la animación pulsante del botón "SUBIR NIVEL".
-- requirements = {
--   canPrestige   : boolean
--   nivelObjetivo : number
--   dragons       : { rareza = { required, current, met } }
--   goldEarned    : { required, current, met }
-- }
--------------------------------------------------------------------------------
function HUD.UpdatePrestigePanel(requirements)
    if type(requirements) ~= "table" then return end
    state.prestigeReqs = requirements

    -- Limpiar filas de requisitos anteriores
    for _, child in ipairs(ui.prestigeReqList:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end

    local nivelObj = requirements.nivelObjetivo or (state.level + 1)
    local reqConst = Constants.PRESTIGE[nivelObj]

    -- Nivel máximo: deshabilitar el panel
    if not reqConst then
        prestigePulseActive = false
        local maxLbl = crearLabel("🏆 ¡Nivel máximo alcanzado!",
            UDim2.new(1, 0, 0, 22), UDim2.new(0,0,0,0),
            ui.prestigeReqList, Enum.Font.GothamBold, TEXT_HEADER,
            Enum.TextXAlignment.Center)
        maxLbl.LayoutOrder   = 0
        ui.prestigeButton.Visible = false
        return
    end

    ui.prestigeButton.Visible = true
    local orden = 0

    -- ── Requisitos de dragones ─────────────────────────────────────────────
    -- Si el servidor envió datos de progreso los usamos; si no, mostramos
    -- solo los targets de Constants con "—" como valor actual.
    local dragonReqs = requirements.dragons or {}
    local mostroAlguno = false

    -- Primero mostramos las rarezas que vienen del servidor (con progreso real)
    for rareza, reqData in pairs(dragonReqs) do
        mostroAlguno = true
        local met       = type(reqData) == "table" and reqData.met or false
        local requerido = type(reqData) == "table" and reqData.required or tonumber(reqData) or 0
        local actual    = type(reqData) == "table" and reqData.current or 0
        local check     = met and "✅" or "🔴"
        local color     = met and Color3.fromRGB(100, 230, 100) or Color3.fromRGB(230, 90, 90)
        local lbl = crearLabel(
            ("%s %s: %d/%d"):format(check, capitalize(rareza), actual, requerido),
            UDim2.new(1, 0, 0, 18), UDim2.new(0,0,0,0),
            ui.prestigeReqList, Enum.Font.Gotham, color)
        lbl.LayoutOrder = orden
        orden += 1
    end

    -- Si no llegaron datos del servidor, mostrar desde Constants con "—"
    if not mostroAlguno and reqConst.DragonRequirements then
        for rareza, requerido in pairs(reqConst.DragonRequirements) do
            local lbl = crearLabel(
                ("🔄 %s: —/%d"):format(capitalize(rareza), requerido),
                UDim2.new(1, 0, 0, 18), UDim2.new(0,0,0,0),
                ui.prestigeReqList, Enum.Font.Gotham, TEXT_DIM)
            lbl.LayoutOrder = orden
            orden += 1
        end
    end

    -- ── Requisito de oro actual ────────────────────────────────────────────
    local goldReq    = requirements.oroActualRequerido
    local requerido  = (type(goldReq) == "table" and goldReq.required)
        or reqConst.oroActualRequerido or 0
    local actual     = (type(goldReq) == "table" and goldReq.current)
        or state.gold or 0
    local met        = (type(goldReq) == "table" and goldReq.met) or (actual >= requerido)

    local checkOro   = met and "✅" or "🔄"
    local colorOro   = met and Color3.fromRGB(100, 230, 100) or Color3.fromRGB(230, 190, 60)
    local goldLbl    = crearLabel(
        ("%s Oro actual: %s/%s"):format(checkOro, formatNumber(actual), formatNumber(requerido)),
        UDim2.new(1, 0, 0, 18), UDim2.new(0,0,0,0),
        ui.prestigeReqList, Enum.Font.Gotham, colorOro)
    goldLbl.LayoutOrder = orden

    -- ── Activar / desactivar botón de prestige ─────────────────────────────
    local puedePrestige = requirements.canPrestige == true

    if puedePrestige then
        -- Activar el botón y arrancar el pulso si no está ya activo
        ui.prestigeButton.TextColor3 = Color3.fromRGB(255, 245, 200)
        if not prestigePulseActive then
            prestigePulseActive = true
            task.spawn(function()
                local colorA = Color3.fromRGB(210, 155, 25)
                local colorB = Color3.fromRGB(130,  90, 12)
                while prestigePulseActive and ui.prestigeButton do
                    TweenService:Create(ui.prestigeButton, TweenInfo.new(0.55),
                        { BackgroundColor3 = colorA }):Play()
                    task.wait(0.60)
                    if not prestigePulseActive then break end
                    TweenService:Create(ui.prestigeButton, TweenInfo.new(0.55),
                        { BackgroundColor3 = colorB }):Play()
                    task.wait(0.60)
                end
            end)
        end
    else
        -- Desactivar pulso y oscurecer el botón
        prestigePulseActive = false
        TweenService:Create(ui.prestigeButton, TWEEN_FAST,
            { BackgroundColor3 = Color3.fromRGB(50, 35, 6) }):Play()
        ui.prestigeButton.TextColor3 = Color3.fromRGB(120, 100, 55)
    end
end

--------------------------------------------------------------------------------
-- HUD.UpdateRankingPanel(estadoServidor)
--
-- Reconstruye el ranking de jugadores en el servidor, ordenado por oro/seg.
-- estadoServidor = tabla de 8 entradas (GetEstadoServidor de ServerManager).
--------------------------------------------------------------------------------
function HUD.UpdateRankingPanel(estadoServidor)
    if not ui.rankingPanel then return end

    -- Filtrar solo slots activos y ordenar por oroPorSegundo desc
    local activos = {}
    for _, slot in ipairs(estadoServidor or {}) do
        if slot.activo and slot.jugador then
            table.insert(activos, slot)
        end
    end
    table.sort(activos, function(a, b)
        return (a.oroPorSegundo or 0) > (b.oroPorSegundo or 0)
    end)

    for i = 1, 8 do
        local row = ui.rankingRows[i]
        if not row then break end

        local slot = activos[i]
        if slot then
            local esYo    = slot.jugador == player.Name
            local prefijo = esYo and "▶ " or "  "
            local color   = esYo and TEXT_HEADER or TEXT_PRIMARY
            row.label.Text       = ("%s%s  N%d  %.0f/s"):format(
                prefijo, slot.jugador, slot.nivel or 1, slot.oroPorSegundo or 0)
            row.label.TextColor3 = color
            row.frame.Visible    = true
        else
            row.frame.Visible = false
        end
    end
end

--------------------------------------------------------------------------------
-- HUD.ShowGoldPopup(amount, nestIndex)
--
-- Muestra un popup flotante "+X oro" que sube 60 px y se desvanece en 1.2 s.
-- Se posiciona a la derecha del panel de nidos, a la altura de la fila del nido.
-- amount    : cantidad de oro ganada
-- nestIndex : índice del nido (para posicionar el popup)
--------------------------------------------------------------------------------
function HUD.ShowGoldPopup(amount, nestIndex)
    if not ui.screenGui then return end
    if not amount or amount <= 0 then return end

    -- Calcular posición basada en la fila del nido en el scroll
    -- (aproximación en pantalla; NestPanel empieza en Y=140, header=33px, filas=66px)
    local fila       = nestIndex or 1
    local xBase      = 12 + 262 + 8   -- NestPanel X + ancho + margen
    local yBase      = 140 + 33 + (fila - 1) * 66 + 20

    local popup = Instance.new("TextLabel")
    popup.Name                  = "GoldPopup"
    popup.Size                  = UDim2.new(0, 110, 0, 28)
    popup.Position              = UDim2.new(0, xBase, 0, yBase)
    popup.AnchorPoint           = Vector2.new(0, 0.5)
    popup.BackgroundColor3      = Color3.fromRGB(255, 220, 50)
    popup.BackgroundTransparency = 0.05
    popup.BorderSizePixel       = 0
    popup.Font                  = Enum.Font.GothamBold
    popup.TextSize              = 15
    popup.TextColor3            = Color3.fromRGB(35, 22, 0)
    popup.Text                  = ("+ %s oro"):format(formatNumber(amount))
    popup.ZIndex                = 20
    popup.Parent                = ui.screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent       = popup

    -- Animación: sube 60 px mientras se desvanece
    local posDestino = UDim2.new(0, xBase, 0, yBase - 60)

    TweenService:Create(popup,
        TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Position = posDestino }):Play()

    local fadeTween = TweenService:Create(popup,
        TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.4),
        { BackgroundTransparency = 1, TextTransparency = 1 })
    fadeTween:Play()
    fadeTween.Completed:Connect(function()
        if popup and popup.Parent then popup:Destroy() end
    end)
end

--------------------------------------------------------------------------------
-- HUD.ShowNotification(message, notifType)
--
-- Muestra una notificación temporal (3 s) en la esquina superior derecha.
-- Entra con slide desde la derecha y sale con fade.
-- notifType : "success" | "warning" | "error" | "event"
--------------------------------------------------------------------------------
function HUD.ShowNotification(message, notifType)
    if not ui.notifContainer then return end

    local accentColor = NOTIF_COLORS[notifType] or NOTIF_COLORS.success

    -- Calcular LayoutOrder como timestamp para que las más nuevas queden primero
    local orden = -os.clock()

    -- Frame contenedor de la notificación
    local notifFrame = Instance.new("Frame")
    notifFrame.Name                   = "Notif"
    notifFrame.Size                   = UDim2.new(1, 0, 0, 46)
    notifFrame.BackgroundColor3       = Color3.fromRGB(
        math.clamp(math.floor(accentColor.R * 255 * 0.25 + 10), 0, 255),
        math.clamp(math.floor(accentColor.G * 255 * 0.25 + 10), 0, 255),
        math.clamp(math.floor(accentColor.B * 255 * 0.25 + 10), 0, 255))
    notifFrame.BackgroundTransparency = 0.10
    notifFrame.BorderSizePixel        = 0
    notifFrame.LayoutOrder            = orden
    notifFrame.Parent                 = ui.notifContainer

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent       = notifFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color     = accentColor
    stroke.Thickness = 1.5
    stroke.Parent    = notifFrame

    -- Barra de color a la izquierda (indicador visual del tipo de notificación)
    local barra = Instance.new("Frame")
    barra.Size               = UDim2.new(0, 4, 1, -10)
    barra.Position           = UDim2.new(0, 6, 0, 5)
    barra.BackgroundColor3   = accentColor
    barra.BorderSizePixel    = 0
    barra.Parent             = notifFrame
    local barraCorner = Instance.new("UICorner")
    barraCorner.CornerRadius = UDim.new(0, 2)
    barraCorner.Parent       = barra

    -- Texto del mensaje
    local msgLbl = Instance.new("TextLabel")
    msgLbl.Size                   = UDim2.new(1, -18, 1, 0)
    msgLbl.Position               = UDim2.new(0, 14, 0, 0)
    msgLbl.BackgroundTransparency = 1
    msgLbl.Font                   = Enum.Font.Gotham
    msgLbl.TextSize               = 12
    msgLbl.TextColor3             = TEXT_PRIMARY
    msgLbl.TextWrapped            = true
    msgLbl.TextXAlignment         = Enum.TextXAlignment.Left
    msgLbl.TextYAlignment         = Enum.TextYAlignment.Center
    msgLbl.Text                   = message
    msgLbl.Parent                 = notifFrame

    -- Entrada: slide desde la derecha fuera de la pantalla
    notifFrame.Position = UDim2.new(1, 10, 0, 0)
    TweenService:Create(notifFrame, TWEEN_BOUNCE,
        { Position = UDim2.new(0, 0, 0, 0) }):Play()

    -- Salida: fade + reducción de altura después de 2.5 s de espera
    task.delay(2.5, function()
        if not notifFrame or not notifFrame.Parent then return end

        -- Fade del texto, borde y fondo
        TweenService:Create(msgLbl, TweenInfo.new(0.4, Enum.EasingStyle.Quad,
            Enum.EasingDirection.In), { TextTransparency = 1 }):Play()
        TweenService:Create(stroke, TweenInfo.new(0.4, Enum.EasingStyle.Quad,
            Enum.EasingDirection.In), { Transparency = 1 }):Play()

        local fadeTween = TweenService:Create(notifFrame,
            TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { BackgroundTransparency = 1 })
        fadeTween:Play()
        fadeTween.Completed:Connect(function()
            if notifFrame and notifFrame.Parent then
                notifFrame:Destroy()
            end
        end)
    end)
end

--------------------------------------------------------------------------------
-- Inicialización automática al cargar el LocalScript
--------------------------------------------------------------------------------

HUD.Init()

-- Cargar datos de prestige una vez que el servidor haya inicializado al jugador
task.delay(3, function()
    local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
    local rf = Remotes and Remotes:FindFirstChild("RequestPrestigeData")
    if rf then
        local ok, prestigeData = pcall(function() return rf:InvokeServer() end)
        if ok and prestigeData then
            HUD.UpdatePrestigePanel(prestigeData)
        end
    end
end)

return HUD
