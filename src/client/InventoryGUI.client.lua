--------------------------------------------------------------------------------
-- InventoryGUI.client.lua  ·  LocalScript de cliente  ·  Dragon Roost
--
-- Inventario unificado del jugador: Dragones, Huevos y Boosts.
--
--   Tab Dragones — grilla de cards por tipo de dragón.
--                  Acciones: Colocar en nido, Reemplazar en nido, Vender (GPS×60).
--   Tab Huevos   — grilla de huevos recolectados sin incubar.
--                  Acciones: Incubar (selector de slot), Vender.
--   Tab Boosts   — inventario de boosts de producción.
--                  Acciones: Aplicar al mejor nido.
--
-- Header: contador compartido X/Y (dragones + huevos) y límite por nivel.
-- Se abre desde el botón 🎒 de la NavBar del HUD.
--------------------------------------------------------------------------------

local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Paleta de colores (alineada con el resto del juego)
--------------------------------------------------------------------------------

local PANEL_BG     = Color3.fromRGB( 15,  10,  25)
local BORDER_COLOR = Color3.fromRGB(200, 160,  50)
local TEXT_PRIMARY = Color3.fromRGB(255, 240, 200)
local TEXT_HEADER  = Color3.fromRGB(255, 215,  80)
local TEXT_DIM     = Color3.fromRGB(160, 148, 120)

local RARITY_COLORS = {
    comun      = Color3.fromRGB(180, 180, 180),
    poco_comun = Color3.fromRGB( 80, 200,  80),
    raro       = Color3.fromRGB( 80, 130, 220),
    epico      = Color3.fromRGB(160,  80, 220),
    legendario = Color3.fromRGB(255, 165,   0),
    mitico     = Color3.fromRGB(255,  50,  50),
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

local TWEEN_FAST  = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_SLIDE = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

--------------------------------------------------------------------------------
-- Estado
--------------------------------------------------------------------------------

local state = {
    visible         = false,
    tabActual       = "dragones",   -- "dragones" | "huevos" | "boosts"
    dragonSelected  = nil,          -- dragonId seleccionado
    huevoSelected   = nil,          -- { idx, entry }
    boostSelected   = nil,          -- boostId seleccionado
    -- Datos cacheados del servidor (se refrescan al abrir)
    inventarioDragones = {},        -- { dragonId = count }
    inventarioHuevos   = {},        -- { [idx] = { dragonId, parentName, parentRareza, ... } }
    inventarioBoosts   = {},        -- { boostId = count }
    inventarioLimite   = 5,
    inventarioTotal    = 0,
}

--------------------------------------------------------------------------------
-- Referencias UI
--------------------------------------------------------------------------------

local ui = {
    screenGui   = nil,
    ventana     = nil,
    headerLbl   = nil,
    contLbl     = nil,
    tabBtns     = {},               -- { dragones, huevos, boosts }
    contenido   = nil,              -- frame que se rellena dinámicamente
    accionPanel = nil,              -- panel de botones de acción
    accionBtns  = {},
    msgLbl      = nil,
}

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local Remotes
local RequestInventarioFunc       -- RequestGetCatalogueData (inventario de dragones)
local RequestBoostInventarioFunc  -- RequestBoostInventario
local RequestAplicarBoostAutoFunc -- RequestAplicarBoostAuto
local RequestReemplazarDragonFunc -- RequestReemplazarDragon
local RequestPlaceDragonFunc      -- RequestPlaceDragonInNest
local StartIncubationFunc         -- RequestStartIncubation
local SellDragonFunc              -- RequestVenderDragon (si existe) — fallback: usar gold
local RequestNestDataFunc         -- RequestGetNestData

-- El RequestVenderDragon se manejará localmente de forma segura
local RequestVenderDragonFunc     -- opcional, puede no existir aún
local RequestEggStatusFunc        -- RequestGetAllEggStatuses

local function obtenerRemote(nombre, clase)
    clase = clase or "RemoteFunction"
    if not Remotes then return nil end
    return Remotes:FindFirstChild(nombre)
end

--------------------------------------------------------------------------------
-- Helpers de creación UI
--------------------------------------------------------------------------------

local function crearFrame(nombre, tamano, posicion, padre, color, transp)
    local fr = Instance.new("Frame")
    fr.Name                   = nombre
    fr.Size                   = tamano
    fr.Position               = posicion
    fr.BackgroundColor3       = color or PANEL_BG
    fr.BackgroundTransparency = transp or 0
    fr.BorderSizePixel        = 0
    fr.Parent                 = padre
    return fr
end

local function crearLabel(texto, tamano, posicion, padre, fuente, color, size)
    local lbl = Instance.new("TextLabel")
    lbl.Size                   = tamano
    lbl.Position               = posicion
    lbl.BackgroundTransparency = 1
    lbl.Text                   = texto
    lbl.Font                   = fuente or Enum.Font.Gotham
    lbl.TextSize               = size or 13
    lbl.TextColor3             = color or TEXT_PRIMARY
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.TextWrapped            = true
    lbl.Parent                 = padre
    return lbl
end

local function crearBoton(texto, tamano, posicion, padre, colorBg)
    local bg  = colorBg or Color3.fromRGB(130, 90, 15)
    local btn = Instance.new("TextButton")
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
    local hover = Color3.fromRGB(math.min(bg.R * 255 + 40, 255) / 255,
        math.min(bg.G * 255 + 25, 255) / 255,
        math.min(bg.B * 255 + 10, 255) / 255)
    btn.MouseEnter:Connect(function() TweenService:Create(btn, TWEEN_FAST, { BackgroundColor3 = hover }):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn, TWEEN_FAST, { BackgroundColor3 = bg }):Play() end)
    return btn
