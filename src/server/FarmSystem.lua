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
local EggService    = require(script.Parent.EggService)
local DataStore     = require(script.Parent.DataStore)
local DragonData    = require(ReplicatedStorage:WaitForChild("DragonData"))
local craterTemplate = ReplicatedStorage:WaitForChild("Crater")

-- Nombre del modelo Dragon Pet en ReplicatedStorage
-- Cambiar al nombre exacto que aparece en Studio
local DRAGON_PET_MODEL_NAME = "Dragon Pet"
local petTemplate = ReplicatedStorage:FindFirstChild(DRAGON_PET_MODEL_NAME)

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

-- ── Apariencia del Dragon Pet ──────────────────────────────────────────────
-- Base por elemento: { bodyColor, accentColor, particleColor, glowColor }
local ELEMENT_BASE = {
    fuego      = { Color3.fromRGB(200, 60, 10),  Color3.fromRGB(255, 130, 0),  Color3.fromRGB(255, 80, 0),   Color3.fromRGB(255, 50, 0)   },
    agua       = { Color3.fromRGB(20,  90, 190), Color3.fromRGB(60,  170, 255),Color3.fromRGB(60,  150, 255),Color3.fromRGB(40,  120, 255) },
    hielo      = { Color3.fromRGB(160, 210, 255),Color3.fromRGB(220, 240, 255),Color3.fromRGB(190, 230, 255),Color3.fromRGB(180, 220, 255) },
    trueno     = { Color3.fromRGB(160, 120, 10), Color3.fromRGB(255, 235, 30), Color3.fromRGB(255, 230, 0),  Color3.fromRGB(255, 210, 0)  },
    naturaleza = { Color3.fromRGB(25,  120, 35), Color3.fromRGB(70,  190, 50), Color3.fromRGB(50,  190, 30), Color3.fromRGB(30,  160, 20)  },
    sombra     = { Color3.fromRGB(40,  15,  70), Color3.fromRGB(120, 50,  190),Color3.fromRGB(110, 30,  170),Color3.fromRGB(90,  15,  150) },
    celestial  = { Color3.fromRGB(190, 170, 255),Color3.fromRGB(255, 245, 255),Color3.fromRGB(210, 190, 255),Color3.fromRGB(190, 170, 255) },
    vacio      = { Color3.fromRGB(35,  30,  40), Color3.fromRGB(160, 0,   255),Color3.fromRGB(140, 20,  255),Color3.fromRGB(120, 0,   220) },
}

