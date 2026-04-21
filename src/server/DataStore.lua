--------------------------------------------------------------------------------
-- DataStore.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Fuente de verdad para la persistencia de todos los datos del jugador.
-- Coordina la carga/guardado entre NestSystem y DragonService.
--
-- NOTAS DE ARQUITECTURA:
--   · localData[uid].nests     y localData[uid].inventory son las MISMAS tablas
--     que NestSystem.playerState[uid] recibe en InitPlayer (misma referencia Lua).
--     Las mutaciones de NestSystem (PlaceDragon, RemoveDragon, BuySlot) se
--     reflejan automáticamente en localData sin necesidad de sync explícita.
--   · level, gold, slots, prestigeScales son NÚMEROS (copia por valor); se
--     deben releer de NestSystem.GetNestData() antes de cada guardado.
--   · lastCollected (DragonService) se guarda como os.time() en el momento
--     del save. DragonService.StartProduction lo resetea igual en cada carga,
--     por lo que el valor guardado sirve solo de referencia histórica.
--   · El balance de oro tiene DOS representaciones:
--       - localData[uid].currentGold   → caché de DataStore
--       - NestSystem.playerState[uid].gold → valor live (BuySlot lo descuenta)
--     DataStore.AddGold / SpendGold mantienen ambas en sincronía.
--     Al guardar, siempre se lee de NestSystem.GetNestData() para obtener
--     el valor más reciente.
--------------------------------------------------------------------------------

local DataStoreService    = game:GetService("DataStoreService")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Módulos compartidos
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))
local DragonData = require(ReplicatedStorage:WaitForChild("DragonData"))

-- Servicios de gameplay (cargados después de este script en la jerarquía)
local NestSystem   = require(ServerScriptService:WaitForChild("NestSystem"))
local BoostSystem  = require(ServerScriptService:WaitForChild("BoostSystem"))
-- EggService se carga de forma diferida para evitar require circular
-- (EggService también requiere DataStore; se accede vía lazy-require en las funciones)
local _EggService = nil
local function getEggService()
    if not _EggService then
        _EggService = require(ServerScriptService:WaitForChild("EggService"))
    end
    return _EggService
end

--------------------------------------------------------------------------------
-- DataStore
--------------------------------------------------------------------------------

local PlayerDataStore
do
    local ok, result = pcall(function()
        return DataStoreService:GetDataStore("PlayerData_v1")
    end)
    if ok then
        PlayerDataStore = result
    else
        warn("[DataStore] No se pudo acceder a DataStore (publica el lugar para activarlo): " .. tostring(result))
        -- Mock para pruebas en Studio sin publicar
        PlayerDataStore = {
            GetAsync    = function() return nil end,
            SetAsync    = function() end,
            UpdateAsync = function(_, _, transform) pcall(transform, nil) end,
        }
    end
end

--------------------------------------------------------------------------------
-- Constantes internas
--------------------------------------------------------------------------------

local VERSION_ACTUAL     = 1
local INTERVALO_AUTOSAVE = 60   -- segundos entre guardados automáticos
local MAX_INTENTOS_CARGA = 3    -- reintentos antes de kickear
local ESPERA_REINTENTO   = 2    -- segundos entre reintentos

-- Elementos para detección de colecciones completas
local ELEMENTOS = { "fire", "water", "ice", "thunder", "nature", "shadow", "celestial", "void" }
local RAREZAS   = { "common", "uncommon", "rare", "epic", "legendary", "mythic" }

--------------------------------------------------------------------------------
-- RemoteEvents
--------------------------------------------------------------------------------

local remotesFolder do
    remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotesFolder then
        remotesFolder        = Instance.new("Folder")
        remotesFolder.Name   = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    end
end

local function obtenerOCrear(clase, nombre)
    local obj = remotesFolder:FindFirstChild(nombre)
    if not obj then
        obj        = Instance.new(clase)
        obj.Name   = nombre
        obj.Parent = remotesFolder
    end
    return obj
end

local GoldUpdatedEvent       = obtenerOCrear("RemoteEvent",    "GoldUpdated")
local GemsUpdatedEvent       = obtenerOCrear("RemoteEvent",    "GemsUpdated")
local GetCatalogueDataFunc   = obtenerOCrear("RemoteFunction", "RequestGetCatalogueData")

