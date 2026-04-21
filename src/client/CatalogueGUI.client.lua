--------------------------------------------------------------------------------
-- CatalogueGUI.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Gestiona el catálogo completo de dragones del juego.
-- Permite al jugador ver todos los dragones, su progreso de colección,
-- detalles de stats y los bonuses activos por colección de elemento.
--
-- ESTADOS DE CARD:
--   CONSEGUIDO    → color completo, borde de rareza, nombre visible
--   NO CONSEGUIDO → escala de grises, nombre ocultado con "???"
--   BLOQUEADO     → completamente oscuro, muestra nivel requerido
--
-- TABS: TODOS · FIRE · WATER · ICE · THUNDER · NATURE · SHADOW · CELESTIAL
--       · VOID · BREEDING · EVENTOS
--
-- REMOTEFUNCTION USADA:
--   RequestGetCatalogueData → { discovered, inventory, nestDragons, playerLevel }
--
-- EVENTOS ESCUCHADOS:
--   EggIncubated      → UpdateProgress si es dragón nuevo
--   BreedingCompleted → UpdateProgress si es dragón nuevo
--   PurchaseCompleted → UpdateProgress si se compró dragón nuevo
--------------------------------------------------------------------------------

local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RARITIES = Constants.RARITIES

--------------------------------------------------------------------------------
-- Paleta de colores (consistente con HUD.lua y ShopGUI.lua)
--------------------------------------------------------------------------------

local RARITY_COLORS = {
    common    = Color3.fromRGB(180, 180, 180),
    uncommon  = Color3.fromRGB( 80, 200,  80),
    rare      = Color3.fromRGB( 80, 130, 220),
    epic      = Color3.fromRGB(160,  80, 220),
    legendary = Color3.fromRGB(255, 165,   0),
    mythic    = Color3.fromRGB(255,  50,  50),
}

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

local ELEMENT_EMOJI = {
    fire = "🔥", water = "💧", ice = "❄️", thunder = "⚡",
    nature = "🌿", shadow = "🌑", celestial = "✨", void = "🌀",
}

local PANEL_BG      = Color3.fromRGB(15,  10,  25)
local PANEL_BG2     = Color3.fromRGB(22,  15,  40)
local BORDER_COLOR  = Color3.fromRGB(200, 160,  50)
local TEXT_PRIMARY  = Color3.fromRGB(240, 220, 160)
local TEXT_SECONDARY = Color3.fromRGB(160, 140, 100)

-- Nivel mínimo requerido por rareza (derivado de Constants.LEVELS)
local RARITY_MIN_LEVEL = {
    common = 1, uncommon = 4, rare = 6, epic = 9, legendary = 12, mythic = 15,
}
local BREEDING_MIN_LEVEL = 7  -- Constants.LEVELS[7].breedingUnlocked = true

-- Orden numérico de rareza para ordenación
local RARITY_ORDER = { common=1, uncommon=2, rare=3, epic=4, legendary=5, mythic=6 }

-- Colecciones y sus bonuses (una por elemento; completa las 6 raridades base)
local COLLECTION_BONUSES = {
    { element = "fire",      emoji = "🔥", bonus = "+15% oro Fire",      color = Color3.fromRGB(255,  90,  20) },
    { element = "water",     emoji = "💧", bonus = "+15% oro Water",     color = Color3.fromRGB( 30, 130, 255) },
    { element = "ice",       emoji = "❄️", bonus = "+15% oro Ice",       color = Color3.fromRGB(180, 230, 255) },
    { element = "thunder",   emoji = "⚡", bonus = "+15% oro Thunder",   color = Color3.fromRGB(255, 240,  50) },
    { element = "nature",    emoji = "🌿", bonus = "+15% oro Nature",    color = Color3.fromRGB( 50, 200,  80) },
    { element = "shadow",    emoji = "🌑", bonus = "+15% oro Shadow",    color = Color3.fromRGB(130,  50, 200) },
    { element = "celestial", emoji = "✨", bonus = "+15% oro Celestial", color = Color3.fromRGB(255, 220, 100) },
    { element = "void",      emoji = "🌀", bonus = "+15% oro Void",      color = Color3.fromRGB( 80,  20, 160) },
}

-- Definición de tabs del catálogo
local TABS = {
    { id = "todos",     label = "TODOS"        },
    { id = "fire",      label = "🔥 FIRE"      },
    { id = "water",     label = "💧 WATER"     },
    { id = "ice",       label = "❄️ ICE"       },
    { id = "thunder",   label = "⚡ THUNDER"   },
    { id = "nature",    label = "🌿 NATURE"    },
    { id = "shadow",    label = "🌑 SHADOW"    },
    { id = "celestial", label = "✨ CELESTIAL" },
    { id = "void",      label = "🌀 VOID"      },
    { id = "breeding",  label = "🥚 BREEDING"  },
    { id = "eventos",   label = "🎉 EVENTOS"   },
}

--------------------------------------------------------------------------------
-- Configuraciones de Tween
--------------------------------------------------------------------------------

