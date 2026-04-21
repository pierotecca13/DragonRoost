--------------------------------------------------------------------------------
-- TradeSystem.lua  ·  Script de servidor  ·  Dragon Roost
--
-- Gestiona el intercambio de items (dragones, huevos, boosts) entre jugadores
-- del mismo servidor. Nunca se intercambia oro ni gemas.
--
-- FLUJO ESTÁNDAR:
--   ProposeTrade   → crea trade "pending", notifica al receiver
--   RespondToTrade → accept  → "confirmed_initiator" + TradeAccepted al iniciador
--                    reject  → "cancelled"            + TradeCancelled a ambos
--                    counter → "negotiating"           + TradeCounterOffer al iniciador
--   ConfirmTrade   → revalida todo → "confirmed_both" → ejecuta intercambio → "completed"
--   CancelTrade    → cualquier jugador, antes de "confirmed_both"
--
-- DOBLE VALIDACIÓN:
--   Los items se validan en ProposeTrade Y en ConfirmTrade para evitar
--   exploits de timing (p.ej. colocar el dragón en un nido entre propuesta
--   y confirmación). Si la revalidación falla, el trade se cancela.
--
-- ESTADO DE DRAGONES EN NIDOS:
--   NestSystem.PlaceDragon descuenta el dragón del inventario. Por lo tanto,
--   si un dragón está en un nido ya no figura en inventory y el chequeo de
--   cantidad lo descarta naturalmente. La restricción "no en nido activo" es
--   implícita, pero se documenta explícitamente para claridad.
--
-- ESTADO DE DRAGONES EN BREEDING:
--   BreedingSystem reserva dragones sin quitarlos del inventario. Se cuenta
--   cuántas veces aparece el dragonId en breedings activos y se descuenta
--   del disponible para trade.
--
-- NOTA SOBRE HUEVOS:
--   La transferencia de huevos requiere que EggService exponga:
--     EggService.GetEggCount(player, dragonId) → number
--     EggService.ConsumeEgg(player, dragonId, count) → boolean
--     EggService.GiveEgg(player, dragonId, count)
--   Si estas funciones no existen en tiempo de ejecución el trade de huevos
--   fallará de forma controlada y el trade se cancelará con un mensaje claro.
--------------------------------------------------------------------------------

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Módulos compartidos
local Constants  = require(ReplicatedStorage:WaitForChild("Constants"))

-- Servicios de datos y gameplay
-- DataStore es la fuente de verdad para inventario y boosts.
-- NestSystem y BreedingSystem se necesitan para las validaciones de bloqueo.
local DataStore      = require(ServerScriptService:WaitForChild("DataStore"))
local NestSystem     = require(ServerScriptService:WaitForChild("NestSystem"))
local BreedingSystem = require(ServerScriptService:WaitForChild("BreedingSystem"))

-- EggService se carga con task.defer para evitar dependencias circulares de
-- orden de carga. Se accede sólo en tiempo de ejecución de las funciones.
local EggService
task.defer(function()
    EggService = require(ServerScriptService:WaitForChild("EggService"))
end)

--------------------------------------------------------------------------------
-- Constantes internas
--------------------------------------------------------------------------------

local TRADE_DURATION_SECS  = 120  -- segundos hasta que un trade expira
local MAX_TRADES_PER_HOUR  = 3    -- propuestas máximas como iniciador por hora
local MAX_ITEMS_PER_SIDE   = 3    -- máximo de items (suma de cantidades) por lado
local HISTORY_MAX          = 10   -- últimos trades en GetTradeHistory
local LOOP_INTERVAL        = 15   -- segundos entre revisiones de expiración

-- Contadores de estado que permiten cancelar task.delay si un trade se
-- completa o cancela antes de que expire.
local tradeExpireGen = {}   -- tradeExpireGen[tradeId] = generación actual

-- Contador global para garantizar tradeIds únicos aunque dos jugadores
-- propongan exactamente al mismo os.time().
local tradeCounter = 0

--------------------------------------------------------------------------------
-- RemoteEvents y RemoteFunctions
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

-- Eventos: notificaciones de una dirección (servidor → cliente)
local TradeProposedEvent  = obtenerOCrear("RemoteEvent", "TradeProposed")
local TradeAcceptedEvent  = obtenerOCrear("RemoteEvent", "TradeAccepted")
local TradeCancelledEvent = obtenerOCrear("RemoteEvent", "TradeCancelled")
local TradeCompletedEvent = obtenerOCrear("RemoteEvent", "TradeCompleted")
local TradeExpiredEvent   = obtenerOCrear("RemoteEvent", "TradeExpired")
local TradeUpdatedEvent   = obtenerOCrear("RemoteEvent", "TradeUpdated")
local TradeCounterEvent   = obtenerOCrear("RemoteEvent", "TradeCounterOffer")

-- Funciones: petición bidireccional (cliente → servidor → cliente)
local RequestProposeFunc      = obtenerOCrear("RemoteFunction", "RequestProposeTrade")
local RequestRespondFunc      = obtenerOCrear("RemoteFunction", "RequestRespondToTrade")
local RequestConfirmFunc      = obtenerOCrear("RemoteFunction", "RequestConfirmTrade")
local RequestCancelFunc       = obtenerOCrear("RemoteFunction", "RequestCancelTrade")
local RequestUpdateFunc       = obtenerOCrear("RemoteFunction", "RequestUpdateOffer")
local RequestGetActiveFunc    = obtenerOCrear("RemoteFunction", "RequestGetActiveTrades")
local RequestGetInventoryFunc = obtenerOCrear("RemoteFunction", "RequestGetInventoryForTrade")

