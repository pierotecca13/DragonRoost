--------------------------------------------------------------------------------
-- ShopGUI.client.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Interfaz de las dos tiendas independientes:
--
--   Tab "Tienda Rápida"  — countdown 3 min, 6 cards de dragones/huevos,
--                          borde por rareza, stock visible, botón comprar.
--
--   Tab "Tienda Especial" — countdown 10 min, 4 cards con ícono por tipo
--                           (mejora, boost, clima, receta, cosmético).
--                           Al comprar evento climático → selector de 6 eventos.
--
-- Se abre/cierra desde la NavBar del HUD (BindableEvent "NavBarClicked").
-- Escucha RemoteEvents "TiendaRapidaActualizada" y "TiendaEspecialActualizada".
--------------------------------------------------------------------------------

local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Paleta de colores
--------------------------------------------------------------------------------

local PANEL_BG     = Color3.fromRGB( 15,  10,  25)
local BORDER_COLOR = Color3.fromRGB(200, 160,  50)
local TEXT_PRIMARY = Color3.fromRGB(255, 240, 200)
local TEXT_HEADER  = Color3.fromRGB(255, 215,  80)
local TEXT_DIM     = Color3.fromRGB(160, 148, 120)

local RARITY_COLORS = {
    comun         = Color3.fromRGB(180, 180, 180),
    poco_comun    = Color3.fromRGB( 80, 200,  80),
    raro          = Color3.fromRGB( 80, 130, 220),
    epico         = Color3.fromRGB(160,  80, 220),
    legendario    = Color3.fromRGB(255, 165,   0),
    mitico        = Color3.fromRGB(255,  50,  50),
}

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

local TIPO_ICONOS = {
    mejora_nido  = "🔨",
    boost        = "⚡",
    boost_dragon = "⚡",
    evento_clima = "🌦️",
    receta       = "📜",
    cosmetico    = "🎨",
    dragon       = "🐉",
    huevo        = "🥚",
}

local TWEEN_FAST  = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_SLIDE = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

--------------------------------------------------------------------------------
-- Estado
--------------------------------------------------------------------------------

local state = {
    visible         = false,
    tabActivo       = "rapida",   -- "rapida" | "especial"
    slotsRapida     = {},
    slotsEspecial   = {},
    proximaRapida   = 0,
    proximaEspecial = 0,
}

--------------------------------------------------------------------------------
-- Referencias UI
--------------------------------------------------------------------------------

local ui = {
    screenGui      = nil,
    ventana        = nil,
    tabRapidaBtn   = nil,
    tabEspBtn      = nil,
    panelRapida    = nil,
    panelEspecial  = nil,
    countdownRapida  = nil,
    countdownEsp     = nil,
    cardsRapida        = {},  -- { frame, btnComprar }
    cardsEsp           = {},
}

--------------------------------------------------------------------------------
-- Helpers de creación
--------------------------------------------------------------------------------

local function crearPanel(nombre, tamano, posicion, padre, transp)
    local fr = Instance.new("Frame")
    fr.Name                   = nombre
    fr.Size                   = tamano
    fr.Position               = posicion
    fr.BackgroundColor3       = PANEL_BG
    fr.BackgroundTransparency = transp or 0.10
    fr.BorderSizePixel        = 0
    fr.Parent                 = padre
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = fr
    local s = Instance.new("UIStroke"); s.Color = BORDER_COLOR; s.Thickness = 1.5; s.Parent = fr
    return fr
end

local function crearLabel(texto, tamano, posicion, padre, fuente, color, alinX)
    local lbl = Instance.new("TextLabel")
    lbl.Name                   = "Lbl"
    lbl.Text                   = texto
    lbl.Size                   = tamano
    lbl.Position               = posicion
    lbl.BackgroundTransparency = 1
    lbl.Font                   = fuente or Enum.Font.Gotham
    lbl.TextSize               = 13
    lbl.TextColor3             = color or TEXT_PRIMARY
    lbl.TextXAlignment         = alinX or Enum.TextXAlignment.Left
    lbl.TextTruncate           = Enum.TextTruncate.AtEnd
    lbl.Parent                 = padre
    return lbl
end

local function crearBoton(texto, tamano, posicion, padre, colorBg)
    local btn = Instance.new("TextButton")
    local bg  = colorBg or Color3.fromRGB(130, 90, 15)
    btn.Name             = "Btn"
    btn.Text             = texto
    btn.Size             = tamano
    btn.Position         = posicion
    btn.BackgroundColor3 = bg
    btn.BorderSizePixel  = 0
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 13
    btn.TextColor3       = Color3.fromRGB(255, 245, 200)
    btn.AutoButtonColor  = false
    btn.Parent           = padre
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = btn
    local hover = Color3.fromRGB(180, 130, 25)
    -- Guardar el color base en un atributo para que actualizarCard pueda cambiarlo
    btn:SetAttribute("BaseColor", bg)
    btn.MouseEnter:Connect(function()
        if not btn.Active then return end
        TweenService:Create(btn, TWEEN_FAST, { BackgroundColor3 = hover }):Play()
    end)
    btn.MouseLeave:Connect(function()
        -- Restaurar al color base actual (puede haber cambiado a rojo si está agotado)
        TweenService:Create(btn, TWEEN_FAST,
            { BackgroundColor3 = btn:GetAttribute("BaseColor") or bg }):Play()
    end)
    return btn