--------------------------------------------------------------------------------
-- Estado en memoria
-- Tabla central que almacena el payload completo listo para serializar.
--------------------------------------------------------------------------------

local localData = {}   -- localData[userId] = { version, level, gold, ... }

--------------------------------------------------------------------------------
-- Datos por defecto para jugadores nuevos
--------------------------------------------------------------------------------

local function datosDefault()
    return {
        version           = VERSION_ACTUAL,
        level             = 1,
        currentGold       = 1000,         -- oro inicial de prueba
        gems              = 1000,         -- gemas iniciales de prueba
        prestigeScales    = 0,
        slots             = 3,
        nests             = {},
        inventory         = {},
        catalogue         = {},
        collectionBonuses = {},
        boosts            = {},
        eggs              = {},   -- array de { idx, dragonId, guaranteed, collectedAt }
        dailyLogin = {
            lastLogin = 0,
            streak    = 0,
        },
        settings = {
            notifications = true,
        },
    }
end

--------------------------------------------------------------------------------
-- Migraciones de versión
-- Añade bloques `if data.version < N` aquí cuando se actualice la estructura.
--------------------------------------------------------------------------------

local function migrar(data)
    if not data.version then
        -- Datos pre-versionados: asumir v0 y migrar a v1
        data.version          = 1
        data.boosts           = data.boosts or {}
        data.collectionBonuses = data.collectionBonuses or {}
        data.catalogue        = data.catalogue or {}
        data.eggs             = data.eggs or {}
    end

    -- Ejemplo de migración futura:
    -- if data.version < 2 then
    --     data.nuevoCampo = valorDefault
    --     data.version = 2
    -- end

    data.version = VERSION_ACTUAL
    return data
end

--------------------------------------------------------------------------------
-- Garantizar campos faltantes tras una migración parcial
--------------------------------------------------------------------------------

local function rellenarCamposFaltantes(data)
    local defaults = datosDefault()
    for campo, valorDefault in pairs(defaults) do
        if data[campo] == nil then
            -- Tabla: copiar referencia del default (es suficiente para inicializar)
            data[campo] = type(valorDefault) == "table" and {} or valorDefault
        end
    end
    -- Sub-tablas de dailyLogin y settings
    if not data.dailyLogin.lastLogin then data.dailyLogin.lastLogin = 0    end
    if not data.dailyLogin.streak    then data.dailyLogin.streak    = 0    end
    if data.settings.notifications == nil then data.settings.notifications = true end
    return data
end

--------------------------------------------------------------------------------
-- Verificar colecciones completas
-- Una colección = los 6 dragones BASE de un mismo elemento en el catálogo.
-- Al completarla se activa un bonus permanente (collectionBonuses).
-- Devuelve true si se desbloqueó al menos un bonus nuevo.
--------------------------------------------------------------------------------

local function verificarColecciones(player)
    local data = localData[player.UserId]
    if not data then return false end

    local huboCambio = false
    for _, elemento in ipairs(ELEMENTOS) do
        local bonusId = "collection_" .. elemento
        if not data.collectionBonuses[bonusId] then
            local completa = true
            for _, rareza in ipairs(RAREZAS) do
                if not data.catalogue[elemento .. "_" .. rareza] then
                    completa = false
                    break
                end
            end
            if completa then
                data.collectionBonuses[bonusId] = true
                huboCambio = true
                print(("[DataStore] ¡Colección '%s' completada por %s!"):format(
                    bonusId, player.Name))
                -- TODO: aplicar efecto del bonus (p.ej. +10 % gps para el elemento)
            end
        end
    end
    return huboCambio
end

--------------------------------------------------------------------------------
-- Construir payload de guardado
-- Combina localData (gems, catalogue, etc.) con el estado live de NestSystem
-- y DragonService para asegurarse de que siempre se guarda el valor más reciente.
--------------------------------------------------------------------------------

