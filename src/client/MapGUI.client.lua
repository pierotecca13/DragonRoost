--------------------------------------------------------------------------------
-- MapGUI.client.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Minimapa siempre visible en la esquina inferior izquierda del HUD.
-- Muestra 8 iconos de granja en posición proporcional al grid del mundo.
--
-- COLORES DE NIVEL:
--   N1-3  : verde       N4-7  : azul
--   N8-11 : morado      N12-15: dorado      Vacío: gris
--
-- Al hacer clic en un ícono aparece un popup con nombre, nivel, oro/seg
-- y botón "Visitar". La propia granja del jugador tiene borde dorado pulsante.
-- Se actualiza al recibir RemoteEvent "EstadoServidorActualizado".
--------------------------------------------------------------------------------

local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Constantes
--------------------------------------------------------------------------------

local MAP_W      = 200
local MAP_H      = 110
local MAP_MARGIN_X = 12
local MAP_MARGIN_Y = 90   -- sobre la NavBar del HUD

local COLUMNAS = 4
local FILAS    = 2
local N_SLOTS  = COLUMNAS * FILAS  -- 8

local ICON_W = 38
local ICON_H = 38

local LEVEL_COLORS = {
    { maxLevel = 3,  color = Color3.fromRGB( 60, 180,  60) },
    { maxLevel = 7,  color = Color3.fromRGB( 60, 120, 220) },
    { maxLevel = 11, color = Color3.fromRGB(140,  60, 210) },
    { maxLevel = 15, color = Color3.fromRGB(210, 165,  30) },
}
local COLOR_VACIO = Color3.fromRGB(70, 70, 80)

local PANEL_BG     = Color3.fromRGB( 15,  10,  25)
local BORDER_COLOR = Color3.fromRGB(200, 160,  50)
local TEXT_PRIMARY = Color3.fromRGB(255, 240, 200)
local TEXT_DIM     = Color3.fromRGB(160, 148, 120)
local TEXT_HEADER  = Color3.fromRGB(255, 215,  80)