--------------------------------------------------------------------------------
-- Estado interno
--------------------------------------------------------------------------------

-- Registro activo de todos los trades. Incluye trades en estados terminales
-- hasta que el loop de limpieza los pasa a historial.
-- trades[tradeId] = { tradeId, initiator, receiver, initiatorOffer,
--                      receiverOffer, status, createdAt, expiresAt }
local trades = {}

-- Índice de trades activos por jugador (para GetActiveTrades sin iterar todo).
-- playerTrades[uid] = { tradeId = true }
local playerTrades = {}

-- Historial de los últimos HISTORY_MAX trades finalizados por jugador.
-- tradeHistory[uid] = { { tradeId, status, resumen, completedAt }, ... }
local tradeHistory = {}

-- Timestamps de propuestas del jugador en la última hora (para rate limit).
-- recentInitiated[uid] = { timestamp, timestamp, ... }
local recentInitiated = {}

--------------------------------------------------------------------------------
-- Helpers de validación y estado
--------------------------------------------------------------------------------

-- Crea la tabla playerTrades[uid] si no existe.
local function asegurarIndice(uid)
    if not playerTrades[uid] then playerTrades[uid] = {} end
    if not tradeHistory[uid]  then tradeHistory[uid]  = {} end
    if not recentInitiated[uid] then recentInitiated[uid] = {} end
end

-- Registra el tradeId en el índice de ambos jugadores.
local function indexarTrade(trade)
    local iUid = trade.initiator.UserId
    local rUid = trade.receiver.UserId
    asegurarIndice(iUid)
    asegurarIndice(rUid)
    playerTrades[iUid][trade.tradeId] = true
    playerTrades[rUid][trade.tradeId] = true
end

-- Elimina el tradeId del índice de ambos jugadores (sin borrar el trade).
local function desindexarTrade(trade)
    local iUid = trade.initiator.UserId
    local rUid = trade.receiver.UserId
    if playerTrades[iUid] then playerTrades[iUid][trade.tradeId] = nil end
    if playerTrades[rUid] then playerTrades[rUid][trade.tradeId] = nil end
end

-- Agrega el trade al historial de ambos jugadores y recorta a HISTORY_MAX.
local function agregarAlHistorial(trade)
    local iUid = trade.initiator.UserId
    local rUid = trade.receiver.UserId

    local entrada = {
        tradeId        = trade.tradeId,
        status         = trade.status,
        initiatorId    = iUid,
        receiverId     = rUid,
        initiatorOffer = trade.initiatorOffer,
        receiverOffer  = trade.receiverOffer,
        completedAt    = os.time(),
    }

    for _, uid in ipairs({ iUid, rUid }) do
        asegurarIndice(uid)
        table.insert(tradeHistory[uid], 1, entrada)  -- más reciente primero
        if #tradeHistory[uid] > HISTORY_MAX then
            table.remove(tradeHistory[uid])           -- descarta el más antiguo
        end
    end
end

-- Elimina los timestamps de propuesta más viejos de una hora.
-- Devuelve el número de propuestas recientes que quedan.
local function limpiarPropuestasAntiguas(uid)
    local ahora    = os.time()
    local umbral   = ahora - 3600
    local reciente = recentInitiated[uid] or {}
    local filtrado = {}
    for _, ts in ipairs(reciente) do
        if ts > umbral then
            table.insert(filtrado, ts)
        end
    end
    recentInitiated[uid] = filtrado
    return #filtrado
end

-- Suma la cantidad total de items en una oferta (dragons + eggs + boosts).
-- Usada para validar el límite de 3 items por lado.
local function contarItemsOferta(offer)
    local total = 0
    if offer.dragons then
        for _, item in ipairs(offer.dragons) do
            total = total + (item.quantity or 1)
        end
    end
    if offer.eggs then
        for _, item in ipairs(offer.eggs) do
            total = total + (item.quantity or 1)
        end
    end
    if offer.boosts then
        for _, item in ipairs(offer.boosts) do
            total = total + (item.quantity or 1)
        end
    end
    return total
end

-- Devuelve cuántas veces aparece dragonId como padre activo en BreedingSystem.
-- Estas copias están reservadas y no están disponibles para trade.
local function dragonesEnBreeding(player, dragonId)
    local status = BreedingSystem.GetBreedingStatus(player)
    local count  = 0
    for _, b in ipairs(status.activos) do
        if b.dragonId1 == dragonId then count += 1 end
        if b.dragonId2 == dragonId then count += 1 end
    end
    return count
end

-- Devuelve cuántas copias del dragón tiene disponibles el jugador para trade.
-- Descuenta los reservados en BreedingSystem. Los dragones en nidos ya
-- están descontados del inventario por NestSystem.PlaceDragon.
local function disponiblesParaTrade(player, dragonId)
    local pd = DataStore.GetPlayerData(player)
    if not pd then return 0 end
    local total    = pd.inventory[dragonId] or 0
    local enBreed  = dragonesEnBreeding(player, dragonId)
    return math.max(0, total - enBreed)
end

-- Construye una oferta vacía (estructura canónica).
local function ofertaVacia()
    return { dragons = {}, eggs = {}, boosts = {} }
end