local function construirPayload(player)
    local uid  = player.UserId
    local data = localData[uid]
    if not data then return nil end

    -- Leer estado actualizado de NestSystem
    local nestData = NestSystem.GetNestData(player)
    if nestData then
        data.level          = nestData.level
        data.currentGold    = nestData.gold
        data.prestigeScales = nestData.prestigeScales
        data.slots          = nestData.slots

        -- Serializar el estado de cada nido activo
        -- lastCollected se guarda como marca de tiempo de este save;
        -- DragonService lo resetea de todas formas al cargar con StartProduction.
        local ahora = os.time()
        local nestsSave = {}
        for nestIndex, nido in pairs(nestData.nests) do
            nestsSave[nestIndex] = {
                dragonId        = nido.dragonId,
                boostMultiplier = nido.boostMultiplier,
                lastCollected   = ahora,
            }
        end
        data.nests = nestsSave
    end

    -- Serializar huevos del inventario (antes volátiles, ahora persistidos)
    data.eggs = getEggService().SerializeInventory(player)

    return data
end

--------------------------------------------------------------------------------
-- DataStore
--------------------------------------------------------------------------------

local DataStore = {}

--------------------------------------------------------------------------------
-- DataStore.LoadPlayer(player)
--
-- Carga los datos del jugador desde el DataStore al unirse al servidor.
-- Si es la primera vez, crea datos por defecto.
-- Reintenta hasta MAX_INTENTOS_CARGA veces ante errores de red.
-- Si todos los intentos fallan, kickea al jugador para evitar que juegue sin datos.
-- Inicializa NestSystem con los datos cargados.
--------------------------------------------------------------------------------
function DataStore.LoadPlayer(player)
    local uid    = player.UserId
    local cargado = nil
    local exito   = false

    -- Intentar cargar con reintentos
    for intento = 1, MAX_INTENTOS_CARGA do
        local ok, resultado = pcall(function()
            return PlayerDataStore:GetAsync(tostring(uid))
        end)

        if ok then
            cargado = resultado
            exito   = true
            break
        else
            warn(("[DataStore] Error cargando %s (intento %d/%d): %s")
                :format(player.Name, intento, MAX_INTENTOS_CARGA, tostring(resultado)))
            if intento < MAX_INTENTOS_CARGA then
                task.wait(ESPERA_REINTENTO)
            end
        end
    end

    -- Si todos los intentos fallaron → kickear, NO dejar jugar sin datos
    if not exito then
        player:Kick(
            "No pudimos cargar tus datos del servidor.\n"
            .. "Por favor, inténtalo de nuevo en unos minutos.\n"
            .. "Si el problema persiste, contacta al soporte."
        )
        return false
    end

    -- Aplicar defaults o migrar datos existentes
    if cargado == nil then
        cargado = datosDefault()
        print(("[DataStore] Jugador nuevo: %s"):format(player.Name))
    else
        cargado = migrar(cargado)
        print(("[DataStore] Datos cargados para %s (v%d, nivel %d)")
            :format(player.Name, cargado.version, cargado.level or 1))
    end

    -- Garantizar que no falte ningún campo (migraciones parciales)
    cargado = rellenarCamposFaltantes(cargado)

    -- Calcular streak de login diario
    local ahora  = os.time()
    local diaSeg = 86400
    local ultimo = cargado.dailyLogin.lastLogin
    local diff   = ahora - ultimo

    if ultimo > 0 then
        if diff >= diaSeg and diff < diaSeg * 2 then
            cargado.dailyLogin.streak = cargado.dailyLogin.streak + 1
        elseif diff >= diaSeg * 2 then
            -- La racha se rompió por más de un día de ausencia
            cargado.dailyLogin.streak = 1
        end
        -- Si diff < diaSeg el jugador ya inició sesión hoy; streak no cambia
    else
        -- Primera vez iniciando sesión
        cargado.dailyLogin.streak = 1
    end
    cargado.dailyLogin.lastLogin = ahora

    -- Guardar en memoria
    localData[uid] = cargado

    -- Inicializar NestSystem pasando las sub-tablas por referencia.
    -- inventory y nests serán la MISMA tabla en memoria; mutaciones de
    -- NestSystem se reflejan automáticamente en localData.
    NestSystem.InitPlayer(player, {
        level          = cargado.level,
        gold           = cargado.currentGold,
        prestigeScales = cargado.prestigeScales,
        slots          = cargado.slots,
        nests          = cargado.nests,       -- referencia compartida
        inventory      = cargado.inventory,   -- referencia compartida
    })

    -- Inicializar BoostSystem: restaura boosts activos y pasa referencia al inventario
    BoostSystem.InitPlayer(player, cargado.boosts)

    -- Restaurar huevos del inventario guardados en la sesión anterior
    getEggService().LoadInventory(player, cargado.eggs or {})

    -- Notificar al cliente con el estado inicial (diferido para que los
    -- LocalScripts del cliente tengan tiempo de conectarse).
    task.delay(1, function()
        if not player.Parent then return end
        local data = localData[uid]
        if not data then return end
        local nestData = NestSystem.GetNestData(player)
        local goldActual = nestData and nestData.gold or data.currentGold
        GoldUpdatedEvent:FireClient(player, {
            currentGold = goldActual,
        })
        GemsUpdatedEvent:FireClient(player, { gems = data.gems })
    end)

    return true