end

local function mostrarMensaje(texto, tipo)
    if not ui.msgLbl then return end
    local colorBg  = tipo == "error"   and Color3.fromRGB(60, 20, 20)    or Color3.fromRGB(20, 50, 20)
    local colorTxt = tipo == "error"   and Color3.fromRGB(255, 130, 130)  or Color3.fromRGB(130, 255, 130)
    if tipo == "warning" then
        colorBg  = Color3.fromRGB(55, 45, 10)
        colorTxt = Color3.fromRGB(255, 220, 80)
    end
    ui.msgLbl.Text             = texto
    ui.msgLbl.BackgroundColor3 = colorBg
    ui.msgLbl.TextColor3       = colorTxt
    ui.msgLbl.Visible          = true
    task.delay(3.5, function()
        if ui.msgLbl then ui.msgLbl.Visible = false end
    end)
end

local function limpiarContenido()
    if ui.contenido then
        for _, c in ipairs(ui.contenido:GetChildren()) do
            if not c:IsA("UIListLayout") and not c:IsA("UIGridLayout")
                and not c:IsA("UIPadding") then
                c:Destroy()
            end
        end
    end
    -- Limpiar selección
    state.dragonSelected = nil
    state.huevoSelected  = nil
    state.boostSelected  = nil
    -- Ocultar panel de acciones
    if ui.accionPanel then
        ui.accionPanel.Visible = false
    end
end

local function actualizarHeader()
    local total = state.inventarioTotal
    local lim   = state.inventarioLimite
    if ui.headerLbl then
        ui.headerLbl.Text = "🎒 INVENTARIO"
    end
    if ui.contLbl then
        -- Contar por tipo
        local nDragones = 0
        for _, c in pairs(state.inventarioDragones) do nDragones += c end
        local nHuevos   = 0
        for _ in pairs(state.inventarioHuevos) do nHuevos += 1 end
        ui.contLbl.Text = ("Dragones: %d  Huevos: %d  /  %d"):format(nDragones, nHuevos, lim)
        -- Colorear rojo si lleno
        ui.contLbl.TextColor3 = (nDragones + nHuevos >= lim)
            and Color3.fromRGB(255, 80, 80)
            or  TEXT_DIM
    end
end

--------------------------------------------------------------------------------
-- Selector de nido (popup para elegir nido)
--------------------------------------------------------------------------------

local function mostrarSelectorNido(dragonId, callback)
    -- Obtener datos de nidos del servidor
    local nestDataFunc = Remotes and Remotes:FindFirstChild("RequestNestData")
    -- Usamos NestUpdated cacheado si no hay función
    local nestData = nil
    if nestDataFunc then
        local ok, nd = pcall(function() return nestDataFunc:InvokeServer() end)
        if ok then nestData = nd end
    end

    -- Crear popup de selección de nido
    local popup = crearFrame("NestSelector",
        UDim2.new(0, 340, 0, 0),
        UDim2.new(0.5, -170, 0.5, -100),
        ui.ventana, Color3.fromRGB(20, 14, 38), 0)
    popup.AutomaticSize  = Enum.AutomaticSize.Y
    popup.ZIndex         = 20
    local popC = Instance.new("UICorner"); popC.CornerRadius = UDim.new(0, 8); popC.Parent = popup
    local popS = Instance.new("UIStroke"); popS.Color = BORDER_COLOR; popS.Thickness = 1.5; popS.Parent = popup
    local popP = Instance.new("UIPadding")
    popP.PaddingTop = UDim.new(0, 8); popP.PaddingBottom = UDim.new(0, 8)
    popP.PaddingLeft = UDim.new(0, 8); popP.PaddingRight = UDim.new(0, 8)
    popP.Parent = popup
    local popList = Instance.new("UIListLayout")
    popList.SortOrder = Enum.SortOrder.LayoutOrder
    popList.Padding   = UDim.new(0, 4)
    popList.Parent    = popup

    local titulo = Instance.new("TextLabel")
    titulo.Size                   = UDim2.new(1, 0, 0, 24)
    titulo.BackgroundTransparency = 1
    titulo.Font                   = Enum.Font.GothamBold
    titulo.TextSize               = 14
    titulo.TextColor3             = TEXT_HEADER
    titulo.TextXAlignment         = Enum.TextXAlignment.Center
    titulo.Text                   = "Seleccioná un nido"
    titulo.LayoutOrder            = 0
    titulo.Parent                 = popup

    local maxSlots = nestData and nestData.slots or 3
    for i = 1, maxSlots do
        local nido    = nestData and nestData.nests and nestData.nests[i]
        local ocupado = nido and nido.dragonId
        local drInfo  = ocupado and DragonData.GetDragonById(nido.dragonId)

        local txt = ocupado
            and ("Nido %d — %s (Reemplazar)"):format(i, drInfo and drInfo.name or ocupado)
            or  ("Nido %d — Vacío"):format(i)

        local rowBtn = crearBoton(txt,
            UDim2.new(1, 0, 0, 32),
            UDim2.new(0, 0, 0, 0),
            popup,
            ocupado and Color3.fromRGB(55, 35, 80) or Color3.fromRGB(35, 55, 30))
        rowBtn.TextXAlignment = Enum.TextXAlignment.Left
        rowBtn.TextSize       = 11
        rowBtn.LayoutOrder    = i

        local capIdx      = i
        local capOcupado  = ocupado
        rowBtn.Activated:Connect(function()
            popup:Destroy()
            callback(capIdx, capOcupado)
        end)
    end

    local cancelBtn = crearBoton("Cancelar",
        UDim2.new(1, 0, 0, 28),
        UDim2.new(0, 0, 0, 0),
        popup, Color3.fromRGB(60, 25, 25))
    cancelBtn.TextXAlignment = Enum.TextXAlignment.Center
    cancelBtn.LayoutOrder    = maxSlots + 1
    cancelBtn.Activated:Connect(function() popup:Destroy() end)
