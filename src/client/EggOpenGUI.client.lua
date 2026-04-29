--------------------------------------------------------------------------------
-- EggOpenGUI.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Gestiona toda la interfaz de recolección, incubación y reveal de huevos.
--
-- FLUJO:
--   EggReady → [Pantalla 1] Recolectar / Vender sin incubar
--           → [Pantalla 2] Probabilidades + Incubar / Acelerar / Vender
--           → [Pantalla 3] Reveal animado del dragón resultante
--
-- REMOTEFUNCTIONS USADAS:
--   RequestCollectEgg(nestIndex)       → { ok, sellValue, incubationSeconds, garantiaRareza }
--   RequestStartIncubation(nestIndex)  → { ok }
--   RequestSellEgg(nestIndex)          → { ok, goldGained }
--   RequestSpeedUpIncubation(nestIndex)→ { ok, gemCost }
--   RequestPlaceDragonInNest(dragonId, nestIndex) → { ok, message }
--   RequestSaveDragonToInventory(dragonId)        → { ok }
--   RequestGetNestStatus()             → { [nestIndex] = dragonId | nil }
--
-- EVENTOS ESCUCHADOS:
--   EggReady      → ShowEggReady(nestIndex, parentDragonId)
--   EggStarted    → actualiza la cola de incubación
--   EggIncubated  → ShowReveal(dragonData, isNew)
--------------------------------------------------------------------------------

local TweenService      = game:GetService("TweenService")
local SoundService      = game:GetService("SoundService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RARITIES = Constants.RARITIES

--------------------------------------------------------------------------------
-- Paleta de colores (consistente con HUD, ShopGUI, CatalogueGUI)
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
    fire = Color3.fromRGB(255, 90, 20),   fuego      = Color3.fromRGB(255,  90,  20),
    water = Color3.fromRGB(30, 130, 255), agua       = Color3.fromRGB( 30, 130, 255),
    ice = Color3.fromRGB(180, 230, 255),  hielo      = Color3.fromRGB(180, 230, 255),
    thunder = Color3.fromRGB(255, 240, 50), trueno   = Color3.fromRGB(255, 240,  50),
    nature = Color3.fromRGB(50, 200, 80), naturaleza = Color3.fromRGB( 50, 200,  80),
    shadow = Color3.fromRGB(130, 50, 200), sombra    = Color3.fromRGB(130,  50, 200),
    celestial = Color3.fromRGB(255, 220, 100),
    void = Color3.fromRGB(80, 20, 160),   vacio      = Color3.fromRGB( 80,  20, 160),
}

local ELEMENT_EMOJI = {
    fire = "🔥", fuego = "🔥",
    water = "💧", agua = "💧",
    ice = "❄️", hielo = "❄️",
    thunder = "⚡", trueno = "⚡",
    nature = "🌿", naturaleza = "🌿",
    shadow = "🌑", sombra = "🌑",
    celestial = "✨",
    void = "🌀", vacio = "🌀",
}

local RARITY_ORDER = { common=1, uncommon=2, rare=3, epic=4, legendary=5, mythic=6 }

local PANEL_BG     = Color3.fromRGB( 15,  10,  25)
local PANEL_BG2    = Color3.fromRGB( 22,  16,  38)
local BORDER_GOLD  = Color3.fromRGB(200, 160,  50)
local TEXT_PRIMARY = Color3.fromRGB(255, 240, 200)
local TEXT_HEADER  = Color3.fromRGB(255, 215,  80)
local TEXT_DIM     = Color3.fromRGB(160, 148, 120)

-- Duración mínima del reveal por rareza (segundos) — los más raros no se apresuran
local REVEAL_DURATION = {
    common = 1.8, uncommon = 2.0, rare = 2.4,
    epic = 2.8, legendary = 3.5, mythic = 5.0,
}

-- Número de partículas por rareza en ShowRarityEffect
local PARTICLE_COUNT = {
    common = 8, uncommon = 12, rare = 18,
    epic = 24, legendary = 36, mythic = 52,
}

-- IDs de sonido (sustituir por assets reales del juego)
-- Formato: rbxassetid://ID
local SOUND_IDS = {
    egg_ready   = "9068591695",   -- campana suave
    crack       = "5801202290",   -- cristal quebrándose
    reveal_common     = "9068565466",
    reveal_rare       = "9068578382",
    reveal_legendary  = "3740851102",   -- fanfarria corta
    reveal_mythic     = "1843463817",   -- sonido épico
}

--------------------------------------------------------------------------------
-- Tweens reutilizables
--------------------------------------------------------------------------------