-- Normaliza una oferta recibida del cliente: garantiza que los tres
-- sub-arrays existen y que cada entry tiene los campos mínimos.
-- Devuelve (ofertaNormalizada, errorMsg).
local function normalizarOferta(raw)
    if type(raw) ~= "table" then
        return nil, "La oferta debe ser una tabla."
    end
    local oferta = {
        dragons = raw.dragons or {},
        eggs    = raw.eggs    or {},
        boosts  = raw.boosts  or {},
    }
    -- Validar tipos de los arrays
    if type(oferta.dragons) ~= "table"
    or type(oferta.eggs)    ~= "table"
    or type(oferta.boosts)  ~= "table" then
        return nil, "Sub-arrays de la oferta inválidos."
    end
    -- Validar campos mínimos por entry
    for _, item in ipairs(oferta.dragons) do
        if type(item.dragonId) ~= "string" or type(item.quantity) ~= "number"
        or item.quantity < 1 or item.quantity ~= math.floor(item.quantity) then
            return nil, "Item de dragón con campos inválidos."
        end
    end
    for _, item in ipairs(oferta.eggs) do
        if type(item.dragonId) ~= "string" or type(item.quantity) ~= "number"
        or item.quantity < 1 or item.quantity ~= math.floor(item.quantity) then
            return nil, "Item de huevo con campos inválidos."
        end
    end
    for _, item in ipairs(oferta.boosts) do
        if type(item.boostId) ~= "string" or type(item.quantity) ~= "number"
        or item.quantity < 1 or item.quantity ~= math.floor(item.quantity) then
            return nil, "Item de boost con campos inválidos."
        end
    end
    return oferta, nil
end

-- Valida que todos los items de la oferta existen en el inventario del jugador
-- y no están bloqueados por nido/breeding/restricción.
-- Devuelve (ok: boolean, errorMsg: string|nil).
local function validarOferta(player, offer)
    -- Límite total de items por lado
    local totalItems = contarItemsOferta(offer)
    if totalItems > MAX_ITEMS_PER_SIDE then
        return false, ("Máximo %d items por lado (tienes %d).")
            :format(MAX_ITEMS_PER_SIDE, totalItems)
    end

    -- Si la oferta está vacía, es válida (un lado puede ir vacío)
    if totalItems == 0 then
        return true, nil
    end

    local pd = DataStore.GetPlayerData(player)
    if not pd then
        return false, "No se encontraron datos del jugador."
    end

    -- Validar dragones ---------------------------------------------------
    -- Dragones en nidos ya no están en inventario (NestSystem.PlaceDragon
    -- los descuenta). Los en breeding se restan manualmente.
    for _, item in ipairs(offer.dragons) do
        local disponibles = disponiblesParaTrade(player, item.dragonId)
        if disponibles < item.quantity then
            -- Diferenciar el motivo para el mensaje de error
            local totalInv = pd.inventory[item.dragonId] or 0
            if totalInv < item.quantity then
                return false, ("No tienes suficientes '%s' en el inventario "
                    .. "(necesitas %d, tienes %d).")
                    :format(item.dragonId, item.quantity, totalInv)
            else
                -- Suficientes en inventario pero algunos están reservados
                return false, ("'%s' está siendo usado en breeding activo.")
                    :format(item.dragonId)
            end
        end
    end

    -- Validar huevos -----------------------------------------------------
    -- Requiere EggService.GetEggCount. Si no está disponible, bloquea
    -- el trade de huevos con un mensaje explicativo.
    if #offer.eggs > 0 then
        if not EggService or not EggService.GetEggCount then
            return false, "El intercambio de huevos no está disponible aún "
                .. "(EggService.GetEggCount no implementado)."
        end
        for _, item in ipairs(offer.eggs) do
            local conteo = EggService.GetEggCount(player, item.dragonId)
            if conteo < item.quantity then
                return false, ("No tienes suficientes huevos de '%s' "
                    .. "(necesitas %d, tienes %d).")
                    :format(item.dragonId, item.quantity, conteo)
            end
        end
    end

    -- Validar boosts -----------------------------------------------------
    for _, item in ipairs(offer.boosts) do
        local cantidad = pd.boosts[item.boostId] or 0
        if cantidad < item.quantity then
            return false, ("No tienes suficientes '%s' (necesitas %d, tienes %d).")
                :format(item.boostId, item.quantity, cantidad)
        end
    end

    return true, nil
end