end

-- Formatea número con sufijos K/M/B
local function fmt(n)
    n = math.floor(n or 0)
    if n >= 1_000_000_000 then return ("%.1fB"):format(n / 1e9) end
    if n >= 1_000_000     then return ("%.1fM"):format(n / 1e6) end
    if n >= 1_000         then return ("%.1fK"):format(n / 1e3) end
    return tostring(n)
end

-- Formatea segundos en MM:SS
local function fmtTime(s)
    s = math.max(0, math.floor(s or 0))
    return ("%02d:%02d"):format(math.floor(s / 60), s % 60)
end

local function capitalize(str)
    if not str or str == "" then return "?" end
    return str:sub(1,1):upper() .. str:sub(2):gsub("_", " ")
end

--------------------------------------------------------------------------------
-- Popup de detalle (abre al hacer clic en una card)
--------------------------------------------------------------------------------

-- Muestra ventana de detalle encima de las cards.
-- slot puede ser de tipo "dragon" o "huevo".
local detallePopup = nil  -- referencia al popup activo

local function cerrarDetalle()
    if detallePopup then detallePopup:Destroy(); detallePopup = nil end
end

local function abrirDetalle(slot, ventanaRef)
    cerrarDetalle()
    if not slot then return end

    -- Panel semi-transparente de fondo que cierra al clic
    local overlay = Instance.new("TextButton")
    overlay.Name                   = "DetalleOverlay"
    overlay.Size                   = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundColor3       = Color3.fromRGB(0,0,0)
    overlay.BackgroundTransparency = 0.55
    overlay.Text                   = ""
    overlay.BorderSizePixel        = 0
    overlay.ZIndex                 = 20
    overlay.Parent                 = ventanaRef
    overlay.Activated:Connect(cerrarDetalle)

    -- Panel de contenido
    local panel = crearPanel("DetallePanel",
        UDim2.new(0.85, 0, 0, 0),
        UDim2.new(0.075, 0, 0.08, 0),
        overlay)
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.ZIndex        = 21
    panel.BackgroundColor3 = Color3.fromRGB(18, 12, 35)
    panel.BackgroundTransparency = 0.05

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding   = UDim.new(0, 6)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Parent = panel

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 10); pad.PaddingBottom = UDim.new(0, 14)
    pad.PaddingLeft = UDim.new(0, 12); pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = panel

    local function addLbl(txt, size, color, bold)
        local l = Instance.new("TextLabel")
        l.Size                   = UDim2.new(1, 0, 0, size)
        l.BackgroundTransparency = 1
        l.Text                   = txt
        l.Font                   = bold and Enum.Font.GothamBold or Enum.Font.Gotham
        l.TextSize               = size
        l.TextColor3             = color or TEXT_PRIMARY
        l.TextXAlignment         = Enum.TextXAlignment.Center
        l.TextWrapped            = true
        l.LayoutOrder            = 99
        l.ZIndex                 = 22
        l.Parent                 = panel
        return l
    end

    if slot.tipo == "dragon" then
        local d = DragonData.GetDragonById and DragonData.GetDragonById(slot.dragonId)
        local nombre = slot.nombre or (d and d.name) or "Dragón"
        local rareza = slot.rareza or (d and d.rarity) or "comun"
        local elem   = slot.elemento or (d and d.element) or "?"
        local gps    = d and d.goldPerSecond or 0

        addLbl("🐉 " .. nombre, 16, RARITY_COLORS[rareza] or TEXT_HEADER, true)
        addLbl("Rareza: " .. capitalize(rareza), 13, RARITY_COLORS[rareza] or TEXT_DIM)
        addLbl("Elemento: " .. capitalize(elem), 13, TEXT_PRIMARY)
        addLbl(("Producción: %.1f oro/seg"):format(gps), 13, Color3.fromRGB(255, 215, 100))
        if d and d.description then
            addLbl(d.description, 11, TEXT_DIM)
        end
        if d and d.soloCria then
            addLbl("⚠ Solo se obtiene por crianza", 11, Color3.fromRGB(220, 180, 80))
        end

    elseif slot.tipo == "huevo" then
        addLbl("🥚 Huevo Misterioso", 16, TEXT_HEADER, true)
        addLbl("Al eclosionar obtiene una rareza aleatoria:", 12, TEXT_DIM)

        local orden = Constants.RARIDADES and Constants.RARIDADES.Orden
            or { "comun","poco_comun","raro","epico","legendario","mitico" }
        local chances = Constants.RARIDADES and Constants.RARIDADES.ChancesEclosion
            and Constants.RARIDADES.ChancesEclosion["comun"] or {}

        for _, rar in ipairs(orden) do
            local prob = chances[rar] or 0
            local pct  = ("%5.1f%%"):format(prob * 100)
            local color = RARITY_COLORS[rar] or TEXT_PRIMARY
            addLbl(pct .. "  " .. capitalize(rar), 12, color)
        end
    end

    local cerrarBtn = crearBoton("Cerrar",
        UDim2.new(0.6, 0, 0, 30),
        UDim2.new(0.2, 0, 0, 0),
        panel, Color3.fromRGB(90, 30, 30))
    cerrarBtn.LayoutOrder = 100
    cerrarBtn.ZIndex = 22
    cerrarBtn.Activated:Connect(cerrarDetalle)

    detallePopup = overlay