local TW_OPEN   = TweenInfo.new(0.35, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TW_CLOSE  = TweenInfo.new(0.20, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local TW_DETAIL = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TW_BAR    = TweenInfo.new(0.50, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TW_FADE   = TweenInfo.new(0.18, Enum.EasingStyle.Linear,Enum.EasingDirection.Out)
local TW_FLASH  = TweenInfo.new(0.12, Enum.EasingStyle.Linear,Enum.EasingDirection.Out)
local TW_SLIDE  = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TW_BOUNCE = TweenInfo.new(0.40, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)

--------------------------------------------------------------------------------
-- Dimensiones
--------------------------------------------------------------------------------

local WIN_W    = 760
local WIN_H    = 540
local HEADER_H = 62
local TAB_H    = 34
local BONUS_H  = 112
local GRID_H   = WIN_H - HEADER_H - TAB_H - BONUS_H - 8  -- ~324px
local CELL_W   = 112
local CELL_H   = 148

-- Panel de detalle (overlay derecho)
local DETAIL_W         = 302
local DETAIL_X_HIDDEN  = WIN_W
local DETAIL_X_VISIBLE = WIN_W - DETAIL_W - 4

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

local state = {
    isOpen        = false,
    activeFilter  = "todos",
    catalogueData = nil,    -- { discovered={}, inventory={}, nestDragons={}, playerLevel=1 }
    activeDetail  = nil,    -- dragonId del panel abierto, nil si cerrado
    barGen        = 0,      -- generación para cancelar tweens de barras al cambiar detalle
    cardFrames    = {},     -- [dragonId] = Frame del card (para UpdateProgress)
    celebrando    = false,  -- evita celebraciones de colección simultáneas
}

local ui             = {}     -- referencias a frames creados en crearVentana()
local CatalogueGUI   = {}     -- módulo a exportar

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

-- Formatea número con separadores de miles
local function formatNumber(n)
    local s = tostring(math.floor(n))
    local r, c = "", 0
    for i = #s, 1, -1 do
        c = c + 1
        r = s:sub(i, i) .. r
        if c % 3 == 0 and i > 1 then r = "," .. r end
    end
    return r
end

-- Formatea segundos en "M:SS" o "H:MM:SS"
local function formatTime(seg)
    seg = math.floor(seg)
    if seg < 3600 then
        return string.format("%d:%02d", math.floor(seg / 60), seg % 60)
    end
    return string.format("%d:%02d:%02d", math.floor(seg/3600),
        math.floor((seg % 3600) / 60), seg % 60)
end

-- Genera estrellas de rareza (★★☆☆☆☆)
local function rarityStars(rarity)
    local n = RARITY_ORDER[rarity] or 1
    return string.rep("★", n) .. string.rep("☆", 6 - n)
end

-- Determina el estado del dragón para el jugador actual
-- Retorna: "conseguido" | "bloqueado" | "no_conseguido"
local function obtenerEstado(dragon, cd)
    if cd and cd.discovered and cd.discovered[dragon.id] then
        return "conseguido"
    end
    local minLv = dragon.breedingOnly and BREEDING_MIN_LEVEL
                  or (RARITY_MIN_LEVEL[dragon.rarity] or 1)
    if (cd and cd.playerLevel or 1) < minLv then
        return "bloqueado"
    end
    return "no_conseguido"
end

-- Cuenta dragones base de un elemento que el jugador ya consiguió (para colecciones)
local function contarProgresionElemento(element, cd)
    local total, conseguidos = 0, 0
    for _, d in ipairs(DragonData.Dragons) do
        if d.element == element and not d.breedingOnly and not d.eventOnly then
            total = total + 1
            if cd and cd.discovered and cd.discovered[d.id] then
                conseguidos = conseguidos + 1
            end
        end
    end
    return conseguidos, total
end

-- Crea un Frame con UICorner y UIStroke opcionales
local function mkFrame(parent, name, size, pos, bg, borderClr, radius)
    local f = Instance.new("Frame")
    f.Name             = name
    f.Size             = size
    f.Position         = pos or UDim2.new(0,0,0,0)
    f.BackgroundColor3 = bg or PANEL_BG
    f.BorderSizePixel  = 0
    f.ClipsDescendants = true
    f.Parent           = parent
    if radius then
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, radius)
        c.Parent = f
    end
    if borderClr then
        local s = Instance.new("UIStroke")
        s.Color     = borderClr
        s.Thickness = 1.5
        s.Parent    = f
    end
    return f
end

-- Crea un TextLabel
local function mkLabel(parent, name, text, size, pos, fontSize, color, font, xAlign)
    local l = Instance.new("TextLabel")
    l.Name               = name
    l.Size               = size
    l.Position           = pos or UDim2.new(0,0,0,0)
    l.Text               = text
    l.TextSize           = fontSize or 13
    l.TextColor3         = color or TEXT_PRIMARY
    l.Font               = font or Enum.Font.GothamMedium
    l.BackgroundTransparency = 1
    l.TextXAlignment     = xAlign or Enum.TextXAlignment.Left
    l.TextWrapped        = true
    l.Parent             = parent
    return l
end

-- Crea un TextButton estilizado
local function mkButton(parent, name, text, size, pos, bg, textClr, fontSize)
    local b = Instance.new("TextButton")
    b.Name             = name
    b.Size             = size
    b.Position         = pos or UDim2.new(0,0,0,0)
    b.Text             = text
    b.TextSize         = fontSize or 13
    b.TextColor3       = textClr or Color3.fromRGB(15,10,25)
    b.BackgroundColor3 = bg or BORDER_COLOR
    b.Font             = Enum.Font.GothamBold
    b.BorderSizePixel  = 0
    b.AutoButtonColor  = false
    b.Parent           = parent
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    return b
end

--------------------------------------------------------------------------------
-- CONSTRUCCIÓN DEL UI PRINCIPAL
-- crearVentana() construye todos los elementos estáticos una sola vez desde Init().
--------------------------------------------------------------------------------

local function crearVentana()
    -- ScreenGui raíz
    local sg = Instance.new("ScreenGui")
    sg.Name           = "CatalogueGUI"
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Enabled        = false
    sg.Parent         = playerGui
    ui.screenGui      = sg

    -- Frame principal centrado
    local main = mkFrame(sg, "MainFrame",
        UDim2.new(0, WIN_W, 0, WIN_H),
        UDim2.new(0.5, -WIN_W/2, 0.5, -WIN_H/2),
        PANEL_BG, BORDER_COLOR, 10)
    ui.mainFrame = main

    -- ── HEADER ────────────────────────────────────────────────────────────────

    local header = mkFrame(main, "Header",
        UDim2.new(1, 0, 0, HEADER_H),
        UDim2.new(0,0,0,0),
        Color3.fromRGB(20,14,38), nil, 0)

    -- Línea separadora inferior del header
    local hLine = Instance.new("Frame")
    hLine.Size             = UDim2.new(1,0,0,1)
    hLine.Position         = UDim2.new(0,0,1,-1)
    hLine.BackgroundColor3 = BORDER_COLOR
    hLine.BorderSizePixel  = 0
    hLine.Parent           = header

    mkLabel(header, "TitleLbl", "📖  CATÁLOGO DE DRAGONES",
        UDim2.new(0,380,0,30), UDim2.new(0,14,0,6),
        21, BORDER_COLOR, Enum.Font.GothamBold)

    ui.progressLabel = mkLabel(header, "ProgressLbl", "Conseguidos: —/—",
        UDim2.new(0,240,0,20), UDim2.new(0,14,0,38),
        13, TEXT_SECONDARY, Enum.Font.Gotham)

    ui.bonusCountLabel = mkLabel(header, "BonusCountLbl", "Bonuses: 0 activos",
        UDim2.new(0,200,0,20), UDim2.new(0,265,0,38),
        13, Color3.fromRGB(100,220,100), Enum.Font.Gotham)

    local closeBtn = mkButton(header, "CloseBtn", "✕",
        UDim2.new(0,34,0,34), UDim2.new(1,-44,0,14),
        Color3.fromRGB(140,40,40), Color3.fromRGB(255,220,220), 17)
    closeBtn.MouseButton1Click:Connect(function() CatalogueGUI.Close() end)

    -- ── TAB BAR ───────────────────────────────────────────────────────────────

    local tabContainer = mkFrame(main, "TabContainer",
        UDim2.new(1,0,0,TAB_H),
        UDim2.new(0,0,0,HEADER_H),
        Color3.fromRGB(18,12,32), nil, 0)

    -- ScrollingFrame horizontal para que los tabs nunca desborden
    local tabScroll = Instance.new("ScrollingFrame")
    tabScroll.Name               = "TabScroll"
    tabScroll.Size               = UDim2.new(1,0,1,0)
    tabScroll.BackgroundTransparency = 1
    tabScroll.BorderSizePixel    = 0
    tabScroll.ScrollBarThickness = 0
    tabScroll.ScrollingDirection = Enum.ScrollingDirection.X
    tabScroll.CanvasSize         = UDim2.new(0,0,1,0)
    tabScroll.Parent             = tabContainer
    ui.tabScroll = tabScroll

    local tabLayout = Instance.new("UIListLayout")
    tabLayout.FillDirection = Enum.FillDirection.Horizontal
    tabLayout.SortOrder     = Enum.SortOrder.LayoutOrder
    tabLayout.Padding       = UDim.new(0,4)
    tabLayout.Parent        = tabScroll

    -- Ajustar CanvasSize del scroll de tabs al contenido real
    tabLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        tabScroll.CanvasSize = UDim2.new(0, tabLayout.AbsoluteContentSize.X + 8, 1, 0)
    end)

    -- Línea decorativa inferior de la tab bar
    local tLine = Instance.new("Frame")
    tLine.Size             = UDim2.new(1,0,0,1)
    tLine.Position         = UDim2.new(0,0,1,-1)
    tLine.BackgroundColor3 = BORDER_COLOR
    tLine.BackgroundTransparency = 0.65
    tLine.BorderSizePixel  = 0
    tLine.Parent           = tabContainer

    -- Crear botón por cada tab definido
    ui.tabButtons = {}
    for i, tab in ipairs(TABS) do
        local btn = Instance.new("TextButton")
        btn.Name             = "Tab_" .. tab.id
        btn.Text             = tab.label
        btn.TextSize         = 12
        btn.Font             = Enum.Font.GothamMedium
        btn.TextColor3       = TEXT_PRIMARY
        btn.BackgroundColor3 = Color3.fromRGB(40,30,60)
        btn.BorderSizePixel  = 0
        btn.AutoButtonColor  = false
        btn.Size             = UDim2.new(0,0,1,-6)
        btn.AutomaticSize    = Enum.AutomaticSize.X
        btn.LayoutOrder      = i
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft  = UDim.new(0,8)
        pad.PaddingRight = UDim.new(0,8)
        pad.Parent       = btn
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0,5)
        corner.Parent       = btn
        btn.Parent          = tabScroll

        local tabId = tab.id
        btn.MouseButton1Click:Connect(function()
            CatalogueGUI.FilterByElement(tabId)
        end)
        ui.tabButtons[tabId] = btn
    end

    -- ── ÁREA DE GRID (ScrollingFrame) ─────────────────────────────────────────

    local gridY = HEADER_H + TAB_H + 4
    local gridScroll = Instance.new("ScrollingFrame")
    gridScroll.Name               = "GridScroll"
    gridScroll.Size               = UDim2.new(1,-8,0, GRID_H)
    gridScroll.Position           = UDim2.new(0,4,0, gridY)
    gridScroll.BackgroundTransparency = 1
    gridScroll.BorderSizePixel    = 0
    gridScroll.ScrollBarThickness = 4
    gridScroll.ScrollBarImageColor3 = BORDER_COLOR
    gridScroll.CanvasSize         = UDim2.new(0,0,0,0)
    gridScroll.ClipsDescendants   = true
    gridScroll.Parent             = main
    ui.gridScroll = gridScroll

    local gridLayout = Instance.new("UIGridLayout")
    gridLayout.CellSize           = UDim2.new(0, CELL_W, 0, CELL_H)
    gridLayout.CellPadding        = UDim2.new(0,8,0,8)
    gridLayout.SortOrder          = Enum.SortOrder.LayoutOrder
    gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    gridLayout.VerticalAlignment   = Enum.VerticalAlignment.Top
    gridLayout.Parent              = gridScroll
    ui.gridLayout = gridLayout

    gridLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        gridScroll.CanvasSize = UDim2.new(0,0,0, gridLayout.AbsoluteContentSize.Y + 14)
    end)

    local gridPad = Instance.new("UIPadding")
    gridPad.PaddingLeft   = UDim.new(0,6)
    gridPad.PaddingTop    = UDim.new(0,6)
    gridPad.PaddingRight  = UDim.new(0,6)
    gridPad.PaddingBottom = UDim.new(0,6)
    gridPad.Parent        = gridScroll

    -- ── PANEL DE BONUSES DE COLECCIÓN (parte inferior) ────────────────────────

    local bonusY = HEADER_H + TAB_H + 4 + GRID_H + 4
    local bonusPanel = mkFrame(main, "BonusPanel",
        UDim2.new(1,-8,0, BONUS_H - 2),
        UDim2.new(0,4,0, bonusY),
        Color3.fromRGB(18,12,32), BORDER_COLOR, 6)
    ui.bonusPanel = bonusPanel

    mkLabel(bonusPanel, "BonusTitle", "BONUSES DE COLECCIÓN",
        UDim2.new(0,240,0,16), UDim2.new(0,8,0,4),
        11, BORDER_COLOR, Enum.Font.GothamBold)

    -- ScrollingFrame horizontal para las tarjetas de bonus
    local bonusScroll = Instance.new("ScrollingFrame")
    bonusScroll.Name               = "BonusScroll"
    bonusScroll.Size               = UDim2.new(1,-8,0, BONUS_H - 24)
    bonusScroll.Position           = UDim2.new(0,4,0,20)
    bonusScroll.BackgroundTransparency = 1
    bonusScroll.BorderSizePixel    = 0
    bonusScroll.ScrollBarThickness = 3
    bonusScroll.ScrollBarImageColor3 = BORDER_COLOR
    bonusScroll.ScrollingDirection = Enum.ScrollingDirection.X
    bonusScroll.CanvasSize         = UDim2.new(0,0,1,0)
    bonusScroll.Parent             = bonusPanel
    ui.bonusScroll = bonusScroll

    local bonusListLayout = Instance.new("UIListLayout")
    bonusListLayout.FillDirection = Enum.FillDirection.Horizontal
    bonusListLayout.SortOrder     = Enum.SortOrder.LayoutOrder
    bonusListLayout.Padding       = UDim.new(0,6)
    bonusListLayout.Parent        = bonusScroll

    bonusListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        bonusScroll.CanvasSize = UDim2.new(0, bonusListLayout.AbsoluteContentSize.X + 12, 1, 0)
    end)

    -- ── PANEL DE DETALLE (overlay derecho, desliza dentro de la ventana) ──────

    local detailTop = HEADER_H + TAB_H + 2
    local detailH   = WIN_H - detailTop - 4
    local detail = mkFrame(main, "DetailPanel",
        UDim2.new(0, DETAIL_W, 0, detailH),
        UDim2.new(0, DETAIL_X_HIDDEN, 0, detailTop),
        Color3.fromRGB(20,14,38), BORDER_COLOR, 8)
    detail.ZIndex           = 5
    detail.ClipsDescendants = true
    ui.detailPanel = detail

    -- Botón de cierre del detalle
    local detailClose = mkButton(detail, "DetailCloseBtn", "✕  Cerrar",
        UDim2.new(1,-8,0,24), UDim2.new(0,4,0,4),
        Color3.fromRGB(40,30,60), TEXT_SECONDARY, 12)
    detailClose.MouseButton1Click:Connect(function()
        -- ocultarDetalle se define después; se llama via upvalue
        state.activeDetail = nil
        state.barGen       = state.barGen + 1
        TweenService:Create(ui.detailPanel, TW_DETAIL, {
            Position = UDim2.new(0, DETAIL_X_HIDDEN, 0, detailTop)
        }):Play()
    end)

    -- ScrollingFrame interno para el contenido del detalle
    local detailScroll = Instance.new("ScrollingFrame")
    detailScroll.Name               = "DetailScroll"
    detailScroll.Size               = UDim2.new(1,0,1,-30)
    detailScroll.Position           = UDim2.new(0,0,0,30)
    detailScroll.BackgroundTransparency = 1
    detailScroll.BorderSizePixel    = 0
    detailScroll.ScrollBarThickness = 3
    detailScroll.ScrollBarImageColor3 = BORDER_COLOR
    detailScroll.CanvasSize         = UDim2.new(0,0,0,0)
    detailScroll.Parent             = detail
    ui.detailScroll = detailScroll

    -- ── OVERLAY DE CELEBRACIÓN (encima del ScreenGui) ─────────────────────────

    local overlay = Instance.new("Frame")
    overlay.Name               = "CelebOverlay"
    overlay.Size               = UDim2.new(1,0,1,0)
    overlay.BackgroundColor3   = Color3.fromRGB(0,0,0)
    overlay.BackgroundTransparency = 1
    overlay.BorderSizePixel    = 0
    overlay.ZIndex             = 20
    overlay.Visible            = false
    overlay.Parent             = sg
    ui.celebOverlay = overlay