-- Modificadores por rareza: rate, brightness, range, accentRate (2º emisor)
local RARITY_MOD = {
    comun      = { rate = 12, brightness = 1.6, range = 8,  accentRate = 0  },
    poco_comun = { rate = 14, brightness = 1.4, range = 7,  accentRate = 0  },
    raro       = { rate = 22, brightness = 2.2, range = 9,  accentRate = 8  },
    epico      = { rate = 35, brightness = 3.5, range = 11, accentRate = 16 },
    legendario = { rate = 55, brightness = 5.0, range = 14, accentRate = 28 },
    mitico     = { rate = 80, brightness = 7.0, range = 18, accentRate = 45 },
}

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
-- Aplica colores, partículas y luz al clon de Dragon Pet
-- dragonData (opcional): entrada de DragonData.Dragons para overrides por dragón
--------------------------------------------------------------------------------
local function applyDragonAppearance(clone, element, rarity, dragonData)
    local base = ELEMENT_BASE[element]
    local mod  = RARITY_MOD[rarity]
    if not base or not mod then return end

    -- Overrides por dragón individual (DragonData) o fallback al base del elemento
    local bodyColor     = (dragonData and dragonData.bodyColor)      or base[1]
    local accentColor   = (dragonData and dragonData.secondaryColor) or base[2]
    local particleColor = (dragonData and dragonData.particleColor)  or base[3]
    local glowColor     = (dragonData and dragonData.glowColor)      or base[4]

    -- Material.Neon: ignora la textura baked del modelo y usa Part.Color directamente.
    -- Esto da colores exactos y un brillo propio en el cuerpo sin PointLight extra.
    -- Sombra y Vacío usan SmoothPlastic para el look mate oscuro que requieren.
    local isMate = (element == "sombra" or element == "vacio")
    local bodyMat = isMate and Enum.Material.SmoothPlastic or Enum.Material.Neon

    local anchor = clone
    if clone:IsA("BasePart") then
        clone.Color    = bodyColor
        clone.Material = bodyMat
        for _, desc in ipairs(clone:GetDescendants()) do
            if desc:IsA("SurfaceAppearance") then
                desc:Destroy()
            elseif desc:IsA("SpecialMesh") then
                desc.VertexColor = Vector3.new(1, 1, 1)
                desc.TextureId   = ""   -- sin textura → Material.Neon muestra color puro
            elseif desc:IsA("BasePart") then
                desc.Color    = accentColor
                desc.Material = bodyMat
            end
        end
    end
    if not anchor then return end

    -- Emisor principal
    local pe = Instance.new("ParticleEmitter")
    pe.Color         = ColorSequence.new({ ColorSequenceKeypoint.new(0, particleColor), ColorSequenceKeypoint.new(1, glowColor) })
    pe.Size          = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0) })
    pe.Transparency  = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
    pe.LightEmission = 1
    pe.Rate          = mod.rate
    pe.Lifetime      = NumberRange.new(0.8, 1.5)
    pe.Speed         = NumberRange.new(2, 5)
    pe.SpreadAngle   = Vector2.new(50, 50)
    pe.Parent        = anchor

    -- Segundo emisor de acento (rareza raro+)
    if mod.accentRate > 0 then
        local pe2 = Instance.new("ParticleEmitter")
        pe2.Color         = ColorSequence.new({ ColorSequenceKeypoint.new(0, accentColor), ColorSequenceKeypoint.new(1, bodyColor) })
        pe2.Size          = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
        pe2.Transparency  = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
        pe2.LightEmission = 1
        pe2.Rate          = mod.accentRate
        pe2.Lifetime      = NumberRange.new(0.8, 1.5)
        pe2.Speed         = NumberRange.new(0.5, 1.5)
        pe2.SpreadAngle   = Vector2.new(60, 60)
        pe2.Parent        = anchor
    end

    -- Emisor de destellos secundarios (particleColor2 en DragonData)
    -- Vida corta + tamaño grande → efecto "pop" de estrella / chispa brillante
    if dragonData and dragonData.particleColor2 then
        local peS = Instance.new("ParticleEmitter")
        peS.Color         = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   dragonData.particleColor2),  -- color secundario puro al nacer
            ColorSequenceKeypoint.new(0.4, dragonData.particleColor2),  -- se mantiene brillante
            ColorSequenceKeypoint.new(1,   particleColor),              -- funde al color base al morir
        })
        peS.Size          = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.0),
            NumberSequenceKeypoint.new(0.2, 0.90),  -- aparece rápido y grande (visible en malla 5×)
            NumberSequenceKeypoint.new(1,   0.0),   -- encoge hasta desaparecer
        })
        peS.Transparency  = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.0),
            NumberSequenceKeypoint.new(0.5, 0.0),
            NumberSequenceKeypoint.new(1,   1.0),
        })
        peS.LightEmission = 1
        peS.Rate          = mod.rate * 2.5          -- frecuente para que los destellos sean continuos
        peS.Lifetime      = NumberRange.new(0.10, 0.28)  -- vida muy corta = flash rápido
        peS.Speed         = NumberRange.new(1, 4)
        peS.SpreadAngle   = Vector2.new(180, 180)
        peS.RotSpeed      = NumberRange.new(-360, 360)
        peS.Rotation      = NumberRange.new(0, 360)
        peS.Parent        = anchor
    end

    -- Llama en la punta de la cola (tailFlame en DragonData)
    -- La malla visual tiene Scale(5,5,5) y Offset(1,0,3) respecto al Handle físico.
    -- El Attachment se desplaza ~5 studs atrás (−Z) del centro del Handle para
    -- quedar aproximadamente en la cola. Ajustar tailOffsetZ si la malla lo requiere.
    if dragonData and dragonData.tailFlame then
        local tailAtt = Instance.new("Attachment")
        tailAtt.CFrame = CFrame.new(1, 0.5, -5)   -- estimado: detrás del cuerpo, ligeramente arriba
        tailAtt.Parent = anchor

        local flame = Instance.new("ParticleEmitter")
        flame.Color         = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 240,  80)),  -- amarillo brillante
            ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 140,   0)),  -- naranja
            ColorSequenceKeypoint.new(1,   Color3.fromRGB(200,  30,   0)),  -- rojo al morir
        })
        flame.Size          = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.15),
            NumberSequenceKeypoint.new(0.3, 0.55),   -- crece rápido → llama visible sobre la malla
            NumberSequenceKeypoint.new(1,   0.0),
        })
        flame.Transparency  = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.0),
            NumberSequenceKeypoint.new(0.6, 0.1),
            NumberSequenceKeypoint.new(1,   1.0),
        })
        flame.LightEmission  = 1
        flame.Rate           = 40
        flame.Lifetime       = NumberRange.new(0.35, 0.70)
        flame.Speed          = NumberRange.new(2.5, 5.0)
        flame.SpreadAngle    = Vector2.new(15, 15)
        flame.RotSpeed       = NumberRange.new(-180, 180)
        flame.Rotation       = NumberRange.new(0, 360)
        flame.Parent         = tailAtt
    end

    -- Partículas cayendo (gotitas de agua, pétalos, etc.)
    -- Usan un Attachment rotado 180° para que el eje +Y apunte hacia abajo
    if dragonData and dragonData.fallingParticles then
        local att = Instance.new("Attachment")
        att.CFrame = CFrame.Angles(math.pi, 0, 0)   -- eje Y apunta hacia abajo
        att.Parent = anchor
        local peD = Instance.new("ParticleEmitter")
        peD.Color         = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   particleColor),
            ColorSequenceKeypoint.new(0.5, accentColor),
            ColorSequenceKeypoint.new(1,   particleColor),
        })
        peD.Size          = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.55),
            NumberSequenceKeypoint.new(0.6, 0.40),
            NumberSequenceKeypoint.new(1,   0.0),
        })
        peD.Transparency  = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.0),
            NumberSequenceKeypoint.new(0.6, 0.2),
            NumberSequenceKeypoint.new(1,   1.0),
        })
        peD.LightEmission = 0.7
        peD.Rate          = mod.rate * 2.2           -- denso para que las gotas sean visibles
        peD.Lifetime      = NumberRange.new(1.0, 2.0) -- vida larga: caen más studs antes de morir
        peD.Speed         = NumberRange.new(3.0, 6.0) -- velocidad alta para caída obvia
        peD.SpreadAngle   = Vector2.new(35, 35)       -- cono algo ancho: algunas gotas salen a los lados
        peD.Parent        = att
    end

    -- Partículas flotantes (copos de nieve, cristalitos girando)
    if dragonData and dragonData.floatingParticles then
        local peFL = Instance.new("ParticleEmitter")
        peFL.Color         = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   particleColor),
            ColorSequenceKeypoint.new(0.5, accentColor),
            ColorSequenceKeypoint.new(1,   glowColor),
        })
        peFL.Size          = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.50),
            NumberSequenceKeypoint.new(0.5, 0.70),
            NumberSequenceKeypoint.new(1,   0),
        })
        peFL.Transparency  = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
        peFL.LightEmission = 0.9
        peFL.Rate          = mod.rate * 2
        peFL.Lifetime      = NumberRange.new(1.5, 3.0)
        peFL.Speed         = NumberRange.new(3, 7)       -- velocidad mayor para salir del mesh
        peFL.SpreadAngle   = Vector2.new(180, 180)
        peFL.RotSpeed      = NumberRange.new(-80, 80)
        peFL.Rotation      = NumberRange.new(0, 360)
        peFL.Parent        = anchor
    end

    -- Luz puntual
    -- Si noGlow=true: solo destello de ojos muy tenue; si no, luz normal por rareza
    local light
    if dragonData and dragonData.noGlow then
        light            = Instance.new("PointLight")
        light.Color      = (dragonData.eyeColor) or glowColor
        light.Brightness = 0.35
        light.Range      = 3
        light.Parent     = anchor
    else
        light            = Instance.new("PointLight")
        light.Color      = glowColor
        light.Brightness = mod.brightness
        light.Range      = mod.range
        light.Parent     = anchor
    end

    -- Destello eléctrico intermitente (trueno)
    if dragonData and dragonData.electricFlash then
        local baseBr = mod.brightness
        task.spawn(function()
            while anchor and anchor.Parent do
                light.Brightness = baseBr * 3.5
                task.wait(0.06 + math.random() * 0.04)
                light.Brightness = baseBr * 0.2
                task.wait(0.15 + math.random() * 0.55)
            end
        end)
    end

    -- Efectos especiales por elemento
    if element == "vacio" then
        -- Semitransparencia+Neon solo para dragones de vacío sin bodyColor propio
        -- (el Void Hatchling común usa cuerpo mate oscuro, sin Neon)
        if not (dragonData and dragonData.bodyColor) then
            if anchor:IsA("BasePart") then
                anchor.Transparency = 0.30
                anchor.Material     = Enum.Material.Neon
            end
        end
        -- Colores del glitch desde DragonData si existen, si no los valores por defecto
        local glitchC1 = (dragonData and dragonData.particleColor)  or Color3.fromRGB(200, 0, 255)
        local glitchC2 = (dragonData and dragonData.particleColor2) or Color3.fromRGB(80,  0, 150)
        -- Partículas de distorsión digital: rápidas, erráticas, corta vida
        local glitch = Instance.new("ParticleEmitter")
        glitch.Color         = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   glitchC1),
            ColorSequenceKeypoint.new(0.5, glitchC2),
            ColorSequenceKeypoint.new(1,   Color3.fromRGB(30,  0,  60)),
        })
        glitch.Size          = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.50),
            NumberSequenceKeypoint.new(0.5, 0.80),
            NumberSequenceKeypoint.new(1,   0),
        })
        glitch.Transparency  = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        })
        glitch.LightEmission = 1
        glitch.Rate          = mod.rate * 2   -- más denso que el emisor base
        glitch.Lifetime      = NumberRange.new(0.05, 0.20)  -- vida muy corta = efecto glitch
        glitch.Speed         = NumberRange.new(4, 10)
        glitch.SpreadAngle   = Vector2.new(180, 180)        -- en todas direcciones
        glitch.RotSpeed      = NumberRange.new(-360, 360)
        glitch.Rotation      = NumberRange.new(0, 360)
        glitch.Parent        = anchor
    end

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

        -- Part invisible en la superficie: ancla para ProximityPrompt y BillboardGui
        local pad = mkPart(model, "NestPad_" .. i,
            Vector3.new(10, 2, 10),
            CFrame.new(padBase + Vector3.new(0, 1, 0)),
            unlocked and COLOR_EMPTY or COLOR_LOCKED,
            Enum.Material.SmoothPlastic)
        pad.Transparency = 1
        pad.CanCollide   = false

        -- Clonar el modelo Crater y escalarlo al footprint del nido (10×10 studs)
        local craterClone = craterTemplate:Clone()
        local _, rawSize  = craterTemplate:GetBoundingBox()
        local scaleFactor = 10 / math.max(rawSize.X, rawSize.Z)
        craterClone:ScaleTo(scaleFactor)

        -- Auto-asignar PrimaryPart si el modelo no lo tiene configurado
        if not craterClone.PrimaryPart then
            local base = craterClone:FindFirstChildWhichIsA("BasePart", true)
            if base then craterClone.PrimaryPart = base end
        end

        -- Posicionar el modelo visual sobre la plataforma
        local _, scaledSize = craterClone:GetBoundingBox()
        if craterClone.PrimaryPart then
            craterClone:PivotTo(CFrame.new(padBase + Vector3.new(0, scaledSize.Y / 2, 0)))
        else
            craterClone:MoveTo(padBase + Vector3.new(0, scaledSize.Y / 2, 0))
        end
        craterClone.Name   = "NestCrater_" .. i
        craterClone.Parent = model

        local bowl = pad   -- bowl apunta al ancla (para el flash de color en recolección)

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
            prompt.MaxActivationDistance  = 12
            prompt.HoldDuration           = 0
            prompt.RequiresLineOfSight    = false
            prompt.Enabled               = false
            prompt.Parent                = pad
        end

        nests[i] = { pad = pad, bowl = bowl, bb = bb, nameLbl = nameLbl, rarLbl = rarLbl, goldLbl = goldLbl, boostLbl = boostLbl, dragonClone = nil }
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

        -- Dragon Pet: crear o recrear el clon si el dragón cambió o no existe
        if entry.dragonClone and entry.currentDragonId ~= nido.dragonId then
            entry.dragonClone:Destroy()
            entry.dragonClone    = nil
            entry.currentDragonId = nil
            if entry.bb then entry.bb.StudsOffset = Vector3.new(0, 7, 0) end
        end
        if petTemplate and not entry.dragonClone then
            local clone = petTemplate:Clone()
            -- Extraer el Handle del Accessory para evitar el auto-attach de Roblox
            local handle = clone:FindFirstChild("Handle") or clone:FindFirstChildWhichIsA("BasePart", true)
            if handle then
                local mesh = handle:FindFirstChildWhichIsA("SpecialMesh")
                if mesh then
                    mesh.Scale  = Vector3.new(5, 5, 5)
                    mesh.Offset = Vector3.new(1, 0, 3)
                end

                -- Anclar y posicionar ANTES de parentar
                local padTop = pad.Position.Y + pad.Size.Y / 2
                handle.Anchored   = true
                handle.CanCollide = false
                handle.CFrame = CFrame.new(pad.Position.X, padTop + 3, pad.Position.Z)

                handle.Parent = pad.Parent
                clone:Destroy()

                local ok, err = pcall(applyDragonAppearance, handle, element, rarity, dragon)
                if not ok then
                    warn("[FarmSystem] applyDragonAppearance error: " .. tostring(err))
                end
                entry.dragonClone    = handle
                entry.currentDragonId = nido.dragonId

                if entry.bb then
                    entry.bb.StudsOffset = Vector3.new(0, 10, 0)
                end
            end
        end
    else
        -- Nido vacío o bloqueado
        -- Destruir dragon pet si existía
        if entry.dragonClone then
            entry.dragonClone:Destroy()
            entry.dragonClone = nil
            if entry.bb then entry.bb.StudsOffset = Vector3.new(0, 7, 0) end
        end
        -- Destruir huevo físico si existía
        if entry.eggModel then
            entry.eggModel:Destroy()
            entry.eggModel = nil
        end

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
                DataStore.AddGold(player, oro)
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
                            DataStore.AddGold(player, oro)
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