end

--------------------------------------------------------------------------------
-- Construcción de cards
--------------------------------------------------------------------------------

-- Card de Tienda Rápida (dragons/huevos)
local function actualizarCardRapida(i, slot)
    local card = ui.cardsRapida[i]
    if not card then return end

    if not slot then
        card.frame.Visible = false
        return
    end

    card.frame.Visible = true

    -- Borde de rareza
    local borderColor = slot.rareza and RARITY_COLORS[slot.rareza] or BORDER_COLOR
    card.stroke.Color = borderColor

    -- Ícono y nombre
    local icono = TIPO_ICONOS[slot.tipo] or "?"
    card.iconoLbl.Text  = icono
    card.nombreLbl.Text = slot.nombre or "?"
    -- Buscar elemento del dragón en DragonData para mostrar emoji + nombre
    local elemEmoji  = ""
    local elemNombre = ""
    if slot.tipo == "dragon" or slot.tipo == "huevo" then
        for _, d in ipairs(DragonData.Dragons) do
            if d.name == slot.nombre then
                elemEmoji  = ELEMENT_EMOJI[d.element] or ""
                elemNombre = capitalize(d.element or "")
                break
            end
        end
    end
    if elemEmoji ~= "" then
        card.rarLbl.Text = elemEmoji .. " " .. elemNombre .. "  ·  " .. (slot.rareza and capitalize(slot.rareza) or "Misterioso")
    else
        card.rarLbl.Text = slot.rareza and capitalize(slot.rareza) or "Misterioso"
    end
    card.rarLbl.TextColor3 = slot.rareza and RARITY_COLORS[slot.rareza] or TEXT_DIM
    card.precioLbl.Text = fmt(slot.precio or 0) .. " " .. (slot.moneda == "gemas" and "💎" or "💰")

    -- Stock
    local stockDisp = slot.stockDisponible or slot.stock or 0
    card.stockLbl.Text = ("Stock: %d"):format(stockDisp)
    card.stockLbl.TextColor3 = stockDisp > 0 and TEXT_PRIMARY or Color3.fromRGB(200, 80, 80)

    -- Botón comprar
    local agotado = stockDisp <= 0
    local colorRapida = agotado and Color3.fromRGB(160, 35, 35) or Color3.fromRGB(100, 70, 12)
    card.btnComprar.Text                = agotado and "Agotado" or "Comprar"
    card.btnComprar.BackgroundColor3    = colorRapida
    card.btnComprar:SetAttribute("BaseColor", colorRapida)
    card.btnComprar.Active              = not agotado
    card.slotIndex                      = i
end

-- Card de Tienda Especial
local function actualizarCardEspecial(i, slot)
    local card = ui.cardsEsp[i]
    if not card then return end

    if not slot then
        card.frame.Visible = false
        return
    end

    card.frame.Visible = true

    local icono = TIPO_ICONOS[slot.tipo] or "❓"
    card.iconoLbl.Text  = icono
    card.nombreLbl.Text = slot.nombre or "?"
    card.descLbl.Text   = slot.descripcion or ""
    card.precioLbl.Text = fmt(slot.precio or 0) .. " 💎"

    local stockDisp = slot.stockDisponible or slot.stock or 0
    local agotado   = stockDisp <= 0
    local colorEsp = agotado and Color3.fromRGB(160, 35, 35) or Color3.fromRGB(70, 40, 120)
    card.btnComprar.Text             = agotado and "Agotado" or "Comprar"
    card.btnComprar.BackgroundColor3 = colorEsp
    card.btnComprar:SetAttribute("BaseColor", colorEsp)
    card.btnComprar.Active           = not agotado
    card.slotIndex                   = i
    card.slotData                    = slot
end

--------------------------------------------------------------------------------
-- Selector de evento climático
--------------------------------------------------------------------------------

local EVENTOS_CLIMA = {
    { id = "sol_dorado",         nombre = "☀️ Sol Dorado" },
    { id = "lluvia_magica",      nombre = "🌧️ Lluvia Mágica" },
    { id = "erupcion_volcanica", nombre = "🌋 Erupción Volcánica" },
    { id = "tormenta_electrica", nombre = "⚡ Tormenta Eléctrica" },
    { id = "noche_eterna",       nombre = "🌑 Noche Eterna" },
    { id = "rift_dimensional",   nombre = "🌀 Rift Dimensional" },
}