end

--------------------------------------------------------------------------------
-- HELPERS INTERNOS DE UI
--------------------------------------------------------------------------------

-- Actualiza la apariencia del tab activo/inactivo con tween
local function actualizarTabVisual(tabId)
    for id, btn in pairs(ui.tabButtons) do
        if id == tabId then
            TweenService:Create(btn, TW_FADE, {
                BackgroundColor3 = Color3.fromRGB(200,160,50),
                TextColor3       = Color3.fromRGB(15,10,25),
            }):Play()
        else
            TweenService:Create(btn, TW_FADE, {
                BackgroundColor3 = Color3.fromRGB(40,30,60),
                TextColor3       = TEXT_PRIMARY,
            }):Play()
        end
    end
end

-- Destruye todos los cards del grid y resetea el registro
local function limpiarGrid()
    for _, child in ipairs(ui.gridScroll:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end
    state.cardFrames           = {}
    ui.gridScroll.CanvasPosition = Vector2.new(0,0)
end

-- Cierra el panel de detalle con animación (helper interno)
local function ocultarDetalle()
    state.activeDetail = nil
    state.barGen       = state.barGen + 1
    local detailTop = HEADER_H + TAB_H + 2
    TweenService:Create(ui.detailPanel, TW_DETAIL, {
        Position = UDim2.new(0, DETAIL_X_HIDDEN, 0, detailTop)
    }):Play()
end

--------------------------------------------------------------------------------
-- CatalogueGUI.RenderCard(dragon, catalogueData)
-- Crea y retorna un Frame con el card del dragón según su estado.
-- El llamador es responsable de asignar .LayoutOrder y .Parent.
--------------------------------------------------------------------------------

function CatalogueGUI.RenderCard(dragon, cd)
    local estado = obtenerEstado(dragon, cd)

    local card = Instance.new("Frame")
    card.Name             = "Card_" .. dragon.id
    card.Size             = UDim2.new(0, CELL_W, 0, CELL_H)
    card.BorderSizePixel  = 0
    card.ClipsDescendants = true

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0,8)
    corner.Parent       = card

    -- ── CONSEGUIDO: color completo, borde de rareza ───────────────────────────
    if estado == "conseguido" then
        card.BackgroundColor3 = Color3.fromRGB(28,20,50)

        local stroke = Instance.new("UIStroke")
        stroke.Color     = RARITY_COLORS[dragon.rarity] or TEXT_PRIMARY
        stroke.Thickness = 2
        stroke.Parent    = card

        -- Zona de imagen coloreada por elemento
        local imgZone = mkFrame(card, "ImgZone",
            UDim2.new(1,-8,0,70), UDim2.new(0,4,0,4),
            ELEMENT_COLORS[dragon.element] or Color3.fromRGB(60,40,80), nil, 6)
        imgZone.BackgroundTransparency = 0.55

        local emojiLbl = Instance.new("TextLabel")
        emojiLbl.Size               = UDim2.new(1,0,1,0)
        emojiLbl.BackgroundTransparency = 1
        emojiLbl.Text               = "🐉"
        emojiLbl.TextSize           = 32
        emojiLbl.Font               = Enum.Font.GothamBold
        emojiLbl.TextXAlignment     = Enum.TextXAlignment.Center
        emojiLbl.TextColor3         = Color3.fromRGB(255,255,255)
        emojiLbl.Parent             = imgZone

        -- Nombre del dragón (visible)
        mkLabel(card, "NameLbl", dragon.name,
            UDim2.new(1,-6,0,28), UDim2.new(0,3,0,77),
            10, TEXT_PRIMARY, Enum.Font.GothamBold, Enum.TextXAlignment.Center)

        -- Rareza con color propio
        mkLabel(card, "RarityLbl",
            dragon.rarity:sub(1,1):upper() .. dragon.rarity:sub(2),
            UDim2.new(1,-6,0,14), UDim2.new(0,3,0,106),
            10, RARITY_COLORS[dragon.rarity] or TEXT_PRIMARY,
            Enum.Font.GothamMedium, Enum.TextXAlignment.Center)

        -- Oro por segundo
        mkLabel(card, "GpsLbl",
            string.format("%.1f/seg", dragon.goldPerSecond),
            UDim2.new(1,-6,0,14), UDim2.new(0,3,0,122),
            10, Color3.fromRGB(255,200,50), Enum.Font.Gotham, Enum.TextXAlignment.Center)

        -- Badge de cantidad en inventario (si > 0)
        if cd and cd.inventory then
            local count = cd.inventory[dragon.id] or 0
            if count > 0 then
                local badge = mkFrame(card, "CountBadge",
                    UDim2.new(0,22,0,18), UDim2.new(1,-24,0,4),
                    Color3.fromRGB(200,160,50), nil, 4)
                mkLabel(badge, "Lbl", tostring(count),
                    UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
                    11, Color3.fromRGB(15,10,25), Enum.Font.GothamBold,
                    Enum.TextXAlignment.Center)
            end
        end

    -- ── NO CONSEGUIDO: escala de grises, nombre oculto ────────────────────────
    elseif estado == "no_conseguido" then
        card.BackgroundColor3 = Color3.fromRGB(18,14,28)

        local stroke = Instance.new("UIStroke")
        stroke.Color     = Color3.fromRGB(60,55,70)
        stroke.Thickness = 1.5
        stroke.Parent    = card

        local imgZone = mkFrame(card, "ImgZone",
            UDim2.new(1,-8,0,70), UDim2.new(0,4,0,4),
            Color3.fromRGB(30,28,40), nil, 6)

        local qLbl = Instance.new("TextLabel")
        qLbl.Size               = UDim2.new(1,0,1,0)
        qLbl.BackgroundTransparency = 1
        qLbl.Text               = "❓"
        qLbl.TextSize           = 32
        qLbl.Font               = Enum.Font.GothamBold
        qLbl.TextXAlignment     = Enum.TextXAlignment.Center
        qLbl.TextColor3         = Color3.fromRGB(90,80,110)
        qLbl.Parent             = imgZone

        -- Nombre ocultado; elemento sí visible como pista
        mkLabel(card, "NameLbl", "???",
            UDim2.new(1,-6,0,28), UDim2.new(0,3,0,77),
            12, Color3.fromRGB(70,60,95), Enum.Font.GothamBold,
            Enum.TextXAlignment.Center)

        local elemEmoji = ELEMENT_EMOJI[dragon.element] or "?"
        mkLabel(card, "ElemLbl",
            elemEmoji .. " " .. dragon.element:sub(1,1):upper() .. dragon.element:sub(2),
            UDim2.new(1,-6,0,14), UDim2.new(0,3,0,108),
            10, Color3.fromRGB(80,70,105), Enum.Font.Gotham,
            Enum.TextXAlignment.Center)

        -- Rareza sí visible (segunda pista)
        mkLabel(card, "RarityLbl",
            dragon.rarity:sub(1,1):upper() .. dragon.rarity:sub(2),
            UDim2.new(1,-6,0,14), UDim2.new(0,3,0,124),
            10, Color3.fromRGB(65,60,85), Enum.Font.Gotham,
            Enum.TextXAlignment.Center)

    -- ── BLOQUEADO POR NIVEL: completamente oscuro ─────────────────────────────
    else
        card.BackgroundColor3 = Color3.fromRGB(12,10,18)

        local stroke = Instance.new("UIStroke")
        stroke.Color     = Color3.fromRGB(40,36,55)
        stroke.Thickness = 1.5
        stroke.Parent    = card

        local imgZone = mkFrame(card, "ImgZone",
            UDim2.new(1,-8,0,70), UDim2.new(0,4,0,4),
            Color3.fromRGB(20,18,28), nil, 6)

        local lockLbl = Instance.new("TextLabel")
        lockLbl.Size               = UDim2.new(1,0,1,0)
        lockLbl.BackgroundTransparency = 1
        lockLbl.Text               = "🔒"
        lockLbl.TextSize           = 32
        lockLbl.Font               = Enum.Font.GothamBold
        lockLbl.TextXAlignment     = Enum.TextXAlignment.Center
        lockLbl.TextColor3         = Color3.fromRGB(55,50,72)
        lockLbl.Parent             = imgZone

        mkLabel(card, "NameLbl", "???",
            UDim2.new(1,-6,0,28), UDim2.new(0,3,0,77),
            12, Color3.fromRGB(45,40,62), Enum.Font.GothamBold,
            Enum.TextXAlignment.Center)

        local minLv = dragon.breedingOnly and BREEDING_MIN_LEVEL
                      or (RARITY_MIN_LEVEL[dragon.rarity] or 1)
        mkLabel(card, "LevelLbl", "Nivel " .. minLv .. "\nrequerido",
            UDim2.new(1,-6,0,32), UDim2.new(0,3,0,106),
            10, Color3.fromRGB(120,100,55), Enum.Font.Gotham,
            Enum.TextXAlignment.Center)
    end

    -- Botón invisible para capturar clics (solo dragones conseguidos o descubiertos)
    if estado ~= "bloqueado" then
        local clickBtn = Instance.new("TextButton")
        clickBtn.Size               = UDim2.new(1,0,1,0)
        clickBtn.BackgroundTransparency = 1
        clickBtn.Text               = ""
        clickBtn.BorderSizePixel    = 0
        clickBtn.ZIndex             = card.ZIndex + 1
        clickBtn.Parent             = card

        local did         = dragon.id
        local estadoLocal = estado
        clickBtn.MouseButton1Click:Connect(function()
            if estadoLocal == "conseguido" then
                CatalogueGUI.ShowDetail(did)
            end
            -- No_conseguido no abre el detalle a propósito (preserva la incógnita)
        end)
    end

    return card