local TWEEN_FAST  = TweenInfo.new(0.20, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_PULSE = TweenInfo.new(0.70, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

--------------------------------------------------------------------------------
-- Estado
--------------------------------------------------------------------------------

local state = {
    estadoServidor = {},
    slotPropio     = nil,
    popupAbierto   = nil,
}

--------------------------------------------------------------------------------
-- Referencias UI
--------------------------------------------------------------------------------

local ui = {
    screenGui  = nil,
    mapPanel   = nil,
    iconos     = {},   -- [slotIndex] = { frame, label, nivelLbl, stroke }
    popup      = nil,
    pulsoTween = nil,
}

--------------------------------------------------------------------------------
-- MapGUI (declarado antes de definir sus funciones)
--------------------------------------------------------------------------------

local MapGUI = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function colorParaNivel(nivel)
    if not nivel or nivel <= 0 then return COLOR_VACIO end
    for _, entry in ipairs(LEVEL_COLORS) do
        if nivel <= entry.maxLevel then return entry.color end
    end
    return LEVEL_COLORS[#LEVEL_COLORS].color
end

local function posEnMapa(slotIndex)
    local col   = (slotIndex - 1) % COLUMNAS
    local row   = math.floor((slotIndex - 1) / COLUMNAS)
    local padX  = 8
    local padY  = 22
    local areaW = MAP_W - padX * 2 - ICON_W
    local areaH = MAP_H - padY - 8 - ICON_H
    local stepX = areaW / math.max(COLUMNAS - 1, 1)
    local stepY = areaH / math.max(FILAS    - 1, 1)
    return UDim2.new(0, math.floor(padX + col * stepX), 0, math.floor(padY + row * stepY))
end

local function fmt(n)
    n = math.floor(n or 0)
    if n >= 1_000_000 then return ("%.1fM"):format(n / 1e6) end
    if n >= 1_000     then return ("%.1fK"):format(n / 1e3) end
    return tostring(n)
end

--------------------------------------------------------------------------------
-- Popup
--------------------------------------------------------------------------------

local function cerrarPopup()
    if ui.popup then
        ui.popup:Destroy()
        ui.popup       = nil
        state.popupAbierto = nil
    end
end

local function abrirPopup(slotIndex)
    cerrarPopup()

    local slot = state.estadoServidor[slotIndex]
    if not slot then return end
    state.popupAbierto = slotIndex

    local Remotes            = ReplicatedStorage:FindFirstChild("Remotes")
    local RequestVisitarFunc = Remotes and Remotes:FindFirstChild("RequestVisitar")

    -- Posición del ícono en pantalla
    local icono   = ui.iconos[slotIndex]
    local iconPos = icono and icono.frame.AbsolutePosition or Vector2.new(0, 0)

    local popup = Instance.new("Frame")
    popup.Name                   = "GranjaPopup"
    popup.Size                   = UDim2.new(0, 200, 0, 0)
    popup.AutomaticSize          = Enum.AutomaticSize.Y
    popup.BackgroundColor3       = PANEL_BG
    popup.BackgroundTransparency = 0.05
    popup.BorderSizePixel        = 0
    popup.ZIndex                 = 20
    popup.Parent                 = ui.screenGui

    local pCorner = Instance.new("UICorner")
    pCorner.CornerRadius = UDim.new(0, 8)
    pCorner.Parent       = popup

    local pStroke = Instance.new("UIStroke")
    pStroke.Color     = slot.activo and colorParaNivel(slot.nivel) or COLOR_VACIO
    pStroke.Thickness = 2
    pStroke.Parent    = popup

    local pLayout = Instance.new("UIListLayout")
    pLayout.SortOrder = Enum.SortOrder.LayoutOrder
    pLayout.Padding   = UDim.new(0, 4)
    pLayout.Parent    = popup

    local pPad = Instance.new("UIPadding")
    pPad.PaddingTop    = UDim.new(0, 8); pPad.PaddingBottom = UDim.new(0, 8)
    pPad.PaddingLeft   = UDim.new(0, 8); pPad.PaddingRight  = UDim.new(0, 8)
    pPad.Parent        = popup

    local orden = 0
    local function addLabel(texto, fuente, color, alin)
        orden = orden + 1
        local lbl = Instance.new("TextLabel")
        lbl.Size                   = UDim2.new(1, 0, 0, 20)
        lbl.BackgroundTransparency = 1
        lbl.Font                   = fuente or Enum.Font.Gotham
        lbl.TextSize               = 12
        lbl.TextColor3             = color or TEXT_PRIMARY
        lbl.TextXAlignment         = alin or Enum.TextXAlignment.Left
        lbl.TextTruncate           = Enum.TextTruncate.AtEnd
        lbl.Text                   = texto
        lbl.LayoutOrder            = orden
        lbl.ZIndex                 = 21
        lbl.Parent                 = popup
        return lbl
    end

    if slot.activo and slot.jugador then
        addLabel(slot.jugador, Enum.Font.GothamBold, TEXT_HEADER, Enum.TextXAlignment.Center)
        addLabel(("Nivel %d"):format(slot.nivel or 1))
        addLabel(("Oro/seg: %s"):format(fmt(slot.oroPorSegundo or 0)), Enum.Font.Gotham, TEXT_DIM)

        if state.slotPropio ~= slotIndex then
            orden = orden + 1
            local visitBtn = Instance.new("TextButton")
            visitBtn.Size             = UDim2.new(1, 0, 0, 32)
            visitBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 140)
            visitBtn.BorderSizePixel  = 0
            visitBtn.Font             = Enum.Font.GothamBold
            visitBtn.TextSize         = 12
            visitBtn.TextColor3       = TEXT_PRIMARY
            visitBtn.Text             = "🚶 Visitar"
            visitBtn.LayoutOrder      = orden
            visitBtn.ZIndex           = 21
            visitBtn.Parent           = popup
            local vc = Instance.new("UICorner"); vc.CornerRadius = UDim.new(0, 6); vc.Parent = visitBtn

            visitBtn.Activated:Connect(function()
                if not RequestVisitarFunc then return end
                cerrarPopup()
                RequestVisitarFunc:InvokeServer(slotIndex)
            end)
        else
            addLabel("← Tu granja", Enum.Font.GothamBold, Color3.fromRGB(255, 215, 80),
                Enum.TextXAlignment.Center)
        end
    else
        addLabel("Slot vacío", Enum.Font.Gotham, TEXT_DIM, Enum.TextXAlignment.Center)
    end

    -- Botón cerrar
    orden = orden + 1
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size             = UDim2.new(1, 0, 0, 26)
    closeBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
    closeBtn.BorderSizePixel  = 0
    closeBtn.Font             = Enum.Font.Gotham
    closeBtn.TextSize         = 11
    closeBtn.TextColor3       = TEXT_DIM
    closeBtn.Text             = "Cerrar"
    closeBtn.LayoutOrder      = orden
    closeBtn.ZIndex           = 21
    closeBtn.Parent           = popup
    local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 6); cc.Parent = closeBtn
    closeBtn.Activated:Connect(cerrarPopup)

    -- Posicionar popup cerca del ícono
    local sg      = ui.screenGui
    local absSize = sg.AbsoluteSize
    local rawX    = iconPos.X - 10
    local rawY    = iconPos.Y - 170
    popup.Position = UDim2.new(0,
        math.clamp(rawX, 4, absSize.X - 210),
        0,
        rawY < 10 and (iconPos.Y + ICON_H + 4) or rawY)
end

--------------------------------------------------------------------------------
-- MapGUI.HighlightGranja(slotIndex) — borde dorado pulsante para slot propio
--------------------------------------------------------------------------------
function MapGUI.HighlightGranja(slotIndex)
    local icono = ui.iconos[slotIndex]
    if not icono then return end

    if ui.pulsoTween then ui.pulsoTween:Cancel() end

    icono.stroke.Color     = BORDER_COLOR
    icono.stroke.Thickness = 3

    local function pulsar()
        ui.pulsoTween = TweenService:Create(icono.stroke, TWEEN_PULSE, { Thickness = 1.5 })
        ui.pulsoTween:Play()
        ui.pulsoTween.Completed:Connect(function()
            if state.slotPropio == slotIndex and ui.iconos[slotIndex] then
                ui.pulsoTween = TweenService:Create(icono.stroke, TWEEN_PULSE, { Thickness = 3 })
                ui.pulsoTween:Play()
                ui.pulsoTween.Completed:Connect(pulsar)
            end
        end)
    end
    pulsar()
end

--------------------------------------------------------------------------------
-- MapGUI.ActualizarEstado(estadoServidor)
--------------------------------------------------------------------------------
function MapGUI.ActualizarEstado(estadoServidor)
    state.estadoServidor = estadoServidor or {}

    -- Detectar slot propio
    state.slotPropio = nil
    for _, slot in ipairs(state.estadoServidor) do
        if slot.jugador == player.Name then
            state.slotPropio = slot.slotIndex
        end
    end

    for i = 1, N_SLOTS do
        local slot  = state.estadoServidor[i]
        local icono = ui.iconos[i]
        if not icono then continue end

        local activo = slot and slot.activo and slot.jugador

        if activo then
            local color = colorParaNivel(slot.nivel or 0)
            icono.frame.BackgroundColor3       = color
            icono.frame.BackgroundTransparency = 0.15
            icono.stroke.Color                 = color
            icono.label.Text                   = slot.jugador:sub(1, 1):upper()
            icono.label.TextColor3             = Color3.fromRGB(255, 250, 220)
            icono.nivelLbl.Text                = "N" .. (slot.nivel or 1)

            if i == state.slotPropio then
                MapGUI.HighlightGranja(i)
            else
                icono.stroke.Thickness = 1.5
            end
        else
            icono.frame.BackgroundColor3       = COLOR_VACIO
            icono.frame.BackgroundTransparency = 0.55
            icono.stroke.Color                 = Color3.fromRGB(90, 90, 100)
            icono.stroke.Thickness             = 1
            icono.label.Text                   = "·"
            icono.label.TextColor3             = TEXT_DIM
            icono.nivelLbl.Text                = ""
        end
    end

    if state.popupAbierto then
        cerrarPopup()
    end
end

--------------------------------------------------------------------------------
-- construirUI
--------------------------------------------------------------------------------

local function construirUI()
    local sg = Instance.new("ScreenGui")
    sg.Name           = "MapGUI"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent         = playerGui
    ui.screenGui      = sg

    local mapPanel = Instance.new("Frame")
    mapPanel.Name                   = "MapPanel"
    mapPanel.Size                   = UDim2.new(0, MAP_W, 0, MAP_H)
    mapPanel.Position               = UDim2.new(0, MAP_MARGIN_X, 1, -(MAP_H + MAP_MARGIN_Y))
    mapPanel.BackgroundColor3       = PANEL_BG
    mapPanel.BackgroundTransparency = 0.20
    mapPanel.BorderSizePixel        = 0
    mapPanel.Parent                 = sg
    ui.mapPanel = mapPanel

    local mpCorner = Instance.new("UICorner")
    mpCorner.CornerRadius = UDim.new(0, 8)
    mpCorner.Parent       = mapPanel

    local mpStroke = Instance.new("UIStroke")
    mpStroke.Color     = BORDER_COLOR
    mpStroke.Thickness = 1.5
    mpStroke.Parent    = mapPanel

    local titulo = Instance.new("TextLabel")
    titulo.Size                   = UDim2.new(1, 0, 0, 18)
    titulo.Position               = UDim2.new(0, 0, 0, 2)
    titulo.BackgroundTransparency = 1
    titulo.Font                   = Enum.Font.GothamBold
    titulo.TextSize               = 10
    titulo.TextColor3             = TEXT_HEADER
    titulo.TextXAlignment         = Enum.TextXAlignment.Center
    titulo.Text                   = "🗺  SERVIDOR"
    titulo.Parent                 = mapPanel

    -- Crear 8 íconos de granja
    for i = 1, N_SLOTS do
        local pos = posEnMapa(i)

        local iconFr = Instance.new("Frame")
        iconFr.Name                   = "Granja_" .. i
        iconFr.Size                   = UDim2.new(0, ICON_W, 0, ICON_H)
        iconFr.Position               = pos
        iconFr.BackgroundColor3       = COLOR_VACIO
        iconFr.BackgroundTransparency = 0.55
        iconFr.BorderSizePixel        = 0
        iconFr.ZIndex                 = 3
        iconFr.Parent                 = mapPanel

        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0, 6)
        iconCorner.Parent       = iconFr

        local iconStroke = Instance.new("UIStroke")
        iconStroke.Color     = Color3.fromRGB(90, 90, 100)
        iconStroke.Thickness = 1
        iconStroke.Parent    = iconFr

        local iconLbl = Instance.new("TextLabel")
        iconLbl.Size                   = UDim2.new(1, 0, 0, 22)
        iconLbl.Position               = UDim2.new(0, 0, 0, 2)
        iconLbl.BackgroundTransparency = 1
        iconLbl.Font                   = Enum.Font.GothamBold
        iconLbl.TextSize               = 16
        iconLbl.TextColor3             = TEXT_DIM
        iconLbl.TextXAlignment         = Enum.TextXAlignment.Center
        iconLbl.Text                   = "·"
        iconLbl.ZIndex                 = 4
        iconLbl.Parent                 = iconFr

        local nivelLbl = Instance.new("TextLabel")
        nivelLbl.Size                   = UDim2.new(1, 0, 0, 12)
        nivelLbl.Position               = UDim2.new(0, 0, 0, 24)
        nivelLbl.BackgroundTransparency = 1
        nivelLbl.Font                   = Enum.Font.Gotham
        nivelLbl.TextSize               = 9
        nivelLbl.TextColor3             = TEXT_DIM
        nivelLbl.TextXAlignment         = Enum.TextXAlignment.Center
        nivelLbl.Text                   = ""
        nivelLbl.ZIndex                 = 4
        nivelLbl.Parent                 = iconFr

        local clickBtn = Instance.new("TextButton")
        clickBtn.Size                   = UDim2.new(1, 0, 1, 0)
        clickBtn.BackgroundTransparency = 1
        clickBtn.Text                   = ""
        clickBtn.ZIndex                 = 5
        clickBtn.Parent                 = iconFr

        local capI = i
        clickBtn.Activated:Connect(function()
            if state.popupAbierto == capI then
                cerrarPopup()
            else
                abrirPopup(capI)
            end
        end)

        ui.iconos[i] = {
            frame    = iconFr,
            label    = iconLbl,
            nivelLbl = nivelLbl,
            stroke   = iconStroke,
        }
    end
end

--------------------------------------------------------------------------------
-- MapGUI.Init()
--------------------------------------------------------------------------------
function MapGUI.Init()
    construirUI()

    local Remotes = ReplicatedStorage:WaitForChild("Remotes", 12)
    local ev = Remotes and Remotes:WaitForChild("EstadoServidorActualizado", 12)
    if ev then
        ev.OnClientEvent:Connect(function(estadoServidor)
            MapGUI.ActualizarEstado(estadoServidor)
        end)
    else
        warn("[MapGUI] RemoteEvent 'EstadoServidorActualizado' no encontrado.")
    end

    print("[MapGUI] Minimapa inicializado.")
end

--------------------------------------------------------------------------------
-- Arranque
--------------------------------------------------------------------------------

MapGUI.Init()

return MapGUI
