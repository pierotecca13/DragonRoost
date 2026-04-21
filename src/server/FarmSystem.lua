--------------------------------------------------------------------------------
-- FarmSystem.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Crea y gestiona granjas físicas en el mundo para cada jugador (máx 8).
-- Cada granja tiene pads de nido con ProximityPrompt para recolectar oro.
-- Los BillboardGui encima de cada nido muestran el dragón activo y el oro
-- pendiente, actualizándose cada 2 segundos.
--
-- API pública:
--   FarmSystem.AssignPlot(player)       → llamar en PlayerAdded (tras cargar datos)
--   FarmSystem.ReleasePlot(player)      → llamar en PlayerRemoving
--   FarmSystem.OnDragonPlaced(player, nestIndex) → actualizar visual tras colocar/retirar
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DragonService = require(script.Parent.DragonService)
local NestSystem    = require(script.Parent.NestSystem)
local DragonData    = require(ReplicatedStorage:WaitForChild("DragonData"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local function obtenerOCrearRemote(tipo, nombre)
    local existente = Remotes:FindFirstChild(nombre)
    if existente then return existente end
    local nuevo = Instance.new(tipo)
    nuevo.Name   = nombre
    nuevo.Parent = Remotes
    return nuevo
end
local GoldCollectedEvent = obtenerOCrearRemote("RemoteEvent", "GoldCollected")

local FarmSystem = {}

--------------------------------------------------------------------------------
-- Constantes de layout
--------------------------------------------------------------------------------
local MAX_PLOTS      = 8
local PLOT_RADIUS    = 140   -- distancia del spawn al centro de cada granja
local PLOT_WIDTH     = 80    -- ancho de la plataforma
local PLOT_DEPTH     = 52    -- profundidad de la plataforma
local PLATFORM_Y     = 12    -- Y de la SUPERFICIE de la plataforma (bien elevada)
local PILLAR_HEIGHT  = 12    -- altura del pilar de soporte
local MAX_NESTS      = 6

-- Posición de cada pad dentro de la granja (3 columnas × 2 filas)
local NEST_COLS      = 3
local NEST_SPACING_X = 22
local NEST_SPACING_Z = 18

-- Color de rareza para el texto del BillboardGui
local RARITY_COLOR = {
    comun         = Color3.fromRGB(180, 180, 180),
    poco_comun    = Color3.fromRGB( 80, 200,  80),
    raro          = Color3.fromRGB( 80, 140, 240),
    epico         = Color3.fromRGB(180,  60, 240),
    legendario    = Color3.fromRGB(255, 190,   0),
    mitico        = Color3.fromRGB(255,  60,  60),
}

local ELEMENT_EMOJI = {
    fuego      = "🔥", agua       = "💧", hielo      = "❄️",
    trueno     = "⚡", naturaleza = "🌿", sombra     = "🌑",
    celestial  = "✨", vacio      = "🌀", ["vacío"]  = "🌀",
}

local function capitalize(str)
    if not str or str == "" then return "" end
    return str:sub(1,1):upper() .. str:sub(2):gsub("_", " ")
end

-- Colores de ladrillos del pad según estado
local COLOR_EMPTY    = BrickColor.new("Medium stone grey")
local COLOR_OCCUPIED = BrickColor.new("Sand green")
local COLOR_LOCKED   = BrickColor.new("Dark grey")

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------
local availablePlots  = {}     -- stack de índices libres (1-8)
local plotAssignments = {}     -- [userId] = plotIndex
local farmModels      = {}     -- [userId] = { model, nests={[i]={pad,bowl,nameLbl,goldLbl}} }

for i = MAX_PLOTS, 1, -1 do
    table.insert(availablePlots, i)
end

--------------------------------------------------------------------------------
-- Helpers de posición
--------------------------------------------------------------------------------
local function getPlotCenter(plotIndex)
    local angle = (plotIndex - 1) * (2 * math.pi / MAX_PLOTS)
    return Vector3.new(
        math.cos(angle) * PLOT_RADIUS,
        PLATFORM_Y,   -- superficie de la plataforma
        math.sin(angle) * PLOT_RADIUS
    )
end

local function getNestOffset(i)
    local col = (i - 1) % NEST_COLS
    local row = math.floor((i - 1) / NEST_COLS)
    local ox  = (col - (NEST_COLS - 1) / 2) * NEST_SPACING_X
    local oz  = (row - 0.5) * NEST_SPACING_Z + 2
    return Vector3.new(ox, 0, oz)
end

--------------------------------------------------------------------------------
-- Construcción de la granja física
--------------------------------------------------------------------------------
local function mkPart(parent, name, size, cframe, bcolor, material)
    local p = Instance.new("Part")
    p.Name        = name
    p.Size        = size
    p.CFrame      = cframe
    p.BrickColor  = bcolor or BrickColor.new("Medium stone grey")
    p.Material    = material or Enum.Material.SmoothPlastic
    p.Anchored    = true
    p.CanCollide  = true
    p.CastShadow  = false
    p.Parent      = parent
    return p
end

local function buildFarm(player, plotIndex)
    -- center.Y = PLATFORM_Y = superficie de la plataforma
    local center = getPlotCenter(plotIndex)
    local model  = Instance.new("Model")
    model.Name   = "Granja_" .. player.Name
    model.Parent = workspace

    -- ── Plataforma principal (2 studs de grosor, bien elevada) ──
    mkPart(model, "Floor",
        Vector3.new(PLOT_WIDTH, 2, PLOT_DEPTH),
        CFrame.new(center + Vector3.new(0, -1, 0)),   -- top surface = center.Y
        BrickColor.new("Bright green"), Enum.Material.Grass)

    -- Borde de piedra alrededor del suelo
    mkPart(model, "EdgeN",
        Vector3.new(PLOT_WIDTH + 4, 1.5, 3),
        CFrame.new(center + Vector3.new(0, -0.25, -(PLOT_DEPTH/2 + 1))),
        BrickColor.new("Medium stone grey"), Enum.Material.SmoothPlastic)
    mkPart(model, "EdgeS",
        Vector3.new(PLOT_WIDTH + 4, 1.5, 3),
        CFrame.new(center + Vector3.new(0, -0.25,  (PLOT_DEPTH/2 + 1))),
        BrickColor.new("Medium stone grey"), Enum.Material.SmoothPlastic)
    mkPart(model, "EdgeW",
        Vector3.new(3, 1.5, PLOT_DEPTH),
        CFrame.new(center + Vector3.new(-(PLOT_WIDTH/2 + 1), -0.25, 0)),
        BrickColor.new("Medium stone grey"), Enum.Material.SmoothPlastic)
    mkPart(model, "EdgeE",
        Vector3.new(3, 1.5, PLOT_DEPTH),
        CFrame.new(center + Vector3.new( (PLOT_WIDTH/2 + 1), -0.25, 0)),
        BrickColor.new("Medium stone grey"), Enum.Material.SmoothPlastic)

    -- Pilares de soporte (4 esquinas) para que la plataforma tenga presencia vertical
    local corners = {
        Vector3.new( PLOT_WIDTH/2,  0,  PLOT_DEPTH/2),
        Vector3.new(-PLOT_WIDTH/2,  0,  PLOT_DEPTH/2),
        Vector3.new( PLOT_WIDTH/2,  0, -PLOT_DEPTH/2),
        Vector3.new(-PLOT_WIDTH/2,  0, -PLOT_DEPTH/2),
    }
    for ci, co in ipairs(corners) do
        mkPart(model, "Pillar_" .. ci,
            Vector3.new(3, PILLAR_HEIGHT, 3),
            CFrame.new(center + co + Vector3.new(0, -1 - PILLAR_HEIGHT/2, 0)),
            BrickColor.new("Medium stone grey"), Enum.Material.SmoothPlastic)
    end

    -- Valla trasera con antorchas decorativas
    mkPart(model, "WallBack",
        Vector3.new(PLOT_WIDTH + 4, 6, 2),
        CFrame.new(center + Vector3.new(0, 2, -(PLOT_DEPTH/2 + 2))),
        BrickColor.new("Reddish brown"), Enum.Material.Wood)

    -- Letrero fijo: sin rotación, paralelo a la pared trasera (ambos corren en X).
    -- El jugador está en el lado +Z de la pared, así que la cara visible es Back.
    local signWorldPos = center + Vector3.new(0, 6.5, -(PLOT_DEPTH/2 + 2))

    local sign = Instance.new("Part")
    sign.Name        = "Sign"
    sign.Size        = Vector3.new(14, 5, 0.6)
    sign.CFrame      = CFrame.new(signWorldPos)   -- sin rotación = paralelo a la pared
    sign.BrickColor  = BrickColor.new("Bright yellow")
    sign.Material    = Enum.Material.Wood
    sign.Anchored    = true
    sign.CanCollide  = false
    sign.CastShadow  = false
    sign.Parent      = model

    local signSG = Instance.new("SurfaceGui")
    signSG.Face            = Enum.NormalId.Back
    signSG.SizingMode      = Enum.SurfaceGuiSizingMode.PixelsPerStud
    signSG.PixelsPerStud   = 50
    signSG.AlwaysOnTop     = false
    signSG.Parent          = sign
    local signLbl = Instance.new("TextLabel", signSG)
    signLbl.Size              = UDim2.new(1, 0, 1, 0)
    signLbl.BackgroundColor3  = Color3.fromRGB(180, 130, 30)
    signLbl.BackgroundTransparency = 0
    signLbl.Text              = "🐉  " .. player.Name
    signLbl.TextColor3        = Color3.fromRGB(255, 240, 180)
    signLbl.Font              = Enum.Font.GothamBold
    signLbl.TextScaled        = true
    local signCorner = Instance.new("UICorner", signSG)
    signCorner.CornerRadius   = UDim.new(0, 12)

    -- ── Pads de nido ──
    local nestData = NestSystem.GetNestData(player)
    local maxSlots = (nestData and nestData.slots) or 1

    local nests = {}
    for i = 1, MAX_NESTS do
        local offset   = getNestOffset(i)
        local padBase  = center + offset      -- superficie de la plataforma
        local unlocked = i <= maxSlots

        -- Pedestal del nido (cubo de 2 studs de alto para que sea prominente)
        local pad = mkPart(model, "NestPad_" .. i,
            Vector3.new(10, 2, 10),
            CFrame.new(padBase + Vector3.new(0, 1, 0)),  -- top en padBase.Y + 2
            unlocked and COLOR_EMPTY or COLOR_LOCKED,
            Enum.Material.SmoothPlastic)

        -- Nido (cuenco marrón sobre el pedestal)
        local bowl = mkPart(model, "Bowl_" .. i,
            Vector3.new(6, 1.5, 6),
            CFrame.new(padBase + Vector3.new(0, 2.75, 0)),
            unlocked and BrickColor.new("Reddish brown") or COLOR_LOCKED,
            Enum.Material.Wood)
        bowl.CanCollide = false

        -- BillboardGui encima del nido
        local bb = Instance.new("BillboardGui")
        bb.Name         = "NestBB"
        bb.Size         = UDim2.new(0, 240, 0, 130)
        bb.StudsOffset  = Vector3.new(0, 7, 0)
        bb.MaxDistance  = 60
        bb.AlwaysOnTop  = false
        bb.Parent       = pad

        local nameLbl = Instance.new("TextLabel", bb)
        nameLbl.Name              = "DragonName"
        nameLbl.Size              = UDim2.new(1, 0, 0.30, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Text              = unlocked and "— Vacío —" or "🔒 Bloqueado"
        nameLbl.TextColor3        = unlocked and Color3.fromRGB(160, 160, 160)
                                    or Color3.fromRGB(90, 90, 90)
        nameLbl.Font              = Enum.Font.GothamBold
        nameLbl.TextScaled        = true

        local rarLbl = Instance.new("TextLabel", bb)
        rarLbl.Name              = "RarityLabel"
        rarLbl.Size              = UDim2.new(1, 0, 0.25, 0)
        rarLbl.Position          = UDim2.new(0, 0, 0.30, 0)
        rarLbl.BackgroundTransparency = 1
        rarLbl.Text              = ""
        rarLbl.TextColor3        = Color3.fromRGB(180, 180, 180)
        rarLbl.Font              = Enum.Font.Gotham
        rarLbl.TextScaled        = true

        local goldLbl = Instance.new("TextLabel", bb)
        goldLbl.Name              = "GoldLabel"
        goldLbl.Size              = UDim2.new(1, 0, 0.25, 0)
        goldLbl.Position          = UDim2.new(0, 0, 0.55, 0)
        goldLbl.BackgroundTransparency = 1
        goldLbl.Text              = ""
        goldLbl.TextColor3        = Color3.fromRGB(255, 200, 40)
        goldLbl.Font              = Enum.Font.Gotham
        goldLbl.TextScaled        = true

        -- Indicador de boost activo
        local boostLbl = Instance.new("TextLabel", bb)
        boostLbl.Name              = "BoostLabel"
        boostLbl.Size              = UDim2.new(1, 0, 0.20, 0)
        boostLbl.Position          = UDim2.new(0, 0, 0.80, 0)
        boostLbl.BackgroundTransparency = 1
        boostLbl.Text              = ""
        boostLbl.TextColor3        = Color3.fromRGB(255, 215, 80)
        boostLbl.Font              = Enum.Font.GothamBold
        boostLbl.TextScaled        = true

        -- ProximityPrompt (solo slots desbloqueados)
        if unlocked then
            local prompt = Instance.new("ProximityPrompt")
            prompt.Name                  = "CollectPrompt"
            prompt.ObjectText            = "Nido " .. i
            prompt.ActionText            = "Recolectar"
            prompt.KeyboardKeyCode       = Enum.KeyCode.E
            prompt.MaxActivationDistance = 12
            prompt.HoldDuration          = 0
            prompt.Enabled               = false
            prompt.Parent                = pad
        end

        nests[i] = { pad = pad, bowl = bowl, nameLbl = nameLbl, rarLbl = rarLbl, goldLbl = goldLbl, boostLbl = boostLbl }
    end

    return { model = model, nests = nests, center = center }
end

--------------------------------------------------------------------------------
-- Actualizar visual de un pad individual
--------------------------------------------------------------------------------
function FarmSystem.UpdateNestPad(player, nestIndex)
    local farm = farmModels[player.UserId]
    if not farm then return end
    local entry = farm.nests[nestIndex]
    if not entry then return end

    local nestData = NestSystem.GetNestData(player)
    if not nestData then return end

    local pad      = entry.pad
    local bowl     = entry.bowl
    local nameLbl  = entry.nameLbl
    local rarLbl   = entry.rarLbl
    local goldLbl  = entry.goldLbl
    local boostLbl = entry.boostLbl
    local prompt   = pad:FindFirstChild("CollectPrompt")

    local nido = nestData.nests[nestIndex]

    if nido and nido.dragonId then
        -- Nido ocupado
        local dragon  = DragonData.GetDragonById(nido.dragonId)
        local dname   = dragon and dragon.name    or nido.dragonId
        local rarity  = dragon and dragon.rarity  or "comun"
        local element = dragon and dragon.element or ""
        local gps     = dragon and dragon.goldPerSecond or 0

        -- Multiplicador de evento climático para este elemento
        local weatherMult = DragonService.GetWeatherMultiplier(element)
        local gpsDisplay  = gps * weatherMult
        local gpsStr      = weatherMult > 1.0
            and string.format("%.1f/s ⚡×%.1f", gpsDisplay, weatherMult)
            or  string.format("%.1f/s", gps)

        nameLbl.Text       = dname .. "  (" .. gpsStr .. ")"
        nameLbl.TextColor3 = RARITY_COLOR[rarity] or Color3.fromRGB(200, 200, 200)

        if rarLbl then
            local emoji = ELEMENT_EMOJI[element] or ""
            rarLbl.Text       = emoji .. " " .. capitalize(element) .. "  ·  " .. capitalize(rarity)
            rarLbl.TextColor3 = RARITY_COLOR[rarity] or Color3.fromRGB(180, 180, 180)
        end

        local pending = DragonService.CalculatePending(player, nestIndex)
        goldLbl.Text  = string.format("💰 %d oro listo", math.floor(pending))

        -- Indicador de boost activo en el nido
        if boostLbl then
            local boostMult = nido.boostMultiplier or 1
            local boostSecs = nido.boostSecondsLeft or 0
            if boostMult > 1 and boostSecs > 0 then
                local mins = math.floor(boostSecs / 60)
                local secs = boostSecs % 60
                boostLbl.Text       = ("⚡ ×%.1f  %d:%02d"):format(boostMult, mins, secs)
                boostLbl.TextColor3 = Color3.fromRGB(255, 215, 80)
            else
                boostLbl.Text = ""
            end
        end

        pad.BrickColor  = COLOR_OCCUPIED
        bowl.BrickColor = BrickColor.new("Reddish brown")

        if prompt then
            prompt.ActionText = string.format("Recolectar  💰 %d", math.floor(pending))
            prompt.Enabled    = pending >= 1
        end
    else
        -- Nido vacío o bloqueado
        local maxSlots = nestData.slots or 1
        if nestIndex <= maxSlots then
            nameLbl.Text       = "— Vacío —"
            nameLbl.TextColor3 = Color3.fromRGB(140, 140, 140)
            pad.BrickColor     = COLOR_EMPTY
            bowl.BrickColor    = BrickColor.new("Reddish brown")
        else
            nameLbl.Text       = "🔒 Bloqueado"
            nameLbl.TextColor3 = Color3.fromRGB(90, 90, 90)
            pad.BrickColor     = COLOR_LOCKED
            bowl.BrickColor    = COLOR_LOCKED
        end
        if rarLbl then rarLbl.Text = "" end
        goldLbl.Text = ""
        if boostLbl then boostLbl.Text = "" end
        if prompt then prompt.Enabled = false end
    end
end

--------------------------------------------------------------------------------
-- Conectar ProximityPrompts de todos los pads de un jugador
--------------------------------------------------------------------------------
local function connectPrompts(player, farm)
    for i = 1, MAX_NESTS do
        local entry  = farm.nests[i]
        if not entry then continue end
        local prompt = entry.pad:FindFirstChild("CollectPrompt")
        if not prompt then continue end

        local nestIndex = i
        prompt.Triggered:Connect(function(who)
            if who ~= player then return end   -- solo el dueño recolecta

            local oro = DragonService.CollectGold(player, nestIndex)
            -- GoldCollectedEvent ya se dispara dentro de DragonService.CollectGold
            if oro > 0 then
                NestSystem.AddGold(player, oro)
                -- Parpadeo dorado del bowl
                local bowl = entry.bowl
                local prev = bowl.BrickColor
                bowl.BrickColor = BrickColor.new("Bright yellow")
                task.delay(0.3, function() bowl.BrickColor = prev end)
            end
            FarmSystem.UpdateNestPad(player, nestIndex)
        end)
    end
end

--------------------------------------------------------------------------------
-- Loop de refresco de BillboardGuis cada 2 s
--------------------------------------------------------------------------------
local function startUpdateLoop()
    task.spawn(function()
        while true do
            task.wait(1)
            for userId, farm in pairs(farmModels) do
                local player = Players:GetPlayerByUserId(userId)
                if player then
                    for i = 1, MAX_NESTS do
                        FarmSystem.UpdateNestPad(player, i)
                    end
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Auto-collect: recolecta el oro de todos los nidos automáticamente cada 60 s
-- El jugador no necesita presionar E; el oro fluye solo como en un juego idle.
-- La ProximityPrompt sigue disponible para colectar manualmente antes de tiempo.
--------------------------------------------------------------------------------
local function startAutoCollectLoop()
    task.spawn(function()
        while true do
            task.wait(60)
            for userId, farm in pairs(farmModels) do
                local player = Players:GetPlayerByUserId(userId)
                if player then
                    for i = 1, MAX_NESTS do
                        local oro = DragonService.CollectGold(player, i)
                        if oro > 0 then
                            NestSystem.AddGold(player, oro)
                            -- Parpadeo dorado del bowl para feedback visual
                            local entry = farm.nests[i]
                            if entry and entry.bowl then
                                local bowl = entry.bowl
                                local prev = bowl.BrickColor
                                bowl.BrickColor = BrickColor.new("Bright yellow")
                                task.delay(0.4, function()
                                    if bowl.Parent then bowl.BrickColor = prev end
                                end)
                            end
                        end
                    end
                end
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- API pública
--------------------------------------------------------------------------------
function FarmSystem.AssignPlot(player)
    -- Evitar asignación doble
    if plotAssignments[player.UserId] then return end

    if #availablePlots == 0 then
        warn("[FarmSystem] Sin granjas disponibles para " .. player.Name)
        return
    end
    local plotIndex = table.remove(availablePlots)
    plotAssignments[player.UserId] = plotIndex

    -- Esperar a que los datos del jugador estén listos (DataStore + NestSystem tardan ~1 s)
    task.delay(3, function()
        if not player.Parent then
            -- Jugador salió antes de que cargara
            plotAssignments[player.UserId] = nil
            table.insert(availablePlots, plotIndex)
            return
        end

        local ok, result = pcall(buildFarm, player, plotIndex)
        if not ok then
            warn("[FarmSystem] Error en buildFarm para " .. player.Name .. ": " .. tostring(result))
            return
        end
        local farm = result
        farmModels[player.UserId] = farm
        connectPrompts(player, farm)

        for i = 1, MAX_NESTS do
            local okU, errU = pcall(FarmSystem.UpdateNestPad, player, i)
            if not okU then
                warn("[FarmSystem] UpdateNestPad " .. i .. " error: " .. tostring(errU))
            end
        end

        -- Teletransportar al jugador al frente de su granja
        local char = player.Character
        if not char then
            local conn
            conn = player.CharacterAdded:Connect(function(c)
                conn:Disconnect()
                task.wait(0.5)
                local hrp = c:FindFirstChild("HumanoidRootPart")
                if hrp then
                    -- Parado sobre la plataforma, cerca del letrero
                    hrp.CFrame = CFrame.new(farm.center + Vector3.new(0, 5, -(PLOT_DEPTH / 2 - 8)))
                end
            end)
        else
            task.wait(0.5)
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                hrp.CFrame = CFrame.new(farm.center + Vector3.new(0, 5, -(PLOT_DEPTH / 2 - 8)))
            end
        end

        print(("[FarmSystem] ✓ Granja %d asignada a %s en %s")
            :format(plotIndex, player.Name, tostring(farm.center)))
    end)
end

function FarmSystem.ReleasePlot(player)
    local uid = player.UserId
    local farm = farmModels[uid]
    if farm and farm.model then
        farm.model:Destroy()
    end
    farmModels[uid]      = nil
    plotAssignments[uid] = nil

    local plotIndex = plotAssignments[uid]  -- ya es nil, usamos el valor previo
    -- re-capturar de plotAssignments antes de borrar:
end

-- Sobrescribir ReleasePlot con la versión correcta
function FarmSystem.ReleasePlot(player)
    local uid       = player.UserId
    local plotIndex = plotAssignments[uid]
    local farm      = farmModels[uid]

    if farm and farm.model then farm.model:Destroy() end
    farmModels[uid]      = nil
    plotAssignments[uid] = nil

    if plotIndex then
        table.insert(availablePlots, plotIndex)
        print(("[FarmSystem] Granja %d liberada (%s)"):format(plotIndex, player.Name))
    end
end

-- Notificar al sistema cuando un dragón es colocado o retirado de un nido
function FarmSystem.OnDragonPlaced(player, nestIndex)
    task.defer(function()
        FarmSystem.UpdateNestPad(player, nestIndex)
    end)
end

-- Hooks automáticos
Players.PlayerRemoving:Connect(FarmSystem.ReleasePlot)

-- Escuchar cambios de nido desde NestSystem para actualizar el visual
NestSystem.OnNestChanged = function(player, nestIndex)
    FarmSystem.OnDragonPlaced(player, nestIndex)
end

startUpdateLoop()
-- Auto-collect eliminado: el jugador recolecta manualmente presionando E al acercarse al nido

return FarmSystem