end

--------------------------------------------------------------------------------
-- CatalogueGUI.RenderGrid(filter)
-- Renderiza el grid filtrado por elemento o tipo.
-- Orden: conseguidos → no_conseguidos → bloqueados; dentro de cada grupo por rareza.
--------------------------------------------------------------------------------

function CatalogueGUI.RenderGrid(filter)
    filter = filter or "todos"
    state.activeFilter = filter
    limpiarGrid()

    -- Recopilar dragones que aplican al filtro activo
    local lista = {}
    for _, d in ipairs(DragonData.Dragons) do
        local incluir = false
        if filter == "todos" then
            incluir = true
        elseif filter == "breeding" then
            incluir = d.breedingOnly == true
        elseif filter == "eventos" then
            incluir = d.eventOnly == true
        else
            -- Filtro por elemento: excluye breeding y eventos de esa corriente
            incluir = (d.element == filter) and not d.breedingOnly and not d.eventOnly
        end
        if incluir then lista[#lista + 1] = d end
    end

    -- Mostrar mensaje si el tab EVENTOS está vacío (no hay dragones de evento aún)
    if filter == "eventos" and #lista == 0 then
        mkLabel(ui.gridScroll, "EmptyMsg",
            "🎉  No hay dragones de evento disponibles.\nVuelve durante un evento especial.",
            UDim2.new(1,-20,0,60), UDim2.new(0,10,0,20),
            14, TEXT_SECONDARY, Enum.Font.GothamMedium,
            Enum.TextXAlignment.Center)
        return
    end

    -- Clasificar por estado del jugador
    local conseguidos, no_conseguidos, bloqueados = {}, {}, {}
    local cd = state.catalogueData
    for _, d in ipairs(lista) do
        local est = obtenerEstado(d, cd)
        if est == "conseguido" then
            conseguidos[#conseguidos + 1] = d
        elseif est == "bloqueado" then
            bloqueados[#bloqueados + 1] = d
        else
            no_conseguidos[#no_conseguidos + 1] = d
        end
    end

    -- Ordenar cada grupo por rareza (common primero)
    local function byRarity(a, b)
        return (RARITY_ORDER[a.rarity] or 0) < (RARITY_ORDER[b.rarity] or 0)
    end
    table.sort(conseguidos,    byRarity)
    table.sort(no_conseguidos, byRarity)
    table.sort(bloqueados,     byRarity)

    -- Unir grupos: conseguidos → no conseguidos → bloqueados
    local ordenFinal = {}
    for _, d in ipairs(conseguidos)    do ordenFinal[#ordenFinal+1] = d end
    for _, d in ipairs(no_conseguidos) do ordenFinal[#ordenFinal+1] = d end
    for _, d in ipairs(bloqueados)     do ordenFinal[#ordenFinal+1] = d end

    -- Instanciar cards
    for i, d in ipairs(ordenFinal) do
        local card      = CatalogueGUI.RenderCard(d, cd)
        card.LayoutOrder = i
        card.Parent      = ui.gridScroll
        state.cardFrames[d.id] = card
    end

    -- Actualizar stats del header
    CatalogueGUI.GetCompletionStats()
end

--------------------------------------------------------------------------------
-- CatalogueGUI.ShowDetail(dragonId)
-- Abre el panel lateral con todos los detalles del dragón.
-- Las barras de probabilidad se animan al abrir.
-- Solo accesible para dragones en estado "conseguido".
--------------------------------------------------------------------------------

function CatalogueGUI.ShowDetail(dragonId)
    local dragon = DragonData.GetDragonById(dragonId)
    if not dragon then return end
    if obtenerEstado(dragon, state.catalogueData) ~= "conseguido" then return end

    -- Nueva generación: cancela tweens de barras del panel anterior
    state.barGen       = state.barGen + 1
    local gen          = state.barGen
    state.activeDetail = dragonId

    -- Limpiar contenido previo del scroll
    local scroll = ui.detailScroll
    for _, child in ipairs(scroll:GetChildren()) do child:Destroy() end

    -- Padding interior y layout vertical
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft   = UDim.new(0,10)
    pad.PaddingRight  = UDim.new(0,10)
    pad.PaddingTop    = UDim.new(0,6)
    pad.PaddingBottom = UDim.new(0,10)
    pad.Parent        = scroll

    local layout = Instance.new("UIListLayout")
    layout.SortOrder           = Enum.SortOrder.LayoutOrder
    layout.FillDirection       = Enum.FillDirection.Vertical
    layout.Padding             = UDim.new(0,4)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Parent              = scroll

    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scroll.CanvasSize = UDim2.new(0,0,0, layout.AbsoluteContentSize.Y + 20)
    end)

    -- ── Zona de imagen grande ────────────────────────────────────────────────
    local imgZone = mkFrame(scroll, "ImgZone",
        UDim2.new(1,0,0,78), UDim2.new(0,0,0,0),
        ELEMENT_COLORS[dragon.element] or Color3.fromRGB(60,40,80), nil, 8)
    imgZone.BackgroundTransparency = 0.50
    imgZone.LayoutOrder = 1

    local bigEmoji = Instance.new("TextLabel")
    bigEmoji.Size               = UDim2.new(0,56,1,0)
    bigEmoji.Position           = UDim2.new(0,8,0,0)
    bigEmoji.BackgroundTransparency = 1
    bigEmoji.Text               = "🐉"
    bigEmoji.TextSize           = 44
    bigEmoji.Font               = Enum.Font.GothamBold
    bigEmoji.TextXAlignment     = Enum.TextXAlignment.Center
    bigEmoji.TextColor3         = Color3.fromRGB(255,255,255)
    bigEmoji.Parent             = imgZone

    mkLabel(imgZone, "NameLbl", dragon.name,
        UDim2.new(1,-68,0,34), UDim2.new(0,66,0,8),
        15, Color3.fromRGB(255,255,255), Enum.Font.GothamBold)
    mkLabel(imgZone, "StarsLbl", rarityStars(dragon.rarity),
        UDim2.new(1,-68,0,20), UDim2.new(0,66,0,46),
        13, RARITY_COLORS[dragon.rarity] or TEXT_PRIMARY, Enum.Font.Gotham)

    -- ── Filas de stats ────────────────────────────────────────────────────────
    local function addStat(labelTxt, valor, order)
        local row = Instance.new("Frame")
        row.Size               = UDim2.new(1,0,0,19)
        row.BackgroundTransparency = 1
        row.BorderSizePixel    = 0
        row.LayoutOrder        = order
        row.Parent             = scroll

        mkLabel(row, "Lbl", labelTxt,
            UDim2.new(0.52,0,1,0), UDim2.new(0,0,0,0),
            12, TEXT_SECONDARY, Enum.Font.Gotham)
        mkLabel(row, "Val", valor,
            UDim2.new(0.48,0,1,0), UDim2.new(0.52,0,0,0),
            12, TEXT_PRIMARY, Enum.Font.GothamMedium)
    end

    local cd       = state.catalogueData
    local elemEmoji = ELEMENT_EMOJI[dragon.element] or ""
    addStat("Elemento:",  elemEmoji .. " " .. dragon.element:sub(1,1):upper() .. dragon.element:sub(2), 2)
    addStat("Rareza:",    dragon.rarity:sub(1,1):upper() .. dragon.rarity:sub(2), 3)
    addStat("Oro/seg:",   string.format("%.1f", dragon.goldPerSecond), 4)
    addStat("Timer huevo:", formatTime(dragon.eggTimerSeconds), 5)
    addStat("Incubación:", formatTime(dragon.incubationSeconds), 6)

    local invCount = (cd and cd.inventory and cd.inventory[dragonId]) or 0
    addStat("En inventario:", tostring(invCount) .. "x", 7)

    -- Detectar en qué nido(s) está colocado
    local nests = {}
    if cd and cd.nestDragons then
        for idx, nid in pairs(cd.nestDragons) do
            if nid == dragonId then nests[#nests+1] = "Nido " .. idx end
        end
    end
    addStat("En nido:", #nests > 0 and table.concat(nests, ", ") or "—", 8)

    -- Separador
    local function addSep(order)
        local s = Instance.new("Frame")
        s.Size               = UDim2.new(1,0,0,1)
        s.BackgroundColor3   = BORDER_COLOR
        s.BackgroundTransparency = 0.70
        s.BorderSizePixel    = 0
        s.LayoutOrder        = order
        s.Parent             = scroll
    end
    addSep(9)

    -- ── Probabilidades de eclosión ────────────────────────────────────────────
    mkLabel(scroll, "ProbTitle", "Probabilidades de huevo:",
        UDim2.new(1,0,0,17), UDim2.new(0,0,0,0),
        12, BORDER_COLOR, Enum.Font.GothamBold
    ).LayoutOrder = 10

    local chances = RARITIES.HatchChances[dragon.rarity]
    for bi, r in ipairs(RARITIES.Order) do
        local pct    = (chances and chances[r]) or 0
        local pctStr = string.format("%.1f%%", pct * 100)

        local barRow = Instance.new("Frame")
        barRow.Name               = "BarRow_" .. r
        barRow.Size               = UDim2.new(1,0,0,17)
        barRow.BackgroundTransparency = 1
        barRow.BorderSizePixel    = 0
        barRow.LayoutOrder        = 10 + bi
        barRow.Parent             = scroll

        -- Etiqueta de rareza (izquierda)
        local rLbl = Instance.new("TextLabel")
        rLbl.Size               = UDim2.new(0,66,1,0)
        rLbl.BackgroundTransparency = 1
        rLbl.Text               = r:sub(1,1):upper() .. r:sub(2)
        rLbl.TextSize           = 11
        rLbl.Font               = Enum.Font.Gotham
        rLbl.TextColor3         = RARITY_COLORS[r] or TEXT_PRIMARY
        rLbl.TextXAlignment     = Enum.TextXAlignment.Left
        rLbl.Parent             = barRow

        -- Fondo de la barra
        local barBg = Instance.new("Frame")
        barBg.Name             = "BarBg"
        barBg.Size             = UDim2.new(1,-116,0,8)
        barBg.Position         = UDim2.new(0,68,0.5,-4)
        barBg.BackgroundColor3 = Color3.fromRGB(40,32,58)
        barBg.BorderSizePixel  = 0
        barBg.Parent           = barRow
        local bgC = Instance.new("UICorner")
        bgC.CornerRadius = UDim.new(0,3)
        bgC.Parent       = barBg

        -- Fill (empieza en 0; se anima con tarea asíncrona)
        local barFill = Instance.new("Frame")
        barFill.Name             = "Fill"
        barFill.Size             = UDim2.new(0,0,1,0)
        barFill.BackgroundColor3 = RARITY_COLORS[r] or TEXT_PRIMARY
        barFill.BorderSizePixel  = 0
        barFill.Parent           = barBg
        local fillC = Instance.new("UICorner")
        fillC.CornerRadius = UDim.new(0,3)
        fillC.Parent       = barFill

        -- Porcentaje (derecha)
        local pLbl = Instance.new("TextLabel")
        pLbl.Size             = UDim2.new(0,44,1,0)
        pLbl.Position         = UDim2.new(1,-46,0,0)
        pLbl.BackgroundTransparency = 1
        pLbl.Text             = pctStr
        pLbl.TextSize         = 11
        pLbl.Font             = Enum.Font.GothamMedium
        pLbl.TextColor3       = TEXT_SECONDARY
        pLbl.TextXAlignment   = Enum.TextXAlignment.Right
        pLbl.Parent           = barRow

        -- Animar fill con ligero delay escalonado para efecto cascada
        local capturedPct = pct
        local capturedGen = gen
        task.spawn(function()
            task.wait(0.06 + (bi - 1) * 0.04)
            if state.barGen ~= capturedGen then return end
            TweenService:Create(barFill, TW_BAR, {
                Size = UDim2.new(capturedPct, 0, 1, 0)
            }):Play()
        end)
    end

    -- ── Info especial: Breeding ───────────────────────────────────────────────
    local extraOrder = 17

    if dragon.breedingOnly and dragon.breedingCombo then
        addSep(extraOrder) ; extraOrder = extraOrder + 1

        mkLabel(scroll, "BreedTitle", "🥚 Obtención: Breeding",
            UDim2.new(1,0,0,17), UDim2.new(0,0,0,0),
            12, Color3.fromRGB(255,200,80), Enum.Font.GothamBold
        ).LayoutOrder = extraOrder ; extraOrder = extraOrder + 1

        local p1 = DragonData.GetDragonById(dragon.breedingCombo[1])
        local p2 = DragonData.GetDragonById(dragon.breedingCombo[2])
        local p1Str = p1 and (p1.name .. " " .. (ELEMENT_EMOJI[p1.element] or ""))
                      or dragon.breedingCombo[1]
        local p2Str = p2 and (p2.name .. " " .. (ELEMENT_EMOJI[p2.element] or ""))
                      or dragon.breedingCombo[2]

        local comboLbl = mkLabel(scroll, "ComboLbl",
            p1Str .. "  ×  " .. p2Str,
            UDim2.new(1,0,0,30), UDim2.new(0,0,0,0),
            11, TEXT_PRIMARY, Enum.Font.Gotham)
        comboLbl.TextWrapped = true
        comboLbl.LayoutOrder = extraOrder ; extraOrder = extraOrder + 1

        local notaLbl = mkLabel(scroll, "RecipeNote",
            "Con receta exacta: probabilidad mayor\nSin receta: probabilidad base reducida",
            UDim2.new(1,0,0,28), UDim2.new(0,0,0,0),
            10, TEXT_SECONDARY, Enum.Font.Gotham)
        notaLbl.TextWrapped = true
        notaLbl.LayoutOrder = extraOrder ; extraOrder = extraOrder + 1

    -- ── Info especial: Evento ─────────────────────────────────────────────────
    elseif dragon.eventOnly then
        addSep(extraOrder) ; extraOrder = extraOrder + 1

        local eventLbl = mkLabel(scroll, "EventLbl",
            "🎉 Solo disponible en evento\n" .. (dragon.eventName or "Evento especial"),
            UDim2.new(1,0,0,30), UDim2.new(0,0,0,0),
            11, Color3.fromRGB(255,200,80), Enum.Font.GothamMedium)
        eventLbl.TextWrapped = true
        eventLbl.LayoutOrder = extraOrder ; extraOrder = extraOrder + 1
    end

    -- ── Descripción ──────────────────────────────────────────────────────────
    if dragon.description then
        addSep(extraOrder) ; extraOrder = extraOrder + 1
        local descLbl = mkLabel(scroll, "DescLbl", dragon.description,
            UDim2.new(1,0,0,46), UDim2.new(0,0,0,0),
            11, TEXT_SECONDARY, Enum.Font.Gotham)
        descLbl.TextWrapped  = true
        descLbl.LayoutOrder  = extraOrder
    end

    -- Deslizar panel de detalle hacia adentro
    local detailTop = HEADER_H + TAB_H + 2
    TweenService:Create(ui.detailPanel, TW_DETAIL, {
        Position = UDim2.new(0, DETAIL_X_VISIBLE, 0, detailTop)
    }):Play()
end

--------------------------------------------------------------------------------
-- CatalogueGUI.RenderCollectionBonuses()
-- Construye el panel inferior con una tarjeta por cada colección de elemento.
-- Colecciones completadas tienen borde dorado pulsante.
--------------------------------------------------------------------------------

function CatalogueGUI.RenderCollectionBonuses()
    -- Limpiar cards anteriores
    for _, child in ipairs(ui.bonusScroll:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end

    local cd              = state.catalogueData
    local bonusActivosCount = 0

    for i, col in ipairs(COLLECTION_BONUSES) do
        local conseguidos, total = contarProgresionElemento(col.element, cd)
        local completado = total > 0 and conseguidos >= total
        if completado then bonusActivosCount = bonusActivosCount + 1 end

        -- Tarjeta del bonus
        local card = Instance.new("Frame")
        card.Name             = "BonusCard_" .. col.element
        card.Size             = UDim2.new(0, 138, 1, -4)
        card.BackgroundColor3 = completado
            and Color3.fromRGB(38,28,8) or Color3.fromRGB(24,17,40)
        card.BorderSizePixel  = 0
        card.LayoutOrder      = i
        card.Parent           = ui.bonusScroll

        local cardCorner = Instance.new("UICorner")
        cardCorner.CornerRadius = UDim.new(0,6)
        cardCorner.Parent       = card

        local cardStroke = Instance.new("UIStroke")
        cardStroke.Color     = completado and BORDER_COLOR or Color3.fromRGB(55,45,75)
        cardStroke.Thickness = completado and 2 or 1
        cardStroke.Parent    = card

        -- Nombre del elemento
        mkLabel(card, "ElemLbl",
            col.emoji .. " " .. col.element:sub(1,1):upper() .. col.element:sub(2),
            UDim2.new(1,-8,0,20), UDim2.new(0,4,0,4),
            13, completado and BORDER_COLOR or TEXT_PRIMARY,
            Enum.Font.GothamBold, Enum.TextXAlignment.Center)

        -- Progreso X/total
        mkLabel(card, "ProgLbl", tostring(conseguidos) .. "/" .. tostring(total),
            UDim2.new(1,-8,0,14), UDim2.new(0,4,0,26),
            12, TEXT_SECONDARY, Enum.Font.Gotham, Enum.TextXAlignment.Center)

        -- Barra de progreso
        local barBg = Instance.new("Frame")
        barBg.Size             = UDim2.new(1,-12,0,6)
        barBg.Position         = UDim2.new(0,6,0,42)
        barBg.BackgroundColor3 = Color3.fromRGB(40,32,58)
        barBg.BorderSizePixel  = 0
        barBg.Parent           = card
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0,3)
        bc.Parent       = barBg

        local pct = total > 0 and (conseguidos / total) or 0
        local barFill = Instance.new("Frame")
        barFill.Size             = UDim2.new(pct, 0, 1, 0)
        barFill.BackgroundColor3 = completado and BORDER_COLOR or col.color
        barFill.BorderSizePixel  = 0
        barFill.Parent           = barBg
        local fc = Instance.new("UICorner")
        fc.CornerRadius = UDim.new(0,3)
        fc.Parent       = barFill

        -- Texto del bonus
        local bonusLbl = mkLabel(card, "BonusLbl",
            completado and ("✅ " .. col.bonus) or col.bonus,
            UDim2.new(1,-8,0,24), UDim2.new(0,4,0,51),
            10, completado and Color3.fromRGB(100,220,100) or TEXT_SECONDARY,
            Enum.Font.Gotham, Enum.TextXAlignment.Center)
        bonusLbl.TextWrapped = true

        -- Pulso dorado para colecciones completadas
        if completado then
            task.spawn(function()
                while card and card.Parent do
                    TweenService:Create(cardStroke, TweenInfo.new(0.8, Enum.EasingStyle.Sine), {
                        Thickness = 2.8
                    }):Play()
                    task.wait(0.85)
                    TweenService:Create(cardStroke, TweenInfo.new(0.8, Enum.EasingStyle.Sine), {
                        Thickness = 1.5
                    }):Play()
                    task.wait(0.85)
                end
            end)
        end
    end

    -- Actualizar label de bonuses activos en el header
    if ui.bonusCountLabel then
        ui.bonusCountLabel.Text = "Bonuses: " .. bonusActivosCount
            .. (bonusActivosCount == 1 and " activo" or " activos")
        ui.bonusCountLabel.TextColor3 = bonusActivosCount > 0
            and Color3.fromRGB(100,220,100) or TEXT_SECONDARY
    end
end

--------------------------------------------------------------------------------
-- CatalogueGUI.GetCompletionStats()
-- Calcula el porcentaje de completitud y actualiza el header.
-- Retorna { total, conseguidos, pct, bonusActivos }
--------------------------------------------------------------------------------

function CatalogueGUI.GetCompletionStats()
    local cd        = state.catalogueData
    local total     = #DragonData.Dragons
    local conseguidos = 0

    for _, d in ipairs(DragonData.Dragons) do
        if cd and cd.discovered and cd.discovered[d.id] then
            conseguidos = conseguidos + 1
        end
    end

    local pct = total > 0 and math.floor(conseguidos / total * 100) or 0

    if ui.progressLabel then
        ui.progressLabel.Text = string.format(
            "Conseguidos: %d/%d  (%d%%)", conseguidos, total, pct)
    end

    local bonusActivos = 0
    for _, col in ipairs(COLLECTION_BONUSES) do
        local got, tot = contarProgresionElemento(col.element, cd)
        if got >= tot and tot > 0 then bonusActivos = bonusActivos + 1 end
    end

    return { total=total, conseguidos=conseguidos, pct=pct, bonusActivos=bonusActivos }
end

--------------------------------------------------------------------------------
-- CatalogueGUI.UpdateProgress(dragonId)
-- Llamado cuando el jugador consigue un dragón nuevo (desde RemoteEvents).
-- Actualiza el card en el grid con animación de desbloqueo y revisa colecciones.
--------------------------------------------------------------------------------

function CatalogueGUI.UpdateProgress(dragonId)
    local dragon = DragonData.GetDragonById(dragonId)
    if not dragon then return end

    -- Actualizar datos locales inmediatamente para que los renders reflejen el cambio
    if state.catalogueData then
        state.catalogueData.discovered          = state.catalogueData.discovered or {}
        state.catalogueData.discovered[dragonId] = true
        state.catalogueData.inventory            = state.catalogueData.inventory or {}
        state.catalogueData.inventory[dragonId]  =
            (state.catalogueData.inventory[dragonId] or 0) + 1
    end

    -- Animación en el card si está visible en el filtro actual
    local cardFrame = state.cardFrames[dragonId]
    if cardFrame then
        -- Flash dorado → color de rareza → render nuevo
        TweenService:Create(cardFrame, TW_FLASH, {
            BackgroundColor3 = Color3.fromRGB(255, 220, 60)
        }):Play()
        task.delay(0.18, function()
            if not cardFrame.Parent then return end
            TweenService:Create(cardFrame, TW_BOUNCE, {
                BackgroundColor3 = Color3.fromRGB(28, 20, 50)
            }):Play()
        end)
        -- Reemplazar card por uno con estado actualizado
        task.delay(0.30, function()
            if not cardFrame.Parent then return end
            local order = cardFrame.LayoutOrder
            cardFrame:Destroy()
            local nuevoCard      = CatalogueGUI.RenderCard(dragon, state.catalogueData)
            nuevoCard.LayoutOrder = order
            nuevoCard.Parent      = ui.gridScroll
            state.cardFrames[dragonId] = nuevoCard
        end)
    else
        -- Card no está en el filtro activo; si correspondería, re-renderizar
        local fa = state.activeFilter
        local aplica = fa == "todos"
            or (fa == "breeding" and dragon.breedingOnly)
            or (fa == "eventos"  and dragon.eventOnly)
            or (fa == dragon.element and not dragon.breedingOnly and not dragon.eventOnly)
        if aplica and state.isOpen then
            CatalogueGUI.RenderGrid(fa)
        end
    end

    CatalogueGUI.GetCompletionStats()

    -- Verificar si se completó una colección de elemento
    if not dragon.breedingOnly and not dragon.eventOnly then
        local got, tot = contarProgresionElemento(dragon.element, state.catalogueData)
        if got >= tot and tot > 0 then
            CatalogueGUI.RenderCollectionBonuses()
            if not state.celebrando then
                CatalogueGUI.ShowCollectionComplete(dragon.element)
            end
            return
        end
    end

    CatalogueGUI.RenderCollectionBonuses()
end

--------------------------------------------------------------------------------
-- CatalogueGUI.ShowCollectionComplete(element)
-- Animación especial al completar una colección de elemento.
-- Muestra banner grande + confeti del color del elemento.
-- Se cierra al hacer clic o automáticamente tras 4 segundos.
--------------------------------------------------------------------------------

function CatalogueGUI.ShowCollectionComplete(element)
    if state.celebrando then return end
    state.celebrando = true

    local elemColor = ELEMENT_COLORS[element] or BORDER_COLOR
    local elemEmoji = ELEMENT_EMOJI[element] or "🐉"
    local elemName  = element:sub(1,1):upper() .. element:sub(2)

    local overlay = ui.celebOverlay
    overlay.Visible = true
    overlay.BackgroundTransparency = 1

    -- Oscurecer fondo progresivamente
    TweenService:Create(overlay, TW_SLIDE, { BackgroundTransparency = 0.45 }):Play()

    -- Banner central que aparece con escala desde cero
    local banner = mkFrame(overlay, "CelebBanner",
        UDim2.new(0,1,0,1),
        UDim2.new(0.5,0,0.5,0),
        Color3.fromRGB(15,10,25), elemColor, 16)
    banner.ZIndex = 21
    banner.ClipsDescendants = false

    -- Stroke extra para visibilidad del banner
    local bannerStroke = Instance.new("UIStroke")
    bannerStroke.Color     = elemColor
    bannerStroke.Thickness = 3
    bannerStroke.Parent    = banner

    -- Animación de entrada: escala desde punto central
    TweenService:Create(banner, TW_OPEN, {
        Size     = UDim2.new(0,480,0,188),
        Position = UDim2.new(0.5,-240,0.5,-94),
    }):Play()

    -- Contenido del banner
    mkLabel(banner, "TitleLbl",
        elemEmoji .. "  COLECCIÓN COMPLETADA  " .. elemEmoji,
        UDim2.new(1,-20,0,36), UDim2.new(0,10,0,12),
        20, BORDER_COLOR, Enum.Font.GothamBold, Enum.TextXAlignment.Center)

    mkLabel(banner, "ElemLbl",
        "Colección " .. elemName .. " al completo",
        UDim2.new(1,-20,0,28), UDim2.new(0,10,0,52),
        17, elemColor, Enum.Font.GothamBold, Enum.TextXAlignment.Center)

    mkLabel(banner, "BonusLbl",
        "✅  +15% oro para todos los dragones " .. elemName,
        UDim2.new(1,-20,0,24), UDim2.new(0,10,0,90),
        13, Color3.fromRGB(100,220,100), Enum.Font.GothamMedium,
        Enum.TextXAlignment.Center)

    mkLabel(banner, "TapLbl", "Toca para continuar",
        UDim2.new(1,-20,0,18), UDim2.new(0,10,0,154),
        12, TEXT_SECONDARY, Enum.Font.Gotham, Enum.TextXAlignment.Center)

    -- Confeti: N frames pequeños que caen desde arriba con delays aleatorios
    local NUM_CONFETI = 20
    for i = 1, NUM_CONFETI do
        local confeti = Instance.new("Frame")
        confeti.Name               = "Confeti_" .. i
        confeti.Size               = UDim2.new(0, math.random(6,14), 0, math.random(6,14))
        confeti.Position           = UDim2.new(math.random(0,100)/100, 0, -0.04, 0)
        confeti.BackgroundColor3   = elemColor
        confeti.BackgroundTransparency = math.random(0,4) / 10
        confeti.BorderSizePixel    = 0
        confeti.ZIndex             = 21
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0, math.random(0,5))
        cc.Parent       = confeti
        confeti.Parent  = overlay

        -- Animación de caída con velocidad y destino aleatorios
        local startX    = confeti.Position.X.Scale
        local duracion  = 1.0 + math.random(0,80)/100
        local targetY   = 0.82 + math.random(0,16)/100
        task.spawn(function()
            task.wait(math.random(0,50)/100)
            TweenService:Create(confeti,
                TweenInfo.new(duracion, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                { Position = UDim2.new(startX, 0, targetY, 0) }
            ):Play()
        end)
    end

    -- Lógica de cierre
    local dismissed = false
    local function cerrar()
        if dismissed then return end
        dismissed = true
        TweenService:Create(overlay, TW_FADE, { BackgroundTransparency = 1 }):Play()
        TweenService:Create(banner, TW_CLOSE,
            { BackgroundTransparency = 1, Size = UDim2.new(0,1,0,1),
              Position = UDim2.new(0.5,0,0.5,0) }):Play()
        task.delay(0.25, function()
            for _, child in ipairs(overlay:GetChildren()) do child:Destroy() end
            overlay.Visible  = false
            state.celebrando = false
        end)
    end

    -- Click en cualquier punto del overlay cierra la celebración
    local clickBtn = Instance.new("TextButton")
    clickBtn.Size               = UDim2.new(1,0,1,0)
    clickBtn.BackgroundTransparency = 1
    clickBtn.Text               = ""
    clickBtn.BorderSizePixel    = 0
    clickBtn.ZIndex             = 22
    clickBtn.Parent             = overlay
    clickBtn.MouseButton1Click:Connect(cerrar)

    -- Auto-cierre tras 4 segundos si el jugador no interactúa
    task.delay(4.0, cerrar)
end

--------------------------------------------------------------------------------
-- CatalogueGUI.FilterByElement(element)
-- Cambia el tab activo con transición suave: fade out → re-render → fade in.
--------------------------------------------------------------------------------

function CatalogueGUI.FilterByElement(element)
    if state.activeFilter == element then return end

    -- Cerrar detalle si estaba abierto
    if state.activeDetail then ocultarDetalle() end

    -- Fade out de los cards actuales
    for _, card in ipairs(ui.gridScroll:GetChildren()) do
        if card:IsA("Frame") then
            TweenService:Create(card, TW_FADE, { BackgroundTransparency = 1 }):Play()
        end
    end

    task.delay(0.20, function()
        actualizarTabVisual(element)
        CatalogueGUI.RenderGrid(element)

        -- Fade in de los nuevos cards
        for _, card in ipairs(ui.gridScroll:GetChildren()) do
            if card:IsA("Frame") then
                local targetTransp = card.BackgroundTransparency
                card.BackgroundTransparency = 1
                TweenService:Create(card, TW_FADE,
                    { BackgroundTransparency = targetTransp }):Play()
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- CatalogueGUI.Open()
-- Abre el catálogo con animación de escala. Solicita datos al servidor.
-- Muestra el tab TODOS por defecto.
--------------------------------------------------------------------------------

function CatalogueGUI.Open()
    if state.isOpen then return end
    state.isOpen = true

    ui.screenGui.Enabled = true

    -- Animación de apertura: escala desde 1×1 hasta tamaño completo
    ui.mainFrame.Size     = UDim2.new(0,1,0,1)
    ui.mainFrame.Position = UDim2.new(0.5,0,0.5,0)
    TweenService:Create(ui.mainFrame, TW_OPEN, {
        Size     = UDim2.new(0, WIN_W, 0, WIN_H),
        Position = UDim2.new(0.5, -WIN_W/2, 0.5, -WIN_H/2),
    }):Play()

    -- Solicitar datos del catálogo al servidor
    local Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local ok, datos = pcall(function()
        return Remotes:WaitForChild("RequestGetCatalogueData"):InvokeServer()
    end)

    if ok and type(datos) == "table" then
        state.catalogueData = datos
    else
        -- Fallback: catálogo visible pero sin progreso del jugador
        state.catalogueData = {
            discovered  = {},
            inventory   = {},
            nestDragons = {},
            playerLevel = 1,
        }
        warn("[CatalogueGUI] No se pudo obtener datos del servidor:", datos)
    end

    -- Renderizar estado inicial
    actualizarTabVisual("todos")
    CatalogueGUI.RenderGrid("todos")
    CatalogueGUI.RenderCollectionBonuses()
end

--------------------------------------------------------------------------------
-- CatalogueGUI.Close()
-- Cierra el catálogo con animación de escala inversa.
--------------------------------------------------------------------------------

function CatalogueGUI.Close()
    if not state.isOpen then return end
    state.isOpen = false

    if state.activeDetail then ocultarDetalle() end

    TweenService:Create(ui.mainFrame, TW_CLOSE, {
        Size     = UDim2.new(0,1,0,1),
        Position = UDim2.new(0.5,0,0.5,0),
    }):Play()

    task.delay(0.22, function()
        if not state.isOpen then
            ui.screenGui.Enabled = false
        end
    end)
end

--------------------------------------------------------------------------------
-- INIT
-- Construye el UI y conecta los RemoteEvents.
-- Se ejecuta una sola vez al cargar el LocalScript.
--------------------------------------------------------------------------------

local function Init()
    crearVentana()

    local Remotes = ReplicatedStorage:WaitForChild("Remotes")

    -- EggIncubated: el jugador incubó un huevo y obtuvo un dragón
    Remotes:WaitForChild("EggIncubated").OnClientEvent:Connect(function(data)
        if not (data and data.dragonId) then return end
        local esNuevo = not (
            state.catalogueData
            and state.catalogueData.discovered
            and state.catalogueData.discovered[data.dragonId]
        )
        if esNuevo then
            CatalogueGUI.UpdateProgress(data.dragonId)
        elseif state.isOpen then
            -- Solo actualiza inventario y re-renderiza si el catálogo está abierto
            if state.catalogueData then
                state.catalogueData.inventory = state.catalogueData.inventory or {}
                state.catalogueData.inventory[data.dragonId] =
                    (state.catalogueData.inventory[data.dragonId] or 0) + 1
            end
            CatalogueGUI.RenderGrid(state.activeFilter)
        end
    end)

    -- BreedingCompleted: resultado de cría en el pen
    Remotes:WaitForChild("BreedingCompleted").OnClientEvent:Connect(function(data)
        if not (data and data.dragonId) then return end
        local esNuevo = not (
            state.catalogueData
            and state.catalogueData.discovered
            and state.catalogueData.discovered[data.dragonId]
        )
        if esNuevo then
            CatalogueGUI.UpdateProgress(data.dragonId)
        elseif state.isOpen then
            if state.catalogueData then
                state.catalogueData.inventory = state.catalogueData.inventory or {}
                state.catalogueData.inventory[data.dragonId] =
                    (state.catalogueData.inventory[data.dragonId] or 0) + 1
            end
            CatalogueGUI.RenderGrid(state.activeFilter)
        end
    end)

    -- PurchaseCompleted: compra en la tienda (solo si es un dragón)
    Remotes:WaitForChild("PurchaseCompleted").OnClientEvent:Connect(function(data)
        if not (data and data.itemType == "dragon" and data.itemId) then return end
        local esNuevo = not (
            state.catalogueData
            and state.catalogueData.discovered
            and state.catalogueData.discovered[data.itemId]
        )
        if esNuevo then
            CatalogueGUI.UpdateProgress(data.itemId)
        elseif state.isOpen then
            if state.catalogueData then
                state.catalogueData.inventory = state.catalogueData.inventory or {}
                state.catalogueData.inventory[data.itemId] =
                    (state.catalogueData.inventory[data.itemId] or 0) + 1
            end
            CatalogueGUI.RenderGrid(state.activeFilter)
        end
    end)
end

Init()

-- Atajo de teclado: C abre / cierra el catálogo
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.C then
        if state.isOpen then
            CatalogueGUI.Close()
        else
            CatalogueGUI.Open()
        end
    end
end)

return CatalogueGUI