end

--------------------------------------------------------------------------------
-- DataStore.SavePlayer(player)
--
-- Guarda el estado actual del jugador en el DataStore.
-- Recopila el estado live de NestSystem y DragonService antes de serializar.
-- Registra éxito o error en la consola del servidor.
-- Devuelve true si el guardado fue exitoso.
--------------------------------------------------------------------------------
function DataStore.SavePlayer(player)
    local uid = player.UserId
    if not localData[uid] then
        warn(("[DataStore] SavePlayer: no hay datos en memoria para %s"):format(player.Name))
        return false
    end

    local payload = construirPayload(player)
    if not payload then
        warn(("[DataStore] SavePlayer: construirPayload devolvió nil para %s"):format(player.Name))
        return false
    end

    local ok, err = pcall(function()
        PlayerDataStore:SetAsync(tostring(uid), payload)
    end)

    if ok then
        print(("[DataStore] ✓ Guardado para %s (nivel %d, %d oro, %d gemas)")
            :format(player.Name, payload.level, payload.currentGold, payload.gems))
        return true
    else
        warn(("[DataStore] ✗ Error guardando %s: %s"):format(player.Name, tostring(err)))
        return false
    end
end

--------------------------------------------------------------------------------
-- DataStore.AutoSave()
--
-- Loop que guarda a todos los jugadores activos cada INTERVALO_AUTOSAVE segundos.
-- Se ejecuta en un hilo separado al inicializar el script.
--------------------------------------------------------------------------------
function DataStore.AutoSave()
    task.spawn(function()
        while true do
            task.wait(INTERVALO_AUTOSAVE)

            local jugadores = Players:GetPlayers()
            for _, player in ipairs(jugadores) do
                -- Guardar en hilo propio para no bloquear el loop si un save es lento
                task.spawn(function()
                    DataStore.SavePlayer(player)
                end)
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- DataStore.OnPlayerLeaving(player)
--
-- Guarda inmediatamente los datos del jugador al abandonar la sesión.
-- Limpia la memoria interna de DataStore, NestSystem y DragonService.
--------------------------------------------------------------------------------
function DataStore.OnPlayerLeaving(player)
    -- Guardar de forma síncrona antes de que el jugador se desconecte
    DataStore.SavePlayer(player)

    -- Limpiar memoria interna de este script
    localData[player.UserId] = nil

    -- Nota: NestSystem y DragonService limpian su propia memoria
    -- a través de sus propios PlayerRemoving listeners.
end

--------------------------------------------------------------------------------
-- DataStore.AddGold(player, amount)
--
-- Suma oro al jugador: actualiza currentGold en caché y en NestSystem.
-- Dispara RemoteEvent "GoldUpdated" para refrescar el HUD del cliente.
--------------------------------------------------------------------------------
function DataStore.AddGold(player, amount)
    if type(amount) ~= "number" or amount <= 0 then return end

    local data = localData[player.UserId]
    if not data then return end

    data.currentGold = data.currentGold + amount

    -- Mantener NestSystem sincronizado (su playerState.gold es independiente)
    NestSystem.AddGold(player, amount)

    GoldUpdatedEvent:FireClient(player, {
        currentGold = data.currentGold,
    })
end

--------------------------------------------------------------------------------
-- DataStore.SpendGold(player, amount)
--
-- Descuenta oro del jugador.
-- Lee el saldo actual desde NestSystem (fuente más actualizada, ya que
-- NestSystem.BuySlot también puede descuenta directamente).
-- Devuelve true si había suficiente oro y se descontó; false si no.
--------------------------------------------------------------------------------
function DataStore.SpendGold(player, amount)
    if type(amount) ~= "number" or amount <= 0 then return false end

    local data = localData[player.UserId]
    if not data then return false end

    -- Leer el saldo live desde NestSystem para evitar stale reads
    local nestData   = NestSystem.GetNestData(player)
    local goldActual = nestData and nestData.gold or data.currentGold

    if goldActual < amount then
        return false
    end

    -- Descontar en NestSystem (live) y actualizar caché
    NestSystem.AddGold(player, -amount)
    data.currentGold = goldActual - amount

    GoldUpdatedEvent:FireClient(player, {
        currentGold = data.currentGold,
    })

    return true
end

--------------------------------------------------------------------------------
-- DataStore.AddGems(player, amount)
--
-- Suma gemas al jugador. Dispara RemoteEvent "GemsUpdated".
--------------------------------------------------------------------------------
function DataStore.AddGems(player, amount)
    if type(amount) ~= "number" or amount <= 0 then return end

    local data = localData[player.UserId]
    if not data then return end

    data.gems = data.gems + amount

    GemsUpdatedEvent:FireClient(player, { gems = data.gems })
end

--------------------------------------------------------------------------------
-- DataStore.SpendGems(player, amount)
--
-- Descuenta gemas del jugador.
-- Devuelve true si había suficientes y se descontaron; false si no.
--------------------------------------------------------------------------------
function DataStore.SpendGems(player, amount)
    if type(amount) ~= "number" or amount <= 0 then return false end

    local data = localData[player.UserId]
    if not data then return false end

    if data.gems < amount then
        return false
    end

    data.gems = data.gems - amount

    GemsUpdatedEvent:FireClient(player, { gems = data.gems })
    return true
end

--------------------------------------------------------------------------------
-- DataStore.AddDragonToInventory(player, dragonId)
--
-- Agrega un dragón al inventario del jugador y lo registra en el catálogo.
-- Verifica si se completó alguna colección de elemento y activa el bonus.
-- Como inventory es una referencia compartida con NestSystem, la adición
-- es inmediatamente visible en NestSystem.PlaceDragon sin sync adicional.
--------------------------------------------------------------------------------
function DataStore.AddDragonToInventory(player, dragonId)
    if type(dragonId) ~= "string" or dragonId == "" then return end

    local dragon = DragonData.GetDragonById(dragonId)
    if not dragon then
        warn(("[DataStore] AddDragonToInventory: dragón desconocido '%s'"):format(dragonId))
        return
    end

    local data = localData[player.UserId]
    if not data then return end

    -- Añadir al inventario (referencia compartida con NestSystem)
    data.inventory[dragonId] = (data.inventory[dragonId] or 0) + 1

    -- Registrar en el catálogo (dragones vistos alguna vez)
    if not data.catalogue[dragonId] then
        data.catalogue[dragonId] = true
        print(("[DataStore] %s desbloqueó '%s' en el catálogo.")
            :format(player.Name, dragon.name))

        -- Verificar si se completó alguna colección con este nuevo dragón
        verificarColecciones(player)
    end
end

--------------------------------------------------------------------------------
-- DataStore.GetInventoryLimit(player)
--
-- Devuelve el límite de inventario compartido (dragones + huevos) para el
-- nivel actual del jugador. Usa Constants.INVENTORY_LIMITS.
--------------------------------------------------------------------------------
function DataStore.GetInventoryLimit(player)
    local data = localData[player.UserId]
    if not data then return 5 end
    local lv = data.level or 1
    return Constants.INVENTORY_LIMITS[lv] or 15
end

--------------------------------------------------------------------------------
-- DataStore.IsInventoryFull(player)
--
-- Devuelve true si la suma de dragones en inventario + huevos en inventario
-- alcanza o supera el límite del nivel actual.
--------------------------------------------------------------------------------
function DataStore.IsInventoryFull(player)
    local data = localData[player.UserId]
    if not data then return false end

    local totalDragones = 0
    for _, count in pairs(data.inventory or {}) do
        totalDragones += count
    end

    local totalHuevos = getEggService().GetEggCount(player)
    return (totalDragones + totalHuevos) >= DataStore.GetInventoryLimit(player)
end

--------------------------------------------------------------------------------
-- DataStore.GetPlayerData(player)
--
-- Devuelve los datos actuales en memoria del jugador (combinados con el
-- estado live de NestSystem para los campos numéricos que pueden divergir).
-- NO hace lectura de DataStore; es una consulta en memoria.
--------------------------------------------------------------------------------
function DataStore.GetPlayerData(player)
    local data = localData[player.UserId]
    if not data then return nil end

    -- Enriquecer con el estado live de NestSystem antes de devolver
    local nestData = NestSystem.GetNestData(player)
    if nestData then
        -- Devolver una copia superficial con los valores actualizados
        return {
            version           = data.version,
            level             = nestData.level,
            currentGold       = nestData.gold,
            gems              = data.gems,
            prestigeScales    = nestData.prestigeScales,
            slots             = nestData.slots,
            nests             = nestData.nests,
            inventory         = data.inventory,
            catalogue         = data.catalogue,
            collectionBonuses = data.collectionBonuses,
            boosts            = data.boosts,
            dailyLogin        = data.dailyLogin,
            settings          = data.settings,
        }
    end

    return data
end

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
--------------------------------------------------------------------------------

-- Datos del catálogo: qué dragones ha descubierto el jugador y cuántos tiene
GetCatalogueDataFunc.OnServerInvoke = function(player)
    local data = DataStore.GetPlayerData(player)
    if not data then return nil end

    -- nestDragons: dragonId → true para los dragones actualmente en nidos
    local nestDragons = {}
    for _, nido in pairs(data.nests or {}) do
        if nido.dragonId then
            nestDragons[nido.dragonId] = true
        end
    end

    return {
        discovered  = data.catalogue   or {},
        inventory   = data.inventory   or {},
        nestDragons = nestDragons,
        playerLevel = data.level       or 1,
    }
end

--------------------------------------------------------------------------------
-- Conexiones de eventos de jugadores
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
    DataStore.LoadPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
    DataStore.OnPlayerLeaving(player)
end)

