-- Main.server.lua
-- Punto de entrada del servidor. Carga todos los servicios en orden de dependencias.

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

-- Servicios base (sin dependencias cruzadas entre sí)
require(ServerScriptService:WaitForChild("DragonService"))
require(ServerScriptService:WaitForChild("NestSystem"))
require(ServerScriptService:WaitForChild("BoostSystem"))
local DataStore = require(ServerScriptService:WaitForChild("DataStore"))
require(ServerScriptService:WaitForChild("EggService"))
require(ServerScriptService:WaitForChild("WeatherSystem"))
require(ServerScriptService:WaitForChild("BreedingSystem"))
require(ServerScriptService:WaitForChild("TradeSystem"))
local FarmSystem = require(ServerScriptService:WaitForChild("FarmSystem"))

-- ShopService depende de WeatherSystem.ActivarEvento
local ShopService = require(ServerScriptService:WaitForChild("ShopService"))
ShopService.Init()

-- ServerManager gestiona los 8 slots de jugador de esta instancia
local ServerManager = require(ServerScriptService:WaitForChild("ServerManager"))
ServerManager.Init()

-- VisitSystem depende de ServerManager
require(ServerScriptService:WaitForChild("VisitSystem"))

-- Asignar granja a cada jugador después de que sus datos cargan.
-- AssignPlot tiene protección interna contra doble-llamada.
Players.PlayerAdded:Connect(FarmSystem.AssignPlot)

-- Jugadores ya en sesión cuando cargó el script (modo Solo de Studio)
for _, player in ipairs(Players:GetPlayers()) do
    FarmSystem.AssignPlot(player)
end