local function mostrarSelectorEvento(parent, onSelect)
    -- Panel modal pequeño encima
    local selector = crearPanel("SelectorEvento",
        UDim2.new(0, 280, 0, 0),
        UDim2.new(0.5, -140, 0.5, -120),
        parent)
    selector.AutomaticSize = Enum.AutomaticSize.Y
    selector.ZIndex = 20

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding   = UDim.new(0, 4)
    layout.Parent    = selector

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 8); pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = selector

    local titulo = crearLabel("Elige qué evento activar:",
        UDim2.new(1, 0, 0, 22), UDim2.new(0,0,0,0),
        selector, Enum.Font.GothamBold, TEXT_HEADER, Enum.TextXAlignment.Center)
    titulo.LayoutOrder = 0

    for idx, ev in ipairs(EVENTOS_CLIMA) do
        local btn = crearBoton(ev.nombre,
            UDim2.new(1, 0, 0, 36),
            UDim2.new(0, 0, 0, 0),
            selector, Color3.fromRGB(40, 25, 70))
        btn.LayoutOrder = idx
        btn.ZIndex      = 21
        local evId = ev.id
        btn.Activated:Connect(function()
            selector:Destroy()
            onSelect(evId)
        end)
    end

    -- Botón cancelar
    local cancelBtn = crearBoton("Cancelar",
        UDim2.new(1, 0, 0, 30),
        UDim2.new(0,0,0,0),
        selector, Color3.fromRGB(80, 30, 30))
    cancelBtn.LayoutOrder = 99
    cancelBtn.ZIndex      = 21
    cancelBtn.Activated:Connect(function()
        selector:Destroy()
    end)
end

--------------------------------------------------------------------------------
-- Construcción de la ventana principal
--------------------------------------------------------------------------------