end

--------------------------------------------------------------------------------
-- Tab: Dragones
--------------------------------------------------------------------------------

local function renderDragones()
    limpiarContenido()
    state.tabActual = "dragones"

    local inv = state.inventarioDragones
    if not next(inv) then
        local lbl = crearLabel("No tenés dragones en el inventario.",
            UDim2.new(1, 0, 0, 40),
            UDim2.new(0, 0, 0, 8),
            ui.contenido, Enum.Font.Gotham, TEXT_DIM, 12)
        lbl.TextXAlignment = Enum.TextXAlignment.Center
        return
    end

    -- Una fila por tipo de dragón con count
    for dragonId, count in pairs(inv) do
        if count <= 0 then continue end
        local dragon = DragonData.GetDragonById(dragonId)
        if not dragon then continue end

        local rarColor = RARITY_COLORS[dragon.rarity] or TEXT_PRIMARY

        local cardFr = crearFrame("Card_" .. dragonId,
            UDim2.new(1, -4, 0, 52),
            UDim2.new(0, 0, 0, 0),
            ui.contenido, Color3.fromRGB(20, 14, 38), 0.15)
        cardFr.AutomaticSize = Enum.AutomaticSize.None
        local cardC = Instance.new("UICorner"); cardC.CornerRadius = UDim.new(0, 6); cardC.Parent = cardFr
        local cardS = Instance.new("UIStroke"); cardS.Color = rarColor; cardS.Thickness = 1.2
            cardS.Transparency = 0.6; cardS.Parent = cardFr

        -- Nombre (con cantidad si hay más de 1)
        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size                   = UDim2.new(1, -98, 0, 22)
        nameLbl.Position               = UDim2.new(0, 8, 0, 4)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font                   = Enum.Font.GothamBold
        nameLbl.TextSize               = 13
        nameLbl.TextColor3             = rarColor
        nameLbl.TextXAlignment         = Enum.TextXAlignment.Left
        nameLbl.Text                   = count > 1
            and (dragon.name .. "  ×" .. count)
            or  dragon.name
        nameLbl.TextTruncate           = Enum.TextTruncate.AtEnd
        nameLbl.Parent                 = cardFr

        -- Elemento · Rareza · GPS
        local infoLbl = Instance.new("TextLabel")
        infoLbl.Size                   = UDim2.new(1, -98, 0, 18)
        infoLbl.Position               = UDim2.new(0, 8, 0, 26)
        infoLbl.BackgroundTransparency = 1
        infoLbl.Font                   = Enum.Font.Gotham
        infoLbl.TextSize               = 10
        infoLbl.TextColor3             = TEXT_DIM
        infoLbl.TextXAlignment         = Enum.TextXAlignment.Left
        local elemEmoji = ELEMENT_EMOJI[dragon.element] or ""
        infoLbl.Text = ("%s%s · %s · %.2f GPS"):format(
            elemEmoji ~= "" and (elemEmoji .. " ") or "",
            dragon.element or "?", dragon.rarity or "?", dragon.goldPerSecond or 0)
        infoLbl.Parent                 = cardFr

        -- Botón Seleccionar
        local selBtn = crearBoton("Seleccionar",
            UDim2.new(0, 88, 0, 30),
            UDim2.new(1, -94, 0.5, -15),
            cardFr, Color3.fromRGB(55, 35, 90))
        selBtn.TextSize = 11

        local capId = dragonId
        selBtn.Activated:Connect(function()
            state.dragonSelected = capId
            mostrarAccionesDragon(capId, dragon)
        end)
    end
end