--------------------------------------------------------------------------------
-- BindToClose: guardar a todos los jugadores cuando Roblox apaga el servidor
--
-- Roblox concede ~30 segundos antes de terminar el proceso.
-- Guardamos a todos en paralelo para maximizar el tiempo disponible, y
-- esperamos a que todos terminen (o hasta 25 segundos como margen de seguridad).
--------------------------------------------------------------------------------

game:BindToClose(function()
    print("[DataStore] Servidor cerrándose — guardando todos los jugadores...")

    local jugadores    = Players:GetPlayers()
    local totalGuardados = 0
    local totalJugadores = #jugadores

    if totalJugadores == 0 then
        print("[DataStore] No hay jugadores activos. Cierre limpio.")
        return
    end

    -- Guardar en paralelo y esperar confirmación de cada uno
    local hilos = {}
    for _, player in ipairs(jugadores) do
        local hilo = task.spawn(function()
            local exito = DataStore.SavePlayer(player)
            totalGuardados = totalGuardados + (exito and 1 or 0)
        end)
        table.insert(hilos, hilo)
    end

    -- Esperar hasta 25 segundos a que todos los saves terminen
    local inicio  = os.clock()
    local TIMEOUT = 25

    while totalGuardados < totalJugadores and (os.clock() - inicio) < TIMEOUT do
        task.wait(0.1)
    end

    if totalGuardados < totalJugadores then
        warn(("[DataStore] BindToClose: solo se guardaron %d/%d jugadores antes del timeout.")
            :format(totalGuardados, totalJugadores))
    else
        print(("[DataStore] BindToClose: %d/%d jugadores guardados correctamente.")
            :format(totalGuardados, totalJugadores))
    end
end)

-- Cargar jugadores que ya estaban en sesión cuando se cargó este script
for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(function()
        DataStore.LoadPlayer(player)
    end)
end

-- Arrancar el loop de autosave
DataStore.AutoSave()

--------------------------------------------------------------------------------

return DataStore