local function construirUI()
    local sg = Instance.new("ScreenGui")
    sg.Name           = "ShopGUI"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Enabled        = false
    sg.Parent         = playerGui
    ui.screenGui      = sg

    -- Fondo semi-transparente (modal overlay)
    local overlay = Instance.new("TextButton")
    overlay.Name                   = "Overlay"
    overlay.Size                   = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 0.50
    overlay.BorderSizePixel        = 0
    overlay.Text                   = ""
    overlay.ZIndex                 = 1
    overlay.Parent                 = sg
    overlay.Activated:Connect(function()
        ShopGUI.Cerrar()
    end)

    -- Ventana principal — centrada en pantalla, máx 560×520 px
    local ventana = crearPanel("Ventana",
        UDim2.new(0.94, 0, 0, 520),
        UDim2.new(0.03, 0, 0, 0),   -- position corregida abajo
        sg)
    ventana.AnchorPoint      = Vector2.new(0.5, 0.5)
    ventana.Position         = UDim2.new(0.5, 0, 0.5, 0)
    ventana.ClipsDescendants = true
    ventana.ZIndex = 5
    ui.ventana = ventana

    local sizeConstraint = Instance.new("UISizeConstraint")
    sizeConstraint.MaxSize = Vector2.new(560, 520)
    sizeConstraint.Parent  = ventana

    -- Título y botón cerrar
    local titulo = crearLabel("🏪 TIENDA",
        UDim2.new(1, -50, 0, 36), UDim2.new(0, 0, 0, 0),
        ventana, Enum.Font.GothamBold, TEXT_HEADER, Enum.TextXAlignment.Center)
    titulo.TextSize = 20

    local cerrarBtn = crearBoton("✕",
        UDim2.new(0, 36, 0, 36), UDim2.new(1, -40, 0, 4),
        ventana, Color3.fromRGB(90, 30, 30))
    cerrarBtn.TextSize = 18
    cerrarBtn.Activated:Connect(function() ShopGUI.Cerrar() end)

    -- Tabs
    local TAB_Y = 44
    ui.tabRapidaBtn = crearBoton("⚡ Tienda Rápida (3 min)",
        UDim2.new(0.5, -4, 0, 34), UDim2.new(0, 4, 0, TAB_Y),
        ventana, Color3.fromRGB(100, 70, 12))
    ui.tabEspBtn = crearBoton("✨ Tienda Especial (10 min)",
        UDim2.new(0.5, -4, 0, 34), UDim2.new(0.5, 0, 0, TAB_Y),
        ventana, Color3.fromRGB(40, 25, 70))

    ui.tabRapidaBtn.Activated:Connect(function() ShopGUI.SetTab("rapida") end)
    ui.tabEspBtn.Activated:Connect(function()    ShopGUI.SetTab("especial") end)

    -- Countdown de tienda rápida
    ui.countdownRapida = crearLabel("Próxima rotación: --:--",
        UDim2.new(0.5, -4, 0, 18), UDim2.new(0, 4, 0, TAB_Y + 38),
        ventana, Enum.Font.Gotham, TEXT_DIM, Enum.TextXAlignment.Center)
    ui.countdownRapida.TextSize = 11

    -- Countdown de tienda especial
    ui.countdownEsp = crearLabel("Próxima rotación: --:--",
        UDim2.new(0.5, -4, 0, 18), UDim2.new(0.5, 0, 0, TAB_Y + 38),
        ventana, Enum.Font.Gotham, TEXT_DIM, Enum.TextXAlignment.Center)
    ui.countdownEsp.TextSize = 11

    -- Panel de Tienda Rápida (ScrollingFrame — 6 cards en cuadrícula 3x2)
    local pRapida = Instance.new("ScrollingFrame")
    pRapida.Name                   = "PanelRapida"
    pRapida.Size                   = UDim2.new(1, -16, 1, -(TAB_Y + 62))
    pRapida.Position               = UDim2.new(0, 8, 0, TAB_Y + 60)
    pRapida.BackgroundTransparency = 1
    pRapida.BorderSizePixel        = 0
    pRapida.ScrollBarThickness     = 5
    pRapida.ScrollBarImageColor3   = BORDER_COLOR
    pRapida.CanvasSize             = UDim2.new(0, 0, 0, 0)  -- se ajusta abajo
    pRapida.AutomaticCanvasSize    = Enum.AutomaticSize.Y
    pRapida.ScrollingDirection     = Enum.ScrollingDirection.Y
    pRapida.Parent                 = ventana
    ui.panelRapida = pRapida

    local Remotes = ReplicatedStorage:WaitForChild("Remotes", 12)
    local ComprarRapidaFunc = Remotes and Remotes:FindFirstChild("RequestComprarTiendaRapida")

    -- UIGridLayout para las 6 cards — 2 columnas, auto-scroll vertical
    local gridRapida = Instance.new("UIGridLayout")
    gridRapida.CellSize     = UDim2.new(0.5, -6, 0, 215)
    gridRapida.CellPadding  = UDim2.new(0, 8, 0, 8)
    gridRapida.SortOrder    = Enum.SortOrder.LayoutOrder
    gridRapida.FillDirection = Enum.FillDirection.Horizontal
    gridRapida.Parent       = pRapida

    -- Crear 6 cards para Tienda Rápida (2×3)
    local CARD_GAP = 8
    for idx = 1, 6 do
        local cardFr = crearPanel("CardRapida_" .. idx,
            UDim2.new(0, 1, 0, 1),   -- tamaño ignorado; UIGridLayout lo gestiona
            UDim2.new(0, 0, 0, 0),
            pRapida)
        cardFr.LayoutOrder = idx
        cardFr.Visible = false

        local stroke = cardFr:FindFirstChildOfClass("UIStroke")

        local iconoLbl = crearLabel("🐉",
            UDim2.new(1, 0, 0, 50), UDim2.new(0, 0, 0, 8),
            cardFr, Enum.Font.GothamBold, TEXT_PRIMARY, Enum.TextXAlignment.Center)
        iconoLbl.TextSize = 36

        local nombreLbl = crearLabel("",
            UDim2.new(1, -8, 0, 30), UDim2.new(0, 4, 0, 62),
            cardFr, Enum.Font.GothamBold, TEXT_PRIMARY, Enum.TextXAlignment.Center)
        nombreLbl.TextWrapped = true
        nombreLbl.TextSize    = 12

        local rarLbl = crearLabel("",
            UDim2.new(1, 0, 0, 18), UDim2.new(0, 0, 0, 96),
            cardFr, Enum.Font.Gotham, TEXT_DIM, Enum.TextXAlignment.Center)
        rarLbl.TextSize = 11

        local precioLbl = crearLabel("",
            UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 0, 116),
            cardFr, Enum.Font.GothamBold, TEXT_HEADER, Enum.TextXAlignment.Center)
        precioLbl.TextSize = 14

        local stockLbl = crearLabel("Stock: 0",
            UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 140),
            cardFr, Enum.Font.Gotham, TEXT_DIM, Enum.TextXAlignment.Center)
        stockLbl.TextSize = 11

        local btnComprar = crearBoton("Comprar",
            UDim2.new(1, -16, 0, 34), UDim2.new(0, 8, 0, 160),
            cardFr, Color3.fromRGB(100, 70, 12))
        btnComprar.TextSize = 13

        local cardObj = {
            frame      = cardFr,
            stroke     = stroke,
            iconoLbl   = iconoLbl,
            nombreLbl  = nombreLbl,
            rarLbl     = rarLbl,
            precioLbl  = precioLbl,
            stockLbl   = stockLbl,
            btnComprar = btnComprar,
            slotIndex  = idx,
        }
        ui.cardsRapida[idx] = cardObj

        local capIdx = idx

        -- Clic en la card (fuera del botón) → muestra detalle
        local cardBtn = Instance.new("TextButton")
        cardBtn.Size                   = UDim2.new(1, 0, 1, -44)  -- todo menos zona del botón
        cardBtn.Position               = UDim2.new(0, 0, 0, 0)
        cardBtn.BackgroundTransparency = 1
        cardBtn.Text                   = ""
        cardBtn.ZIndex                 = 2
        cardBtn.Parent                 = cardFr
        cardBtn.Activated:Connect(function()
            abrirDetalle(state.slotsRapida[capIdx], ventana)
        end)

        btnComprar.Activated:Connect(function()
            if not btnComprar.Active then return end
            if not ComprarRapidaFunc then return end
            btnComprar.Active = false
            local ok, res = ComprarRapidaFunc:InvokeServer(ui.cardsRapida[capIdx].slotIndex)
            if ok then
                ShopGUI.ShowMensaje(type(res) == "table" and res.mensaje or "¡Compra exitosa!", "success")
                local slot = state.slotsRapida[capIdx]
                if slot then
                    slot.stockDisponible = math.max(0, (slot.stockDisponible or 1) - 1)
                    actualizarCardRapida(capIdx, slot)
                end
            else
                ShopGUI.ShowMensaje(tostring(res or "Error al comprar."), "error")
                btnComprar.Active = true
            end
        end)
    end

    -- Panel de Tienda Especial (ScrollingFrame — 4 cards en cuadrícula 2×2)
    local pEsp = Instance.new("ScrollingFrame")
    pEsp.Name                   = "PanelEspecial"
    pEsp.Size                   = UDim2.new(1, -16, 1, -(TAB_Y + 62))
    pEsp.Position               = UDim2.new(0, 8, 0, TAB_Y + 60)
    pEsp.BackgroundTransparency = 1
    pEsp.BorderSizePixel        = 0
    pEsp.ScrollBarThickness     = 5
    pEsp.ScrollBarImageColor3   = BORDER_COLOR
    pEsp.CanvasSize             = UDim2.new(0, 0, 0, 0)
    pEsp.AutomaticCanvasSize    = Enum.AutomaticSize.Y
    pEsp.ScrollingDirection     = Enum.ScrollingDirection.Y
    pEsp.Visible                = false
    pEsp.Parent                 = ventana
    ui.panelEspecial = pEsp

    local ComprarEspFunc        = Remotes and Remotes:FindFirstChild("RequestComprarTiendaEspecial")
    local ActivarEventoFunc     = Remotes and Remotes:FindFirstChild("RequestActivarEvento")

    -- pEsp usa UIListLayout para poder tener secciones apiladas verticalmente
    local listEsp = Instance.new("UIListLayout")
    listEsp.SortOrder  = Enum.SortOrder.LayoutOrder
    listEsp.Padding    = UDim.new(0, 6)
    listEsp.HorizontalAlignment = Enum.HorizontalAlignment.Center
    listEsp.Parent     = pEsp

    -- Sub-contenedor de las 4 cards con su UIGridLayout propio
    local cardsContainer = Instance.new("Frame")
    cardsContainer.Name                   = "CardsContainer"
    cardsContainer.Size                   = UDim2.new(1, 0, 0, 416)   -- 2 filas × 200 + 8 gap + 8 pad
    cardsContainer.BackgroundTransparency = 1
    cardsContainer.BorderSizePixel        = 0
    cardsContainer.LayoutOrder            = 1
    cardsContainer.Parent                 = pEsp

    local gridEsp = Instance.new("UIGridLayout")
    gridEsp.CellSize      = UDim2.new(0.5, -6, 0, 200)
    gridEsp.CellPadding   = UDim2.new(0, 8, 0, 8)
    gridEsp.SortOrder     = Enum.SortOrder.LayoutOrder
    gridEsp.FillDirection = Enum.FillDirection.Horizontal
    gridEsp.Parent        = cardsContainer

    for idx = 1, 4 do
        local cardFr = crearPanel("CardEsp_" .. idx,
            UDim2.new(0, 1, 0, 1),
            UDim2.new(0, 0, 0, 0),
            cardsContainer)
        cardFr.LayoutOrder = idx
        cardFr.Visible = false

        local stroke = cardFr:FindFirstChildOfClass("UIStroke")
        stroke.Color = Color3.fromRGB(120, 80, 200)

        local iconoLbl = crearLabel("❓",
            UDim2.new(1, 0, 0, 44), UDim2.new(0, 0, 0, 8),
            cardFr, Enum.Font.GothamBold, TEXT_HEADER, Enum.TextXAlignment.Center)
        iconoLbl.TextSize = 32

        local nombreLbl = crearLabel("",
            UDim2.new(1, -8, 0, 24), UDim2.new(0, 4, 0, 56),
            cardFr, Enum.Font.GothamBold, TEXT_PRIMARY, Enum.TextXAlignment.Center)
        nombreLbl.TextWrapped = true
        nombreLbl.TextSize    = 12

        local descLbl = crearLabel("",
            UDim2.new(1, -8, 0, 44), UDim2.new(0, 4, 0, 83),
            cardFr, Enum.Font.Gotham, TEXT_DIM, Enum.TextXAlignment.Left)
        descLbl.TextWrapped = true
        descLbl.TextSize    = 10

        local precioLbl = crearLabel("",
            UDim2.new(1, 0, 0, 20), UDim2.new(0, 0, 0, 130),
            cardFr, Enum.Font.GothamBold, Color3.fromRGB(160, 200, 255),
            Enum.TextXAlignment.Center)
        precioLbl.TextSize = 14

        local btnComprar = crearBoton("Comprar",
            UDim2.new(1, -16, 0, 30), UDim2.new(0, 8, 0, 155),
            cardFr, Color3.fromRGB(70, 40, 120))
        btnComprar.TextSize = 13

        local cardObj = {
            frame      = cardFr,
            stroke     = stroke,
            iconoLbl   = iconoLbl,
            nombreLbl  = nombreLbl,
            descLbl    = descLbl,
            precioLbl  = precioLbl,
            btnComprar = btnComprar,
            slotIndex  = idx,
            slotData   = nil,
        }
        ui.cardsEsp[idx] = cardObj

        local capIdx = idx

        -- Clic en la card (fuera del botón) → muestra detalle del item especial
        local cardBtnEsp = Instance.new("TextButton")
        cardBtnEsp.Size                   = UDim2.new(1, 0, 1, -40)
        cardBtnEsp.Position               = UDim2.new(0, 0, 0, 0)
        cardBtnEsp.BackgroundTransparency = 1
        cardBtnEsp.Text                   = ""
        cardBtnEsp.ZIndex                 = 2
        cardBtnEsp.Parent                 = cardFr
        cardBtnEsp.Activated:Connect(function()
            local sd = ui.cardsEsp[capIdx] and ui.cardsEsp[capIdx].slotData
            if sd then abrirDetalle(sd, ventana) end
        end)

        btnComprar.Activated:Connect(function()
            if not btnComprar.Active then return end
            if not ComprarEspFunc then return end

            local card = ui.cardsEsp[capIdx]
            local slotData = card.slotData

            -- Si es evento climático, mostrar selector antes de comprar
            if slotData and slotData.tipo == "evento_clima" then
                mostrarSelectorEvento(ventana, function(tipoEvento)
                    if not ActivarEventoFunc then return end
                    -- Primero comprar si no lo tiene
                    btnComprar.Active = false
                    local ok, res = ComprarEspFunc:InvokeServer(card.slotIndex)
                    if ok then
                        -- Luego activar el evento
                        local okAct, resAct = ActivarEventoFunc:InvokeServer(tipoEvento)
                        if okAct then
                            ShopGUI.ShowMensaje(type(resAct) == "table" and resAct.mensaje or "¡Evento activado!", "success")
                        else
                            ShopGUI.ShowMensaje(tostring(resAct or "Error al activar."), "error")
                        end
                        -- Marcar como agotado
                        if slotData then
                            slotData.stockDisponible = 0
                            actualizarCardEspecial(capIdx, slotData)
                        end
                    else
                        ShopGUI.ShowMensaje(tostring(res or "Error al comprar."), "error")
                        btnComprar.Active = true
                    end
                end)
                return
            end

            -- Compra normal
            btnComprar.Active = false
            local ok, res = ComprarEspFunc:InvokeServer(card.slotIndex)
            if ok then
                ShopGUI.ShowMensaje(type(res) == "table" and res.mensaje or "¡Compra exitosa!", "success")
                if slotData then
                    slotData.stockDisponible = 0
                    actualizarCardEspecial(capIdx, slotData)
                end
            else
                ShopGUI.ShowMensaje(tostring(res or "Error al comprar."), "error")
                btnComprar.Active = true
            end
        end)
    end

    -- Label de mensaje de feedback (aparece brevemente)
    local msgLbl = Instance.new("TextLabel")
    msgLbl.Name                   = "MsgLbl"
    msgLbl.Size                   = UDim2.new(0, 400, 0, 32)
    msgLbl.Position               = UDim2.new(0.5, -200, 1, -40)
    msgLbl.BackgroundColor3       = Color3.fromRGB(20, 50, 20)
    msgLbl.BackgroundTransparency = 0.20
    msgLbl.BorderSizePixel        = 0
    msgLbl.Font                   = Enum.Font.GothamBold
    msgLbl.TextSize               = 13
    msgLbl.TextColor3             = Color3.fromRGB(130, 255, 130)
    msgLbl.TextXAlignment         = Enum.TextXAlignment.Center
    msgLbl.Text                   = ""
    msgLbl.Visible                = false
    msgLbl.ZIndex                 = 10
    msgLbl.Parent                 = ventana
    local msgCorner = Instance.new("UICorner"); msgCorner.CornerRadius = UDim.new(0, 6); msgCorner.Parent = msgLbl
    ui.msgLbl = msgLbl