-- Colores de huevo por rareza
local EGG_RARITY_COLORS = {
    comun       = Color3.fromRGB(200, 200, 200),
    poco_comun  = Color3.fromRGB(100, 220, 100),
    raro        = Color3.fromRGB(80,  130, 255),
    epico       = Color3.fromRGB(160, 80,  255),
    legendario  = Color3.fromRGB(255, 180, 50),
    mitico      = Color3.fromRGB(255, 80,  80),
}

-- Crea un Part de huevo físico encima del nido cuando el huevo está listo
function FarmSystem.ShowEggOnNest(player, nestIndex)
    local farm = farmModels[player.UserId]
    if not farm then return end
    local entry = farm.nests[nestIndex]
    if not entry then return end
    if entry.eggModel then return end  -- ya existe, no duplicar

    local pad = farm.model:FindFirstChild("NestPad_" .. nestIndex)
    if not pad then return end

    local nestData = NestSystem.GetNestData(player)
    local dragonId = nestData and nestData.nests[nestIndex] and nestData.nests[nestIndex].dragonId
    local dragon   = dragonId and DragonData.GetDragonById(dragonId)
    local color    = EGG_RARITY_COLORS[dragon and dragon.rarity or "comun"] or Color3.fromRGB(200, 200, 200)

    local egg = Instance.new("Part")
    egg.Name       = "EggModel"
    egg.Size       = Vector3.new(1.2, 1.5, 1.2)
    egg.Anchored   = true
    egg.CanCollide = false
    egg.Color      = color
    egg.Material   = Enum.Material.SmoothPlastic

    local mesh = Instance.new("SpecialMesh", egg)
    mesh.MeshType = Enum.MeshType.Sphere
    mesh.Scale    = Vector3.new(1, 1.3, 1)

    local padTop = pad.Position.Y + pad.Size.Y / 2
    egg.CFrame = CFrame.new(pad.Position.X, padTop + 0.75, pad.Position.Z + 4)
    egg.Parent = farm.model

    entry.eggModel = egg
end

-- Elimina el Part de huevo físico del nido
function FarmSystem.RemoveEggFromNest(player, nestIndex)
    local farm = farmModels[player.UserId]
    if not farm then return end
    local entry = farm.nests[nestIndex]
    if not entry then return end
    if entry.eggModel then
        entry.eggModel:Destroy()
        entry.eggModel = nil
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

-- Mostrar/quitar huevo físico cuando EggService lo notifica
EggService.OnEggReady = function(player, nestIndex)
    FarmSystem.ShowEggOnNest(player, nestIndex)
end
EggService.OnEggCollected = function(player, nestIndex)
    FarmSystem.RemoveEggFromNest(player, nestIndex)
end

startUpdateLoop()
-- Auto-collect eliminado: el jugador recolecta manualmente presionando E al acercarse al nido

return FarmSystem
