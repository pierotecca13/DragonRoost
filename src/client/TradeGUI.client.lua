--------------------------------------------------------------------------------
-- TradeGUI.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Gestiona toda la interfaz de intercambio entre jugadores.
-- Soporta el flujo completo: proponer → negociar → confirmar → completar.
--
-- ESTADOS DEL TRADE:
--   idle        → Sin intercambio activo
--   proposing   → Construyendo oferta para enviar
--   waiting     → Oferta enviada, esperando respuesta del otro
--   receiving   → Recibimos una propuesta de otro jugador
--   negotiating → Enviando/recibiendo contraoferta
--   confirming  → Ambos aceptaron, resumen final antes de confirmar
--   completed   → Intercambio finalizado con éxito
--   cancelled   → Intercambio rechazado o cancelado
--   expired     → Tiempo expirado sin respuesta
--
-- REMOTEFUNCTIONS:
--   RequestProposeTrade(targetUserId, myOffer)
--   RequestRespondToTrade(tradeId, "accepted"|"rejected"|"counter", counterOffer)
--   RequestConfirmTrade(tradeId)
--   RequestCancelTrade(tradeId)
--   RequestGetInventoryForTrade()  → dragons disponibles (no en nido, no en breeding)
--
-- EVENTOS ESCUCHADOS:
--   TradeProposed     → OnReceiveProposal
--   TradeAccepted     → mostrar confirmación final
--   TradeCancelled    → cerrar con mensaje
--   TradeCompleted    → ShowTradeComplete
--   TradeExpired      → ShowTradeExpired
--   TradeUpdated      → actualizar oferta del otro jugador
--   TradeCounterOffer → ShowCounterOfferReceived
--------------------------------------------------------------------------------

local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RARITIES = Constants.RARITIES

--------------------------------------------------------------------------------
-- Paleta de colores (consistente con todos los demás GUIs)
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
    fire="🔥", water="💧", ice="❄️", thunder="⚡",
    nature="🌿", shadow="🌑", celestial="✨", void="🌀",
}

local PANEL_BG    = Color3.fromRGB( 15,  10,  25)
local PANEL_BG2   = Color3.fromRGB( 22,  16,  38)
local BORDER_GOLD = Color3.fromRGB(200, 160,  50)
local TEXT_PRIMARY = Color3.fromRGB(255, 240, 200)
local TEXT_DIM    = Color3.fromRGB(160, 148, 120)
local TEXT_HEADER = Color3.fromRGB(255, 215,  80)

-- Color por estado del trade para el indicador visual
local STATE_COLORS = {
    idle        = Color3.fromRGB( 80,  80,  80),
    proposing   = Color3.fromRGB( 80,  80, 180),
    waiting     = Color3.fromRGB( 60, 120, 220),  -- azul
    receiving   = Color3.fromRGB( 80, 140, 220),
    negotiating = Color3.fromRGB(200, 160,  30),  -- amarillo
    confirming  = Color3.fromRGB( 30, 160,  80),  -- verde
    completed   = Color3.fromRGB( 30, 200, 100),  -- verde brillante
    cancelled   = Color3.fromRGB(180,  40,  40),  -- rojo
    expired     = Color3.fromRGB(180, 100,  20),  -- naranja
}

local STATE_LABELS = {
    idle        = "Sin intercambio activo",
    proposing   = "Preparando oferta...",
    waiting     = "Esperando respuesta... ⏳",
    receiving   = "¡Nueva propuesta recibida!",
    negotiating = "Negociando contraoferta...",
    confirming  = "Revisando resumen final",
    completed   = "¡Intercambio completado! ✅",
    cancelled   = "Intercambio cancelado ✗",
    expired     = "Intercambio expirado por tiempo",
}

local MAX_ITEMS = 3  -- máximo de items por lado

--------------------------------------------------------------------------------
-- Tweens
--------------------------------------------------------------------------------