function mostrarAccionesDragon(dragonId, dragon)
    if not ui.accionPanel then return end
    -- Limpiar botones anteriores
    for _, c in ipairs(ui.accionBtns) do
        if c and c.Parent then c:Destroy() end
    end
    ui.accionBtns = {}
    ui.accionPanel.Visible = true

    local rarColor = RARITY_COLORS[dragon.rarity] or TEXT_PRIMARY

    -- Título
    local titLbl = Instance.new("TextLabel")
    titLbl.Size                   = UDim2.new(1, -10, 0, 20)
    titLbl.Position               = UDim2.new(0, 5, 0, 4)
    titLbl.BackgroundTransparency = 1
    titLbl.Font                   = Enum.Font.GothamBold
    titLbl.TextSize               = 12
    titLbl.TextColor3             = rarColor
    titLbl.Text                   = dragon.name
    titLbl.TextXAlignment         = Enum.TextXAlignment.Left
    titLbl.Parent                 = ui.accionPanel
    table.insert(ui.accionBtns, titLbl)

    -- Subtítulo: tipo · rareza · GPS
    local subLbl = Instance.new("TextLabel")
    subLbl.Size                   = UDim2.new(1, -10, 0, 16)
    subLbl.Position               = UDim2.new(0, 5, 0, 26)
    subLbl.BackgroundTransparency = 1
    subLbl.Font                   = Enum.Font.Gotham
    subLbl.TextSize               = 10
    subLbl.TextColor3             = TEXT_DIM
    subLbl.TextXAlignment         = Enum.TextXAlignment.Left
    local subEmoji = ELEMENT_EMOJI[dragon.element] or ""
    subLbl.Text = ("%s%s · %s · %.2f GPS"):format(
        subEmoji ~= "" and (subEmoji .. " ") or "",
        dragon.element or "?", dragon.rarity or "?", dragon.goldPerSecond or 0)
    subLbl.Parent                 = ui.accionPanel
    table.insert(ui.accionBtns, subLbl)

    -- Vender (GPS × 60)
    local sellPrice = math.floor((dragon.goldPerSecond or 0) * 60)
    local sellBtn   = crearBoton(("Vender — %d oro"):format(sellPrice),
        UDim2.new(1, -10, 0, 28),
        UDim2.new(0, 5, 0, 46),
        ui.accionPanel, Color3.fromRGB(100, 50, 10))
    sellBtn.TextSize = 11
    table.insert(ui.accionBtns, sellBtn)

    sellBtn.Activated:Connect(function()
        if not sellBtn.Active then return end
        sellBtn.Active = false
        local rf = Remotes and Remotes:FindFirstChild("RequestVenderDragonInventario")
        if not rf then
            mostrarMensaje("Función de venta no disponible aún.", "warning")
            sellBtn.Active = true
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer(dragonId) end)
        if ok and type(res) == "table" and res.ok then
            mostrarMensaje(("Vendiste %s por %d oro."):format(dragon.name, sellPrice), "success")
            -- Actualizar local
            state.inventarioDragones[dragonId] = (state.inventarioDragones[dragonId] or 1) - 1
            if state.inventarioDragones[dragonId] <= 0 then
                state.inventarioDragones[dragonId] = nil
            end
            renderDragones()
            actualizarHeader()
        else
            local msg = (type(res) == "table" and res.error) or "No se pudo vender."
            mostrarMensaje(msg, "error")
            sellBtn.Active = true
        end
    end)

    -- Colocar / Reemplazar en nido
    local colocarBtn = crearBoton("Colocar en nido",
        UDim2.new(1, -10, 0, 28),
        UDim2.new(0, 5, 0, 78),
        ui.accionPanel, Color3.fromRGB(35, 70, 35))
    colocarBtn.TextSize = 11
    table.insert(ui.accionBtns, colocarBtn)

    colocarBtn.Activated:Connect(function()
        if not colocarBtn.Active then return end
        mostrarSelectorNido(dragonId, function(nestIndex, estaOcupado)
            colocarBtn.Active = false
            if estaOcupado then
                -- Reemplazar
                local rf = Remotes and Remotes:FindFirstChild("RequestReemplazarDragon")
                if not rf then
                    mostrarMensaje("No se pudo conectar con el servidor.", "error")
                    colocarBtn.Active = true
                    return
                end
                local ok, res = pcall(function() return rf:InvokeServer(nestIndex, dragonId) end)
                if ok and type(res) == "table" and res.ok then
                    mostrarMensaje(res.message or "¡Dragón reemplazado!", "success")
                    state.inventarioDragones[dragonId] = (state.inventarioDragones[dragonId] or 1) - 1
                    if state.inventarioDragones[dragonId] <= 0 then
                        state.inventarioDragones[dragonId] = nil
                    end
                    renderDragones()
                    actualizarHeader()
                else
                    local msg = (type(res) == "table" and res.error) or "Error al reemplazar."
                    mostrarMensaje(msg, "error")
                    colocarBtn.Active = true
                end
            else
                -- Colocar en vacío
                local rf = Remotes and Remotes:FindFirstChild("RequestPlaceDragonInNest")
                if not rf then
                    mostrarMensaje("No se pudo conectar con el servidor.", "error")
                    colocarBtn.Active = true
                    return
                end
                local ok, res = pcall(function() return rf:InvokeServer(dragonId, nestIndex) end)
                if ok and type(res) == "table" and res.ok then
                    mostrarMensaje(res.message or "¡Dragón colocado!", "success")
                    state.inventarioDragones[dragonId] = (state.inventarioDragones[dragonId] or 1) - 1
                    if state.inventarioDragones[dragonId] <= 0 then
                        state.inventarioDragones[dragonId] = nil
                    end
                    renderDragones()
                    actualizarHeader()
                else
                    local err = (type(res) == "table" and res.error) or tostring(res or "")
                    mostrarMensaje(err ~= "" and err or "Error al colocar.", "error")
                    colocarBtn.Active = true
                end
            end
        end)
    end)
end

--------------------------------------------------------------------------------
-- Tab: Huevos
--------------------------------------------------------------------------------