-- Ejecuta la transferencia de items entre dos jugadores.
-- Debe llamarse solo después de doble validación exitosa.
-- Devuelve (ok: boolean, errorMsg: string|nil).
local function transferirItems(fromPlayer, toPlayer, offer)
    local fromPd = DataStore.GetPlayerData(fromPlayer)
    local toPd   = DataStore.GetPlayerData(toPlayer)
    if not fromPd or not toPd then
        return false, "Datos de jugador no disponibles al transferir."
    end

    -- Transferir dragones ------------------------------------------------
    -- inventory es la tabla compartida con NestSystem; mutarla aquí es
    -- equivalente a que NestSystem lo hiciera directamente.
    for _, item in ipairs(offer.dragons) do
        local dragonId  = item.dragonId
        local cantidad  = item.quantity
        local fromCount = fromPd.inventory[dragonId] or 0
        if fromCount < cantidad then
            return false, ("Inventario insuficiente de '%s' al ejecutar transfer.")
                :format(dragonId)
        end
        -- Quitar del origen
        fromPd.inventory[dragonId] = fromCount - cantidad
        if fromPd.inventory[dragonId] <= 0 then
            fromPd.inventory[dragonId] = nil
        end
        -- Añadir al destino (AddDragonToInventory actualiza catálogo y colecciones)
        for _ = 1, cantidad do
            DataStore.AddDragonToInventory(toPlayer, dragonId)
        end
    end

    -- Transferir huevos --------------------------------------------------
    if #offer.eggs > 0 then
        if not EggService or not EggService.ConsumeEgg or not EggService.GiveEgg then
            return false, "Transferencia de huevos no implementada en EggService."
        end
        for _, item in ipairs(offer.eggs) do
            local ok = EggService.ConsumeEgg(fromPlayer, item.dragonId, item.quantity)
            if not ok then
                return false, ("Error al consumir huevo '%s' del origen.")
                    :format(item.dragonId)
            end
            EggService.GiveEgg(toPlayer, item.dragonId, item.quantity)
        end
    end

    -- Transferir boosts --------------------------------------------------
    -- boosts en DataStore es { [boostId] = cantidad }. Los mutamos
    -- directamente ya que fromPd.boosts y toPd.boosts son referencias
    -- a las tablas internas de DataStore.
    for _, item in ipairs(offer.boosts) do
        local boostId  = item.boostId
        local cantidad = item.quantity

        local fromCount = fromPd.boosts[boostId] or 0
        if fromCount < cantidad then
            return false, ("Boost '%s' insuficiente al ejecutar transfer.")
                :format(boostId)
        end

        fromPd.boosts[boostId] = fromCount - cantidad
        if fromPd.boosts[boostId] <= 0 then
            fromPd.boosts[boostId] = nil
        end

        toPd.boosts[boostId] = (toPd.boosts[boostId] or 0) + cantidad
    end

    return true, nil
end

-- Marca un trade como cancelado, lo desindexxa, lo pasa a historial
-- y dispara TradeCancelled a ambos jugadores (si siguen conectados).
-- Puede llamarse con eventName="TradeExpired" para el caso de expiración.
local function cancelarTrade(trade, eventName)
    if trade.status == "completed"
    or trade.status == "cancelled"
    or trade.status == "expired" then
        return  -- ya terminal, ignorar llamada duplicada
    end

    -- Incrementar generación para cancelar el task.delay de expiración
    tradeExpireGen[trade.tradeId] = (tradeExpireGen[trade.tradeId] or 0) + 1

    trade.status = eventName == "TradeExpired" and "expired" or "cancelled"
    desindexarTrade(trade)
    agregarAlHistorial(trade)

    local fireEvento = eventName == "TradeExpired"
        and TradeExpiredEvent
        or  TradeCancelledEvent

    local payload = {
        tradeId      = trade.tradeId,
        initiatorId  = trade.initiator.UserId,
        receiverId   = trade.receiver.UserId,
    }

    -- Disparar a ambos jugadores si siguen en el servidor
    if trade.initiator and trade.initiator.Parent then
        fireEvento:FireClient(trade.initiator, payload)
    end
    if trade.receiver and trade.receiver.Parent then
        fireEvento:FireClient(trade.receiver, payload)
    end
end

-- Programa la cancelación automática del trade cuando llega expiresAt.
-- Si el trade se completa o cancela antes, el generation counter invalida
-- el callback.
local function programarExpiracion(trade)
    tradeExpireGen[trade.tradeId] = (tradeExpireGen[trade.tradeId] or 0) + 1
    local gen     = tradeExpireGen[trade.tradeId]
    local segundos = trade.expiresAt - os.time()
    if segundos <= 0 then
        cancelarTrade(trade, "TradeExpired")
        return
    end
    task.delay(segundos, function()
        if tradeExpireGen[trade.tradeId] ~= gen then return end
        cancelarTrade(trade, "TradeExpired")
    end)
end

--------------------------------------------------------------------------------
-- TradeSystem
--------------------------------------------------------------------------------

local TradeSystem = {}

--------------------------------------------------------------------------------
-- TradeSystem.CheckTradeLimit(player)
--
-- Verifica si el jugador puede iniciar un nuevo trade como iniciador.
-- Aplica un límite de MAX_TRADES_PER_HOUR propuestas activas por hora.
-- Devuelve: { allowed: boolean, remaining: number, resetIn: number }
-- · remaining = cuántos trades más puede iniciar en esta ventana de 1h
-- · resetIn   = segundos hasta que el trade más antiguo salga de la ventana
--------------------------------------------------------------------------------
function TradeSystem.CheckTradeLimit(player)
    local uid   = player.UserId
    local count = limpiarPropuestasAntiguas(uid)

    local resetIn = 0
    if count >= MAX_TRADES_PER_HOUR then
        -- El más antiguo en la ventana determina cuándo se libera el slot
        local oldest = recentInitiated[uid][1] or os.time()
        resetIn = math.max(0, (oldest + 3600) - os.time())
    end

    return {
        allowed   = count < MAX_TRADES_PER_HOUR,
        remaining = math.max(0, MAX_TRADES_PER_HOUR - count),
        resetIn   = resetIn,
    }
end