end

--------------------------------------------------------------------------------
-- ShopGUI
--------------------------------------------------------------------------------

ShopGUI = {}

function ShopGUI.SetTab(tab)
    state.tabActivo = tab

    local esRapida = tab == "rapida"
    ui.panelRapida.Visible   = esRapida
    ui.panelEspecial.Visible = not esRapida

    -- Resaltar tab activo
    ui.tabRapidaBtn.BackgroundColor3 = esRapida
        and Color3.fromRGB(150, 105, 20)
        or  Color3.fromRGB(40, 28, 8)
    ui.tabEspBtn.BackgroundColor3 = not esRapida
        and Color3.fromRGB(90, 55, 160)
        or  Color3.fromRGB(30, 18, 55)
end

function ShopGUI.Abrir()
    if state.visible then return end
    state.visible = true
    ui.screenGui.Enabled = true

    -- Animación de entrada: escala desde 0.8 a 1.0
    ui.ventana.Size = UDim2.new(0, 496, 0, 400)
    TweenService:Create(ui.ventana, TWEEN_SLIDE,
        { Size = UDim2.new(0, 620, 0, 500) }):Play()

    ShopGUI.SetTab(state.tabActivo)
end

function ShopGUI.Cerrar()
    if not state.visible then return end
    state.visible = false

    local t = TweenService:Create(ui.ventana, TWEEN_SLIDE,
        { Size = UDim2.new(0, 496, 0, 400) })
    t:Play()
    t.Completed:Connect(function()
        if not state.visible then
            ui.screenGui.Enabled = false
        end
    end)