local function renderHuevos()
    limpiarContenido()
    state.tabActual = "huevos"

    local inv = state.inventarioHuevos
    if not next(inv) then
        local lbl = crearLabel("No tenés huevos en el inventario.",
            UDim2.new(1, 0, 0, 40),
            UDim2.new(0, 0, 0, 8),
            ui.contenido, Enum.Font.Gotham, TEXT_DIM, 12)
        lbl.TextXAlignment = Enum.TextXAlignment.Center
        return
    end

    for eggIdx, huevo in pairs(inv) do
        local rarColor = RARITY_COLORS[huevo.parentRareza] or TEXT_PRIMARY

        local cardFr = crearFrame("EggCard_" .. tostring(eggIdx),
            UDim2.new(1, -4, 0, 52),
            UDim2.new(0, 0, 0, 0),
            ui.contenido, Color3.fromRGB(20, 14, 38), 0.15)
        local cC = Instance.new("UICorner"); cC.CornerRadius = UDim.new(0, 6); cC.Parent = cardFr
        local cS = Instance.new("UIStroke"); cS.Color = rarColor; cS.Thickness = 1.2
            cS.Transparency = 0.6; cS.Parent = cardFr

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size                   = UDim2.new(1, -100, 0, 22)
        nameLbl.Position               = UDim2.new(0, 8, 0, 4)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font                   = Enum.Font.GothamBold
        nameLbl.TextSize               = 12
        nameLbl.TextColor3             = rarColor
        nameLbl.Text                   = "🥚 " .. (huevo.parentName or huevo.dragonId)
        nameLbl.TextXAlignment         = Enum.TextXAlignment.Left
        nameLbl.TextTruncate           = Enum.TextTruncate.AtEnd
        nameLbl.Parent                 = cardFr

        local infoLbl = Instance.new("TextLabel")
        infoLbl.Size                   = UDim2.new(1, -100, 0, 18)
        infoLbl.Position               = UDim2.new(0, 8, 0, 26)
        infoLbl.BackgroundTransparency = 1
        infoLbl.Font                   = Enum.Font.Gotham
        infoLbl.TextSize               = 10
        infoLbl.TextColor3             = TEXT_DIM
        infoLbl.TextXAlignment         = Enum.TextXAlignment.Left
        infoLbl.Text                   = huevo.guaranteed
            and ("Garantía: " .. huevo.guaranteed)
            or  ("Rareza padre: " .. (huevo.parentRareza or "?"))
        infoLbl.Parent                 = cardFr

        local selBtn = crearBoton("Seleccionar",
            UDim2.new(0, 88, 0, 30),
            UDim2.new(1, -94, 0.5, -15),
            cardFr, Color3.fromRGB(55, 35, 90))
        selBtn.TextSize = 11

        local capIdx  = eggIdx
        local capHuevo = huevo
        selBtn.Activated:Connect(function()
            state.huevoSelected = { idx = capIdx, entry = capHuevo }
            mostrarAccionesHuevo(capIdx, capHuevo)
        end)
    end
end

function mostrarAccionesHuevo(eggIdx, huevo)
    if not ui.accionPanel then return end
    for _, c in ipairs(ui.accionBtns) do
        if c and c.Parent then c:Destroy() end
    end
    ui.accionBtns = {}
    ui.accionPanel.Visible = true

    local rarColor = RARITY_COLORS[huevo.parentRareza] or TEXT_PRIMARY

    local titLbl = Instance.new("TextLabel")
    titLbl.Size                   = UDim2.new(1, -10, 0, 20)
    titLbl.Position               = UDim2.new(0, 5, 0, 4)
    titLbl.BackgroundTransparency = 1
    titLbl.Font                   = Enum.Font.GothamBold
    titLbl.TextSize               = 12
    titLbl.TextColor3             = rarColor
    titLbl.Text                   = "🥚 " .. (huevo.parentName or huevo.dragonId)
    titLbl.TextXAlignment         = Enum.TextXAlignment.Left
    titLbl.Parent                 = ui.accionPanel
    table.insert(ui.accionBtns, titLbl)

    -- Incubar
    local incubarBtn = crearBoton("Incubar",
        UDim2.new(1, -10, 0, 28),
        UDim2.new(0, 5, 0, 28),
        ui.accionPanel, Color3.fromRGB(35, 60, 100))
    incubarBtn.TextSize = 11
    table.insert(ui.accionBtns, incubarBtn)

    incubarBtn.Activated:Connect(function()
        if not incubarBtn.Active then return end
        incubarBtn.Active = false
        local rf = Remotes and Remotes:FindFirstChild("RequestStartIncubation")
        if not rf then
            mostrarMensaje("Función de incubación no disponible.", "warning")
            incubarBtn.Active = true
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer(eggIdx) end)
        if ok and type(res) == "table" and res.ok then
            local dragonResult = DragonData.GetDragonById(res.dragonId)
            mostrarMensaje(("¡Naciste un %s (%s)!"):format(
                dragonResult and dragonResult.name or res.dragonId,
                res.rareza or "?"), "success")
            state.inventarioHuevos[eggIdx] = nil
            renderHuevos()
            actualizarHeader()
        else
            local msg = (type(res) == "table" and res.error) or "Error al incubar."
            mostrarMensaje(msg, "error")
            incubarBtn.Active = true
        end
    end)

    -- Vender huevo
    local vendBtn = crearBoton("Vender",
        UDim2.new(1, -10, 0, 28),
        UDim2.new(0, 5, 0, 60),
        ui.accionPanel, Color3.fromRGB(100, 50, 10))
    vendBtn.TextSize = 11
    table.insert(ui.accionBtns, vendBtn)

    vendBtn.Activated:Connect(function()
        if not vendBtn.Active then return end
        vendBtn.Active = false
        local rf = Remotes and Remotes:FindFirstChild("RequestSellEgg")
        if not rf then
            mostrarMensaje("Función de venta no disponible.", "warning")
            vendBtn.Active = true
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer(eggIdx) end)
        if ok and type(res) == "table" and res.ok then
            mostrarMensaje(("Vendiste el huevo por %d oro."):format(res.goldGained or 0), "success")
            state.inventarioHuevos[eggIdx] = nil
            renderHuevos()
            actualizarHeader()
        else
            local msg = (type(res) == "table" and res.error) or "Error al vender."
            mostrarMensaje(msg, "error")
            vendBtn.Active = true
        end
    end)