--------------------------------------------------------------------------------
-- TradeSystem.ProposeTrade(initiator, receiverUserId, offer)
--
-- Inicia una propuesta de intercambio con otro jugador del mismo servidor.
-- Validaciones:
--   · Ambos jugadores deben estar en el mismo servidor (receiver en Players).
--   · El iniciador no puede proponer a sí mismo.
--   · El iniciador no supera MAX_TRADES_PER_HOUR propuestas por hora.
--   · offer pasa validarOferta (inventario disponible, límite de items).
-- Crea el trade con status "pending" y lo registra en el índice.
-- Dispara "TradeProposed" al receiver con los detalles de la oferta.
-- Devuelve: (éxito: boolean, resultado: tradeId|errorMsg)
--------------------------------------------------------------------------------
function TradeSystem.ProposeTrade(initiator, receiverUserId, offer)
    -- Validar tipos de parámetros
    if typeof(initiator) ~= "Instance" or not initiator:IsA("Player") then
        return false, "Iniciador inválido."
    end
    if type(receiverUserId) ~= "number" then
        return false, "UserId del receiver debe ser un número."
    end
    if receiverUserId == initiator.UserId then
        return false, "No puedes proponer un trade contigo mismo."
    end

    -- Verificar que el receiver está en el servidor
    local receiver = Players:GetPlayerByUserId(receiverUserId)
    if not receiver then
        return false, "El jugador no está en el servidor."
    end

    -- Verificar rate limit de propuestas del iniciador
    local limitCheck = TradeSystem.CheckTradeLimit(initiator)
    if not limitCheck.allowed then
        return false, ("Límite de trades alcanzado. Puedes proponer de nuevo en %d s.")
            :format(math.ceil(limitCheck.resetIn))
    end

    -- Normalizar y validar la oferta
    local ofertaNorm, normErr = normalizarOferta(offer)
    if not ofertaNorm then
        return false, normErr
    end

    local ok, errMsg = validarOferta(initiator, ofertaNorm)
    if not ok then
        return false, errMsg
    end

    -- Generar tradeId único
    tradeCounter += 1
    local tradeId = tostring(os.time()) .. "_" .. tostring(initiator.UserId)
        .. "_" .. tostring(tradeCounter)

    -- Crear la entrada del trade
    local ahora = os.time()
    local trade = {
        tradeId        = tradeId,
        initiator      = initiator,
        receiver       = receiver,
        initiatorOffer = ofertaNorm,
        receiverOffer  = ofertaVacia(),
        status         = "pending",
        createdAt      = ahora,
        expiresAt      = ahora + TRADE_DURATION_SECS,
    }
    trades[tradeId] = trade

    -- Registrar en índices
    indexarTrade(trade)

    -- Registrar timestamp para rate limit
    asegurarIndice(initiator.UserId)
    table.insert(recentInitiated[initiator.UserId], ahora)

    -- Programar expiración automática
    programarExpiracion(trade)

    -- Notificar al receiver
    TradeProposedEvent:FireClient(receiver, {
        tradeId        = tradeId,
        initiatorId    = initiator.UserId,
        initiatorName  = initiator.Name,
        initiatorOffer = ofertaNorm,
        expiresAt      = trade.expiresAt,
    })

    print(("[TradeSystem] Trade '%s' propuesto por %s a %s.")
        :format(tradeId, initiator.Name, receiver.Name))

    return true, tradeId
end

--------------------------------------------------------------------------------
-- TradeSystem.RespondToTrade(receiver, tradeId, response)
--
-- El receiver responde a una propuesta pendiente o en negociación.
-- response debe ser: { action = "accept"|"reject"|"counter", offer = {...} }
-- · "accept"  → status "confirmed_initiator", dispara TradeAccepted al iniciador.
-- · "reject"  → cancela el trade, dispara TradeCancelled a ambos.
-- · "counter" → actualiza receiverOffer, status "negotiating",
--               dispara TradeCounterOffer al iniciador.
-- Solo el receiver puede llamar esta función.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function TradeSystem.RespondToTrade(receiver, tradeId, response)
    if type(tradeId) ~= "string" then
        return false, "tradeId inválido."
    end
    if type(response) ~= "table" or type(response.action) ~= "string" then
        return false, "Respuesta inválida."
    end

    local trade = trades[tradeId]
    if not trade then
        return false, "Trade no encontrado."
    end

    -- Solo el receiver puede responder
    if trade.receiver.UserId ~= receiver.UserId then
        return false, "Solo el receptor puede responder a este trade."
    end

    -- Solo se puede responder en estado pending o negotiating
    if trade.status ~= "pending" and trade.status ~= "negotiating" then
        return false, ("No se puede responder a un trade en estado '%s'.")
            :format(trade.status)
    end

    local accion = response.action

    -- Rechazar el trade -------------------------------------------------
    if accion == "reject" then
        cancelarTrade(trade, "TradeCancelled")
        print(("[TradeSystem] Trade '%s' rechazado por %s.")
            :format(tradeId, receiver.Name))
        return true, "Trade rechazado."

    -- Aceptar sin contraoferta ------------------------------------------
    elseif accion == "accept" then
        trade.status = "confirmed_initiator"
        -- Notificar al iniciador para su confirmación final
        if trade.initiator and trade.initiator.Parent then
            TradeAcceptedEvent:FireClient(trade.initiator, {
                tradeId       = tradeId,
                receiverId    = receiver.UserId,
                receiverName  = receiver.Name,
                receiverOffer = trade.receiverOffer,
            })
        end
        print(("[TradeSystem] Trade '%s' aceptado por %s — esperando confirmación del iniciador.")
            :format(tradeId, receiver.Name))
        return true, "Trade aceptado. Esperando confirmación del iniciador."

    -- Contraoferta -------------------------------------------------------
    elseif accion == "counter" then
        local ofertaNorm, normErr = normalizarOferta(response.offer)
        if not ofertaNorm then
            return false, normErr
        end

        local ok, errMsg = validarOferta(receiver, ofertaNorm)
        if not ok then
            return false, errMsg
        end

        trade.receiverOffer = ofertaNorm
        trade.status        = "negotiating"

        -- Notificar al iniciador de la contraoferta
        if trade.initiator and trade.initiator.Parent then
            TradeCounterEvent:FireClient(trade.initiator, {
                tradeId       = tradeId,
                receiverId    = receiver.UserId,
                receiverName  = receiver.Name,
                receiverOffer = ofertaNorm,
            })
        end

        print(("[TradeSystem] Contraoferta en trade '%s' de %s a %s.")
            :format(tradeId, receiver.Name, trade.initiator.Name))
        return true, "Contraoferta enviada."

    else
        return false, ("Acción desconocida: '%s'. Usa 'accept', 'reject' o 'counter'.")
            :format(tostring(accion))
    end