local TW_FAST   = TweenInfo.new(0.18, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TW_MED    = TweenInfo.new(0.30, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TW_BOUNCE = TweenInfo.new(0.40, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TW_SLIDE  = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TW_SLOW   = TweenInfo.new(0.55, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TW_BLINK  = TweenInfo.new(0.28, Enum.EasingStyle.Linear,Enum.EasingDirection.Out)
local TW_FLY    = TweenInfo.new(0.50, Enum.EasingStyle.Back,  Enum.EasingDirection.InOut)

--------------------------------------------------------------------------------
-- Dimensiones
--------------------------------------------------------------------------------

local WIN_W    = 630
local WIN_H    = 478
local HEADER_H = 54
local PANELS_Y = HEADER_H + 4
local PANELS_H = 228
local INFO_Y   = PANELS_Y + PANELS_H + 4
local INFO_H   = 42
local STATUS_Y = INFO_Y + INFO_H + 2
local STATUS_H = 34
local FOOTER_Y = STATUS_Y + STATUS_H + 4
local FOOTER_H = 52

-- Paneles de oferta: cada uno ocupa la mitad del ancho menos separador
local PANEL_W  = math.floor((WIN_W - 18) / 2)  -- 306px

-- Cards de item en los paneles de oferta
local CARD_W   = 88
local CARD_H   = 112

-- Panel de inventario (selector de items, sube desde abajo)
local INV_H    = 290

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

local state = {
    isOpen          = false,
    tradeEstado     = "idle",        -- estado actual del flujo
    tradeId         = nil,
    targetUserId    = nil,
    targetName      = "Jugador",
    targetLevel     = 1,
    amInitiator     = false,         -- true si fuimos nosotros quienes propusimos
    myOffer         = {},            -- array de itemData { type, id, dragon }
    theirOffer      = {},            -- array de itemData del otro jugador
    inventoryData   = nil,           -- { [dragonId] = count } para el selector
    countdownGen    = 0,             -- generación del loop de countdown
    cdBlinkActive   = false,         -- true cuando el CD está parpadeando (<30s)
    closePending    = false,         -- confirmación de cierre con trade activo
    history         = {},            -- últimos 10 trades completados
    tradesHoy       = 0,
    tradesLimite    = 3,
}

local ui           = {}
local TradeGUI     = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function fmtNum(n)
    n = math.floor(n or 0)
    if n >= 1_000_000 then return ("%.1fM"):format(n/1_000_000) end
    if n >= 10_000    then return ("%.1fK"):format(n/1_000) end
    local s, r = tostring(n), ""
    for i = 1, #s do
        if i > 1 and (#s-i+1) % 3 == 0 then r = r .. "," end
        r = r .. s:sub(i,i)
    end
    return r
end

local function fmtTime(seg)
    seg = math.max(0, math.floor(seg or 0))
    return ("%02d:%02d"):format(math.floor(seg/60), seg%60)
end

local function rarityStars(r)
    local n = ({ common=1,uncommon=2,rare=3,epic=4,legendary=5,mythic=6 })[r] or 1
    return string.rep("★",n) .. string.rep("☆",6-n)
end

-- Constructores de UI reutilizables
local function mkF(parent, name, size, pos, bg, border, radius)
    local f = Instance.new("Frame")
    f.Name             = name
    f.Size             = size or UDim2.new(0,100,0,30)
    f.Position         = pos  or UDim2.new(0,0,0,0)
    f.BackgroundColor3 = bg   or PANEL_BG
    f.BorderSizePixel  = 0
    f.ClipsDescendants = true
    f.Parent           = parent
    if radius then
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0,radius)
        c.Parent = f
    end
    if border then
        local s = Instance.new("UIStroke")
        s.Color = border ; s.Thickness = 1.5
        s.Parent = f
    end
    return f
end

local function mkL(parent, name, text, size, pos, fs, col, font, xA)
    local l = Instance.new("TextLabel")
    l.Name               = name
    l.Size               = size or UDim2.new(1,0,0,20)
    l.Position           = pos  or UDim2.new(0,0,0,0)
    l.Text               = text or ""
    l.TextSize           = fs   or 13
    l.TextColor3         = col  or TEXT_PRIMARY
    l.Font               = font or Enum.Font.GothamMedium
    l.BackgroundTransparency = 1
    l.TextXAlignment     = xA  or Enum.TextXAlignment.Left
    l.TextWrapped        = true
    l.Parent             = parent
    return l
end

local function mkB(parent, name, text, size, pos, bg, tc, fs)
    local b = Instance.new("TextButton")
    b.Name             = name
    b.Size             = size or UDim2.new(0,120,0,40)
    b.Position         = pos  or UDim2.new(0,0,0,0)
    b.Text             = text or ""
    b.TextSize         = fs   or 14
    b.TextColor3       = tc   or Color3.fromRGB(15,10,25)
    b.BackgroundColor3 = bg   or BORDER_GOLD
    b.Font             = Enum.Font.GothamBold
    b.BorderSizePixel  = 0
    b.AutoButtonColor  = false
    b.Parent           = parent
    local c = Instance.new("UICorner") ; c.CornerRadius = UDim.new(0,7) ; c.Parent=b
    return b
end

-- Muestra una notificación temporal en el banner superior
local function showNotif(msg, color, duracion)
    local lbl = ui.notifLbl
    if not lbl or not lbl.Parent then return end
    lbl.Text       = "  " .. msg .. "  "
    lbl.TextColor3 = color or Color3.fromRGB(100,220,100)
    lbl.BackgroundColor3 = Color3.fromRGB(12,8,22)
    lbl.Position = UDim2.new(0.5,-200,0,-40)
    TweenService:Create(lbl, TW_BOUNCE, {
        Position = UDim2.new(0.5,-200,0,8)
    }):Play()
    task.delay(duracion or 2.8, function()
        if lbl.Parent then
            TweenService:Create(lbl, TW_MED, {
                Position = UDim2.new(0.5,-200,0,-40)
            }):Play()
        end
    end)
end

--------------------------------------------------------------------------------
-- CONSTRUCCIÓN DEL UI ESTÁTICO (llamado una vez desde Init)
--------------------------------------------------------------------------------

local function crearUI()
    local sg = Instance.new("ScreenGui")
    sg.Name           = "TradeGUI"
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Enabled        = false
    sg.Parent         = playerGui
    ui.screenGui      = sg

    -- Fondo oscuro semi-transparente
    local bgOv = Instance.new("Frame")
    bgOv.Name               = "BgOverlay"
    bgOv.Size               = UDim2.new(1,0,1,0)
    bgOv.BackgroundColor3   = Color3.fromRGB(0,0,0)
    bgOv.BackgroundTransparency = 0.58
    bgOv.BorderSizePixel    = 0
    bgOv.ZIndex             = 1
    bgOv.Parent             = sg
    ui.bgOverlay = bgOv

    -- ── VENTANA PRINCIPAL ─────────────────────────────────────────────────────
    local main = mkF(sg, "MainFrame",
        UDim2.new(0, WIN_W, 0, WIN_H),
        UDim2.new(0.5,-WIN_W/2, 0.5,-WIN_H/2),
        PANEL_BG, BORDER_GOLD, 10)
    main.ZIndex = 3
    ui.mainFrame = main

    -- ── HEADER ────────────────────────────────────────────────────────────────
    local header = mkF(main, "Header",
        UDim2.new(1,0,0,HEADER_H),
        UDim2.new(0,0,0,0),
        Color3.fromRGB(20,14,38), nil, 0)

    local hLine = Instance.new("Frame")
    hLine.Size = UDim2.new(1,0,0,1) ; hLine.Position = UDim2.new(0,0,1,-1)
    hLine.BackgroundColor3 = BORDER_GOLD ; hLine.BorderSizePixel = 0
    hLine.Parent = header

    mkL(header, "TitleLbl", "🔄  INTERCAMBIO",
        UDim2.new(0,220,0,28), UDim2.new(0,12,0,4),
        20, BORDER_GOLD, Enum.Font.GothamBold)

    ui.targetLbl = mkL(header, "TargetLbl", "Con: —",
        UDim2.new(0,260,0,18), UDim2.new(0,12,0,32),
        12, TEXT_DIM, Enum.Font.Gotham)

    -- Indicador de estado coloreado (bolita)
    ui.stateIndicator = mkF(header, "StateIndicator",
        UDim2.new(0,10,0,10), UDim2.new(0,240,0,8),
        STATE_COLORS.idle, nil, 5)

    ui.stateHeaderLbl = mkL(header, "StateHeaderLbl", "Sin intercambio activo",
        UDim2.new(0,240,0,18), UDim2.new(0,256,0,4),
        11, TEXT_DIM, Enum.Font.Gotham)

    local closeBtn = mkB(header, "CloseBtn", "✕",
        UDim2.new(0,32,0,32), UDim2.new(1,-40,0,11),
        Color3.fromRGB(100,28,28), Color3.fromRGB(255,200,200), 15)
    closeBtn.MouseButton1Click:Connect(function() TradeGUI.Close() end)

    -- ── PANELES DE OFERTA (lado a lado) ───────────────────────────────────────

    -- Panel izquierdo: TÚ ofreces
    local myPanel = mkF(main, "MyPanel",
        UDim2.new(0, PANEL_W, 0, PANELS_H),
        UDim2.new(0, 6, 0, PANELS_Y),
        PANEL_BG2, Color3.fromRGB(60,80,120), 8)
    ui.myPanel = myPanel

    mkL(myPanel, "MyTitle", "TÚ ofreces:",
        UDim2.new(1,-8,0,20), UDim2.new(0,6,0,6),
        13, Color3.fromRGB(140,180,255), Enum.Font.GothamBold)

    -- Área de items de mi oferta (UIListLayout horizontal, máx 3)
    local myItemsArea = mkF(myPanel, "MyItemsArea",
        UDim2.new(1,-10,0,CARD_H+8), UDim2.new(0,5,0,30),
        Color3.fromRGB(10,8,18), nil, 6)
    myItemsArea.BackgroundTransparency = 0.5
    ui.myItemsArea = myItemsArea

    local myItemsLayout = Instance.new("UIListLayout")
    myItemsLayout.FillDirection = Enum.FillDirection.Horizontal
    myItemsLayout.SortOrder     = Enum.SortOrder.LayoutOrder
    myItemsLayout.Padding       = UDim.new(0,6)
    myItemsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    myItemsLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
    myItemsLayout.Parent        = myItemsArea
    local myPad = Instance.new("UIPadding")
    myPad.PaddingLeft = UDim.new(0,6) ; myPad.PaddingRight = UDim.new(0,6)
    myPad.Parent      = myItemsArea
    ui.myItemsLayout  = myItemsLayout

    -- Botón "+ Agregar item"
    ui.addBtn = mkB(myPanel, "AddBtn", "+ Agregar item",
        UDim2.new(1,-12,0,34), UDim2.new(0,6,0,CARD_H+44),
        Color3.fromRGB(25,50,90), Color3.fromRGB(140,190,255), 13)
    ui.addBtn.MouseButton1Click:Connect(function()
        TradeGUI.RenderInventorySelector()
    end)

    -- Separador vertical central
    local vSep = Instance.new("Frame")
    vSep.Size             = UDim2.new(0,1,0,PANELS_H)
    vSep.Position         = UDim2.new(0, 6+PANEL_W+3, 0, PANELS_Y)
    vSep.BackgroundColor3 = BORDER_GOLD
    vSep.BackgroundTransparency = 0.70
    vSep.BorderSizePixel  = 0
    vSep.Parent           = main

    -- Panel derecho: ELLOS ofrecen
    local theirPanel = mkF(main, "TheirPanel",
        UDim2.new(0, PANEL_W, 0, PANELS_H),
        UDim2.new(0, 6+PANEL_W+8, 0, PANELS_Y),
        PANEL_BG2, Color3.fromRGB(100,60,60), 8)
    ui.theirPanel = theirPanel

    mkL(theirPanel, "TheirTitle", "ELLOS ofrecen:",
        UDim2.new(1,-8,0,20), UDim2.new(0,6,0,6),
        13, Color3.fromRGB(255,160,140), Enum.Font.GothamBold)

    local theirItemsArea = mkF(theirPanel, "TheirItemsArea",
        UDim2.new(1,-10,0,CARD_H+8), UDim2.new(0,5,0,30),
        Color3.fromRGB(10,8,18), nil, 6)
    theirItemsArea.BackgroundTransparency = 0.5
    ui.theirItemsArea = theirItemsArea

    local theirItemsLayout = Instance.new("UIListLayout")
    theirItemsLayout.FillDirection = Enum.FillDirection.Horizontal
    theirItemsLayout.SortOrder     = Enum.SortOrder.LayoutOrder
    theirItemsLayout.Padding       = UDim.new(0,6)
    theirItemsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    theirItemsLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
    theirItemsLayout.Parent        = theirItemsArea
    local theirPad = Instance.new("UIPadding")
    theirPad.PaddingLeft = UDim.new(0,6) ; theirPad.PaddingRight = UDim.new(0,6)
    theirPad.Parent      = theirItemsArea
    ui.theirItemsLayout  = theirItemsLayout

    -- Placeholder "esperando..." en panel del otro jugador
    ui.theirStatusLbl = mkL(theirPanel, "TheirStatusLbl",
        "⏳ esperando oferta...",
        UDim2.new(1,-8,0,60), UDim2.new(0,4,0,CARD_H+46),
        12, TEXT_DIM, Enum.Font.Gotham, Enum.TextXAlignment.Center)

    -- ── BARRA DE INFORMACIÓN ──────────────────────────────────────────────────
    local infoBar = mkF(main, "InfoBar",
        UDim2.new(1,-12,0,INFO_H),
        UDim2.new(0,6,0,INFO_Y),
        Color3.fromRGB(18,13,32), nil, 6)

    mkL(infoBar, "LimitLbl",
        "Límite: " .. MAX_ITEMS .. " items por lado",
        UDim2.new(0,200,0,18), UDim2.new(0,8,0,4),
        11, TEXT_DIM, Enum.Font.Gotham)

    ui.tradesCountLbl = mkL(infoBar, "TradesCountLbl",
        "Intercambios hoy: 0/" .. state.tradesLimite,
        UDim2.new(0,220,0,18), UDim2.new(0,8,0,22),
        11, TEXT_DIM, Enum.Font.Gotham)

    -- Límite de items en MI oferta
    ui.myItemCountLbl = mkL(infoBar, "MyItemCountLbl", "0/" .. MAX_ITEMS,
        UDim2.new(0,80,0,36), UDim2.new(0,180,0,4),
        12, TEXT_DIM, Enum.Font.GothamBold, Enum.TextXAlignment.Right)

    -- ── BARRA DE ESTADO ───────────────────────────────────────────────────────
    local statusBar = mkF(main, "StatusBar",
        UDim2.new(1,-12,0,STATUS_H),
        UDim2.new(0,6,0,STATUS_Y),
        Color3.fromRGB(15,10,26), BORDER_GOLD, 6)
    statusBar.BackgroundTransparency = 0.4
    ui.statusBar = statusBar

    -- Bolita indicadora de color
    ui.statusDot = mkF(statusBar, "StatusDot",
        UDim2.new(0,12,0,12), UDim2.new(0,8,0.5,-6),
        STATE_COLORS.idle, nil, 6)

    ui.statusLbl = mkL(statusBar, "StatusLbl",
        "Sin intercambio activo",
        UDim2.new(1,-130,1,0), UDim2.new(0,26,0,0),
        12, TEXT_PRIMARY, Enum.Font.GothamMedium)

    ui.countdownLbl = mkL(statusBar, "CountdownLbl", "",
        UDim2.new(0,80,1,0), UDim2.new(1,-84,0,0),
        14, Color3.fromRGB(200,200,200), Enum.Font.GothamBold,
        Enum.TextXAlignment.Right)

    -- ── FOOTER DE BOTONES ─────────────────────────────────────────────────────
    local footer = mkF(main, "Footer",
        UDim2.new(1,-12,0,FOOTER_H),
        UDim2.new(0,6,0,FOOTER_Y),
        Color3.fromRGB(12,8,22), nil, 0)
    footer.BackgroundTransparency = 1

    local footerLayout = Instance.new("UIListLayout")
    footerLayout.FillDirection  = Enum.FillDirection.Horizontal
    footerLayout.SortOrder      = Enum.SortOrder.LayoutOrder
    footerLayout.Padding        = UDim.new(0,10)
    footerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    footerLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
    footerLayout.Parent = footer

    -- Botón PROPONER (estado: proposing)
    ui.proposeBtn = mkB(footer, "ProposeBtn", "✅ PROPONER",
        UDim2.new(0,150,0,44), nil,
        Color3.fromRGB(20,80,30), Color3.fromRGB(180,255,180), 15)
    ui.proposeBtn.LayoutOrder = 1
    ui.proposeBtn.MouseButton1Click:Connect(function() TradeGUI.OnPropose() end)

    -- Botón ACEPTAR (estado: receiving)
    ui.acceptBtn = mkB(footer, "AcceptBtn", "✅ Aceptar",
        UDim2.new(0,130,0,44), nil,
        Color3.fromRGB(20,80,30), Color3.fromRGB(180,255,180), 14)
    ui.acceptBtn.LayoutOrder = 2
    ui.acceptBtn.MouseButton1Click:Connect(function()
        if not state.tradeId then return end
        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        local ok, res = pcall(function()
            return Remotes:WaitForChild("RequestRespondToTrade")
                :InvokeServer(state.tradeId, "accepted", nil)
        end)
        if ok and res and res.ok then
            TradeGUI.OnConfirm(state.tradeId)
        else
            showNotif("Error al aceptar", Color3.fromRGB(200,60,60))
        end
    end)

    -- Botón RECHAZAR (estado: receiving)
    ui.rejectBtn = mkB(footer, "RejectBtn", "✗ Rechazar",
        UDim2.new(0,120,0,44), nil,
        Color3.fromRGB(80,20,20), Color3.fromRGB(255,180,180), 14)
    ui.rejectBtn.LayoutOrder = 3
    ui.rejectBtn.MouseButton1Click:Connect(function()
        if not state.tradeId then return end
        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        pcall(function()
            Remotes:WaitForChild("RequestRespondToTrade")
                :InvokeServer(state.tradeId, "rejected", nil)
        end)
        showNotif("Propuesta rechazada", Color3.fromRGB(200,120,40))
        setEstado("cancelled")
    end)

    -- Botón CONTRAOFERTA (estado: receiving)
    ui.counterBtn = mkB(footer, "CounterBtn", "🔄 Contraoferta",
        UDim2.new(0,138,0,44), nil,
        Color3.fromRGB(50,40,10), Color3.fromRGB(255,220,80), 14)
    ui.counterBtn.LayoutOrder = 4
    ui.counterBtn.MouseButton1Click:Connect(function() TradeGUI.OnCounterOffer() end)

    -- Botón ENVIAR CONTRAOFERTA (estado: negotiating)
    ui.sendCounterBtn = mkB(footer, "SendCounterBtn", "📤 Enviar contraoferta",
        UDim2.new(0,190,0,44), nil,
        Color3.fromRGB(50,40,10), Color3.fromRGB(255,220,80), 14)
    ui.sendCounterBtn.LayoutOrder = 5
    ui.sendCounterBtn.MouseButton1Click:Connect(function()
        if not state.tradeId then return end
        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        local myOfferPayload = {}
        for _, item in ipairs(state.myOffer) do
            myOfferPayload[#myOfferPayload+1] = item.id
        end
        local ok, res = pcall(function()
            return Remotes:WaitForChild("RequestRespondToTrade")
                :InvokeServer(state.tradeId, "counter", { dragons = myOfferPayload })
        end)
        if ok and res and res.ok then
            setEstado("waiting")
            showNotif("Contraoferta enviada", Color3.fromRGB(255,220,80))
        else
            showNotif("Error al enviar contraoferta", Color3.fromRGB(200,60,60))
        end
    end)

    -- Botón CANCELAR / CERRAR (siempre visible)
    ui.cancelBtn = mkB(footer, "CancelBtn", "✕ Cancelar",
        UDim2.new(0,120,0,44), nil,
        Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 14)
    ui.cancelBtn.LayoutOrder = 10
    ui.cancelBtn.MouseButton1Click:Connect(function()
        if state.tradeId then
            local Remotes = ReplicatedStorage:WaitForChild("Remotes")
            pcall(function()
                Remotes:WaitForChild("RequestCancelTrade"):InvokeServer(state.tradeId)
            end)
        end
        TradeGUI.Close()
    end)

    -- ── PANEL DEL SELECTOR DE INVENTARIO (sube desde abajo) ──────────────────
    local invPanel = mkF(sg, "InventoryPanel",
        UDim2.new(0, WIN_W, 0, INV_H),
        UDim2.new(0.5, -WIN_W/2, 1, 0),  -- oculto debajo de la pantalla
        PANEL_BG2, BORDER_GOLD, 10)
    invPanel.ZIndex = 8
    ui.invPanel = invPanel

    mkL(invPanel, "InvTitle", "🎒 Seleccionar item para ofrecer",
        UDim2.new(1,-60,0,22), UDim2.new(0,10,0,6),
        15, BORDER_GOLD, Enum.Font.GothamBold)

    local invClose = mkB(invPanel, "InvClose", "✕",
        UDim2.new(0,30,0,26), UDim2.new(1,-36,0,6),
        Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 14)
    invClose.MouseButton1Click:Connect(function()
        TweenService:Create(ui.invPanel, TW_SLIDE, {
            Position = UDim2.new(0.5, -WIN_W/2, 1, 0)
        }):Play()
    end)

    local invScroll = Instance.new("ScrollingFrame")
    invScroll.Name               = "InvScroll"
    invScroll.Size               = UDim2.new(1,-8,0,INV_H-38)
    invScroll.Position           = UDim2.new(0,4,0,34)
    invScroll.BackgroundTransparency = 1
    invScroll.BorderSizePixel    = 0
    invScroll.ScrollBarThickness = 4
    invScroll.ScrollBarImageColor3 = BORDER_GOLD
    invScroll.CanvasSize         = UDim2.new(0,0,0,0)
    invScroll.Parent             = invPanel
    ui.invScroll = invScroll

    local invGrid = Instance.new("UIGridLayout")
    invGrid.CellSize    = UDim2.new(0,90,0,118)
    invGrid.CellPadding = UDim2.new(0,7,0,7)
    invGrid.SortOrder   = Enum.SortOrder.LayoutOrder
    invGrid.Parent      = invScroll
    local invPad = Instance.new("UIPadding")
    invPad.PaddingLeft = UDim.new(0,6) ; invPad.PaddingTop = UDim.new(0,6)
    invPad.Parent      = invScroll

    invGrid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        invScroll.CanvasSize = UDim2.new(0,0,0, invGrid.AbsoluteContentSize.Y + 12)
    end)
    ui.invGrid = invGrid

    -- ── OVERLAY DE CONFIRMACIÓN FINAL (aparece sobre la ventana) ─────────────
    local confirmOverlay = mkF(main, "ConfirmOverlay",
        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
        Color3.fromRGB(0,0,0), nil, 0)
    confirmOverlay.BackgroundTransparency = 0.35
    confirmOverlay.ZIndex   = 10
    confirmOverlay.Visible  = false
    ui.confirmOverlay = confirmOverlay

    -- ── PANEL DEL HISTORIAL (panel lateral derecho) ───────────────────────────
    local histPanel = mkF(sg, "HistoryPanel",
        UDim2.new(0,300,0,440),
        UDim2.new(1,10,0.5,-220),   -- oculto a la derecha
        PANEL_BG2, BORDER_GOLD, 10)
    histPanel.ZIndex = 6
    ui.histPanel = histPanel

    mkL(histPanel, "HistTitle", "📋 Historial de intercambios",
        UDim2.new(1,-60,0,22), UDim2.new(0,8,0,8),
        13, BORDER_GOLD, Enum.Font.GothamBold)

    local histClose = mkB(histPanel, "HistClose", "✕",
        UDim2.new(0,28,0,24), UDim2.new(1,-32,0,8),
        Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 13)
    histClose.MouseButton1Click:Connect(function()
        TweenService:Create(ui.histPanel, TW_SLIDE, {
            Position = UDim2.new(1,10,0.5,-220)
        }):Play()
    end)

    local histScroll = Instance.new("ScrollingFrame")
    histScroll.Name               = "HistScroll"
    histScroll.Size               = UDim2.new(1,-8,1,-38)
    histScroll.Position           = UDim2.new(0,4,0,34)
    histScroll.BackgroundTransparency = 1
    histScroll.BorderSizePixel    = 0
    histScroll.ScrollBarThickness = 3
    histScroll.ScrollBarImageColor3 = BORDER_GOLD
    histScroll.CanvasSize         = UDim2.new(0,0,0,0)
    histScroll.Parent             = histPanel
    ui.histScroll = histScroll

    local histLayout = Instance.new("UIListLayout")
    histLayout.SortOrder = Enum.SortOrder.LayoutOrder
    histLayout.Padding   = UDim.new(0,5)
    histLayout.Parent    = histScroll
    histLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        histScroll.CanvasSize = UDim2.new(0,0,0, histLayout.AbsoluteContentSize.Y + 8)
    end)

    -- ── NOTIFICACIÓN FLOTANTE (banner superior) ───────────────────────────────
    local notifLbl = Instance.new("TextLabel")
    notifLbl.Name               = "NotifLbl"
    notifLbl.Size               = UDim2.new(0,400,0,34)
    notifLbl.Position           = UDim2.new(0.5,-200,0,-40)
    notifLbl.Text               = ""
    notifLbl.TextSize           = 13
    notifLbl.TextColor3         = Color3.fromRGB(100,220,100)
    notifLbl.Font               = Enum.Font.GothamBold
    notifLbl.BackgroundColor3   = Color3.fromRGB(12,8,22)
    notifLbl.BackgroundTransparency = 0.2
    notifLbl.BorderSizePixel    = 0
    notifLbl.TextXAlignment     = Enum.TextXAlignment.Center
    notifLbl.ZIndex             = 15
    notifLbl.Parent             = sg
    local notifC = Instance.new("UICorner")
    notifC.CornerRadius = UDim.new(0,8) ; notifC.Parent = notifLbl
    ui.notifLbl = notifLbl
end

--------------------------------------------------------------------------------
-- setEstado(estado)
-- Actualiza el indicador visual, el label de estado y la visibilidad de botones.
-- Centraliza todos los cambios de estado para mantener la UI coherente.
--------------------------------------------------------------------------------

function setEstado(estado)
    state.tradeEstado = estado
    local col   = STATE_COLORS[estado]  or STATE_COLORS.idle
    local label = STATE_LABELS[estado]  or estado

    -- Actualizar indicador y labels
    if ui.statusDot   then
        TweenService:Create(ui.statusDot, TW_FAST, { BackgroundColor3 = col }):Play()
    end
    if ui.statusLbl        then ui.statusLbl.Text       = label end
    if ui.stateHeaderLbl   then ui.stateHeaderLbl.Text  = label end
    if ui.stateIndicator   then
        TweenService:Create(ui.stateIndicator, TW_FAST, { BackgroundColor3 = col }):Play()
    end

    -- Visibilidad de botones según estado
    local vis = {
        proposeBtn    = (estado == "proposing"),
        acceptBtn     = (estado == "receiving" or estado == "negotiating_recv"),
        rejectBtn     = (estado == "receiving"),
        counterBtn    = (estado == "receiving"),
        sendCounterBtn= (estado == "negotiating"),
        cancelBtn     = (estado ~= "completed" and estado ~= "cancelled" and estado ~= "expired"),
        addBtn        = (estado == "proposing" or estado == "negotiating"),
    }
    for name, visible in pairs(vis) do
        if ui[name] then ui[name].Visible = visible end
    end

    -- Cancelar countdown si salimos de waiting
    if estado ~= "waiting" then
        state.countdownGen  = state.countdownGen + 1
        state.cdBlinkActive = false
        if ui.countdownLbl then
            ui.countdownLbl.Text          = ""
            ui.countdownLbl.TextColor3    = Color3.fromRGB(200,200,200)
            ui.countdownLbl.TextTransparency = 0
        end
    end
end

--------------------------------------------------------------------------------
-- Crea el card visual de un item para los paneles de oferta
-- isMyOffer: si true, incluye botón [X] para quitar
--------------------------------------------------------------------------------

local function crearItemCard(parent, itemData, isMyOffer, orden)
    local dragon = itemData.dragon
    if not dragon then return end

    local rarColor  = RARITY_COLORS[dragon.rarity] or TEXT_DIM
    local elemColor = ELEMENT_COLORS[dragon.element] or Color3.fromRGB(60,40,80)

    local card = mkF(parent, "Card_" .. itemData.id,
        UDim2.new(0, CARD_W, 0, CARD_H),
        nil, Color3.fromRGB(22,16,42), rarColor, 7)
    card.LayoutOrder = orden or 1

    -- Imagen / zona de emoji
    local imgZone = mkF(card, "ImgZone",
        UDim2.new(1,-8,0,56), UDim2.new(0,4,0,4),
        elemColor, nil, 5)
    imgZone.BackgroundTransparency = 0.58

    mkL(imgZone, "Emoji", "🐉",
        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
        44, Color3.fromRGB(255,255,255), Enum.Font.GothamBold,
        Enum.TextXAlignment.Center)

    -- Nombre (truncado si es largo)
    local shortName = #dragon.name > 12
        and dragon.name:sub(1,10) .. ".." or dragon.name
    mkL(card, "NameLbl", shortName,
        UDim2.new(1,-4,0,22), UDim2.new(0,2,0,62),
        10, TEXT_PRIMARY, Enum.Font.GothamBold, Enum.TextXAlignment.Center)

    -- Rareza con color
    mkL(card, "RarLbl",
        dragon.rarity:sub(1,1):upper() .. dragon.rarity:sub(2),
        UDim2.new(1,-4,0,14), UDim2.new(0,2,0,82),
        9, rarColor, Enum.Font.GothamMedium, Enum.TextXAlignment.Center)

    -- GPS
    mkL(card, "GpsLbl",
        string.format("%.1f/s", dragon.goldPerSecond),
        UDim2.new(1,-4,0,13), UDim2.new(0,2,0,96),
        9, Color3.fromRGB(255,200,50), Enum.Font.Gotham, Enum.TextXAlignment.Center)

    -- Botón [X] solo en el panel propio
    if isMyOffer then
        local xBtn = mkB(card, "RemoveBtn", "✕",
            UDim2.new(1,-4,0,14), UDim2.new(0,2,0,CARD_H-18),
            Color3.fromRGB(80,20,20), Color3.fromRGB(255,180,180), 9)
        local captId = itemData.id
        xBtn.MouseButton1Click:Connect(function()
            TradeGUI.RemoveItemFromOffer(captId)
        end)
    end

    return card
end

--------------------------------------------------------------------------------
-- renderOfertaPanel(lista, parentFrame, isMyOffer)
-- Re-renderiza todos los cards de un panel de oferta.
--------------------------------------------------------------------------------

local function renderOfertaPanel(lista, parentFrame, isMyOffer)
    for _, c in ipairs(parentFrame:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    for i, item in ipairs(lista) do
        crearItemCard(parentFrame, item, isMyOffer, i)
    end
end

--------------------------------------------------------------------------------
-- TradeGUI.Open(targetPlayer)
-- Abre la interfaz de trade con el jugador objetivo.
-- targetPlayer: instancia Player o tabla { name, userId, level }
--------------------------------------------------------------------------------

function TradeGUI.Open(targetPlayer)
    if state.isOpen then return end

    -- Extraer datos del jugador objetivo
    if typeof(targetPlayer) == "Instance" and targetPlayer:IsA("Player") then
        state.targetName   = targetPlayer.DisplayName or targetPlayer.Name
        state.targetUserId = targetPlayer.UserId
        state.targetLevel  = 1  -- nivel se puede solicitar al servidor
    elseif type(targetPlayer) == "table" then
        state.targetName   = targetPlayer.name   or "Jugador"
        state.targetUserId = targetPlayer.userId or 0
        state.targetLevel  = targetPlayer.level  or 1
    else
        warn("[TradeGUI] targetPlayer inválido")
        return
    end

    -- Resetear estado
    state.isOpen      = true
    state.tradeId     = nil
    state.amInitiator = true
    state.myOffer     = {}
    state.theirOffer  = {}

    -- Actualizar header con el jugador objetivo
    if ui.targetLbl then
        ui.targetLbl.Text = "Con: " .. state.targetName .. " (Nv. " .. state.targetLevel .. ")"
    end

    -- Vaciar paneles de oferta
    renderOfertaPanel(state.myOffer,    ui.myItemsArea,    true)
    renderOfertaPanel(state.theirOffer, ui.theirItemsArea, false)
    if ui.theirStatusLbl then ui.theirStatusLbl.Visible = true end
    if ui.myItemCountLbl then ui.myItemCountLbl.Text = "0/" .. MAX_ITEMS end
    if ui.tradesCountLbl then
        ui.tradesCountLbl.Text = "Intercambios hoy: "
            .. state.tradesHoy .. "/" .. state.tradesLimite
    end

    -- Configurar estado inicial
    setEstado("proposing")

    -- Animar apertura
    ui.screenGui.Enabled = true
    ui.bgOverlay.BackgroundTransparency = 1
    TweenService:Create(ui.bgOverlay, TW_MED, { BackgroundTransparency = 0.58 }):Play()
    ui.mainFrame.Size     = UDim2.new(0,1,0,1)
    ui.mainFrame.Position = UDim2.new(0.5,0,0.5,0)
    TweenService:Create(ui.mainFrame, TW_BOUNCE, {
        Size     = UDim2.new(0, WIN_W, 0, WIN_H),
        Position = UDim2.new(0.5,-WIN_W/2, 0.5,-WIN_H/2),
    }):Play()
end

--------------------------------------------------------------------------------
-- TradeGUI.Close()
-- Cierra el trade con animación. Si hay trade activo pide confirmación.
--------------------------------------------------------------------------------

function TradeGUI.Close()
    if not state.isOpen then return end

    -- Si hay trade activo (waiting/receiving/negotiating) pedir confirmación
    local estadoActivo = state.tradeEstado
    if estadoActivo == "waiting" or estadoActivo == "receiving"
       or estadoActivo == "negotiating" then
        -- Mostrar mini-diálogo de confirmación
        local dlg = mkF(ui.mainFrame, "CloseDialog",
            UDim2.new(0,320,0,120), UDim2.new(0.5,-160,0.5,-60),
            Color3.fromRGB(20,14,38), BORDER_GOLD, 10)
        dlg.ZIndex = 20
        mkL(dlg, "Q", "¿Cancelar el intercambio activo y cerrar?",
            UDim2.new(1,-12,0,40), UDim2.new(0,6,0,10),
            13, TEXT_PRIMARY, Enum.Font.GothamMedium, Enum.TextXAlignment.Center)
        local yesBtn = mkB(dlg, "Yes", "Sí, cancelar",
            UDim2.new(0,130,0,38), UDim2.new(0,12,0,62),
            Color3.fromRGB(80,20,20), Color3.fromRGB(255,180,180), 13)
        local noBtn = mkB(dlg, "No", "No, volver",
            UDim2.new(0,130,0,38), UDim2.new(0,152,0,62),
            Color3.fromRGB(20,50,20), Color3.fromRGB(180,255,180), 13)
        yesBtn.MouseButton1Click:Connect(function()
            dlg:Destroy()
            if state.tradeId then
                local R = ReplicatedStorage:WaitForChild("Remotes")
                pcall(function()
                    R:WaitForChild("RequestCancelTrade"):InvokeServer(state.tradeId)
                end)
            end
            TradeGUI.Close()
        end)
        noBtn.MouseButton1Click:Connect(function() dlg:Destroy() end)
        return
    end

    state.isOpen        = false
    state.countdownGen  = state.countdownGen + 1
    state.cdBlinkActive = false

    TweenService:Create(ui.mainFrame, TW_MED, {
        Size     = UDim2.new(0,1,0,1),
        Position = UDim2.new(0.5,0,0.5,0),
    }):Play()
    TweenService:Create(ui.bgOverlay, TW_MED, { BackgroundTransparency = 1 }):Play()
    -- Ocultar panel de inventario si estaba abierto
    ui.invPanel.Position = UDim2.new(0.5,-WIN_W/2,1,0)
    task.delay(0.25, function()
        if not state.isOpen then
            ui.screenGui.Enabled = false
        end
    end)
end

--------------------------------------------------------------------------------
-- TradeGUI.RenderInventorySelector()
-- Abre el panel inferior con los dragones disponibles para ofrecer.
-- Solicita al servidor los items no ocupados en nidos ni en breeding.
--------------------------------------------------------------------------------

function TradeGUI.RenderInventorySelector()
    if #state.myOffer >= MAX_ITEMS then
        showNotif("Máximo " .. MAX_ITEMS .. " items por intercambio",
            Color3.fromRGB(200,120,40))
        return
    end

    -- Limpiar grid de inventario
    for _, c in ipairs(ui.invScroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end

    -- Solicitar inventario disponible al servidor
    local Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local ok, invData = pcall(function()
        return Remotes:WaitForChild("RequestGetInventoryForTrade"):InvokeServer()
    end)

    if not (ok and invData) then
        -- Fallback: mostrar mensaje de error
        mkL(ui.invScroll, "ErrLbl",
            "No se pudo cargar el inventario. Inténtalo de nuevo.",
            UDim2.new(1,-16,0,40), UDim2.new(0,8,0,8),
            13, Color3.fromRGB(200,80,80), Enum.Font.Gotham)
    else
        state.inventoryData = invData
        -- invData: { [dragonId] = count } (solo dragons disponibles para trade)
        local orden = 1
        for dragonId, count in pairs(invData) do
            if count > 0 then
                local dragon = DragonData.GetDragonById(dragonId)
                if dragon then
                    local card = mkF(ui.invScroll, "InvCard_" .. dragonId,
                        UDim2.new(0,90,0,118), nil,
                        Color3.fromRGB(22,16,42),
                        RARITY_COLORS[dragon.rarity] or TEXT_DIM, 7)
                    card.LayoutOrder = orden

                    -- Zona de emoji
                    local iz = mkF(card, "Iz",
                        UDim2.new(1,-8,0,58), UDim2.new(0,4,0,4),
                        ELEMENT_COLORS[dragon.element] or Color3.fromRGB(60,40,80),
                        nil, 5)
                    iz.BackgroundTransparency = 0.55
                    mkL(iz, "E", "🐉",
                        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
                        42, Color3.fromRGB(255,255,255),
                        Enum.Font.GothamBold, Enum.TextXAlignment.Center)

                    local nm = #dragon.name > 10 and dragon.name:sub(1,9) .. ".."
                               or dragon.name
                    mkL(card, "Nm", nm,
                        UDim2.new(1,-4,0,20), UDim2.new(0,2,0,64),
                        9, TEXT_PRIMARY, Enum.Font.GothamBold,
                        Enum.TextXAlignment.Center)

                    mkL(card, "Cnt", "x" .. count,
                        UDim2.new(1,-4,0,12), UDim2.new(0,2,0,83),
                        9, Color3.fromRGB(255,200,60), Enum.Font.Gotham,
                        Enum.TextXAlignment.Center)

                    -- Botón seleccionar
                    local selBtn = Instance.new("TextButton")
                    selBtn.Size               = UDim2.new(1,0,1,0)
                    selBtn.BackgroundTransparency = 1
                    selBtn.Text               = ""
                    selBtn.BorderSizePixel    = 0
                    selBtn.Parent             = card

                    local captId     = dragonId
                    local captDragon = dragon
                    selBtn.MouseButton1Click:Connect(function()
                        TradeGUI.AddItemToOffer({
                            type   = "dragon",
                            id     = captId,
                            dragon = captDragon,
                        })
                        -- Cerrar panel de inventario
                        TweenService:Create(ui.invPanel, TW_SLIDE, {
                            Position = UDim2.new(0.5,-WIN_W/2,1,0)
                        }):Play()
                    end)

                    orden = orden + 1
                end
            end
        end

        if orden == 1 then
            mkL(ui.invScroll, "EmptyLbl",
                "No tienes dragones disponibles para intercambiar.",
                UDim2.new(1,-16,0,40), UDim2.new(0,8,0,8),
                13, TEXT_DIM, Enum.Font.Gotham)
        end
    end

    -- Deslizar panel hacia arriba
    ui.invPanel.Position = UDim2.new(0.5,-WIN_W/2,1,0)
    TweenService:Create(ui.invPanel, TW_SLIDE, {
        Position = UDim2.new(0.5,-WIN_W/2,1,-INV_H-2)
    }):Play()
end

--------------------------------------------------------------------------------
-- TradeGUI.AddItemToOffer(itemData)
-- Agrega un item al panel "TÚ ofreces". Máximo MAX_ITEMS items.
--------------------------------------------------------------------------------

function TradeGUI.AddItemToOffer(itemData)
    if #state.myOffer >= MAX_ITEMS then
        showNotif("Máximo " .. MAX_ITEMS .. " items por intercambio",
            Color3.fromRGB(200,120,40))
        return
    end

    -- Verificar que no esté ya agregado
    for _, existing in ipairs(state.myOffer) do
        if existing.id == itemData.id then
            showNotif("Ese item ya está en tu oferta", Color3.fromRGB(200,120,40))
            return
        end
    end

    state.myOffer[#state.myOffer+1] = itemData

    -- Actualizar la UI de mi panel con animación de entrada
    local card = crearItemCard(ui.myItemsArea, itemData, true, #state.myOffer)
    if card then
        card.BackgroundTransparency = 1
        TweenService:Create(card, TW_BOUNCE, { BackgroundTransparency = 0 }):Play()
    end

    -- Actualizar contador
    if ui.myItemCountLbl then
        ui.myItemCountLbl.Text = #state.myOffer .. "/" .. MAX_ITEMS
        ui.myItemCountLbl.TextColor3 = #state.myOffer >= MAX_ITEMS
            and Color3.fromRGB(255,150,50) or TEXT_DIM
    end
end

--------------------------------------------------------------------------------
-- TradeGUI.RemoveItemFromOffer(itemId)
-- Quita un item de la oferta propia. Solo posible antes de confirmar.
--------------------------------------------------------------------------------

function TradeGUI.RemoveItemFromOffer(itemId)
    if state.tradeEstado == "confirming" then return end

    -- Quitar del array state.myOffer
    for i, item in ipairs(state.myOffer) do
        if item.id == itemId then
            table.remove(state.myOffer, i)
            break
        end
    end

    -- Destruir el card correspondiente con animación
    local cardName = "Card_" .. itemId
    local card     = ui.myItemsArea:FindFirstChild(cardName)
    if card then
        TweenService:Create(card, TW_FAST, { BackgroundTransparency = 1 }):Play()
        task.delay(0.20, function()
            if card.Parent then card:Destroy() end
        end)
    end

    -- Actualizar contador
    if ui.myItemCountLbl then
        ui.myItemCountLbl.Text = #state.myOffer .. "/" .. MAX_ITEMS
        ui.myItemCountLbl.TextColor3 = TEXT_DIM
    end
end

--------------------------------------------------------------------------------
-- TradeGUI.OnPropose()
-- Envía la propuesta al servidor. Activa el countdown de 120 segundos.
--------------------------------------------------------------------------------

function TradeGUI.OnPropose()
    if #state.myOffer == 0 then
        showNotif("Agrega al menos 1 item a tu oferta", Color3.fromRGB(200,120,40))
        return
    end
    if state.tradesHoy >= state.tradesLimite then
        TradeGUI.ShowTradeLimit(0, 60)
        return
    end

    if ui.proposeBtn then
        ui.proposeBtn.Active = false
        ui.proposeBtn.Text   = "Enviando..."
    end

    -- Construir payload de oferta
    local dragonIds = {}
    for _, item in ipairs(state.myOffer) do
        if item.type == "dragon" then
            dragonIds[#dragonIds+1] = item.id
        end
    end

    local Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local ok, result = pcall(function()
        return Remotes:WaitForChild("RequestProposeTrade"):InvokeServer(
            state.targetUserId,
            { dragons = dragonIds, eggs = {}, boosts = {} }
        )
    end)

    if ok and result and result.ok then
        state.tradeId     = result.tradeId
        state.amInitiator = true
        state.tradesHoy   = state.tradesHoy + 1
        setEstado("waiting")
        showNotif("¡Propuesta enviada a " .. state.targetName .. "!")
        TradeGUI.UpdateCountdown(result.expiresIn or 120)
    else
        if ui.proposeBtn then
            ui.proposeBtn.Active = true
            ui.proposeBtn.Text   = "✅ PROPONER"
        end
        local msg = (result and type(result) == "string") and result or "Error al proponer"
        if msg:find("límite") or msg:find("limite") then
            TradeGUI.ShowTradeLimit(0, 60)
        else
            showNotif(msg, Color3.fromRGB(200,60,60))
        end
    end
end

--------------------------------------------------------------------------------
-- TradeGUI.OnReceiveProposal(tradeData)
-- Llamado cuando llega TradeProposed al cliente.
-- Abre el GUI si no está abierto y muestra la propuesta del otro jugador.
--------------------------------------------------------------------------------

function TradeGUI.OnReceiveProposal(tradeData)
    if not tradeData then return end

    state.tradeId     = tradeData.tradeId
    state.amInitiator = false

    -- Determinar nombre del que propone
    local initiatorInfo = tradeData.initiator or {}
    local proposerName  = initiatorInfo.name or "Jugador"
    local proposerLevel = initiatorInfo.level or 1

    -- Abrir GUI si no estaba abierto (con datos del proponente)
    if not state.isOpen then
        TradeGUI.Open({ name=proposerName, userId=initiatorInfo.userId or 0, level=proposerLevel })
        -- Open resetea el estado; re-asignar tradeId
        state.tradeId     = tradeData.tradeId
        state.amInitiator = false
    end

    -- Mostrar notificación llamativa
    showNotif("🔄 " .. proposerName .. " quiere intercambiar contigo!", BORDER_GOLD, 3.5)

    -- Poblar el panel "ELLOS ofrecen" con la oferta del proponente
    state.theirOffer = {}
    if tradeData.initiatorOffer then
        for _, dragonId in ipairs(tradeData.initiatorOffer.dragons or {}) do
            local dragon = DragonData.GetDragonById(dragonId)
            if dragon then
                state.theirOffer[#state.theirOffer+1] = {
                    type = "dragon", id = dragonId, dragon = dragon
                }
            end
        end
    end

    renderOfertaPanel(state.theirOffer, ui.theirItemsArea, false)
    if ui.theirStatusLbl then ui.theirStatusLbl.Visible = #state.theirOffer == 0 end

    -- Countdown basado en expiresAt
    local expiresIn = tradeData.expiresAt and (tradeData.expiresAt - tick()) or 120
    setEstado("receiving")
    TradeGUI.UpdateCountdown(math.max(0, expiresIn))
end

--------------------------------------------------------------------------------
-- TradeGUI.OnCounterOffer()
-- El jugador decide hacer una contraoferta.
-- Habilita el panel "TÚ ofreces" para construir la contraoferta.
--------------------------------------------------------------------------------

function TradeGUI.OnCounterOffer()
    -- Limpiar oferta propia para la contraoferta
    state.myOffer = {}
    renderOfertaPanel(state.myOffer, ui.myItemsArea, true)

    setEstado("negotiating")
    showNotif("Construye tu contraoferta y pulsa 'Enviar'",
        Color3.fromRGB(255,220,80), 3.0)

    -- Enfocar el panel propio visualmente
    if ui.myPanel then
        TweenService:Create(ui.myPanel, TW_MED, {
            BackgroundColor3 = Color3.fromRGB(30,30,60)
        }):Play()
    end
end

--------------------------------------------------------------------------------
-- TradeGUI.ShowCounterOfferReceived(tradeData)
-- Llega TradeCounterOffer: el otro jugador hizo una contraoferta.
-- Actualiza el panel "ELLOS ofrecen" y muestra opciones Aceptar/Rechazar.
--------------------------------------------------------------------------------

function TradeGUI.ShowCounterOfferReceived(tradeData)
    if not tradeData then return end

    showNotif("🔄 " .. state.targetName .. " envió una contraoferta", BORDER_GOLD, 3.0)

    -- Actualizar oferta del otro jugador
    state.theirOffer = {}
    local offerSrc = state.amInitiator
        and tradeData.receiverOffer or tradeData.initiatorOffer

    if offerSrc then
        for _, dragonId in ipairs(offerSrc.dragons or {}) do
            local dragon = DragonData.GetDragonById(dragonId)
            if dragon then
                state.theirOffer[#state.theirOffer+1] = {
                    type = "dragon", id = dragonId, dragon = dragon
                }
            end
        end
    end

    renderOfertaPanel(state.theirOffer, ui.theirItemsArea, false)
    if ui.theirStatusLbl then ui.theirStatusLbl.Visible = #state.theirOffer == 0 end

    -- El estado pasa a "receiving" con las nuevas opciones
    setEstado("receiving")

    -- Resaltar el panel del otro jugador para indicar el cambio
    if ui.theirPanel then
        TweenService:Create(ui.theirPanel, TW_FAST, {
            BackgroundColor3 = Color3.fromRGB(50,30,15)
        }):Play()
        task.delay(0.5, function()
            TweenService:Create(ui.theirPanel, TW_MED, {
                BackgroundColor3 = PANEL_BG2
            }):Play()
        end)
    end
end

--------------------------------------------------------------------------------
-- TradeGUI.OnConfirm(tradeId)
-- Muestra el overlay de confirmación final con resumen completo.
-- "Darás: X → Recibirás: Y" — el jugador confirma o cancela.
--------------------------------------------------------------------------------

function TradeGUI.OnConfirm(tradeId)
    setEstado("confirming")
    state.tradeId = tradeId or state.tradeId

    local overlay = ui.confirmOverlay
    -- Limpiar contenido anterior
    for _, c in ipairs(overlay:GetChildren()) do c:Destroy() end
    overlay.BackgroundTransparency = 0.35
    overlay.Visible = true

    -- Panel de resumen
    local summaryPanel = mkF(overlay, "SummaryPanel",
        UDim2.new(0,460,0,300), UDim2.new(0.5,-230,0.5,-150),
        PANEL_BG, BORDER_GOLD, 12)
    summaryPanel.ZIndex = 12

    mkL(summaryPanel, "SumTitle", "📋 Resumen del intercambio",
        UDim2.new(1,-16,0,24), UDim2.new(0,8,0,8),
        16, BORDER_GOLD, Enum.Font.GothamBold, Enum.TextXAlignment.Center)

    -- Columna izquierda: darás
    local leftCol = mkF(summaryPanel, "LeftCol",
        UDim2.new(0,190,0,200), UDim2.new(0,10,0,38),
        Color3.fromRGB(18,14,30), Color3.fromRGB(60,80,120), 7)
    mkL(leftCol, "LeftTitle", "Tú darás:",
        UDim2.new(1,0,0,22), UDim2.new(0,0,0,4),
        13, Color3.fromRGB(140,180,255), Enum.Font.GothamBold,
        Enum.TextXAlignment.Center)
    local leftList = mkF(leftCol, "LeftList",
        UDim2.new(1,-8,1,-30), UDim2.new(0,4,0,26),
        Color3.fromRGB(0,0,0), nil, 0)
    leftList.BackgroundTransparency = 1
    local ll = Instance.new("UIListLayout")
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding   = UDim.new(0,3) ; ll.Parent = leftList
    for i, item in ipairs(state.myOffer) do
        local d = item.dragon
        local lbl = mkL(leftList, "i"..i,
            "🐉 " .. (d and d.name or item.id),
            UDim2.new(1,0,0,18), nil,
            11, d and RARITY_COLORS[d.rarity] or TEXT_PRIMARY, Enum.Font.Gotham)
        lbl.LayoutOrder = i
    end

    -- Flecha central
    mkL(summaryPanel, "Arrow", "→",
        UDim2.new(0,30,0,200), UDim2.new(0.5,-15,0,38),
        28, BORDER_GOLD, Enum.Font.GothamBold, Enum.TextXAlignment.Center)

    -- Columna derecha: recibirás
    local rightCol = mkF(summaryPanel, "RightCol",
        UDim2.new(0,190,0,200), UDim2.new(1,-200,0,38),
        Color3.fromRGB(18,14,30), Color3.fromRGB(100,60,60), 7)
    mkL(rightCol, "RightTitle", "Recibirás:",
        UDim2.new(1,0,0,22), UDim2.new(0,0,0,4),
        13, Color3.fromRGB(255,160,140), Enum.Font.GothamBold,
        Enum.TextXAlignment.Center)
    local rightList = mkF(rightCol, "RightList",
        UDim2.new(1,-8,1,-30), UDim2.new(0,4,0,26),
        Color3.fromRGB(0,0,0), nil, 0)
    rightList.BackgroundTransparency = 1
    local rl = Instance.new("UIListLayout")
    rl.SortOrder = Enum.SortOrder.LayoutOrder
    rl.Padding   = UDim.new(0,3) ; rl.Parent = rightList
    for i, item in ipairs(state.theirOffer) do
        local d = item.dragon
        mkL(rightList, "i"..i,
            "🐉 " .. (d and d.name or item.id),
            UDim2.new(1,0,0,18), nil,
            11, d and RARITY_COLORS[d.rarity] or TEXT_PRIMARY,
            Enum.Font.Gotham).LayoutOrder = i
    end

    -- Botones del resumen
    local confirmFinalBtn = mkB(summaryPanel, "ConfirmFinal",
        "✅ Confirmar intercambio",
        UDim2.new(0,200,0,40), UDim2.new(0,14,1,-50),
        Color3.fromRGB(20,80,30), Color3.fromRGB(180,255,180), 14)
    confirmFinalBtn.ZIndex = 13
    confirmFinalBtn.MouseButton1Click:Connect(function()
        confirmFinalBtn.Active = false
        confirmFinalBtn.Text   = "Confirmando..."
        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        local ok, res = pcall(function()
            return Remotes:WaitForChild("RequestConfirmTrade"):InvokeServer(state.tradeId)
        end)
        if not (ok and res and res.ok) then
            confirmFinalBtn.Active = true
            confirmFinalBtn.Text   = "✅ Confirmar intercambio"
            showNotif("Error al confirmar: " .. tostring(res), Color3.fromRGB(200,60,60))
        end
        -- El evento TradeCompleted llegará del servidor cuando ambos confirmen
    end)

    local cancelFinalBtn = mkB(summaryPanel, "CancelFinal",
        "✕ Cancelar",
        UDim2.new(0,140,0,40), UDim2.new(1,-154,1,-50),
        Color3.fromRGB(80,20,20), Color3.fromRGB(255,180,180), 14)
    cancelFinalBtn.ZIndex = 13
    cancelFinalBtn.MouseButton1Click:Connect(function()
        overlay.Visible = false
        setEstado("receiving")
    end)
end

--------------------------------------------------------------------------------
-- TradeGUI.ShowTradeComplete(result)
-- Animación de intercambio completado: items vuelan entre paneles.
-- Muestra "¡Intercambio exitoso!" y marca los dragones nuevos.
-- result: { myGiven=[ids], received=[ids], newDragons=[ids] }
--------------------------------------------------------------------------------

function TradeGUI.ShowTradeComplete(result)
    -- Ocultar overlay de confirmación si estaba abierto
    if ui.confirmOverlay then ui.confirmOverlay.Visible = false end
    setEstado("completed")
    state.countdownGen = state.countdownGen + 1

    -- Guardar en historial local
    local entrada = {
        partnerName = state.targetName,
        gave        = state.myOffer,
        received    = state.theirOffer,
        timestamp   = os.time(),
        status      = "completed",
    }
    table.insert(state.history, 1, entrada)
    if #state.history > 10 then state.history[11] = nil end

    -- ── Animación de vuelo de items ───────────────────────────────────────────
    -- Posiciones aproximadas de los centros de cada panel (relativo a mainFrame)
    local myCenterX    = 6 + PANEL_W/2         -- ~159
    local theirCenterX = 6 + PANEL_W + 8 + PANEL_W/2  -- ~471
    local offerCenterY = PANELS_Y + PANELS_H/2  -- ~169

    local function lanzarParticula(fromX, toX, centerY, text)
        local p = mkL(ui.mainFrame, "FlyParticle",
            text or "🐉",
            UDim2.new(0,36,0,36), UDim2.new(0, fromX-18, 0, centerY-18),
            28, Color3.fromRGB(255,255,255), Enum.Font.GothamBold,
            Enum.TextXAlignment.Center)
        p.ZIndex = 7
        TweenService:Create(p, TW_FLY, {
            Position = UDim2.new(0, toX-18, 0, centerY-18)
        }):Play()
        task.delay(0.55, function() if p.Parent then p:Destroy() end end)
    end

    -- Items míos vuelan hacia la derecha
    for i = 1, #state.myOffer do
        task.spawn(function()
            task.wait((i-1) * 0.12)
            lanzarParticula(myCenterX, theirCenterX, offerCenterY + (i-1)*10)
        end)
    end
    -- Items del otro vuelan hacia la izquierda
    for i = 1, #state.theirOffer do
        task.spawn(function()
            task.wait((i-1) * 0.12 + 0.08)
            lanzarParticula(theirCenterX, myCenterX, offerCenterY - (i-1)*10)
        end)
    end

    task.wait(0.70)

    -- ── Overlay de éxito ──────────────────────────────────────────────────────
    local successOv = mkF(ui.mainFrame, "SuccessOverlay",
        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
        Color3.fromRGB(5,25,10), nil, 0)
    successOv.BackgroundTransparency = 0.25
    successOv.ZIndex = 9

    mkL(successOv, "SuccessTitle", "¡Intercambio exitoso! ✅",
        UDim2.new(1,0,0,40), UDim2.new(0,0,0.35,0),
        24, Color3.fromRGB(100,255,140), Enum.Font.GothamBold,
        Enum.TextXAlignment.Center)

    -- Listar items recibidos
    if result and result.received then
        local recY = 0.48
        for i, dragonId in ipairs(result.received) do
            local d   = DragonData.GetDragonById(dragonId)
            local nm  = d and d.name or dragonId
            local col = d and RARITY_COLORS[d.rarity] or TEXT_PRIMARY
            mkL(successOv, "Rec_"..i, "🐉 " .. nm,
                UDim2.new(1,-20,0,22), UDim2.new(0,10,0, 0),
                14, col, Enum.Font.GothamBold, Enum.TextXAlignment.Center
            ).Position = UDim2.new(0, 10, recY + (i-1)*0.07, 0)
        end
    end

    -- Banner "¡Nuevo dragón!" para cada dragón nuevo en catálogo
    if result and result.newDragons and #result.newDragons > 0 then
        for i, newId in ipairs(result.newDragons) do
            local d = DragonData.GetDragonById(newId)
            mkL(successOv, "New_"..i,
                "✨ ¡Nuevo dragón: " .. (d and d.name or newId) .. "!",
                UDim2.new(1,-20,0,20), UDim2.new(0,10, 0.72 + (i-1)*0.07, 0),
                13, Color3.fromRGB(255,220,60), Enum.Font.GothamBold,
                Enum.TextXAlignment.Center)
        end
    end

    -- Botón cerrar el overlay
    local closeOvBtn = mkB(successOv, "CloseOv", "Cerrar",
        UDim2.new(0,160,0,42), UDim2.new(0.5,-80,1,-56),
        BORDER_GOLD, Color3.fromRGB(15,10,25), 15)
    closeOvBtn.ZIndex = 10
    closeOvBtn.MouseButton1Click:Connect(function()
        TradeGUI.Close()
    end)
end

--------------------------------------------------------------------------------
-- TradeGUI.ShowTradeExpired()
-- Muestra mensaje de expiración y cierra el panel.
--------------------------------------------------------------------------------

function TradeGUI.ShowTradeExpired()
    setEstado("expired")
    showNotif("⏰ El intercambio expiró por tiempo", Color3.fromRGB(180,100,20), 3.5)
    task.delay(3.0, function()
        if state.tradeEstado == "expired" then
            TradeGUI.Close()
        end
    end)
end

--------------------------------------------------------------------------------
-- TradeGUI.UpdateCountdown(secondsLeft)
-- Actualiza el contador de expiración visible.
-- Cuando quedan <30s el texto parpadea en rojo.
--------------------------------------------------------------------------------

function TradeGUI.UpdateCountdown(secondsLeft)
    state.countdownGen = state.countdownGen + 1
    local gen          = state.countdownGen
    local remaining    = math.max(0, math.floor(secondsLeft))

    task.spawn(function()
        while state.countdownGen == gen and remaining >= 0 do
            if not ui.countdownLbl or not ui.countdownLbl.Parent then break end

            ui.countdownLbl.Text = fmtTime(remaining)

            -- Bajo 30 segundos → rojo y parpadeo
            if remaining <= 30 then
                ui.countdownLbl.TextColor3 = Color3.fromRGB(220,50,50)
                if not state.cdBlinkActive then
                    state.cdBlinkActive = true
                    task.spawn(function()
                        while state.cdBlinkActive and state.countdownGen == gen do
                            TweenService:Create(ui.countdownLbl, TW_BLINK,
                                { TextTransparency = 0.85 }):Play()
                            task.wait(0.30)
                            TweenService:Create(ui.countdownLbl, TW_BLINK,
                                { TextTransparency = 0 }):Play()
                            task.wait(0.30)
                        end
                    end)
                end
            else
                ui.countdownLbl.TextColor3  = Color3.fromRGB(200,200,200)
                ui.countdownLbl.TextTransparency = 0
            end

            if remaining == 0 then break end
            remaining = remaining - 1
            task.wait(1)
        end

        -- Si agotó el tiempo y el trade sigue activo, expirarlo localmente
        if state.countdownGen == gen and remaining <= 0
           and state.tradeEstado == "waiting" then
            TradeGUI.ShowTradeExpired()
        end
    end)
end

--------------------------------------------------------------------------------
-- TradeGUI.ShowTradeHistory()
-- Abre el panel lateral con los últimos 10 intercambios del jugador.
--------------------------------------------------------------------------------

function TradeGUI.ShowTradeHistory()
    -- Limpiar filas antiguas
    for _, c in ipairs(ui.histScroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end

    if #state.history == 0 then
        mkL(ui.histScroll, "EmptyLbl",
            "No hay intercambios recientes.",
            UDim2.new(1,-16,0,40), UDim2.new(0,8,0,10),
            13, TEXT_DIM, Enum.Font.Gotham)
    else
        for i, entry in ipairs(state.history) do
            local row = mkF(ui.histScroll, "Row_"..i,
                UDim2.new(1,-8,0,80), nil,
                Color3.fromRGB(20,15,35), BORDER_GOLD, 6)
            row.BackgroundTransparency = 0.3
            row.LayoutOrder = i

            -- Con quién y cuándo
            local ts = entry.timestamp
                and os.date("%d/%m %H:%M", entry.timestamp) or "—"
            mkL(row, "Partner",
                "Con: " .. (entry.partnerName or "?") .. "  •  " .. ts,
                UDim2.new(1,-8,0,18), UDim2.new(0,4,0,4),
                11, BORDER_GOLD, Enum.Font.GothamBold)

            -- Qué se dio
            local gaveTxt = "Diste: "
            for j, item in ipairs(entry.gave or {}) do
                local d = item.dragon
                gaveTxt = gaveTxt .. (d and d.name or item.id)
                if j < #entry.gave then gaveTxt = gaveTxt .. ", " end
            end
            mkL(row, "Gave", gaveTxt,
                UDim2.new(1,-8,0,16), UDim2.new(0,4,0,24),
                10, Color3.fromRGB(150,180,255), Enum.Font.Gotham)

            -- Qué se recibió
            local recTxt = "Recibiste: "
            for j, item in ipairs(entry.received or {}) do
                local d = item.dragon
                recTxt = recTxt .. (d and d.name or item.id)
                if j < #entry.received then recTxt = recTxt .. ", " end
            end
            mkL(row, "Received", recTxt,
                UDim2.new(1,-8,0,16), UDim2.new(0,4,0,42),
                10, Color3.fromRGB(255,160,140), Enum.Font.Gotham)

            -- Estado
            local stCol = entry.status == "completed"
                and Color3.fromRGB(80,200,100) or Color3.fromRGB(200,80,80)
            mkL(row, "Status", entry.status or "?",
                UDim2.new(1,-8,0,14), UDim2.new(0,4,0,60),
                10, stCol, Enum.Font.GothamMedium)
        end
    end

    -- Deslizar hacia adentro desde la derecha
    ui.histPanel.Position = UDim2.new(1,10,0.5,-220)
    TweenService:Create(ui.histPanel, TW_SLIDE, {
        Position = UDim2.new(1,-306,0.5,-220)
    }):Play()
end

--------------------------------------------------------------------------------
-- TradeGUI.ShowTradeLimit(remaining, resetIn)
-- Muestra un banner de límite de intercambios alcanzado.
-- remaining: trades restantes (0 si límite), resetIn: minutos para reset.
--------------------------------------------------------------------------------

function TradeGUI.ShowTradeLimit(remaining, resetIn)
    local msg = remaining > 0
        and ("⚠️ Intercambios restantes hoy: " .. remaining)
        or  ("🚫 Límite alcanzado — se resetea en " .. (resetIn or 60) .. " minutos")
    local col = remaining > 0
        and Color3.fromRGB(200,160,50) or Color3.fromRGB(220,60,60)
    showNotif(msg, col, 4.0)

    -- También actualizar el label de conteo en la barra de info
    if ui.tradesCountLbl then
        ui.tradesCountLbl.Text       = "Intercambios hoy: " .. state.tradesHoy
            .. "/" .. state.tradesLimite
        ui.tradesCountLbl.TextColor3 = remaining <= 0
            and Color3.fromRGB(220,80,80) or TEXT_DIM
    end
end

--------------------------------------------------------------------------------
-- INIT
-- Construye el UI y conecta todos los RemoteEvents del servidor.
--------------------------------------------------------------------------------

local function Init()
    crearUI()

    local Remotes = ReplicatedStorage:WaitForChild("Remotes")

    -- TradeProposed: otro jugador nos propone un intercambio
    Remotes:WaitForChild("TradeProposed").OnClientEvent:Connect(function(data)
        TradeGUI.OnReceiveProposal(data)
    end)

    -- TradeAccepted: el otro jugador aceptó nuestra propuesta → mostrar confirmación
    Remotes:WaitForChild("TradeAccepted").OnClientEvent:Connect(function(data)
        if not data then return end
        showNotif("✅ " .. state.targetName .. " aceptó tu propuesta — confirma el intercambio",
            Color3.fromRGB(100,220,100), 3.5)
        -- Poblar theirOffer si llegaron datos actualizados
        if data.receiverOffer or data.initiatorOffer then
            local offerSrc = state.amInitiator and data.receiverOffer or data.initiatorOffer
            state.theirOffer = {}
            for _, dragonId in ipairs((offerSrc and offerSrc.dragons) or {}) do
                local dragon = DragonData.GetDragonById(dragonId)
                if dragon then
                    state.theirOffer[#state.theirOffer+1] = {
                        type="dragon", id=dragonId, dragon=dragon
                    }
                end
            end
            renderOfertaPanel(state.theirOffer, ui.theirItemsArea, false)
        end
        TradeGUI.OnConfirm(data.tradeId or state.tradeId)
    end)

    -- TradeCancelled: el otro jugador canceló
    Remotes:WaitForChild("TradeCancelled").OnClientEvent:Connect(function(data)
        local reason = (data and data.cancelledBy)
            and (state.targetName .. " canceló el intercambio")
            or  "El intercambio fue cancelado"
        setEstado("cancelled")
        showNotif("✗ " .. reason, Color3.fromRGB(200,60,60), 3.5)
        task.delay(2.5, function()
            if state.tradeEstado == "cancelled" then
                TradeGUI.Close()
            end
        end)
    end)

    -- TradeCompleted: intercambio finalizado con éxito por el servidor
    Remotes:WaitForChild("TradeCompleted").OnClientEvent:Connect(function(data)
        TradeGUI.ShowTradeComplete(data)
    end)

    -- TradeExpired: timeout del servidor
    Remotes:WaitForChild("TradeExpired").OnClientEvent:Connect(function(_data)
        TradeGUI.ShowTradeExpired()
    end)

    -- TradeUpdated: el otro jugador modificó su oferta (durante negociación)
    Remotes:WaitForChild("TradeUpdated").OnClientEvent:Connect(function(data)
        if not data then return end
        showNotif("🔄 " .. state.targetName .. " actualizó su oferta",
            Color3.fromRGB(255,220,80))
        local offerSrc = state.amInitiator and data.receiverOffer or data.initiatorOffer
        if offerSrc then
            state.theirOffer = {}
            for _, dragonId in ipairs(offerSrc.dragons or {}) do
                local dragon = DragonData.GetDragonById(dragonId)
                if dragon then
                    state.theirOffer[#state.theirOffer+1] = {
                        type="dragon", id=dragonId, dragon=dragon
                    }
                end
            end
            renderOfertaPanel(state.theirOffer, ui.theirItemsArea, false)
            if ui.theirStatusLbl then
                ui.theirStatusLbl.Visible = #state.theirOffer == 0
            end
        end
    end)

    -- TradeCounterOffer: el otro jugador envió una contraoferta
    Remotes:WaitForChild("TradeCounterOffer").OnClientEvent:Connect(function(data)
        TradeGUI.ShowCounterOfferReceived(data)
    end)
end

Init()

return TradeGUI