end

--------------------------------------------------------------------------------
-- Tab: Boosts
--------------------------------------------------------------------------------

local BOOST_ORDEN = { "festin", "cristal", "runa", "bendicion", "corona", "x2_1h", "x3_30min" }

local function renderBoosts()
    limpiarContenido()
    state.tabActual = "boosts"

    local inv        = state.inventarioBoosts
    local BOOST_DEF  = Constants.BOOST_TYPES or {}
    local hayAlguno  = false

    for _, boostId in ipairs(BOOST_ORDEN) do
        local count = inv[boostId] or 0
        if count <= 0 then continue end
        hayAlguno = true
        local def = BOOST_DEF[boostId]
        if not def then continue end

        local cardFr = crearFrame("BoostCard_" .. boostId,
            UDim2.new(1, -4, 0, 52),
            UDim2.new(0, 0, 0, 0),
            ui.contenido, Color3.fromRGB(20, 14, 38), 0.15)
        local cC = Instance.new("UICorner"); cC.CornerRadius = UDim.new(0, 6); cC.Parent = cardFr
        local cS = Instance.new("UIStroke"); cS.Color = BORDER_COLOR; cS.Thickness = 1.2
            cS.Transparency = 0.5; cS.Parent = cardFr

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size                   = UDim2.new(1, -96, 0, 22)
        nameLbl.Position               = UDim2.new(0, 8, 0, 4)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font                   = Enum.Font.GothamBold
        nameLbl.TextSize               = 13
        nameLbl.TextColor3             = TEXT_HEADER
        nameLbl.Text                   = count > 1
            and ("⚡ %s  ×%d"):format(def.nombre, count)
            or  ("⚡ %s"):format(def.nombre)
        nameLbl.TextXAlignment         = Enum.TextXAlignment.Left
        nameLbl.Parent                 = cardFr

        local durMin = math.floor(def.duracionSeg / 60)
        local infoLbl = Instance.new("TextLabel")
        infoLbl.Size                   = UDim2.new(1, -96, 0, 18)
        infoLbl.Position               = UDim2.new(0, 8, 0, 26)
        infoLbl.BackgroundTransparency = 1
        infoLbl.Font                   = Enum.Font.Gotham
        infoLbl.TextSize               = 10
        infoLbl.TextColor3             = TEXT_DIM
        infoLbl.TextXAlignment         = Enum.TextXAlignment.Left
        infoLbl.Text                   = ("×%.2f durante %d min · %s"):format(
            def.multiplicador, durMin,
            def.alcance == "granja" and "toda la granja" or "un nido")
        infoLbl.Parent                 = cardFr

        local aplicarBtn = crearBoton("Aplicar",
            UDim2.new(0, 80, 0, 30),
            UDim2.new(1, -86, 0.5, -15),
            cardFr, Color3.fromRGB(55, 35, 110))
        aplicarBtn.TextSize = 11

        local capBoostId = boostId
        aplicarBtn.Activated:Connect(function()
            if not aplicarBtn.Active then return end
            local rf = Remotes and Remotes:FindFirstChild("RequestAplicarBoostAuto")
            if not rf then
                mostrarMensaje("No se pudo conectar con el servidor.", "error")
                return
            end
            aplicarBtn.Active = false
            local ok, res = pcall(function() return rf:InvokeServer(capBoostId) end)
            local msg = type(res) == "table" and res.message or tostring(res or "")
            if ok and type(res) == "table" and res.ok then
                mostrarMensaje(msg ~= "" and msg or "¡Boost aplicado!", "success")
                state.inventarioBoosts[capBoostId] = math.max(0, (state.inventarioBoosts[capBoostId] or 1) - 1)
                renderBoosts()
            else
                mostrarMensaje(msg ~= "" and msg or "No se pudo aplicar.", "error")
                aplicarBtn.Active = true
            end
        end)
    end

    if not hayAlguno then
        local lbl = crearLabel("No tenés boosts en el inventario.",
            UDim2.new(1, 0, 0, 40),
            UDim2.new(0, 0, 0, 8),
            ui.contenido, Enum.Font.Gotham, TEXT_DIM, 12)
        lbl.TextXAlignment = Enum.TextXAlignment.Center
    end
end

--------------------------------------------------------------------------------
-- Construcción de la UI
--------------------------------------------------------------------------------

local InventoryGUI = {}