end

--------------------------------------------------------------------------------
-- TradeSystem.ConfirmTrade(player, tradeId)
--
-- Confirmación final del iniciador después de que el receiver aceptó.
-- 1. Verifica que el trade está en "confirmed_initiator".
-- 2. REVALIDA TODOS LOS ITEMS de ambas partes (doble validación anti-exploit).
-- 3. Ejecuta el intercambio con transferirItems.
-- 4. Marca el trade como "completed" y lo pasa al historial.
-- 5. Dispara "TradeCompleted" a ambos jugadores con resumen.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function TradeSystem.ConfirmTrade(player, tradeId)
    if type(tradeId) ~= "string" then
        return false, "tradeId inválido."
    end

    local trade = trades[tradeId]
    if not trade then
        return false, "Trade no encontrado."
    end

    -- Solo el iniciador puede confirmar
    if trade.initiator.UserId ~= player.UserId then
        return false, "Solo el iniciador puede confirmar el trade."
    end

    -- El trade debe estar esperando confirmación del iniciador
    if trade.status ~= "confirmed_initiator" then
        return false, ("No se puede confirmar un trade en estado '%s'.")
            :format(trade.status)
    end

    -- Verificar que ambos jugadores siguen conectados
    if not (trade.initiator and trade.initiator.Parent) then
        cancelarTrade(trade, "TradeCancelled")
        return false, "El iniciador ya no está en el servidor."
    end
    if not (trade.receiver and trade.receiver.Parent) then
        cancelarTrade(trade, "TradeCancelled")
        return false, "El receptor ya no está en el servidor."
    end

    -- ===== DOBLE VALIDACIÓN ==============================================
    -- Segunda comprobación: los items podrían haberse movido a un nido o
    -- a un breeding entre el momento de la propuesta y esta confirmación.
    local okI, errI = validarOferta(trade.initiator, trade.initiatorOffer)
    if not okI then
        cancelarTrade(trade, "TradeCancelled")
        return false, ("Oferta del iniciador ya no es válida: %s Trade cancelado.")
            :format(errI)
    end

    local okR, errR = validarOferta(trade.receiver, trade.receiverOffer)
    if not okR then
        cancelarTrade(trade, "TradeCancelled")
        return false, ("Oferta del receptor ya no es válida: %s Trade cancelado.")
            :format(errR)
    end
    -- ===== FIN DOBLE VALIDACIÓN ==========================================

    -- Marcar como confirmed_both (bloquea cancelaciones simultáneas)
    trade.status = "confirmed_both"

    -- Cancelar timer de expiración
    tradeExpireGen[tradeId] = (tradeExpireGen[tradeId] or 0) + 1

    -- Ejecutar intercambio: iniciador recibe oferta del receiver, y viceversa
    local okTransI, errTransI = transferirItems(
        trade.initiator, trade.receiver, trade.initiatorOffer)
    if not okTransI then
        -- Si la primera transferencia falla el estado es inconsistente;
        -- se cancela y se warn. El oro/items del iniciador no se tocaron.
        trade.status = "cancelled"
        desindexarTrade(trade)
        agregarAlHistorial(trade)
        warn(("[TradeSystem] Error en transferencia del iniciador en '%s': %s")
            :format(tradeId, errTransI))
        if trade.initiator.Parent then
            TradeCancelledEvent:FireClient(trade.initiator,
                { tradeId = tradeId, motivo = errTransI })
        end
        if trade.receiver.Parent then
            TradeCancelledEvent:FireClient(trade.receiver,
                { tradeId = tradeId, motivo = errTransI })
        end
        return false, "Error al ejecutar el intercambio. Trade cancelado."
    end

    local okTransR, errTransR = transferirItems(
        trade.receiver, trade.initiator, trade.receiverOffer)
    if not okTransR then
        -- La primera parte ya se transfirió; este es un estado inconsistente.
        -- Se warn para alerta manual. En producción se podría añadir reversión.
        warn(("[TradeSystem] ⚠ INCONSISTENCIA en trade '%s': primera parte "
            .. "transferida pero segunda falló: %s")
            :format(tradeId, errTransR))
        -- Marcar igualmente como completado para que no se intente de nuevo
    end

    -- Marcar como completado
    trade.status = "completed"
    desindexarTrade(trade)
    agregarAlHistorial(trade)

    -- Resumen del intercambio para ambos jugadores
    local resumen = {
        tradeId        = tradeId,
        initiatorId    = trade.initiator.UserId,
        receiverId     = trade.receiver.UserId,
        initiatorOffer = trade.initiatorOffer,   -- lo que dio el iniciador
        receiverOffer  = trade.receiverOffer,     -- lo que recibió el iniciador
        completedAt    = os.time(),
    }

    TradeCompletedEvent:FireClient(trade.initiator, resumen)
    TradeCompletedEvent:FireClient(trade.receiver,  resumen)

    print(("[TradeSystem] ✓ Trade '%s' completado entre %s y %s.")
        :format(tradeId, trade.initiator.Name, trade.receiver.Name))

    return true, "Intercambio completado."