local TW_FAST   = TweenInfo.new(0.18, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TW_MED    = TweenInfo.new(0.32, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TW_SLOW   = TweenInfo.new(0.55, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TW_BOUNCE = TweenInfo.new(0.45, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TW_SLIDE  = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TW_LINEAR = TweenInfo.new(0.20, Enum.EasingStyle.Linear,Enum.EasingDirection.Out)
local TW_SHAKE  = TweenInfo.new(0.07, Enum.EasingStyle.Linear,Enum.EasingDirection.InOut)
local TW_BAR    = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- Ancho del modal para pantallas 1 y 2
local MODAL_W = 440

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

local state = {
    huevoActual    = nil,   -- datos del huevo en pantalla (nestIndex, parentDragon, etc.)
    incubando      = false, -- true mientras hay un countdown de incubación activo
    incubaGen      = 0,     -- generación del countdown de incubación (para cancelarlo)
    pulsoGen       = 0,     -- generación del loop de pulso del huevo (pantalla 1)
    tembloreGen    = 0,     -- generación del loop de temblor durante incubación
    queueGen       = 0,     -- generación del tick de la cola
    dragonReveal   = nil,   -- dragón que se está mostrando en el reveal
    revealActivo   = false, -- true mientras el reveal está en pantalla
    -- Cola de incubaciones activas: [nestIndex] = { parentId, readyAt }
    cola           = {},
    -- [nestIndex] = true cuando el jugador cerró el popup sin recoger
    popupDismissed = {},
}

-- Referencias a frames creados en crearUI()
local ui = {}

-- Módulo a exportar
local EggOpenGUI = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

-- Formatea número con separadores de miles
local function fmtNum(n)
    n = math.floor(n or 0)
    if n >= 1_000_000 then return ("%.1fM"):format(n / 1_000_000) end
    if n >= 10_000    then return ("%.1fK"):format(n / 1_000) end
    local s, r = tostring(n), ""
    for i = 1, #s do
        if i > 1 and (#s - i + 1) % 3 == 0 then r = r .. "," end
        r = r .. s:sub(i, i)
    end
    return r
end

-- Formatea segundos a "MM:SS" o "H:MM:SS"
local function fmtTime(seg)
    seg = math.max(0, math.floor(seg or 0))
    if seg < 3600 then
        return ("%d:%02d min"):format(math.floor(seg/60), seg % 60)
    end
    return ("%dh %02dm"):format(math.floor(seg/3600), math.floor((seg%3600)/60))
end

-- Genera estrellas de rareza
local function rarityStars(rarity)
    local n = RARITY_ORDER[rarity] or 1
    return string.rep("★", n) .. string.rep("☆", 6 - n)
end

-- Calcula el valor de venta del huevo (igual que servidor: gps × 100 × 0.30)
local function calcSellValue(parentDragon)
    if not parentDragon then return 0 end
    return math.floor(parentDragon.goldPerSecond * 100 * 0.30)
end

-- Calcula el coste de acelerar en gemas (1 gema por cada 60 seg restantes)
local function calcSpeedCost(secondsLeft)
    return math.max(1, math.floor(secondsLeft / 60))
end

-- Crea un Frame con UICorner y UIStroke opcionales
local function mkF(parent, name, size, pos, bg, borderClr, radius)
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
local function mkL(parent, name, text, size, pos, fs, col, font, xA)
    local l = Instance.new("TextLabel")
    l.Name               = name
    l.Size               = size or UDim2.new(1,0,0,24)
    l.Position           = pos  or UDim2.new(0,0,0,0)
    l.Text               = text or ""
    l.TextSize           = fs   or 14
    l.TextColor3         = col  or TEXT_PRIMARY
    l.Font               = font or Enum.Font.GothamMedium
    l.BackgroundTransparency = 1
    l.TextXAlignment     = xA  or Enum.TextXAlignment.Center
    l.TextWrapped        = true
    l.Parent             = parent
    return l
end

-- Crea un TextButton estilizado
local function mkB(parent, name, text, size, pos, bg, textClr, fs)
    local b = Instance.new("TextButton")
    b.Name             = name
    b.Size             = size or UDim2.new(1,-20,0,44)
    b.Position         = pos  or UDim2.new(0,10,0,0)
    b.Text             = text or ""
    b.TextSize         = fs   or 15
    b.TextColor3       = textClr or Color3.fromRGB(15,10,25)
    b.BackgroundColor3 = bg   or BORDER_GOLD
    b.Font             = Enum.Font.GothamBold
    b.BorderSizePixel  = 0
    b.AutoButtonColor  = false
    b.Parent           = parent
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0,8)
    c.Parent = b
    return b
end

-- Reproduce un sonido (autodesctruye al terminar)
local function playSound(soundId, volume, pitch)
    if not soundId or soundId == "" then return end
    local s = Instance.new("Sound")
    s.SoundId = "rbxassetid://" .. soundId
    s.Volume  = volume or 0.6
    s.Pitch   = pitch  or 1
    s.Parent  = SoundService
    s:Play()
    s.Ended:Connect(function() s:Destroy() end)
end

-- Efecto typewriter: escribe el texto letra a letra
local function typewriter(label, text, delay)
    delay = delay or 0.045
    label.Text = ""
    for i = 1, #text do
        label.Text = text:sub(1, i)
        task.wait(delay)
    end
end

--------------------------------------------------------------------------------
-- CONSTRUCCIÓN DEL UI ESTÁTICO (llamado una vez desde Init)
--------------------------------------------------------------------------------

local function crearUI()
    -- ScreenGui raíz
    local sg = Instance.new("ScreenGui")
    sg.Name           = "EggOpenGUI"
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Enabled        = false
    sg.Parent         = playerGui
    ui.screenGui      = sg

    -- Fondo oscuro semi-transparente (pantallas 1 y 2)
    local bg = Instance.new("Frame")
    bg.Name               = "BgOverlay"
    bg.Size               = UDim2.new(1,0,1,0)
    bg.BackgroundColor3   = Color3.fromRGB(0,0,0)
    bg.BackgroundTransparency = 0.55
    bg.BorderSizePixel    = 0
    bg.ZIndex             = 1
    bg.Parent             = sg
    ui.bgOverlay = bg

    -- Modal centrado para pantallas 1 y 2 (tamaño dinámico)
    local modal = mkF(sg, "Modal",
        UDim2.new(0, MODAL_W, 0, 320),
        UDim2.new(0.5, -MODAL_W/2, 0.5, -160),
        PANEL_BG, BORDER_GOLD, 12)
    modal.ZIndex           = 3
    modal.ClipsDescendants = false
    ui.modal = modal

    -- Frame interno del modal donde se construye el contenido
    local inner = Instance.new("Frame")
    inner.Name               = "Inner"
    inner.Size               = UDim2.new(1,0,1,0)
    inner.BackgroundTransparency = 1
    inner.BorderSizePixel    = 0
    inner.Parent             = modal
    ui.modalInner = inner

    -- Frame fullscreen para el reveal (pantalla 3), separado del modal
    local revealFrame = Instance.new("Frame")
    revealFrame.Name               = "RevealFrame"
    revealFrame.Size               = UDim2.new(1,0,1,0)
    revealFrame.BackgroundColor3   = Color3.fromRGB(0,0,0)
    revealFrame.BackgroundTransparency = 1
    revealFrame.BorderSizePixel    = 0
    revealFrame.ZIndex             = 10
    revealFrame.Visible            = false
    revealFrame.Parent             = sg
    ui.revealFrame = revealFrame

    -- Panel lateral de cola de incubación (derecha de la pantalla)
    local queuePanel = mkF(sg, "QueuePanel",
        UDim2.new(0,280,0,400),
        UDim2.new(1,0,0.5,-200),    -- inicialmente fuera de pantalla
        PANEL_BG2, BORDER_GOLD, 10)
    queuePanel.ZIndex   = 5
    queuePanel.Visible  = false
    ui.queuePanel = queuePanel

    mkL(queuePanel, "QueueTitle", "⏳ Incubaciones activas",
        UDim2.new(1,-16,0,22), UDim2.new(0,8,0,8),
        13, BORDER_GOLD, Enum.Font.GothamBold)

    local queueScroll = Instance.new("ScrollingFrame")
    queueScroll.Name               = "QueueScroll"
    queueScroll.Size               = UDim2.new(1,-8,1,-38)
    queueScroll.Position           = UDim2.new(0,4,0,34)
    queueScroll.BackgroundTransparency = 1
    queueScroll.BorderSizePixel    = 0
    queueScroll.ScrollBarThickness = 3
    queueScroll.ScrollBarImageColor3 = BORDER_GOLD
    queueScroll.CanvasSize         = UDim2.new(0,0,0,0)
    queueScroll.Parent             = queuePanel
    ui.queueScroll = queueScroll

    local queueLayout = Instance.new("UIListLayout")
    queueLayout.SortOrder  = Enum.SortOrder.LayoutOrder
    queueLayout.Padding    = UDim.new(0,4)
    queueLayout.Parent     = queueScroll
    queueLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        queueScroll.CanvasSize = UDim2.new(0,0,0, queueLayout.AbsoluteContentSize.Y + 8)
    end)

    -- Botón cerrar la cola
    local queueClose = mkB(queuePanel, "QueueClose", "✕",
        UDim2.new(0,28,0,22), UDim2.new(1,-32,0,6),
        Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 13)
    queueClose.MouseButton1Click:Connect(function()
        state.queueGen = state.queueGen + 1
        TweenService:Create(ui.queuePanel, TW_SLIDE, {
            Position = UDim2.new(1,0,0.5,-200)
        }):Play()
        task.delay(0.32, function() ui.queuePanel.Visible = false end)
    end)

    -- Label de notificación flotante (aparece en la parte superior del modal)
    local notif = mkL(sg, "NotifLabel", "",
        UDim2.new(0,380,0,36), UDim2.new(0.5,-190,0,-50),
        14, Color3.fromRGB(100,220,100), Enum.Font.GothamBold)
    notif.ZIndex      = 15
    notif.TextWrapped = false
    local notifBg = Instance.new("Frame")
    notifBg.Size             = UDim2.new(1,0,1,0)
    notifBg.BackgroundColor3 = Color3.fromRGB(10,30,15)
    notifBg.BorderSizePixel  = 0
    notifBg.ZIndex           = 14
    notifBg.Parent           = notif
    local notifC = Instance.new("UICorner")
    notifC.CornerRadius = UDim.new(0,8)
    notifC.Parent       = notifBg
    ui.notifLabel = notif
    notif.Visible = false  -- oculto hasta que showNotif lo active
end

-- Limpia el contenido del modal para la siguiente pantalla
local function limpiarModal()
    for _, c in ipairs(ui.modalInner:GetChildren()) do c:Destroy() end
end

-- Redimensiona y centra el modal con animación
local function redimModal(w, h)
    ui.modal.Size     = UDim2.new(0, w, 0, h)
    ui.modal.Position = UDim2.new(0.5, -w/2, 0.5, -h/2)
end

-- Abre el ScreenGui y muestra el overlay + modal
local function mostrarModal(w, h)
    ui.revealFrame.Visible        = false
    -- Resetear tamaño/posición ANTES de mostrar para evitar destello en posición anterior
    ui.modal.Size     = UDim2.new(0,1,0,1)
    ui.modal.Position = UDim2.new(0.5,0,0.5,0)
    -- Ocultar notif flotante de sesiones anteriores (Visible=false ignora tweens activos)
    if ui.notifLabel then
        ui.notifLabel.Visible = false
    end
    ui.bgOverlay.BackgroundTransparency = 1
    ui.bgOverlay.Visible          = true
    ui.modal.Visible              = true
    ui.screenGui.Enabled          = true
    TweenService:Create(ui.bgOverlay, TW_MED, { BackgroundTransparency = 0.55 }):Play()
    redimModal(w, h)
    -- Entrada del modal con escala
    TweenService:Create(ui.modal, TW_BOUNCE, {
        Size     = UDim2.new(0, w, 0, h),
        Position = UDim2.new(0.5, -w/2, 0.5, -h/2),
    }):Play()
end

-- Cierra el modal con animación y, opcionalmente, desactiva el ScreenGui
local function cerrarModal(desactivar)
    state.pulsoGen  = state.pulsoGen  + 1
    state.incubaGen = state.incubaGen + 1
    TweenService:Create(ui.modal, TW_MED, {
        Size     = UDim2.new(0,1,0,1),
        Position = UDim2.new(0.5,0,0.5,0),
    }):Play()
    TweenService:Create(ui.bgOverlay, TW_MED, { BackgroundTransparency = 1 }):Play()
    if desactivar then
        task.delay(0.25, function()
            ui.screenGui.Enabled = false
        end)
    end
end

-- Muestra la notificación flotante y la oculta automáticamente
-- Dispara una notificación en el sistema de notificaciones del HUD (esquina superior derecha).
-- notifType: "success" | "warning" | "error" | "event"
local function hudNotif(msg, notifType)
    local hudGui = playerGui:FindFirstChild("DragonRoostHUD")
    local ev = hudGui and hudGui:FindFirstChild("HUDNotify")
    if ev then
        ev:Fire(msg, notifType or "success")
    end
end

local function showNotif(msg, color, duracion)
    local lbl = ui.notifLabel
    lbl.Visible    = true
    lbl.Text       = "  " .. msg .. "  "
    lbl.TextColor3 = color or Color3.fromRGB(100,220,100)
    local bg = lbl:FindFirstChildWhichIsA("Frame")
    if bg then
        bg.BackgroundColor3 = color and Color3.fromRGB(10,10,10)
            or Color3.fromRGB(10,30,15)
    end
    lbl.Position   = UDim2.new(0.5,-190,0,-50)
    TweenService:Create(lbl, TW_BOUNCE, {
        Position = UDim2.new(0.5,-190,0,14)
    }):Play()
    task.delay(duracion or 2.5, function()
        TweenService:Create(lbl, TW_MED, {
            Position = UDim2.new(0.5,-190,0,-50)
        }):Play()
    end)
end

--------------------------------------------------------------------------------
-- EggOpenGUI.ShowEggReady(nestIndex, parentDragonId)
-- PANTALLA 1 — Muestra el modal de huevo listo.
-- El huevo pulsa con un brillo en loop. El botón RECOLECTAR llama al servidor.
-- El botón "Vender sin incubar" llama RequestSellEgg directamente.
--------------------------------------------------------------------------------

function EggOpenGUI.ShowEggReady(nestIndex, parentDragonId)
    local parentDragon = DragonData.GetDragonById(parentDragonId)
    if not parentDragon then return end

    local sellValue = calcSellValue(parentDragon)

    -- Guardar estado del huevo actual
    state.huevoActual = {
        nestIndex    = nestIndex,
        parentId     = parentDragonId,
        parentDragon = parentDragon,
        sellValue    = sellValue,
    }

    limpiarModal()
    mostrarModal(MODAL_W, 330)

    local inner = ui.modalInner

    -- ── Header ────────────────────────────────────────────────────────────────
    local headerBg = mkF(inner, "Header",
        UDim2.new(1,0,0,52), UDim2.new(0,0,0,0),
        Color3.fromRGB(20,14,38), nil, 0)

    mkL(headerBg, "Title", "🥚  HUEVO LISTO",
        UDim2.new(1,-60,1,0), UDim2.new(0,14,0,0),
        20, BORDER_GOLD, Enum.Font.GothamBold)

    mkL(headerBg, "Subtitle",
        "Nido " .. nestIndex .. "  —  " .. parentDragon.name,
        UDim2.new(1,-14,0,18), UDim2.new(0,7,0,34),
        12, TEXT_DIM, Enum.Font.Gotham)

    -- Botón cerrar (X) en el header
    local xBtn = mkB(inner, "CloseX", "✕",
        UDim2.new(0,32,0,32), UDim2.new(1,-40,0,10),
        Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 15)
    xBtn.MouseButton1Click:Connect(function()
        -- Marcar como descartado para que no vuelva a aparecer solo
        if state.huevoActual then
            state.popupDismissed[state.huevoActual.nestIndex] = true
        end
        cerrarModal(true)
    end)

    -- ── Zona del huevo (con animación de pulso) ────────────────────────────────
    local eggZone = mkF(inner, "EggZone",
        UDim2.new(1,0,0,150), UDim2.new(0,0,0,52),
        Color3.fromRGB(20,16,36), nil, 0)

    -- Anillo de brillo detrás del huevo
    local glowRing = mkF(eggZone, "GlowRing",
        UDim2.new(0,110,0,110), UDim2.new(0.5,-55,0.5,-55),
        Color3.fromRGB(255,220,80), nil, 55)
    glowRing.BackgroundTransparency = 0.82
    glowRing.ZIndex = 1

    -- Emoji del huevo (grande)
    local eggLbl = mkL(eggZone, "EggEmoji", "🥚",
        UDim2.new(0,90,0,90), UDim2.new(0.5,-45,0.5,-45),
        72, TEXT_PRIMARY, Enum.Font.GothamBold)
    eggLbl.ZIndex = 2

    -- Rareza del dragón padre (pista del elemento)
    local elemEmoji = ELEMENT_EMOJI[parentDragon.element] or ""
    mkL(eggZone, "ElemLbl",
        elemEmoji .. " " .. parentDragon.element:sub(1,1):upper()
            .. parentDragon.element:sub(2) .. " — "
            .. parentDragon.rarity:sub(1,1):upper() .. parentDragon.rarity:sub(2),
        UDim2.new(1,0,0,20), UDim2.new(0,0,1,-22),
        12, RARITY_COLORS[parentDragon.rarity] or TEXT_DIM,
        Enum.Font.GothamMedium)

    -- ── Loop de pulso del huevo ────────────────────────────────────────────────
    state.pulsoGen = state.pulsoGen + 1
    local gen = state.pulsoGen
    task.spawn(function()
        while state.pulsoGen == gen and eggLbl.Parent do
            -- Crecer con brillo
            TweenService:Create(eggLbl, TweenInfo.new(0.55, Enum.EasingStyle.Sine,
                Enum.EasingDirection.InOut), { TextSize = 82 }):Play()
            TweenService:Create(glowRing, TweenInfo.new(0.55, Enum.EasingStyle.Sine),
                { BackgroundTransparency = 0.65 }):Play()
            task.wait(0.58)
            if state.pulsoGen ~= gen then break end
            -- Volver al tamaño normal
            TweenService:Create(eggLbl, TweenInfo.new(0.55, Enum.EasingStyle.Sine,
                Enum.EasingDirection.InOut), { TextSize = 72 }):Play()
            TweenService:Create(glowRing, TweenInfo.new(0.55, Enum.EasingStyle.Sine),
                { BackgroundTransparency = 0.82 }):Play()
            task.wait(0.60)
        end
    end)

    -- ── Botones ───────────────────────────────────────────────────────────────
    local btnArea = mkF(inner, "BtnArea",
        UDim2.new(1,0,0,118), UDim2.new(0,0,0,204),
        Color3.fromRGB(15,10,25), nil, 0)

    -- Botón principal: RECOLECTAR
    local collectBtn = mkB(btnArea, "CollectBtn",
        "🥚  RECOLECTAR",
        UDim2.new(1,-20,0,46), UDim2.new(0,10,0,10),
        Color3.fromRGB(30,80,30), Color3.fromRGB(180,255,180), 17)
    collectBtn.MouseButton1Click:Connect(function()
        collectBtn.Active = false
        collectBtn.Text   = "Recolectando..."

        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        local ok, result = pcall(function()
            return Remotes:WaitForChild("RequestCollectEgg"):InvokeServer(nestIndex)
        end)

        if ok and result and result.ok then
            -- Huevo guardado en inventario → cerrar popup y notificar en el HUD
            playSound(SOUND_IDS.egg_ready, 0.5)
            cerrarModal(true)
            hudNotif("¡Huevo guardado en el inventario! 🥚", "success")
        else
            collectBtn.Active = true
            collectBtn.Text   = "🥚  RECOLECTAR"
            local errMsg = (type(result) == "table" and result.error) or "Inventario lleno"
            hudNotif(errMsg, "error")
        end
    end)

    -- Botón secundario: Vender sin incubar
    local sellBtn = mkB(btnArea, "SellBtn",
        "Vender sin incubar: " .. fmtNum(sellValue) .. " 🪙",
        UDim2.new(1,-20,0,36), UDim2.new(0,10,0,62),
        Color3.fromRGB(40,28,10), Color3.fromRGB(200,160,60), 14)
    sellBtn.MouseButton1Click:Connect(function()
        sellBtn.Active = false

        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        local ok, result = pcall(function()
            return Remotes:WaitForChild("RequestSellEgg"):InvokeServer(nestIndex)
        end)

        if ok and result and result.ok then
            showNotif("Vendido: +" .. fmtNum(result.goldGained or sellValue) .. " 🪙",
                Color3.fromRGB(255,200,60))
            cerrarModal(true)
        else
            sellBtn.Active = true
            showNotif("Error al vender", Color3.fromRGB(200,60,60))
        end
    end)

    -- Sonido de huevo listo
    playSound(SOUND_IDS.egg_ready, 0.4)
end

--------------------------------------------------------------------------------
-- EggOpenGUI.ShowProbabilities(eggData)
-- PANTALLA 2 — Muestra las probabilidades de eclosión animadas.
-- Resalta la rareza más probable con borde brillante.
-- Si hay garantía de rareza muestra banner especial.
--------------------------------------------------------------------------------

function EggOpenGUI.ShowProbabilities(eggData)
    local parentDragon = eggData.parentDragon
    if not parentDragon then return end

    state.pulsoGen = state.pulsoGen + 1  -- cancela pulso de pantalla 1

    limpiarModal()
    mostrarModal(MODAL_W, 500)

    local inner = ui.modalInner

    -- ── Header ────────────────────────────────────────────────────────────────
    local headerBg = mkF(inner, "Header",
        UDim2.new(1,0,0,48), UDim2.new(0,0,0,0),
        Color3.fromRGB(20,14,38), nil, 0)

    mkL(headerBg, "Title",
        "🥚 Huevo de " .. parentDragon.name
        .. " (" .. parentDragon.rarity:sub(1,1):upper() .. parentDragon.rarity:sub(2) .. ")",
        UDim2.new(1,-50,0,28), UDim2.new(0,10,0,6),
        15, BORDER_GOLD, Enum.Font.GothamBold)

    mkL(headerBg, "SubLbl", "¿Qué puede salir?",
        UDim2.new(1,-50,0,18), UDim2.new(0,10,0,30),
        12, TEXT_DIM, Enum.Font.Gotham)

    -- Botón cerrar
    local xBtn = mkB(inner, "CloseX", "✕",
        UDim2.new(0,32,0,32), UDim2.new(1,-40,0,8),
        Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 15)
    xBtn.MouseButton1Click:Connect(function() cerrarModal(true) end)

    -- ── Banner de boost de rareza (si hay garantía activa) ────────────────────
    local barrasOffsetY = 52
    if eggData.garantiaRareza then
        local banner = mkF(inner, "GuaranteeBanner",
            UDim2.new(1,-14,0,28), UDim2.new(0,7,0,54),
            Color3.fromRGB(30,20,60), Color3.fromRGB(160,80,220), 6)
        mkL(banner, "BannerLbl",
            "⚡ Rareza mínima garantizada: "
                .. eggData.garantiaRareza:sub(1,1):upper()
                .. eggData.garantiaRareza:sub(2),
            UDim2.new(1,-10,1,0), UDim2.new(0,5,0,0),
            12, Color3.fromRGB(200,150,255), Enum.Font.GothamBold)
        barrasOffsetY = 88
    end

    -- ── Barras de probabilidad ────────────────────────────────────────────────
    local chances = RARITIES.HatchChances[parentDragon.rarity] or {}

    -- Determinar rareza más probable (para el borde brillante)
    local maxPct, rarMasProb = 0, "common"
    for r, p in pairs(chances) do
        if p > maxPct then maxPct = p ; rarMasProb = r end
    end

    for bi, r in ipairs(RARITIES.Order) do
        local pct    = chances[r] or 0
        local pctStr = string.format("%.1f%%", pct * 100)
        local esMasProb = (r == rarMasProb)

        -- Fila de barra
        local row = mkF(inner, "Row_" .. r,
            UDim2.new(1,-14,0,22),
            UDim2.new(0,7,0, barrasOffsetY + (bi-1) * 26),
            esMasProb and Color3.fromRGB(30,24,52) or Color3.fromRGB(0,0,0,0),
            esMasProb and RARITY_COLORS[r] or nil,
            esMasProb and 5 or 0)
        row.BackgroundTransparency = esMasProb and 0.5 or 1

        -- Nombre de rareza
        mkL(row, "RarLbl",
            r:sub(1,1):upper() .. r:sub(2),
            UDim2.new(0,72,1,0), UDim2.new(0,4,0,0),
            11, RARITY_COLORS[r] or TEXT_PRIMARY, Enum.Font.Gotham,
            Enum.TextXAlignment.Left)

        -- Fondo de la barra
        local barBg = mkF(row, "BarBg",
            UDim2.new(1,-122,0,10), UDim2.new(0,76,0.5,-5),
            Color3.fromRGB(35,28,50), nil, 3)
        barBg.ClipsDescendants = true

        -- Fill animado (empieza en 0)
        local barFill = mkF(barBg, "Fill",
            UDim2.new(0,0,1,0), UDim2.new(0,0,0,0),
            RARITY_COLORS[r] or TEXT_PRIMARY, nil, 3)

        -- Porcentaje
        mkL(row, "PctLbl", pctStr,
            UDim2.new(0,42,1,0), UDim2.new(1,-44,0,0),
            11, TEXT_DIM, Enum.Font.GothamMedium, Enum.TextXAlignment.Right)

        -- Animar fill con delay escalonado
        local captPct = pct
        task.spawn(function()
            task.wait(0.05 + (bi-1) * 0.06)
            TweenService:Create(barFill, TW_BAR, {
                Size = UDim2.new(captPct, 0, 1, 0)
            }):Play()
        end)
    end

    -- ── Elemento posible ──────────────────────────────────────────────────────
    local elemY = barrasOffsetY + 6 * 26 + 4
    local elemEmoji = ELEMENT_EMOJI[parentDragon.element] or ""
    mkL(inner, "ElemHint",
        "Elemento posible: " .. elemEmoji .. " "
            .. parentDragon.element:sub(1,1):upper() .. parentDragon.element:sub(2),
        UDim2.new(1,-14,0,20), UDim2.new(0,7,0, elemY),
        12, ELEMENT_COLORS[parentDragon.element] or TEXT_DIM,
        Enum.Font.GothamMedium)

    -- ── Botones ───────────────────────────────────────────────────────────────
    local btnY = elemY + 26

    -- Incubar (botón principal)
    local incubSeconds = eggData.incubationSeconds or parentDragon.incubationSeconds or 300
    local incubBtn = mkB(inner, "IncubBtn",
        "🥚  INCUBAR  —  " .. fmtTime(incubSeconds),
        UDim2.new(1,-20,0,44), UDim2.new(0,10,0, btnY),
        Color3.fromRGB(15,50,100), Color3.fromRGB(160,210,255), 17)
    incubBtn.MouseButton1Click:Connect(function()
        incubBtn.Active = false
        incubBtn.Text   = "Iniciando..."

        local Remotes = ReplicatedStorage:WaitForChild("Remotes")
        local ok, result = pcall(function()
            return Remotes:WaitForChild("RequestStartIncubation")
                :InvokeServer(eggData.eggIndex)
        end)

        if ok and result and result.ok then
            EggOpenGUI.StartIncubation(eggData)
        else
            incubBtn.Active = true
            incubBtn.Text   = "🥚  INCUBAR  —  " .. fmtTime(incubSeconds)
            showNotif("Error al iniciar incubación", Color3.fromRGB(200,60,60))
        end
    end)

    -- Acelerar (requiere gemas) — solo si hay nido activo (no aplica desde inventario)
    local gemCost = calcSpeedCost(incubSeconds)
    if eggData.nestIndex then
        local accelBtn = mkB(inner, "AccelBtn",
            "⚡ Acelerar  —  " .. gemCost .. " 💎",
            UDim2.new(1,-20,0,36), UDim2.new(0,10,0, btnY + 50),
            Color3.fromRGB(30,40,90), Color3.fromRGB(150,190,255), 14)
        accelBtn.MouseButton1Click:Connect(function()
            accelBtn.Text   = "¿Confirmar " .. gemCost .. " 💎?"
            accelBtn.Active = false
            task.delay(0.10, function()
                local Remotes = ReplicatedStorage:WaitForChild("Remotes")
                local ok, result = pcall(function()
                    return Remotes:WaitForChild("RequestSpeedUpIncubation")
                        :InvokeServer(eggData.nestIndex)
                end)
                if ok and result and result.ok then
                    showNotif("¡Incubación acelerada!", Color3.fromRGB(100,160,255))
                    EggOpenGUI.StartIncubation(eggData)
                else
                    accelBtn.Active = true
                    accelBtn.Text   = "⚡ Acelerar  —  " .. gemCost .. " 💎"
                    showNotif("Gemas insuficientes", Color3.fromRGB(200,60,60))
                end
            end)
        end)
    end

    -- Vender (posición dinámica: junto a Incubar si no hay Acelerar)
    local sellOffsetY = eggData.nestIndex and (btnY + 92) or (btnY + 50)
    local sellBtn = mkB(inner, "SellBtn",
        "Vender: " .. fmtNum(eggData.sellValue) .. " 🪙",
        UDim2.new(1,-20,0,32), UDim2.new(0,10,0, sellOffsetY),
        Color3.fromRGB(40,28,10), Color3.fromRGB(200,160,60), 13)
    sellBtn.MouseButton1Click:Connect(function()
        sellBtn.Active = false
        local Remotes  = ReplicatedStorage:WaitForChild("Remotes")
        local ok, result = pcall(function()
            return Remotes:WaitForChild("RequestSellEgg"):InvokeServer(eggData.eggIndex, true)
        end)
        if ok and result and result.ok then
            hudNotif("Vendido: +" .. fmtNum(result.goldGained or eggData.sellValue) .. " 🪙", "success")
            local invEvt = playerGui:FindFirstChild("HuevoInventarioVendido")
            if invEvt then invEvt:Fire(eggData.eggIndex) end
            cerrarModal(true)
        else
            sellBtn.Active = true
            showNotif("Error al vender", Color3.fromRGB(200,60,60))
        end
    end)
end

--------------------------------------------------------------------------------
-- EggOpenGUI.StartIncubation(eggData)
-- Transición a la vista de countdown de incubación.
-- El huevo tiembla suavemente mientras espera. El botón de acelerar se actualiza.
--------------------------------------------------------------------------------

function EggOpenGUI.StartIncubation(eggData)
    local parentDragon = eggData.parentDragon
    if not parentDragon then return end

    state.incubaGen  = state.incubaGen + 1
    local localGen   = state.incubaGen
    state.incubando  = true
    state.pulsoGen   = state.pulsoGen + 1  -- cancela pulsos anteriores

    limpiarModal()
    mostrarModal(MODAL_W, 260)

    local inner = ui.modalInner

    -- Header
    local headerBg = mkF(inner, "Header",
        UDim2.new(1,0,0,46), UDim2.new(0,0,0,0),
        Color3.fromRGB(20,14,38), nil, 0)
    mkL(headerBg, "Title", "⏳ Incubando...",
        UDim2.new(1,-50,1,0), UDim2.new(0,14,0,0),
        18, BORDER_GOLD, Enum.Font.GothamBold)
    mkL(headerBg, "Sub", parentDragon.name .. (eggData.nestIndex and ("  •  Nido " .. eggData.nestIndex) or "  •  Inventario"),
        UDim2.new(1,-14,0,16), UDim2.new(0,7,0,30),
        12, TEXT_DIM, Enum.Font.Gotham)

    -- Huevo con zona de temblor
    local eggZone = mkF(inner, "EggZone",
        UDim2.new(1,0,0,110), UDim2.new(0,0,0,46),
        Color3.fromRGB(18,14,30), nil, 0)

    local eggLbl = mkL(eggZone, "EggEmoji", "🥚",
        UDim2.new(0,80,0,80), UDim2.new(0.5,-40,0.5,-40),
        64, TEXT_PRIMARY, Enum.Font.GothamBold)

    -- Countdown label
    local cdLbl = mkL(inner, "CountdownLbl", "",
        UDim2.new(1,-20,0,30), UDim2.new(0,10,0,162),
        16, TEXT_PRIMARY, Enum.Font.GothamBold)

    -- Botón acelerar
    local incubSeconds = eggData.incubationSeconds or parentDragon.incubationSeconds or 300
    local remaining    = incubSeconds
    local accelBtn = mkB(inner, "AccelBtn",
        "⚡ Acelerar  —  " .. calcSpeedCost(remaining) .. " 💎",
        UDim2.new(1,-20,0,34), UDim2.new(0,10,0,196),
        Color3.fromRGB(30,40,90), Color3.fromRGB(150,190,255), 14)
    accelBtn.MouseButton1Click:Connect(function()
        accelBtn.Active = false
        local Remotes   = ReplicatedStorage:WaitForChild("Remotes")
        local ok, result = pcall(function()
            return Remotes:WaitForChild("RequestSpeedUpIncubation")
                :InvokeServer(eggData.nestIndex)
        end)
        if ok and result and result.ok then
            showNotif("¡Incubación acelerada!", Color3.fromRGB(100,160,255))
        else
            accelBtn.Active = true
            showNotif("Gemas insuficientes", Color3.fromRGB(200,60,60))
        end
    end)

    -- ── Loop de temblor suave del huevo ───────────────────────────────────────
    state.tembloreGen = state.tembloreGen + 1
    local shakeGen    = state.tembloreGen
    task.spawn(function()
        local basePosX = 0.5
        while state.tembloreGen == shakeGen and eggLbl.Parent do
            local dx = math.random(-3, 3)
            TweenService:Create(eggLbl, TW_SHAKE, {
                Position = UDim2.new(0, (MODAL_W/2 - 40) + dx, 0, 15)
            }):Play()
            task.wait(0.12)
        end
        -- Recentrar al terminar
        if eggLbl.Parent then
            TweenService:Create(eggLbl, TW_FAST, {
                Position = UDim2.new(0.5,-40,0.5,-40)
            }):Play()
        end
    end)

    -- ── Countdown loop ────────────────────────────────────────────────────────
    local readyAt = tick() + remaining
    task.spawn(function()
        while state.incubaGen == localGen do
            local segundosRestantes = math.max(0, readyAt - tick())
            remaining = segundosRestantes
            if cdLbl.Parent then
                cdLbl.Text = "⏱  " .. fmtTime(segundosRestantes)
            end
            if accelBtn.Parent then
                local newCost = calcSpeedCost(segundosRestantes)
                accelBtn.Text = "⚡ Acelerar  —  " .. newCost .. " 💎"
            end
            if segundosRestantes <= 0 then
                -- El servidor enviará EggIncubated cuando esté listo
                if cdLbl.Parent then cdLbl.Text = "✅ ¡Listo para eclosionar!" end
                break
            end
            task.wait(1)
        end
    end)
end

--------------------------------------------------------------------------------
-- EggOpenGUI.AnimateEggCrack()
-- Secuencia de animación del cascarón rompiéndose.
-- Llamada desde ShowReveal; bloquea con task.wait entre cada frame.
-- Retorna el Frame contenedor del área de animación para uso posterior.
--------------------------------------------------------------------------------

function EggOpenGUI.AnimateEggCrack(revealContent, elemColor)
    -- Zona central donde ocurre toda la animación del huevo
    local eggArea = mkF(revealContent, "EggArea",
        UDim2.new(0,200,0,200), UDim2.new(0.5,-100,0.5,-130),
        Color3.fromRGB(0,0,0), nil, 0)
    eggArea.BackgroundTransparency = 1
    eggArea.ClipsDescendants = false
    eggArea.ZIndex = 12

    -- Anillo de brillo de elemento detrás del huevo
    local glow = mkF(eggArea, "Glow",
        UDim2.new(0,170,0,170), UDim2.new(0.5,-85,0.5,-85),
        elemColor or Color3.fromRGB(255,220,80), nil, 85)
    glow.BackgroundTransparency = 1
    glow.ZIndex = 11

    -- Huevo principal
    local eggLbl = mkL(eggArea, "Egg", "🥚",
        UDim2.new(0,130,0,130), UDim2.new(0.5,-65,0.5,-65),
        110, TEXT_PRIMARY, Enum.Font.GothamBold)
    eggLbl.ZIndex = 13

    -- FRAME 1: huevo aparece con escala desde 0
    eggLbl.TextSize = 20
    TweenService:Create(eggLbl, TW_BOUNCE, { TextSize = 110 }):Play()
    TweenService:Create(glow, TW_SLOW, { BackgroundTransparency = 0.75 }):Play()
    task.wait(0.5)

    -- FRAME 2: pequeño temblor previo al crack
    for i = 1, 5 do
        local dx = math.random(-6, 6)
        TweenService:Create(eggLbl, TW_SHAKE, {
            Position = UDim2.new(0.5, -65 + dx, 0.5, -65)
        }):Play()
        task.wait(0.10)
    end
    TweenService:Create(eggLbl, TW_FAST, { Position = UDim2.new(0.5,-65,0.5,-65) }):Play()
    task.wait(0.15)

    playSound(SOUND_IDS.crack, 0.7)

    -- FRAME 3: crack izquierdo (línea diagonal blanca)
    local crackL = mkF(eggArea, "CrackL",
        UDim2.new(0,3,0,52), UDim2.new(0.5,-14,0.5,-26),
        Color3.fromRGB(255,255,255), nil, 1)
    crackL.Rotation               = 28
    crackL.BackgroundTransparency = 1
    crackL.ZIndex                 = 14
    TweenService:Create(crackL, TW_FAST, { BackgroundTransparency = 0 }):Play()
    task.wait(0.12)

    -- FRAME 4: crack derecho
    local crackR = mkF(eggArea, "CrackR",
        UDim2.new(0,3,0,52), UDim2.new(0.5,10,0.5,-26),
        Color3.fromRGB(255,255,255), nil, 1)
    crackR.Rotation               = -22
    crackR.BackgroundTransparency = 1
    crackR.ZIndex                 = 14
    TweenService:Create(crackR, TW_FAST, { BackgroundTransparency = 0 }):Play()
    task.wait(0.18)

    -- FRAME 5: crack adicional (fragmento lateral)
    local crackTop = mkF(eggArea, "CrackTop",
        UDim2.new(0,3,0,30), UDim2.new(0.5,-2,0.5,-58),
        Color3.fromRGB(255,255,255), nil, 1)
    crackTop.BackgroundTransparency = 1
    crackTop.ZIndex = 14
    TweenService:Create(crackTop, TW_FAST, { BackgroundTransparency = 0.2 }):Play()
    task.wait(0.20)

    -- FRAME 6: destello blanco que llena la pantalla
    local flash = mkF(revealContent, "FlashFrame",
        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
        Color3.fromRGB(255,255,255), nil, 0)
    flash.BackgroundTransparency = 1
    flash.ZIndex = 18
    TweenService:Create(flash, TW_FAST, { BackgroundTransparency = 0 }):Play()
    task.wait(0.15)

    -- Desaparecer el huevo y los cracks durante el flash
    eggLbl.Visible = false
    crackL.Visible = false
    crackR.Visible = false
    crackTop.Visible = false

    -- Desvanecer el flash
    TweenService:Create(flash, TW_SLOW, { BackgroundTransparency = 1 }):Play()
    task.wait(0.25)

    flash:Destroy()
    return eggArea  -- el llamador puede destruirlo o reutilizarlo
end

--------------------------------------------------------------------------------
-- EggOpenGUI.ShowRarityEffect(rarity, parent, centerX, centerY)
-- Lanza partículas y efectos de pantalla según la rareza del dragón.
-- Common: partículas grises pequeñas.
-- Uncommon: partículas verdes.
-- Rare: partículas azules + destello.
-- Epic: partículas moradas + anillo de shockwave.
-- Legendary: lluvia dorada + pantalla dorada.
-- Mythic: partículas rojas masivas + shake de cámara + pantalla roja.
--------------------------------------------------------------------------------

function EggOpenGUI.ShowRarityEffect(rarity, parent, cx, cy)
    cx = cx or 0.5  -- posición X relativa al padre (0-1)
    cy = cy or 0.4  -- posición Y relativa al padre

    local count     = PARTICLE_COUNT[rarity] or 12
    local baseColor = RARITY_COLORS[rarity] or Color3.fromRGB(200,200,200)
    local baseSize  = 8
    local baseDist  = 120

    -- Ajustes por rareza
    if rarity == "epic" or rarity == "legendary" or rarity == "mythic" then
        baseSize = 12 ; baseDist = 180
    end
    if rarity == "mythic" then baseSize = 16 ; baseDist = 240 end

    -- ── Crear partículas ──────────────────────────────────────────────────────
    for i = 1, count do
        local pSize = baseSize + math.random(-3, 5)
        local p = Instance.new("Frame")
        p.Name               = "Particle_" .. i
        p.Size               = UDim2.new(0, pSize, 0, pSize)
        p.Position           = UDim2.new(cx, -pSize/2, cy, -pSize/2)
        p.BackgroundColor3   = baseColor
        p.BackgroundTransparency = 0.10
        p.BorderSizePixel    = 0
        p.ZIndex             = 16
        p.Parent             = parent
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(0, math.random(0,4))
        pc.Parent = p

        -- Dirección aleatoria en 360°
        local angle = (i / count) * math.pi * 2 + math.random() * 0.6
        local dist  = baseDist + math.random(0, 80)
        local tx    = math.cos(angle) * dist
        local ty    = math.sin(angle) * dist
        local dur   = 0.6 + math.random(0,40)/100

        task.spawn(function()
            task.wait(math.random(0,20)/100)
            TweenService:Create(p, TweenInfo.new(dur, Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out), {
                Position             = UDim2.new(cx, -pSize/2 + tx, cy, -pSize/2 + ty),
                BackgroundTransparency = 1,
                Size                 = UDim2.new(0,0,0,0),
            }):Play()
            task.delay(dur + 0.05, function()
                if p and p.Parent then p:Destroy() end
            end)
        end)
    end

    -- ── Efectos extra por rareza ──────────────────────────────────────────────

    -- Rare: destello azul breve
    if rarity == "rare" then
        local flash = mkF(parent, "BlueFlash",
            UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
            Color3.fromRGB(60,100,255), nil, 0)
        flash.BackgroundTransparency = 0.88
        flash.ZIndex = 15
        task.spawn(function()
            task.wait(0.1)
            TweenService:Create(flash, TW_MED, { BackgroundTransparency = 1 }):Play()
            task.delay(0.35, function() if flash.Parent then flash:Destroy() end end)
        end)
    end

    -- Epic: anillo de shockwave que se expande desde el centro
    if rarity == "epic" then
        local ring = Instance.new("Frame")
        ring.Name               = "ShockRing"
        ring.Size               = UDim2.new(0,10,0,10)
        ring.Position           = UDim2.new(cx,-5,cy,-5)
        ring.BackgroundTransparency = 1
        ring.BorderSizePixel    = 0
        ring.ZIndex             = 15
        ring.Parent             = parent
        local ringStroke = Instance.new("UIStroke")
        ringStroke.Color     = RARITY_COLORS.epic
        ringStroke.Thickness = 4
        ringStroke.Parent    = ring
        local ringCorner = Instance.new("UICorner")
        ringCorner.CornerRadius = UDim.new(0,150)
        ringCorner.Parent       = ring

        TweenService:Create(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quad,
            Enum.EasingDirection.Out), {
            Size     = UDim2.new(0,280,0,280),
            Position = UDim2.new(cx,-140,cy,-140),
        }):Play()
        TweenService:Create(ringStroke, TweenInfo.new(0.55), { Thickness = 0 }):Play()
        task.delay(0.6, function() if ring.Parent then ring:Destroy() end end)
    end

    -- Legendary: tinte dorado de pantalla + segunda ola de partículas
    if rarity == "legendary" then
        local tinte = mkF(parent, "GoldTint",
            UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
            Color3.fromRGB(255,180,10), nil, 0)
        tinte.BackgroundTransparency = 0.78
        tinte.ZIndex = 15
        task.spawn(function()
            task.wait(0.40)
            TweenService:Create(tinte, TweenInfo.new(1.0, Enum.EasingStyle.Quint),
                { BackgroundTransparency = 1 }):Play()
            task.delay(1.1, function() if tinte.Parent then tinte:Destroy() end end)
        end)

        -- Segunda ola: lluvia desde arriba
        for i = 1, 14 do
            local pSize2 = 10 + math.random(0,8)
            local p2 = mkF(parent, "Rain_" .. i,
                UDim2.new(0,pSize2,0,pSize2),
                UDim2.new(math.random(5,95)/100,-pSize2/2,0,-pSize2),
                RARITY_COLORS.legendary, nil, pSize2//2)
            p2.BackgroundTransparency = 0.15
            p2.ZIndex = 16
            task.spawn(function()
                task.wait(math.random(0,60)/100)
                TweenService:Create(p2, TweenInfo.new(0.8+math.random(0,40)/100,
                    Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                    Position             = UDim2.new(p2.Position.X.Scale,-pSize2/2,1.05,0),
                    BackgroundTransparency = 1,
                }):Play()
                task.delay(0.9, function() if p2.Parent then p2:Destroy() end end)
            end)
        end
    end

    -- Mythic: tinte rojo + shake de cámara simulado sobre el frame principal
    if rarity == "mythic" then
        local redTinte = mkF(parent, "RedTint",
            UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
            Color3.fromRGB(180,10,10), nil, 0)
        redTinte.BackgroundTransparency = 0.72
        redTinte.ZIndex = 15
        task.spawn(function()
            task.wait(0.35)
            TweenService:Create(redTinte, TweenInfo.new(1.5, Enum.EasingStyle.Quint),
                { BackgroundTransparency = 1 }):Play()
            task.delay(1.6, function() if redTinte.Parent then redTinte:Destroy() end end)
        end)

        -- Shake simulado: tween de posición del revealFrame
        task.spawn(function()
            for i = 1, 10 do
                local ox = math.random(-14, 14)
                local oy = math.random(-9, 9)
                TweenService:Create(ui.revealFrame, TW_SHAKE, {
                    Position = UDim2.new(0, ox, 0, oy)
                }):Play()
                task.wait(0.09)
            end
            TweenService:Create(ui.revealFrame, TW_MED, {
                Position = UDim2.new(0,0,0,0)
            }):Play()
        end)

        -- Anillo de shockwave doble
        for wave = 1, 2 do
            task.spawn(function()
                task.wait((wave-1) * 0.25)
                local ring2 = Instance.new("Frame")
                ring2.Size               = UDim2.new(0,10,0,10)
                ring2.Position           = UDim2.new(cx,-5,cy,-5)
                ring2.BackgroundTransparency = 1
                ring2.BorderSizePixel    = 0
                ring2.ZIndex             = 15
                ring2.Parent             = parent
                local rs = Instance.new("UIStroke")
                rs.Color     = RARITY_COLORS.mythic
                rs.Thickness = 5
                rs.Parent    = ring2
                local rc2 = Instance.new("UICorner")
                rc2.CornerRadius = UDim.new(0,150)
                rc2.Parent       = ring2
                TweenService:Create(ring2, TweenInfo.new(0.7, Enum.EasingStyle.Quad,
                    Enum.EasingDirection.Out), {
                    Size     = UDim2.new(0,360,0,360),
                    Position = UDim2.new(cx,-180,cy,-180),
                }):Play()
                TweenService:Create(rs, TweenInfo.new(0.7), { Thickness = 0 }):Play()
                task.delay(0.75, function()
                    if ring2.Parent then ring2:Destroy() end
                end)
            end)
        end
    end
end

--------------------------------------------------------------------------------
-- EggOpenGUI.ShowReveal(dragonData, isNew)
-- PANTALLA 3 — Reveal animado del dragón resultante.
-- Secuencia: fade in → huevo → crack → flash → dragón + partículas →
--            typewriter del nombre → stats → banner "Primera vez" si isNew.
--------------------------------------------------------------------------------

function EggOpenGUI.ShowReveal(dragonData, isNew)
    if not dragonData then return end

    -- Cancelar incubación activa
    state.incubaGen  = state.incubaGen + 1
    state.tembloreGen = state.tembloreGen + 1
    state.incubando  = false
    state.revealActivo = true
    state.dragonReveal = dragonData

    local rarity     = dragonData.rarity or "common"
    local rarColor   = RARITY_COLORS[rarity] or Color3.fromRGB(200,200,200)
    local elemColor  = ELEMENT_COLORS[dragonData.element] or Color3.fromRGB(100,100,100)
    local elemEmoji  = ELEMENT_EMOJI[dragonData.element] or ""
    local revealDur  = REVEAL_DURATION[rarity] or 2.0

    -- Ocultar el modal si estaba abierto
    ui.modal.Visible     = false
    ui.bgOverlay.Visible = false

    -- Activar frame fullscreen
    ui.revealFrame.Visible            = true
    ui.revealFrame.BackgroundTransparency = 1
    ui.revealFrame.Position           = UDim2.new(0,0,0,0)
    ui.screenGui.Enabled              = true

    -- Fade in del fondo oscuro del reveal
    TweenService:Create(ui.revealFrame, TW_MED, {
        BackgroundTransparency = 0.08
    }):Play()
    task.wait(0.30)

    -- Contenedor del contenido del reveal (se construye dentro del revealFrame)
    local revealContent = mkF(ui.revealFrame, "RevealContent",
        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
        Color3.fromRGB(0,0,0), nil, 0)
    revealContent.BackgroundTransparency = 1
    revealContent.ClipsDescendants       = false
    revealContent.ZIndex                 = 11

    -- ── Animación del crack (bloquea la tarea hasta completarse) ─────────────
    local eggArea = EggOpenGUI.AnimateEggCrack(revealContent, elemColor)

    -- Reproducir sonido según rareza
    if rarity == "legendary" or rarity == "mythic" then
        playSound(rarity == "mythic" and SOUND_IDS.reveal_mythic or SOUND_IDS.reveal_legendary, 0.85)
    elseif rarity == "rare" or rarity == "epic" then
        playSound(SOUND_IDS.reveal_rare, 0.7)
    else
        playSound(SOUND_IDS.reveal_common, 0.6)
    end

    -- ── Dragón emerge ─────────────────────────────────────────────────────────
    -- Destruir el área del huevo
    if eggArea and eggArea.Parent then eggArea:Destroy() end

    -- Fondo de rareza detrás del dragón
    local dragonBg = mkF(revealContent, "DragonBg",
        UDim2.new(0,220,0,220), UDim2.new(0.5,-110,0.5,-170),
        elemColor, nil, 110)
    dragonBg.BackgroundTransparency = 0.75
    dragonBg.ZIndex = 11
    TweenService:Create(dragonBg, TW_BOUNCE, {
        Size     = UDim2.new(0,220,0,220),
        BackgroundTransparency = 0.65,
    }):Play()

    -- Emoji del dragón (aparece desde pequeño)
    local dragonLbl = mkL(revealContent, "DragonEmoji", "🐉",
        UDim2.new(0,160,0,160), UDim2.new(0.5,-80,0.5,-160),
        20, Color3.fromRGB(255,255,255), Enum.Font.GothamBold)
    dragonLbl.ZIndex = 13

    TweenService:Create(dragonLbl, TW_BOUNCE, { TextSize = 128 }):Play()

    -- Lanzar efecto de rareza centrado en el dragón
    task.spawn(function()
        task.wait(0.15)
        EggOpenGUI.ShowRarityEffect(rarity, revealContent, 0.5, 0.38)
    end)

    task.wait(0.45)

    -- ── Nombre con efecto typewriter ──────────────────────────────────────────
    local nameArea = mkF(revealContent, "NameArea",
        UDim2.new(0,500,0,44), UDim2.new(0.5,-250,0.5,70),
        Color3.fromRGB(0,0,0), nil, 0)
    nameArea.BackgroundTransparency = 1
    nameArea.ZIndex = 12

    local nameLbl = mkL(nameArea, "NameLbl", "",
        UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
        28, Color3.fromRGB(255,255,255), Enum.Font.GothamBold)
    nameLbl.ZIndex = 13

    -- Borde de rareza bajo el nombre
    local rarityLine = mkF(revealContent, "RarityLine",
        UDim2.new(0,0,0,3), UDim2.new(0.5,0,0.5,116),
        rarColor, nil, 1)
    rarityLine.ZIndex = 12
    TweenService:Create(rarityLine, TW_SLOW, { Size = UDim2.new(0,440,0,3),
        Position = UDim2.new(0.5,-220,0.5,116) }):Play()

    -- Typewriter del nombre del dragón
    task.spawn(function()
        typewriter(nameLbl, dragonData.name, 0.05)
    end)
    task.wait(#dragonData.name * 0.05 + 0.10)

    -- ── Rareza, elemento y GPS aparecen ───────────────────────────────────────
    local statsArea = mkF(revealContent, "StatsArea",
        UDim2.new(0,440,0,66), UDim2.new(0.5,-220,0.5,122),
        Color3.fromRGB(0,0,0), nil, 0)
    statsArea.BackgroundTransparency = 1
    statsArea.ZIndex = 12
    statsArea.BackgroundTransparency = 0.80

    -- Rareza con estrellas
    local rarLbl = mkL(statsArea, "RarLbl",
        rarityStars(rarity) .. "  " .. rarity:sub(1,1):upper() .. rarity:sub(2),
        UDim2.new(1,0,0,28), UDim2.new(0,0,0,0),
        17, rarColor, Enum.Font.GothamBold)
    rarLbl.ZIndex = 13
    rarLbl.BackgroundTransparency = 1

    -- Elemento + GPS
    mkL(statsArea, "ElemGpsLbl",
        elemEmoji .. "  " .. dragonData.element:sub(1,1):upper()
            .. dragonData.element:sub(2)
            .. "     🪙 " .. string.format("%.1f", dragonData.goldPerSecond) .. "/seg",
        UDim2.new(1,0,0,22), UDim2.new(0,0,0,32),
        14, elemColor, Enum.Font.GothamMedium)
    :GetPropertyChangedSignal("ZIndex"):Connect(function() end)

    -- Animar aparición del área de stats
    statsArea.BackgroundTransparency = 1
    for _, c in ipairs(statsArea:GetChildren()) do
        if c:IsA("TextLabel") then c.TextTransparency = 1 end
    end
    TweenService:Create(statsArea, TW_MED, { BackgroundTransparency = 0.72 }):Play()
    for _, c in ipairs(statsArea:GetChildren()) do
        if c:IsA("TextLabel") then
            TweenService:Create(c, TW_MED, { TextTransparency = 0 }):Play()
        end
    end

    task.wait(0.35)

    -- ── Banner "¡Primera vez!" si es dragón nuevo ─────────────────────────────
    if isNew then
        local newBanner = mkF(revealContent, "NewBanner",
            UDim2.new(0,360,0,36), UDim2.new(0.5,-180,0.5,196),
            Color3.fromRGB(180,130,0), BORDER_GOLD, 10)
        newBanner.ZIndex = 13
        newBanner.BackgroundTransparency = 0.25

        mkL(newBanner, "NewLbl", "✨  ¡Primera vez que lo consigues!  ✨",
            UDim2.new(1,-10,1,0), UDim2.new(0,5,0,0),
            14, Color3.fromRGB(255,245,180), Enum.Font.GothamBold)
            :GetPropertyChangedSignal("ZIndex"):Connect(function() end)

        -- Pulso del banner de nuevo dragón
        task.spawn(function()
            for _ = 1, 4 do
                if not newBanner.Parent then break end
                TweenService:Create(newBanner, TweenInfo.new(0.4, Enum.EasingStyle.Sine), {
                    BackgroundTransparency = 0.05
                }):Play()
                task.wait(0.45)
                TweenService:Create(newBanner, TweenInfo.new(0.4, Enum.EasingStyle.Sine), {
                    BackgroundTransparency = 0.40
                }):Play()
                task.wait(0.45)
            end
        end)

        -- Partículas doradas adicionales para "nueva primera vez"
        task.spawn(function()
            task.wait(0.1)
            EggOpenGUI.ShowRarityEffect("legendary", revealContent, 0.5, 0.68)
        end)
    end

    -- ── Botones de acción (aparecen tras el reveal) ───────────────────────────
    task.wait(math.max(0.20, revealDur - (#dragonData.name * 0.05) - 0.9))

    local btnArea = mkF(revealContent, "RevealBtns",
        UDim2.new(0,380,0,100), UDim2.new(0.5,-190,1,-116),
        Color3.fromRGB(0,0,0), nil, 0)
    btnArea.BackgroundTransparency = 1
    btnArea.ZIndex = 14

    local btnLayout = Instance.new("UIListLayout")
    btnLayout.FillDirection = Enum.FillDirection.Horizontal
    btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    btnLayout.Padding       = UDim.new(0,12)
    btnLayout.Parent        = btnArea

    -- Botón: Poner en nido
    local nestBtn = mkB(btnArea, "NestBtn", "🏠 Poner en nido",
        UDim2.new(0,178,0,44), UDim2.new(0,0,0,0),
        Color3.fromRGB(20,60,20), Color3.fromRGB(160,255,160), 14)
    nestBtn.ZIndex = 15
    nestBtn.MouseButton1Click:Connect(function()
        EggOpenGUI.OnPlaceInNest(dragonData.id)
    end)

    -- Botón: Guardar en inventario
    local invBtn = mkB(btnArea, "InvBtn", "🎒 Guardar",
        UDim2.new(0,158,0,44), UDim2.new(0,0,0,0),
        Color3.fromRGB(40,28,10), Color3.fromRGB(255,220,120), 14)
    invBtn.ZIndex = 15
    invBtn.MouseButton1Click:Connect(function()
        EggOpenGUI.OnSaveToInventory(dragonData.id)
    end)

    -- Animar entrada de los botones desde abajo
    for _, btn in ipairs({nestBtn, invBtn}) do
        local origPos = btn.Position
        btn.Position  = UDim2.new(origPos.X.Scale, origPos.X.Offset,
            origPos.Y.Scale, origPos.Y.Offset + 30)
        btn.BackgroundTransparency = 1
        TweenService:Create(btn, TW_BOUNCE, {
            Position             = origPos,
            BackgroundTransparency = 0,
        }):Play()
    end
end

--------------------------------------------------------------------------------
-- EggOpenGUI.OnPlaceInNest(dragonId)
-- Muestra un selector de nidos vacíos disponibles.
-- Si todos están ocupados, muestra mensaje de error.
--------------------------------------------------------------------------------

function EggOpenGUI.OnPlaceInNest(dragonId)
    local abrioDesdeAfuera = not ui.screenGui.Enabled

    local function cerrarReveal()
        if abrioDesdeAfuera then
            ui.revealFrame.Visible        = false
            ui.revealFrame.BackgroundTransparency = 1
            ui.screenGui.Enabled          = false
        end
    end

    -- Solicitar estado actual de los nidos al servidor
    local Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local ok, nestStatus = pcall(function()
        return Remotes:WaitForChild("RequestGetNestStatus"):InvokeServer()
    end)

    if not (ok and nestStatus) then
        showNotif("Error al obtener nidos", Color3.fromRGB(200,60,60))
        task.delay(2.5, cerrarReveal)
        return
    end

    -- Filtrar nidos vacíos
    local nestosVacios = {}
    for nestIndex, occupant in pairs(nestStatus) do
        if not occupant or occupant == false or occupant == "" then
            nestosVacios[#nestosVacios + 1] = nestIndex
        end
    end
    table.sort(nestosVacios)

    if #nestosVacios == 0 then
        showNotif("Todos los nidos están ocupados — retira un dragón primero",
            Color3.fromRGB(200,120,40))
        task.delay(2.5, cerrarReveal)
        return
    end

    -- ScreenGui propio para el selector (sin depender de revealFrame)
    local existente = playerGui:FindFirstChild("NestSelectorGui")
    if existente then existente:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name           = "NestSelectorGui"
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent         = playerGui

    local overlay = Instance.new("Frame")
    overlay.Size                   = UDim2.new(1,0,1,0)
    overlay.BackgroundColor3       = Color3.fromRGB(0,0,0)
    overlay.BackgroundTransparency = 0.45
    overlay.BorderSizePixel        = 0
    overlay.Parent                 = sg

    local function cerrar()
        sg:Destroy()
        cerrarReveal()
    end

    -- Panel con tamaño fijo calculado: título(28) + N*botones(40) + cancelar(34) + separadores + padding
    local N      = #nestosVacios
    local panelH = 48 + 28 + 8 + N * 46 + 34 + 12
    local panelW = 320

    local panel = Instance.new("Frame")
    panel.Name             = "SelectorPanel"
    panel.Size             = UDim2.new(0, panelW, 0, panelH)
    panel.Position         = UDim2.new(0.5, -panelW/2, 0.5, -panelH/2)
    panel.BackgroundColor3 = Color3.fromRGB(18, 12, 32)
    panel.BorderSizePixel  = 0
    panel.Parent           = overlay
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
    local ps = Instance.new("UIStroke", panel)
    ps.Color     = Color3.fromRGB(200, 160, 50)
    ps.Thickness = 1.5

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size               = UDim2.new(1,-20,0,28)
    titleLbl.Position           = UDim2.new(0,10,0,10)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text               = "Seleccionar nido vacío:"
    titleLbl.TextSize           = 15
    titleLbl.TextColor3         = Color3.fromRGB(200,160,50)
    titleLbl.Font               = Enum.Font.GothamBold
    titleLbl.TextXAlignment     = Enum.TextXAlignment.Center
    titleLbl.Parent             = panel

    for i, nestIdx in ipairs(nestosVacios) do
        local btnY = 48 + 28 + 8 + (i-1) * 46
        local btn  = Instance.new("TextButton")
        btn.Size             = UDim2.new(1,-20,0,40)
        btn.Position         = UDim2.new(0,10,0,btnY)
        btn.BackgroundColor3 = Color3.fromRGB(20,60,20)
        btn.TextColor3       = Color3.fromRGB(180,255,180)
        btn.Text             = "🏠  Nido " .. nestIdx
        btn.TextSize         = 14
        btn.Font             = Enum.Font.GothamBold
        btn.BorderSizePixel  = 0
        btn.AutoButtonColor  = false
        btn.Parent           = panel
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,8)

        btn.MouseButton1Click:Connect(function()
            btn.Active = false
            btn.Text   = "Colocando..."

            local placeOk, placeResult = pcall(function()
                return Remotes:WaitForChild("RequestPlaceDragonInNest")
                    :InvokeServer(dragonId, nestIdx)
            end)

            if placeOk and placeResult and placeResult.ok then
                cerrar()
                showNotif("¡Dragón colocado en Nido " .. nestIdx .. "!", nil)
                if not abrioDesdeAfuera then
                    task.delay(1.5, function()
                        TweenService:Create(ui.revealFrame, TW_MED,
                            { BackgroundTransparency = 1 }):Play()
                        task.delay(0.25, function()
                            ui.revealFrame.Visible  = false
                            ui.screenGui.Enabled    = false
                            state.revealActivo      = false
                            for _, c in ipairs(ui.revealFrame:GetChildren()) do
                                c:Destroy()
                            end
                        end)
                    end)
                end
            else
                btn.Active = true
                btn.Text   = "🏠  Nido " .. nestIdx
                showNotif(placeResult and placeResult.message or "Error al colocar",
                    Color3.fromRGB(200,60,60))
            end
        end)
    end

    local cancelY  = 48 + 28 + 8 + N * 46
    local cancelBtn = Instance.new("TextButton")
    cancelBtn.Size             = UDim2.new(1,-20,0,34)
    cancelBtn.Position         = UDim2.new(0,10,0,cancelY)
    cancelBtn.BackgroundColor3 = Color3.fromRGB(60,20,20)
    cancelBtn.TextColor3       = Color3.fromRGB(255,180,180)
    cancelBtn.Text             = "Cancelar"
    cancelBtn.TextSize         = 13
    cancelBtn.Font             = Enum.Font.GothamBold
    cancelBtn.BorderSizePixel  = 0
    cancelBtn.AutoButtonColor  = false
    cancelBtn.Parent           = panel
    Instance.new("UICorner", cancelBtn).CornerRadius = UDim.new(0,8)
    cancelBtn.MouseButton1Click:Connect(cerrar)
end

--------------------------------------------------------------------------------
-- EggOpenGUI.OnSaveToInventory(dragonId)
-- Guarda el dragón en el inventario y cierra el reveal con animación.
--------------------------------------------------------------------------------

function EggOpenGUI.OnSaveToInventory(dragonId)
    local Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local ok, result = pcall(function()
        return Remotes:WaitForChild("RequestSaveDragonToInventory"):InvokeServer(dragonId)
    end)

    if ok and result and result.ok then
        showNotif("🎒 Dragón guardado en inventario", Color3.fromRGB(255,220,80))
        -- Cerrar el reveal con fade out
        task.delay(0.80, function()
            TweenService:Create(ui.revealFrame, TW_SLOW,
                { BackgroundTransparency = 1 }):Play()
            task.delay(0.60, function()
                ui.revealFrame.Visible = false
                ui.screenGui.Enabled   = false
                state.revealActivo     = false
                -- Limpiar contenido del reveal para la próxima vez
                for _, c in ipairs(ui.revealFrame:GetChildren()) do
                    c:Destroy()
                end
            end)
        end)
    else
        showNotif("Error al guardar: " .. tostring(result), Color3.fromRGB(200,60,60))
    end
end

--------------------------------------------------------------------------------
-- EggOpenGUI.ShowIncubationQueue()
-- Muestra el panel lateral con todos los huevos en cola de incubación.
-- Permite cancelar incubaciones en progreso.
-- Se actualiza con un tick loop mientras el panel esté visible.
--------------------------------------------------------------------------------

function EggOpenGUI.ShowIncubationQueue()
    -- Limpiar filas antiguas
    for _, c in ipairs(ui.queueScroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end

    local ahora     = tick()
    local hayHuevos = false

    for nestIndex, entry in pairs(state.cola) do
        if not entry then continue end
        hayHuevos = true
        local parentDragon = DragonData.GetDragonById(entry.parentId)
        local parentName   = parentDragon and parentDragon.name or "Huevo"
        local remaining    = math.max(0, entry.readyAt - ahora)

        -- Fila de la cola
        local row = mkF(ui.queueScroll, "Row_" .. nestIndex,
            UDim2.new(1,0,0,58), nil,
            Color3.fromRGB(24,18,42), BORDER_GOLD, 6)
        row.LayoutOrder = nestIndex

        -- Icono + nombre
        mkL(row, "NameLbl",
            "🥚  Nido " .. nestIndex .. " — " .. parentName,
            UDim2.new(1,-52,0,20), UDim2.new(0,6,0,4),
            12, TEXT_PRIMARY, Enum.Font.GothamBold, Enum.TextXAlignment.Left)

        -- Countdown (se actualiza en el tick loop)
        local cdLbl = mkL(row, "CdLbl",
            "⏱  " .. fmtTime(remaining),
            UDim2.new(1,-52,0,18), UDim2.new(0,6,0,24),
            11, TEXT_DIM, Enum.Font.Gotham, Enum.TextXAlignment.Left)
        cdLbl.Name = "CdLbl_" .. nestIndex

        -- Botón cancelar
        local cancelBtn = mkB(row, "CancelBtn", "✕",
            UDim2.new(0,36,0,36), UDim2.new(1,-42,0.5,-18),
            Color3.fromRGB(60,20,20), Color3.fromRGB(255,180,180), 14)
        cancelBtn.MouseButton1Click:Connect(function()
            cancelBtn.Active = false
            cancelBtn.Text   = "..."
            local Remotes    = ReplicatedStorage:WaitForChild("Remotes")
            local ok, res    = pcall(function()
                return Remotes:WaitForChild("RequestCancelIncubation")
                    :InvokeServer(nestIndex)
            end)
            if ok and res and res.ok then
                state.cola[nestIndex] = nil
                row:Destroy()
                showNotif("Incubación cancelada (Nido " .. nestIndex .. ")",
                    Color3.fromRGB(200,120,40))
            else
                cancelBtn.Active = true
                cancelBtn.Text   = "✕"
                showNotif("Error al cancelar", Color3.fromRGB(200,60,60))
            end
        end)
    end

    -- Mensaje si no hay incubaciones activas
    if not hayHuevos then
        mkL(ui.queueScroll, "EmptyLbl",
            "No hay huevos en incubación.",
            UDim2.new(1,0,0,40), UDim2.new(0,0,0,10),
            13, TEXT_DIM, Enum.Font.Gotham)
    end

    -- Mostrar panel con slide desde la derecha
    ui.queuePanel.Visible  = true
    ui.screenGui.Enabled   = true
    ui.queuePanel.Position = UDim2.new(1,0,0.5,-200)
    TweenService:Create(ui.queuePanel, TW_SLIDE, {
        Position = UDim2.new(1,-292,0.5,-200)
    }):Play()

    -- Tick loop para actualizar countdowns mientras el panel está abierto
    state.queueGen = state.queueGen + 1
    local gen      = state.queueGen
    task.spawn(function()
        while state.queueGen == gen and ui.queuePanel.Visible do
            task.wait(1)
            local now = tick()
            for nestIdx, entry in pairs(state.cola) do
                local cdLbl = ui.queueScroll:FindFirstChild("CdLbl_" .. nestIdx)
                if cdLbl then
                    local secs = math.max(0, entry.readyAt - now)
                    cdLbl.Text = secs <= 0
                        and "✅ Listo para eclosionar"
                        or  ("⏱  " .. fmtTime(secs))
                    cdLbl.TextColor3 = secs <= 0
                        and Color3.fromRGB(100,220,100) or TEXT_DIM
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- INIT
-- Construye el UI y conecta los RemoteEvents del servidor.
-- Se ejecuta una sola vez al cargar el LocalScript.
--------------------------------------------------------------------------------

local function Init()
    crearUI()

    -- BindableEvent para que InventoryGUI abra la ventana de detalle de huevo
    local detallEvt = Instance.new("BindableEvent")
    detallEvt.Name   = "AbrirDetallHuevo"
    detallEvt.Parent = playerGui

    -- BindableEvent para notificar a InventoryGUI que un huevo del inventario fue vendido
    local invVendidoEvt = Instance.new("BindableEvent")
    invVendidoEvt.Name   = "HuevoInventarioVendido"
    invVendidoEvt.Parent = playerGui
    detallEvt.Event:Connect(function(eggData)
        if state.revealActivo then return end
        EggOpenGUI.ShowProbabilities(eggData)
    end)

    local Remotes = ReplicatedStorage:WaitForChild("Remotes")

    -- EggReady → mostrar pantalla 1 de recolección
    Remotes:WaitForChild("EggReady").OnClientEvent:Connect(function(data)
        if not (data and data.nestIndex and data.dragonId) then return end
        -- Limpiar dismissal cuando el huevo fue recolectado
        if data.collected then
            state.popupDismissed[data.nestIndex] = nil
            return
        end
        -- No interrumpir un reveal activo
        if state.revealActivo then return end
        -- No reabrir si el jugador ya cerró el popup deliberadamente
        if state.popupDismissed[data.nestIndex] then return end
        EggOpenGUI.ShowEggReady(data.nestIndex, data.dragonId)
    end)

    -- Exponer para que HUD pueda reabrir el popup aunque estuviera cerrado
    _G.DragonRoost_ShowEggReady = function(nestIndex, dragonId)
        if state.revealActivo then return end
        state.popupDismissed[nestIndex] = nil
        EggOpenGUI.ShowEggReady(nestIndex, dragonId)
    end

    -- EggStarted → registrar en la cola de incubación local
    Remotes:WaitForChild("EggStarted").OnClientEvent:Connect(function(data)
        if not (data and data.nestIndex and data.dragonId) then return end
        state.cola[data.nestIndex] = {
            parentId = data.dragonId,
            readyAt  = data.readyAt or (tick() + (data.secondsLeft or 300)),
        }
    end)

    -- EggIncubated → mostrar reveal del dragón resultante
    Remotes:WaitForChild("EggIncubated").OnClientEvent:Connect(function(data)
        if not (data and data.dragonId) then return end
        -- Limpiar entrada de la cola
        if data.nestIndex then
            state.cola[data.nestIndex] = nil
        end
        local dragon = DragonData.GetDragonById(data.dragonId)
        if dragon then
            EggOpenGUI.ShowReveal(dragon, data.isNew == true)
        end
    end)
end

Init()

--------------------------------------------------------------------------------
-- Panel de inventario: presionar N muestra los dragones disponibles para
-- colocar en un nido. Solo sirve para pruebas / flujo inicial.
--------------------------------------------------------------------------------

local function abrirInventarioPicker()
    -- Pedir datos del catálogo al servidor para obtener el inventario
    local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
    if not Remotes then return end
    local ok, datos = pcall(function()
        return Remotes:WaitForChild("RequestGetCatalogueData", 5):InvokeServer()
    end)
    if not (ok and datos and datos.inventory) then
        warn("[EggOpenGUI] No se pudo obtener inventario:", datos)
        return
    end

    -- Si ya hay un picker abierto, cerrarlo
    local existing = playerGui:FindFirstChild("InventoryPickerGui")
    if existing then existing:Destroy() return end

    local sg = Instance.new("ScreenGui")
    sg.Name            = "InventoryPickerGui"
    sg.ResetOnSpawn    = false
    sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
    sg.Parent          = playerGui

    local bg = Instance.new("Frame")
    bg.Name               = "BG"
    bg.Size               = UDim2.new(0,320,0,420)
    bg.Position           = UDim2.new(0.5,-160,0.5,-210)
    bg.BackgroundColor3   = Color3.fromRGB(18,12,32)
    bg.BorderSizePixel    = 0
    bg.Parent             = sg
    Instance.new("UICorner", bg).CornerRadius = UDim.new(0,10)
    local stroke = Instance.new("UIStroke", bg)
    stroke.Color     = Color3.fromRGB(200,160,40)
    stroke.Thickness = 2

    -- Título
    local titulo = Instance.new("TextLabel")
    titulo.Size               = UDim2.new(1,-40,0,36)
    titulo.Position           = UDim2.new(0,10,0,6)
    titulo.BackgroundTransparency = 1
    titulo.Text               = "🎒  Inventario — elige un dragón"
    titulo.TextColor3         = Color3.fromRGB(200,160,40)
    titulo.Font               = Enum.Font.GothamBold
    titulo.TextSize           = 14
    titulo.TextXAlignment     = Enum.TextXAlignment.Left
    titulo.Parent             = bg

    local cerrarBtn = Instance.new("TextButton")
    cerrarBtn.Size             = UDim2.new(0,28,0,28)
    cerrarBtn.Position         = UDim2.new(1,-34,0,8)
    cerrarBtn.Text             = "✕"
    cerrarBtn.TextColor3       = Color3.fromRGB(255,180,180)
    cerrarBtn.BackgroundColor3 = Color3.fromRGB(60,20,20)
    cerrarBtn.Font             = Enum.Font.GothamBold
    cerrarBtn.TextSize         = 14
    cerrarBtn.Parent           = bg
    Instance.new("UICorner", cerrarBtn).CornerRadius = UDim.new(0,6)
    cerrarBtn.MouseButton1Click:Connect(function() sg:Destroy() end)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size               = UDim2.new(1,-16,1,-54)
    scroll.Position           = UDim2.new(0,8,0,48)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel    = 0
    scroll.ScrollBarThickness = 6
    scroll.CanvasSize         = UDim2.new(0,0,0,0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent             = bg

    local layout = Instance.new("UIListLayout", scroll)
    layout.Padding   = UDim.new(0,4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder

    local RARITY_COLORS_PICKER = {
        common    = Color3.fromRGB(180,180,180),
        uncommon  = Color3.fromRGB(80,200,80),
        rare      = Color3.fromRGB(80,130,220),
        epic      = Color3.fromRGB(160,80,220),
        legendary = Color3.fromRGB(255,165,0),
        mythic    = Color3.fromRGB(255,60,220),
    }

    local hayItems = false
    for dragonId, count in pairs(datos.inventory) do
        if count and count > 0 then
            hayItems = true
            local dragon = DragonData.GetDragonById(dragonId)
            if not dragon then continue end

            local btn = Instance.new("TextButton")
            btn.Size               = UDim2.new(1,0,0,44)
            btn.BackgroundColor3   = Color3.fromRGB(28,20,48)
            btn.BorderSizePixel    = 0
            btn.Text               = ""
            btn.Parent             = scroll
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)

            local nameLbl = Instance.new("TextLabel", btn)
            nameLbl.Size             = UDim2.new(1,-56,0,22)
            nameLbl.Position         = UDim2.new(0,8,0,4)
            nameLbl.BackgroundTransparency = 1
            nameLbl.Text             = dragon.name
            nameLbl.TextColor3       = RARITY_COLORS_PICKER[dragon.rarity] or Color3.fromRGB(200,200,200)
            nameLbl.Font             = Enum.Font.GothamBold
            nameLbl.TextSize         = 13
            nameLbl.TextXAlignment   = Enum.TextXAlignment.Left

            local detLbl = Instance.new("TextLabel", btn)
            detLbl.Size              = UDim2.new(1,-56,0,16)
            detLbl.Position          = UDim2.new(0,8,0,24)
            detLbl.BackgroundTransparency = 1
            detLbl.Text              = dragon.element .. " · " .. dragon.rarity .. " · " .. dragon.goldPerSecond .. " gps"
            detLbl.TextColor3        = Color3.fromRGB(140,130,160)
            detLbl.Font              = Enum.Font.Gotham
            detLbl.TextSize          = 11
            detLbl.TextXAlignment    = Enum.TextXAlignment.Left

            local cntLbl = Instance.new("TextLabel", btn)
            cntLbl.Size              = UDim2.new(0,44,1,0)
            cntLbl.Position          = UDim2.new(1,-50,0,0)
            cntLbl.BackgroundTransparency = 1
            cntLbl.Text              = "x" .. count
            cntLbl.TextColor3        = Color3.fromRGB(200,160,40)
            cntLbl.Font              = Enum.Font.GothamBold
            cntLbl.TextSize          = 14

            btn.MouseButton1Click:Connect(function()
                sg:Destroy()
                EggOpenGUI.OnPlaceInNest(dragonId)
            end)
        end
    end

    if not hayItems then
        local emptyLbl = Instance.new("TextLabel", scroll)
        emptyLbl.Size               = UDim2.new(1,0,0,60)
        emptyLbl.BackgroundTransparency = 1
        emptyLbl.Text               = "Inventario vacío.\nCompra dragones en la tienda (tecla B)."
        emptyLbl.TextColor3         = Color3.fromRGB(160,140,180)
        emptyLbl.Font               = Enum.Font.Gotham
        emptyLbl.TextSize           = 13
        emptyLbl.TextWrapped        = true
    end
end

-- Atajo de teclado: N deshabilitado (flujo reemplazado por InventoryGUI)

return EggOpenGUI