local function construirUI()
    local sg = Instance.new("ScreenGui")
    sg.Name                  = "InventoryGUI"
    sg.ResetOnSpawn          = false
    sg.ZIndexBehavior        = Enum.ZIndexBehavior.Sibling
    sg.Enabled               = false
    sg.Parent                = playerGui
    ui.screenGui             = sg

    local ventana = Instance.new("Frame")
    ventana.Name                   = "Ventana"
    ventana.Size                   = UDim2.new(0, 620, 0, 500)
    ventana.Position               = UDim2.new(0.5, -310, 0.5, -250)
    ventana.BackgroundColor3       = PANEL_BG
    ventana.BackgroundTransparency = 0.05
    ventana.BorderSizePixel        = 0
    ventana.Parent                 = sg
    ui.ventana                     = ventana
    local vC = Instance.new("UICorner"); vC.CornerRadius = UDim.new(0, 10); vC.Parent = ventana
    local vS = Instance.new("UIStroke"); vS.Color = BORDER_COLOR; vS.Thickness = 1.5; vS.Parent = ventana

    -- Botón cerrar
    local cerrarBtn = Instance.new("TextButton")
    cerrarBtn.Text                   = "✕"
    cerrarBtn.Size                   = UDim2.new(0, 30, 0, 30)
    cerrarBtn.Position               = UDim2.new(1, -38, 0, 8)
    cerrarBtn.BackgroundColor3       = Color3.fromRGB(100, 30, 30)
    cerrarBtn.BorderSizePixel        = 0
    cerrarBtn.Font                   = Enum.Font.GothamBold
    cerrarBtn.TextSize               = 14
    cerrarBtn.TextColor3             = Color3.fromRGB(255, 220, 220)
    cerrarBtn.Parent                 = ventana
    local cBtnC = Instance.new("UICorner"); cBtnC.CornerRadius = UDim.new(0, 6); cBtnC.Parent = cerrarBtn
    cerrarBtn.Activated:Connect(function() InventoryGUI.Cerrar() end)

    -- Header
    local headerFr = crearFrame("Header",
        UDim2.new(1, -20, 0, 48),
        UDim2.new(0, 10, 0, 8),
        ventana, Color3.fromRGB(20, 14, 38), 0.2)
    local hC = Instance.new("UICorner"); hC.CornerRadius = UDim.new(0, 6); hC.Parent = headerFr

    local headerLbl = Instance.new("TextLabel")
    headerLbl.Size                   = UDim2.new(0, 200, 1, 0)
    headerLbl.Position               = UDim2.new(0, 10, 0, 0)
    headerLbl.BackgroundTransparency = 1
    headerLbl.Font                   = Enum.Font.GothamBold
    headerLbl.TextSize               = 18
    headerLbl.TextColor3             = TEXT_HEADER
    headerLbl.TextXAlignment         = Enum.TextXAlignment.Left
    headerLbl.Text                   = "🎒 INVENTARIO"
    headerLbl.Parent                 = headerFr
    ui.headerLbl                     = headerLbl

    local contLbl = Instance.new("TextLabel")
    contLbl.Size                   = UDim2.new(0, 280, 1, 0)
    contLbl.Position               = UDim2.new(1, -290, 0, 0)
    contLbl.BackgroundTransparency = 1
    contLbl.Font                   = Enum.Font.Gotham
    contLbl.TextSize               = 11
    contLbl.TextColor3             = TEXT_DIM
    contLbl.TextXAlignment         = Enum.TextXAlignment.Right
    contLbl.Text                   = "Dragones: 0  Huevos: 0  /  5"
    contLbl.Parent                 = headerFr
    ui.contLbl                     = contLbl

    -- Tabs
    local tabFr = crearFrame("Tabs",
        UDim2.new(1, -20, 0, 32),
        UDim2.new(0, 10, 0, 62),
        ventana, Color3.fromRGB(10, 7, 20), 0)

    local tabDefs = {
        { id = "dragones", texto = "🐉 Dragones" },
        { id = "huevos",   texto = "🥚 Huevos" },
        { id = "boosts",   texto = "⚡ Boosts" },
    }
    for i, td in ipairs(tabDefs) do
        local tw  = math.floor((600 - 20) / 3)
        local btn = crearBoton(td.texto,
            UDim2.new(0, tw - 4, 1, 0),
            UDim2.new(0, (i - 1) * tw, 0, 0),
            tabFr,
            state.tabActual == td.id
                and Color3.fromRGB(90, 55, 160)
                or  Color3.fromRGB(30, 20, 55))
        btn.TextSize = 12
        ui.tabBtns[td.id] = btn

        local capId = td.id
        btn.Activated:Connect(function()
            for id2, b2 in pairs(ui.tabBtns) do
                b2.BackgroundColor3 = id2 == capId
                    and Color3.fromRGB(90, 55, 160)
                    or  Color3.fromRGB(30, 20, 55)
            end
            if capId == "dragones" then
                renderDragones()
            elseif capId == "huevos" then
                renderHuevos()
            elseif capId == "boosts" then
                renderBoosts()
            end
        end)
    end

    -- Panel de contenido (ScrollingFrame con lista)
    local scrollFr = Instance.new("ScrollingFrame")
    scrollFr.Name                  = "Contenido"
    scrollFr.Size                  = UDim2.new(0, 370, 1, -120)
    scrollFr.Position              = UDim2.new(0, 10, 0, 100)
    scrollFr.BackgroundTransparency = 1
    scrollFr.BorderSizePixel       = 0
    scrollFr.ScrollBarThickness    = 4
    scrollFr.ScrollBarImageColor3  = BORDER_COLOR
    scrollFr.AutomaticCanvasSize   = Enum.AutomaticSize.Y
    scrollFr.CanvasSize            = UDim2.new(0, 0, 0, 0)
    scrollFr.Parent                = ventana
    ui.contenido                   = scrollFr

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder        = Enum.SortOrder.LayoutOrder
    listLayout.Padding          = UDim.new(0, 4)
    listLayout.Parent           = scrollFr

    local contPad = Instance.new("UIPadding")
    contPad.PaddingLeft   = UDim.new(0, 2)
    contPad.PaddingRight  = UDim.new(0, 2)
    contPad.PaddingTop    = UDim.new(0, 2)
    contPad.PaddingBottom = UDim.new(0, 4)
    contPad.Parent        = scrollFr

    -- Panel de acciones (derecha)
    local accionFr = crearFrame("Acciones",
        UDim2.new(0, 220, 1, -120),
        UDim2.new(1, -230, 0, 100),
        ventana, Color3.fromRGB(20, 14, 38), 0.2)
    accionFr.Visible = false
    local aFrC = Instance.new("UICorner"); aFrC.CornerRadius = UDim.new(0, 8); aFrC.Parent = accionFr
    local aFrS = Instance.new("UIStroke"); aFrS.Color = BORDER_COLOR; aFrS.Thickness = 1; aFrS.Parent = accionFr
    ui.accionPanel = accionFr

    -- Label de mensaje
    local msgLbl = Instance.new("TextLabel")
    msgLbl.Name                   = "MsgLbl"
    msgLbl.Size                   = UDim2.new(0, 580, 0, 30)
    msgLbl.Position               = UDim2.new(0.5, -290, 1, -38)
    msgLbl.BackgroundColor3       = Color3.fromRGB(20, 50, 20)
    msgLbl.BackgroundTransparency = 0.20
    msgLbl.BorderSizePixel        = 0
    msgLbl.Font                   = Enum.Font.GothamBold
    msgLbl.TextSize               = 12
    msgLbl.TextColor3             = Color3.fromRGB(130, 255, 130)
    msgLbl.TextXAlignment         = Enum.TextXAlignment.Center
    msgLbl.Text                   = ""
    msgLbl.Visible                = false
    msgLbl.ZIndex                 = 10
    msgLbl.Parent                 = ventana
    local mC = Instance.new("UICorner"); mC.CornerRadius = UDim.new(0, 6); mC.Parent = msgLbl
    ui.msgLbl = msgLbl