end

--------------------------------------------------------------------------------
-- TradeSystem.CancelTrade(player, tradeId)
--
-- Cancela un trade activo. Cualquiera de los dos jugadores puede cancelar
-- mientras el trade no esté en "confirmed_both" ni "completed".
-- Dispara "TradeCancelled" a ambos jugadores.
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function TradeSystem.CancelTrade(player, tradeId)
    if type(tradeId) ~= "string" then
        return false, "tradeId inválido."
    end

    local trade = trades[tradeId]
    if not trade then
        return false, "Trade no encontrado."
    end

    -- Solo los participantes pueden cancelar
    if trade.initiator.UserId ~= player.UserId
    and trade.receiver.UserId ~= player.UserId then
        return false, "No eres participante de este trade."
    end

    -- No se puede cancelar si ya está en ejecución o terminado
    if trade.status == "confirmed_both" then
        return false, "El trade ya está siendo ejecutado, no se puede cancelar."
    end
    if trade.status == "completed"
    or trade.status == "cancelled"
    or trade.status == "expired" then
        return false, ("El trade ya finalizó con estado '%s'."):format(trade.status)
    end

    cancelarTrade(trade, "TradeCancelled")

    print(("[TradeSystem] Trade '%s' cancelado por %s.")
        :format(tradeId, player.Name))

    return true, "Trade cancelado."
end

--------------------------------------------------------------------------------
-- TradeSystem.UpdateOffer(player, tradeId, newOffer)
--
-- Actualiza la oferta del jugador durante una negociación activa.
-- Cada jugador solo puede actualizar su propia oferta.
-- Dispara "TradeUpdated" al otro jugador con la nueva oferta.
-- Solo funciona cuando el trade está en estado "negotiating".
-- Devuelve: (éxito: boolean, mensaje: string)
--------------------------------------------------------------------------------
function TradeSystem.UpdateOffer(player, tradeId, newOffer)
    if type(tradeId) ~= "string" then
        return false, "tradeId inválido."
    end

    local trade = trades[tradeId]
    if not trade then
        return false, "Trade no encontrado."
    end

    -- Solo funciona en negociación activa
    if trade.status ~= "negotiating" then
        return false, ("Solo se puede actualizar la oferta en negociación "
            .. "(estado actual: '%s')."):format(trade.status)
    end

    -- Determinar qué lado es el jugador
    local esIniciador = trade.initiator.UserId == player.UserId
    local esReceiver  = trade.receiver.UserId  == player.UserId
    if not esIniciador and not esReceiver then
        return false, "No eres participante de este trade."
    end

    -- Normalizar y validar la nueva oferta
    local ofertaNorm, normErr = normalizarOferta(newOffer)
    if not ofertaNorm then
        return false, normErr
    end

    local ok, errMsg = validarOferta(player, ofertaNorm)
    if not ok then
        return false, errMsg
    end

    -- Actualizar el lado correcto
    local otroJugador
    if esIniciador then
        trade.initiatorOffer = ofertaNorm
        otroJugador = trade.receiver
    else
        trade.receiverOffer = ofertaNorm
        otroJugador = trade.initiator
    end

    -- Notificar al otro jugador
    if otroJugador and otroJugador.Parent then
        TradeUpdatedEvent:FireClient(otroJugador, {
            tradeId      = tradeId,
            updatedBy    = player.UserId,
            updatedOffer = ofertaNorm,
        })
    end

    return true, "Oferta actualizada."
end

--------------------------------------------------------------------------------
-- TradeSystem.GetActiveTrades(player)
--
-- Devuelve todos los trades activos del jugador (como iniciador o receiver).
-- Los estados activos son: "pending", "negotiating", "confirmed_initiator".
-- Devuelve una lista de entradas con los datos públicos del trade.
--------------------------------------------------------------------------------
function TradeSystem.GetActiveTrades(player)
    local uid     = player.UserId
    local activos = {}

    if not playerTrades[uid] then return activos end

    for tradeId in pairs(playerTrades[uid]) do
        local trade = trades[tradeId]
        if trade then
            table.insert(activos, {
                tradeId        = trade.tradeId,
                initiatorId    = trade.initiator.UserId,
                initiatorName  = trade.initiator.Name,
                receiverId     = trade.receiver.UserId,
                receiverName   = trade.receiver.Name,
                initiatorOffer = trade.initiatorOffer,
                receiverOffer  = trade.receiverOffer,
                status         = trade.status,
                createdAt      = trade.createdAt,
                expiresAt      = trade.expiresAt,
                secondsLeft    = math.max(0, trade.expiresAt - os.time()),
                esIniciador    = trade.initiator.UserId == uid,
            })
        end
    end

    return activos
end