end

function ShopGUI.ShowMensaje(texto, tipo)
    if not ui.msgLbl then return end
    local colorBg = tipo == "error"
        and Color3.fromRGB(60, 20, 20)
        or  Color3.fromRGB(20, 50, 20)
    local colorTxt = tipo == "error"
        and Color3.fromRGB(255, 130, 130)
        or  Color3.fromRGB(130, 255, 130)
    ui.msgLbl.Text             = texto
    ui.msgLbl.BackgroundColor3 = colorBg
    ui.msgLbl.TextColor3       = colorTxt
    ui.msgLbl.Visible          = true
    task.delay(3, function()
        if ui.msgLbl then ui.msgLbl.Visible = false end
    end)
end

-- Actualiza las cards de Tienda Rápida con el payload del servidor
function ShopGUI.ActualizarTiendaRapida(payload)
    if not payload then return end
    state.proximaRapida = payload.proximaRotacion or 0

    local slotsEnviados = payload.slots or {}

    -- Mapear por slotIndex para colocar en el lugar correcto
    local porSlot = {}
    for _, slot in ipairs(slotsEnviados) do
        local idx = slot.slotIndex or 1
        porSlot[idx] = slot
    end

    for i = 1, 6 do
        local slot = porSlot[i]
        state.slotsRapida[i] = slot
        actualizarCardRapida(i, slot)
    end