end

--------------------------------------------------------------------------------
-- Carga de datos del servidor
--------------------------------------------------------------------------------

local function cargarDatos()
    task.spawn(function()
        if not Remotes then return end

        -- Dragones en inventario
        local rfCat = Remotes:FindFirstChild("RequestGetCatalogueData")
        if rfCat then
            local ok, data = pcall(function() return rfCat:InvokeServer() end)
            if ok and type(data) == "table" then
                state.inventarioDragones = data.inventory or {}
            end
        end

        -- Huevos en inventario
        local rfEgg = Remotes:FindFirstChild("RequestGetAllEggStatuses")
        if rfEgg then
            local ok, data = pcall(function() return rfEgg:InvokeServer() end)
            if ok and type(data) == "table" then
                state.inventarioHuevos = data.inventario or {}
            end
        end

        -- Boosts en inventario
        local rfBoost = Remotes:FindFirstChild("RequestBoostInventario")
        if rfBoost then
            local ok, data = pcall(function() return rfBoost:InvokeServer() end)
            if ok and type(data) == "table" then
                state.inventarioBoosts = data
            end
        end

        -- Límite de inventario desde NestData (tiene el nivel del jugador)
        local rfNest = Remotes:FindFirstChild("RequestNestData")
        if rfNest then
            local ok, nd = pcall(function() return rfNest:InvokeServer() end)
            if ok and type(nd) == "table" then
                local lv   = nd.level or 1
                local lims = Constants.INVENTORY_LIMITS or {}
                state.inventarioLimite = lims[lv] or 15
            end
        end

        actualizarHeader()

        -- Mostrar tab actual
        if state.tabActual == "dragones" then
            renderDragones()
        elseif state.tabActual == "huevos" then
            renderHuevos()
        elseif state.tabActual == "boosts" then
            renderBoosts()
        end
    end)
end

--------------------------------------------------------------------------------
-- API pública
--------------------------------------------------------------------------------

function InventoryGUI.Abrir()
    if state.visible then return end
    state.visible       = true
    ui.screenGui.Enabled = true

    ui.ventana.Size = UDim2.new(0, 500, 0, 400)
    TweenService:Create(ui.ventana, TWEEN_SLIDE, { Size = UDim2.new(0, 620, 0, 500) }):Play()

    cargarDatos()
end

function InventoryGUI.Cerrar()
    if not state.visible then return end
    state.visible = false

    local t = TweenService:Create(ui.ventana, TWEEN_SLIDE, { Size = UDim2.new(0, 500, 0, 400) })
    t:Play()
    t.Completed:Connect(function()
        if not state.visible then
            ui.screenGui.Enabled = false
        end
    end)
end

--------------------------------------------------------------------------------
-- Inicialización
--------------------------------------------------------------------------------

-- Esperar los Remotes del servidor
task.spawn(function()
    Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
end)

construirUI()

-- Escuchar NavBar del HUD
task.spawn(function()
    local hudGui = playerGui:WaitForChild("DragonRoostHUD", 30)
    if not hudGui then return end
    local navEvent = hudGui:WaitForChild("NavBarClicked", 10)
    if not navEvent then return end
    navEvent.Event:Connect(function(accion)
        if accion == "AbrirInventario" then
            if state.visible then
                InventoryGUI.Cerrar()
            else
                InventoryGUI.Abrir()
            end
        end
    end)
end)

-- Re-renderizar si se actualiza NestUpdated mientras el GUI está abierto
task.spawn(function()
    local Rem = ReplicatedStorage:WaitForChild("Remotes", 30)
    if not Rem then return end
    local nestEv = Rem:WaitForChild("NestUpdated", 15)
    if nestEv then
        nestEv.OnClientEvent:Connect(function()
            if state.visible then
                cargarDatos()
            end
        end)
    end
end)

return InventoryGUI