--------------------------------------------------------------------------------
-- TradeSystem.GetTradeHistory(player)
--
-- Devuelve los últimos HISTORY_MAX trades completados o cancelados del jugador,
-- en orden cronológico inverso (más reciente primero).
--------------------------------------------------------------------------------
function TradeSystem.GetTradeHistory(player)
    local uid = player.UserId
    asegurarIndice(uid)
    return tradeHistory[uid]
end

--------------------------------------------------------------------------------
-- Handlers de RemoteFunctions
-- Cada handler valida que el parámetro "player" es quien invoca la función
-- (Roblox lo garantiza automáticamente como primer argumento).
--------------------------------------------------------------------------------

RequestProposeFunc.OnServerInvoke = function(player, receiverUserId, offer)
    local ok, resultado = TradeSystem.ProposeTrade(player, receiverUserId, offer)
    return { success = ok, result = resultado }
end

RequestRespondFunc.OnServerInvoke = function(player, tradeId, response)
    local ok, msg = TradeSystem.RespondToTrade(player, tradeId, response)
    return { success = ok, message = msg }
end

RequestConfirmFunc.OnServerInvoke = function(player, tradeId)
    local ok, msg = TradeSystem.ConfirmTrade(player, tradeId)
    return { success = ok, message = msg }
end

RequestCancelFunc.OnServerInvoke = function(player, tradeId)
    local ok, msg = TradeSystem.CancelTrade(player, tradeId)
    return { success = ok, message = msg }
end

RequestUpdateFunc.OnServerInvoke = function(player, tradeId, newOffer)
    local ok, msg = TradeSystem.UpdateOffer(player, tradeId, newOffer)
    return { success = ok, message = msg }
end

RequestGetActiveFunc.OnServerInvoke = function(player)
    return TradeSystem.GetActiveTrades(player)
end

-- Inventario disponible para ofrecer en un trade (excluye dragones en breeding)
RequestGetInventoryFunc.OnServerInvoke = function(player)
    local data = DataStore.GetPlayerData(player)
    if not data then return {} end

    -- Contar reservas activas en breeding
    local reservas = {}
    local breedStatus = BreedingSystem.GetBreedingStatus(player)
    for _, entry in ipairs(breedStatus.activos or {}) do
        reservas[entry.dragonId1] = (reservas[entry.dragonId1] or 0) + 1
        reservas[entry.dragonId2] = (reservas[entry.dragonId2] or 0) + 1
    end

    local disponible = {}
    for dragonId, count in pairs(data.inventory or {}) do
        local reservado = reservas[dragonId] or 0
        local libre = count - reservado
        if libre > 0 then
            disponible[dragonId] = libre
        end
    end
    return disponible
end

--------------------------------------------------------------------------------
-- Loop principal — revisión de trades expirados cada LOOP_INTERVAL segundos
--
-- Aunque programarExpiracion() usa task.delay para cancelar cada trade
-- al llegar a expiresAt, este loop actúa como red de seguridad en caso de
-- que algún task.delay no se haya disparado correctamente (p.ej. errores
-- en ticks de Lua scheduler). También limpia las entradas en estado terminal
-- que ya pasaron al historial (libera memoria).
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(LOOP_INTERVAL)

        local ahora     = os.time()
        local aEliminar = {}

        for tradeId, trade in pairs(trades) do
            -- Expirar trades activos que superaron su tiempo
            if trade.status ~= "completed"
            and trade.status ~= "cancelled"
            and trade.status ~= "expired"
            and ahora > trade.expiresAt then
                cancelarTrade(trade, "TradeExpired")
                print(("[TradeSystem] Trade '%s' expirado (loop de seguridad).")
                    :format(tradeId))
            end

            -- Marcar para limpieza los trades terminales que ya llevan
            -- al menos 60 s en estado terminal (tiempo suficiente para
            -- que el cliente reciba el evento final).
            if (trade.status == "completed"
            or  trade.status == "cancelled"
            or  trade.status == "expired")
            and ahora > (trade.expiresAt + 60) then
                table.insert(aEliminar, tradeId)
            end
        end

        -- Limpiar entradas terminales de la tabla principal
        for _, tradeId in ipairs(aEliminar) do
            trades[tradeId]           = nil
            tradeExpireGen[tradeId]   = nil
        end
    end
end)

--------------------------------------------------------------------------------
-- Limpieza al desconectarse el jugador
--
-- Si un jugador se desconecta mientras tiene trades activos, todos sus trades
-- pendientes se cancelan automáticamente para no bloquear al otro jugador.
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
    local uid = player.UserId

    -- Cancelar todos los trades activos en los que participaba
    if playerTrades[uid] then
        -- Copiar las claves porque cancelarTrade modifica playerTrades[uid]
        local tradeIds = {}
        for tradeId in pairs(playerTrades[uid]) do
            table.insert(tradeIds, tradeId)
        end

        for _, tradeId in ipairs(tradeIds) do
            local trade = trades[tradeId]
            if trade and trade.status ~= "completed"
            and trade.status ~= "cancelled"
            and trade.status ~= "expired" then
                cancelarTrade(trade, "TradeCancelled")
                print(("[TradeSystem] Trade '%s' cancelado por desconexión de %s.")
                    :format(tradeId, player.Name))
            end
        end
    end

    -- Limpiar estado en memoria del jugador
    playerTrades[uid]    = nil
    recentInitiated[uid] = nil
    -- tradeHistory se mantiene brevemente hasta que el servidor libere la memoria
end)

--------------------------------------------------------------------------------

return TradeSystem