end

-- Actualiza las cards de Tienda Especial con el payload del servidor
function ShopGUI.ActualizarTiendaEspecial(payload)
    if not payload then return end
    state.proximaEspecial = payload.proximaRotacion or 0

    local slots = payload.slots or {}
    for i = 1, 4 do
        local slot = slots[i]
        state.slotsEspecial[i] = slot
        actualizarCardEspecial(i, slot)
    end
end

--------------------------------------------------------------------------------
-- Tick loop para countdowns
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(1)
        local ahora = os.time()

        if ui.countdownRapida then
            local secsLeft = math.max(0, state.proximaRapida - ahora)
            ui.countdownRapida.Text = ("Próxima rotación: %s"):format(fmtTime(secsLeft))
            -- Animación de flash al llegar a 0
            if secsLeft == 0 then
                ui.countdownRapida.TextColor3 = Color3.fromRGB(255, 220, 50)
            else
                ui.countdownRapida.TextColor3 = TEXT_DIM
            end
        end

        if ui.countdownEsp then
            local secsLeft = math.max(0, state.proximaEspecial - ahora)
            ui.countdownEsp.Text = ("Próxima rotación: %s"):format(fmtTime(secsLeft))
            ui.countdownEsp.TextColor3 = secsLeft == 0
                and Color3.fromRGB(180, 130, 255)
                or TEXT_DIM
        end
    end
end)

--------------------------------------------------------------------------------
-- Conexión de eventos del servidor
--------------------------------------------------------------------------------

local function conectar(nombre, callback)
    local Remotes = ReplicatedStorage:WaitForChild("Remotes", 12)
    local ev = Remotes and Remotes:WaitForChild(nombre, 12)
    if ev then
        ev.OnClientEvent:Connect(callback)
    else
        warn(("[ShopGUI] RemoteEvent '%s' no encontrado."):format(nombre))
    end
end

conectar("TiendaRapidaActualizada", function(payload)
    ShopGUI.ActualizarTiendaRapida(payload)
    -- Animación de refresh: parpadeo de las cards
    if state.visible and state.tabActivo == "rapida" then
        for _, card in ipairs(ui.cardsRapida) do
            if card.frame.Visible then
                TweenService:Create(card.frame, TweenInfo.new(0.15),
                    { BackgroundColor3 = Color3.fromRGB(30, 20, 50) }):Play()
                task.delay(0.20, function()
                    TweenService:Create(card.frame, TweenInfo.new(0.15),
                        { BackgroundColor3 = PANEL_BG }):Play()
                end)
            end
        end
    end
end)

conectar("TiendaEspecialActualizada", function(payload)
    ShopGUI.ActualizarTiendaEspecial(payload)
    -- Desvanecimiento de cards al rotar
    if state.visible and state.tabActivo == "especial" then
        for _, card in ipairs(ui.cardsEsp) do
            if card.frame.Visible then
                TweenService:Create(card.frame, TweenInfo.new(0.20),
                    { BackgroundTransparency = 0.8 }):Play()
                task.delay(0.25, function()
                    TweenService:Create(card.frame, TweenInfo.new(0.20),
                        { BackgroundTransparency = 0.10 }):Play()
                end)
            end
        end
    end
end)

-- Escuchar NavBar del HUD
task.spawn(function()
    local hudGui = playerGui:WaitForChild("DragonRoostHUD", 30)
    if not hudGui then return end
    local navEvent = hudGui:WaitForChild("NavBarClicked", 10)
    if not navEvent then return end
    navEvent.Event:Connect(function(accion)
        if accion == "AbrirTienda" then
            if state.visible then
                ShopGUI.Cerrar()
            else
                ShopGUI.Abrir()
            end
        end
    end)
end)

--------------------------------------------------------------------------------
-- Inicialización
--------------------------------------------------------------------------------

construirUI()
ShopGUI.SetTab("rapida")

return ShopGUI
