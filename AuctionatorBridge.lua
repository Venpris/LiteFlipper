local _, ns = ...
local LF = ns.LF

local DAY_SECONDS = 86400
local AUCTIONATOR_CACHE_SECONDS = 60
local AUCTIONATOR_MISS_CACHE_SECONDS = 60
local AUCTIONATOR_TREND_CACHE_SECONDS = 600
local AUCTIONATOR_FULL_SCAN_SOURCE = "Auctionator full scan"
local AUCTIONATOR_SUMMARY_SCAN_SOURCE = "Auctionator scan"

-- Wider fences than the market-value ones: a single freak day (1c dump or a
-- gouged lone listing) should not decide the trend, but normal swings must
-- survive or there is no volatility left to measure.
local TREND_OUTLIER_LOW_MULTIPLIER = 0.25
local TREND_OUTLIER_HIGH_MULTIPLIER = 4.0

local function Today()
  return math.floor(time() / DAY_SECONDS)
end

local function IsCopper(value)
  return type(value) == "number" and value > 0 and value < 1000000000
end

local function GetAuctionatorApi()
  return Auctionator and Auctionator.API and Auctionator.API.v1 or nil
end

-- === Current price ===

-- Last price Auctionator has recorded for the item, through its public API.
-- The second argument is kept for callers written against the Classic Era
-- version and is ignored.
function LF:GetAuctionatorPrice(itemLinkOrId)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  self.auctionatorPriceCache = self.auctionatorPriceCache or {}

  local cached = self.auctionatorPriceCache[itemKey]
  local now = time()
  if cached then
    local maxAge = cached.price and AUCTIONATOR_CACHE_SECONDS or AUCTIONATOR_MISS_CACHE_SECONDS
    if (now - cached.checkedAt) < maxAge then
      return cached.price, cached.label
    end
  end

  local api = GetAuctionatorApi()
  local price, label
  local itemId = tonumber(itemKey)

  if api then
    if type(itemLinkOrId) == "string" and string.find(itemLinkOrId, "|H", 1, true)
      and type(api.GetAuctionPriceByItemLink) == "function" then
      local ok, result = pcall(api.GetAuctionPriceByItemLink, LF.name, itemLinkOrId)
      if ok and IsCopper(result) then
        price, label = math.floor(result), "Auctionator price (link)"
      end
    end
    if not price and itemId and type(api.GetAuctionPriceByItemID) == "function" then
      local ok, result = pcall(api.GetAuctionPriceByItemID, LF.name, itemId)
      if ok and IsCopper(result) then
        price, label = math.floor(result), "Auctionator price"
      end
    end
  end

  self.auctionatorPriceCache[itemKey] = { price = price, label = label, checkedAt = now }

  if price then
    -- Only count it as one of today's observations if Auctionator actually saw
    -- the item today; an old last-seen price says nothing about today's low.
    local age
    if itemId and type(api.GetAuctionAgeByItemID) == "function" then
      local ok, result = pcall(api.GetAuctionAgeByItemID, LF.name, itemId)
      if ok then
        age = result
      end
    end
    if age == 0 then
      self:RecordObservation(itemKey, price, nil, nil)
    end
    self:Debug("Auctionator price for " .. itemKey .. ": " .. price)
  end

  return price, label
end

function LF:InvalidateAuctionatorCaches()
  self.auctionatorPriceCache = nil
  self.auctionatorTrendCache = nil
  self.craftCostMemo = nil
end

-- === Scan snapshots ===

local function GetInfoValue(info, key, fallbackIndex)
  if type(info) ~= "table" then
    return nil
  end

  local constants = Auctionator
    and Auctionator.Constants
    and Auctionator.Constants.AuctionItemInfo
  local index = constants and constants[key] or fallbackIndex

  return index and info[index] or nil
end

-- One entry of Auctionator's replicate ("full") scan: every auction on the
-- house with its stack size, buyout and seller.
local function NormalizeReplicateEntry(entry)
  if type(entry) ~= "table" then
    return nil
  end

  local info = entry.replicateInfo or entry.info or entry.auctionInfo
  local itemLink = entry.itemLink
  local buyout = GetInfoValue(info, "Buyout", 10)
  local stackSize = GetInfoValue(info, "Quantity", 3) or 1

  if not buyout or buyout <= 0 or not stackSize or stackSize <= 0 then
    return nil
  end

  local itemId = GetInfoValue(info, "ItemID", 17)
  if (not itemId or itemId == 0) and itemLink then
    itemId = tonumber(string.match(itemLink, "item:(%d+)"))
  end
  if not itemId or itemId == 0 then
    return nil
  end

  local name = info and info[1] or nil
  if not name or name == "" then
    name = LF:GetItemName(itemId)
  end

  return {
    index = entry.index,
    name = name,
    texture = info and info[2] or nil,
    itemLink = itemLink,
    itemId = itemId,
    stackSize = stackSize,
    buyout = buyout,
    unitBuyout = math.floor(buyout / stackSize),
    owner = GetInfoValue(info, "Owner", 14),
    quality = (info and info[4]) or 1,
  }
end

local function NormalizeReplicateEntries(entries)
  local auctions = {}

  for _, entry in ipairs(entries or {}) do
    local auction = NormalizeReplicateEntry(entry)
    if auction then
      table.insert(auctions, auction)
    end
  end

  return auctions
end

-- Stores a set of auction rows as the saved LiteFlipper snapshot (what
-- /lf scan and /lf browse fall back to) and feeds them into price history.
--
-- A small result set never replaces a saved full scan - it would throw away
-- the whole-market view for the sake of one search - but its prices are still
-- recorded, so history and "current low" stay fresh between full scans.
function LF:SaveScanSnapshot(auctions, options)
  if not self.db or type(auctions) ~= "table" or #auctions == 0 then
    return false
  end
  options = options or {}

  if not options.preferForDeals
    and self.lastScan
    and self.lastScan.preferForDeals
    and #auctions < math.max(50, math.floor((self.lastScan.count or #self.lastScan.auctions or 0) * 0.25)) then
    if options.recordHistory and self.ObserveAuctions then
      self:ObserveAuctions(auctions)
    end
    self:Debug("Kept the saved full scan; learned prices from " .. #auctions .. " new row(s).")
    return false
  end

  self.lastScan = {
    auctions = auctions,
    count = options.count or #auctions,
    scannedAt = time(),
    sourceLabel = options.sourceLabel or "Saved scan",
    complete = options.complete and true or false,
    historyRecorded = false,
    preferForDeals = options.preferForDeals and true or false,
    summary = options.summary and true or false,
  }
  local scan = self.lastScan

  -- A whole-house scan supersedes everything seen before it, including items
  -- that have since sold out. A partial result set says nothing about the
  -- items it does not contain, so their fresher lows are kept.
  if options.preferForDeals then
    local recentLows = self:GetRecentLows()
    for itemKey in pairs(recentLows) do
      recentLows[itemKey] = nil
    end
  end

  if options.recordHistory and self.RecordAuctionObservationsAsync then
    self:RecordAuctionObservationsAsync(auctions, function()
      scan.historyRecorded = true
    end)
  end

  self:SaveLastScan()
  self:Debug("Saved snapshot with " .. #auctions .. " row(s) from " .. scan.sourceLabel .. ".")
  return true
end

function LF:SaveAuctionatorScanSnapshot(entries, complete, recordHistory, sourceLabel, preferForDeals)
  return self:SaveScanSnapshot(NormalizeReplicateEntries(entries), {
    sourceLabel = sourceLabel or AUCTIONATOR_FULL_SCAN_SOURCE,
    complete = complete,
    recordHistory = recordHistory,
    preferForDeals = preferForDeals,
  })
end

-- Auctionator has two kinds of whole-house scan on this client. The default
-- one pages through the browse list and yields one row per item (lowest price
-- and total quantity); the optional "replicate" one yields every auction.
-- LiteFlipper listens for both finishing and keeps the result as its snapshot.
function LF:InstallAuctionatorScanListener()
  if self.auctionatorScanListenerInstalled then
    return true
  end

  if not (Auctionator and Auctionator.EventBus and Auctionator.EventBus.Register) then
    return false
  end

  local incremental = Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events or {}
  local replicate = Auctionator.FullScan and Auctionator.FullScan.Events or {}

  local events = {}
  local function Add(eventName)
    if eventName then
      table.insert(events, eventName)
    end
  end
  Add(incremental.ScanStart)
  Add(incremental.ScanComplete)
  Add(incremental.ScanFailed)
  Add(incremental.PricesProcessed)
  Add(replicate.ScanStart)
  Add(replicate.ScanComplete)
  Add(replicate.ScanFailed)

  if #events == 0 then
    return false
  end

  local listener = {}

  function listener:ReceiveEvent(eventName, payload)
    if eventName == incremental.ScanStart or eventName == replicate.ScanStart then
      -- While Auctionator pages through the whole house, the per-page browse
      -- events are noise; the finished scan arrives in one piece below.
      LF.auctionatorScanActive = true
    elseif eventName == incremental.ScanFailed or eventName == replicate.ScanFailed then
      LF.auctionatorScanActive = false
    elseif eventName == incremental.ScanComplete then
      LF.auctionatorScanActive = false
      LF:InvalidateAuctionatorCaches()
      local auctions = LF.BrowseResultsToAuctions and LF:BrowseResultsToAuctions(payload) or {}
      LF:SaveScanSnapshot(auctions, {
        sourceLabel = AUCTIONATOR_SUMMARY_SCAN_SOURCE,
        complete = true,
        recordHistory = true,
        preferForDeals = true,
        summary = true,
      })
    elseif eventName == replicate.ScanComplete then
      LF.auctionatorScanActive = false
      LF:InvalidateAuctionatorCaches()
      LF:SaveAuctionatorScanSnapshot(payload, true, true, AUCTIONATOR_FULL_SCAN_SOURCE, true)
    elseif eventName == incremental.PricesProcessed then
      -- Auctionator just updated its price database from a search.
      LF:InvalidateAuctionatorCaches()
    end
  end

  local ok, errorMessage = pcall(Auctionator.EventBus.Register, Auctionator.EventBus, listener, events)
  if not ok then
    self:Debug("Could not listen for Auctionator scans: " .. tostring(errorMessage))
    return false
  end

  self.auctionatorScanListener = listener
  self.auctionatorScanListenerInstalled = true
  self:Debug("Listening for Auctionator scan snapshots.")
  return true
end

-- === LiteFlipper's own day buckets ===

function LF:RecordObservation(itemKey, minPrice, highPrice, lowPrice)
  if not itemKey or not IsCopper(minPrice) then
    return
  end

  local history = self:GetHistory()
  history[itemKey] = history[itemKey] or {}

  local day = tostring(Today())
  local bucket = history[itemKey][day] or { seen = 0 }
  bucket.seen = (bucket.seen or 0) + 1
  bucket.min = bucket.min and math.min(bucket.min, minPrice) or minPrice

  if IsCopper(lowPrice) then
    bucket.low = bucket.low and math.min(bucket.low, lowPrice) or lowPrice
  end

  if IsCopper(highPrice) then
    bucket.high = bucket.high and math.max(bucket.high, highPrice) or highPrice
  end

  history[itemKey][day] = bucket
end

function LF:RecordSupplySnapshot(itemKey, auctionCount, unitCount)
  if not itemKey or type(auctionCount) ~= "number" or auctionCount <= 0 then
    return
  end

  local history = self:GetHistory()
  history[itemKey] = history[itemKey] or {}

  local day = tostring(Today())
  local bucket = history[itemKey][day] or { seen = 0 }
  bucket.supplyAuctions = bucket.supplyAuctions and math.max(bucket.supplyAuctions, auctionCount) or auctionCount
  bucket.supplyUnits = bucket.supplyUnits and math.max(bucket.supplyUnits, unitCount or auctionCount) or (unitCount or auctionCount)
  bucket.lastSupplyScan = time()

  history[itemKey][day] = bucket
end

-- === Auctionator's daily price history ===

-- Auctionator numbers its history days from local midnight on 1 January 2020.
function LF:GetAuctionatorDayZero()
  local constants = Auctionator and Auctionator.Constants
  if constants and type(constants.SCAN_DAY_0) == "number" then
    return constants.SCAN_DAY_0
  end
  if not self.fallbackDayZero then
    self.fallbackDayZero = time({ year = 2020, month = 1, day = 1, hour = 0 })
  end
  return self.fallbackDayZero
end

function LF:GetAuctionatorDay(timestamp)
  return math.floor(((timestamp or time()) - self:GetAuctionatorDayZero()) / DAY_SECONDS)
end

-- Auctionator has no public call for its price history, so this reads the
-- in-memory database directly and checks every step: if a future Auctionator
-- changes the layout, history quietly becomes unavailable instead of erroring.
local function GetAuctionatorItemData(dbKey)
  local database = Auctionator and Auctionator.Database
  local db = database and database.db
  if type(db) ~= "table" then
    return nil
  end

  local data = db[tostring(dbKey)]
  if type(data) ~= "table" or type(data.h) ~= "table" then
    return nil
  end

  return data
end

-- Reads the per-day price history Auctionator keeps (21 days by default).
-- Auctionator records the day's minimum listing price, tracked as the lowest
-- (l) and highest (h) minimum seen that day, plus the largest quantity
-- available (a). Returns points oldest first:
-- { age (days ago), rawDay, low, high, typical, available }.
--
-- dbKey is optional: Auctionator files random-suffix gear under a more
-- specific key as well as the plain item id, and the history window passes
-- that key when it knows it.
function LF:GetAuctionatorHistory(itemLinkOrId, maxDays, dbKey)
  local itemKey = dbKey or self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  local data = GetAuctionatorItemData(itemKey)
  if not data then
    return nil
  end

  local todayRaw = self:GetAuctionatorDay()
  local points = {}

  for day, high in pairs(data.h) do
    local rawDay = tonumber(day)
    local age = rawDay and (todayRaw - rawDay)
    if age and age >= 0 and (not maxDays or age < maxDays) and IsCopper(high) then
      local low = (type(data.l) == "table" and IsCopper(data.l[day]) and data.l[day]) or high
      table.insert(points, {
        age = age,
        rawDay = rawDay,
        low = low,
        high = high,
        typical = math.floor((low + high) / 2),
        available = type(data.a) == "table" and data.a[day] or nil,
      })
    end
  end

  if #points == 0 then
    return nil
  end

  table.sort(points, function(left, right)
    return left.age > right.age
  end)

  return points
end

function LF:HasAuctionatorHistory(dbKey)
  return GetAuctionatorItemData(dbKey) ~= nil
end

-- Market value from Auctionator's recorded daily prices, for items we have
-- no scan samples of our own for. Uses the same robust average as scans.
function LF:GetAuctionatorHistoryValue(itemLinkOrId)
  local days = (self.db and self.db.daysToAverage) or 7
  local points = self:GetAuctionatorHistory(itemLinkOrId, days)
  if not points then
    return nil
  end

  local samples = {}
  for _, point in ipairs(points) do
    table.insert(samples, { price = point.typical, units = 1 })
  end

  local average = self:GetRobustMarketAverage(samples)
  if not average then
    return nil
  end

  return average, #samples
end

-- Trend and volatility from Auctionator's daily history. The trend is the
-- least-squares slope of daily price over the window, expressed as the
-- fractional change across the window relative to the average price (+0.15 =
-- prices climbed ~15% across the window). Volatility is the coefficient of
-- variation of daily prices (stddev / mean), so 0.20 means days typically
-- land within about +/-20% of the average.
function LF:GetPriceTrend(itemLinkOrId)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  self.auctionatorTrendCache = self.auctionatorTrendCache or {}
  local cached = self.auctionatorTrendCache[itemKey]
  local now = time()
  if cached and (now - cached.checkedAt) < AUCTIONATOR_TREND_CACHE_SECONDS then
    return cached.stats
  end

  local stats
  local windowDays = (self.db and self.db.trendDays) or 21
  local points = self:GetAuctionatorHistory(itemLinkOrId, windowDays)

  if points and #points >= 3 then
    local prices = {}
    for _, point in ipairs(points) do
      table.insert(prices, point.typical)
    end
    table.sort(prices)
    local median = prices[math.ceil(#prices / 2)]

    local kept = {}
    for _, point in ipairs(points) do
      if point.typical >= median * TREND_OUTLIER_LOW_MULTIPLIER
        and point.typical <= median * TREND_OUTLIER_HIGH_MULTIPLIER then
        table.insert(kept, point)
      end
    end

    local n = #kept
    local span = n > 0 and (kept[1].age - kept[n].age) or 0

    if n >= 3 and span >= 2 then
      local sumX, sumY = 0, 0
      local historicalLow, historicalHigh
      for _, point in ipairs(kept) do
        sumX = sumX - point.age
        sumY = sumY + point.typical
        historicalLow = historicalLow and math.min(historicalLow, point.low) or point.low
        historicalHigh = historicalHigh and math.max(historicalHigh, point.high) or point.high
      end
      local meanX = sumX / n
      local meanY = sumY / n

      local covXY, varX, varY = 0, 0, 0
      for _, point in ipairs(kept) do
        local dx = -point.age - meanX
        local dy = point.typical - meanY
        covXY = covXY + dx * dy
        varX = varX + dx * dx
        varY = varY + dy * dy
      end

      if varX > 0 and meanY > 0 then
        local slope = covXY / varX
        local change = slope * span / meanY
        local volatility = math.sqrt(varY / n) / meanY
        local threshold = (self.db and self.db.priceTrendThreshold) or 0.10

        local label = "Stable"
        if change >= threshold then
          label = "Rising"
        elseif change <= -threshold then
          label = "Falling"
        end

        stats = {
          label = label,
          change = change,
          volatility = volatility,
          days = n,
          span = span,
          average = math.floor(meanY),
          latest = kept[n].typical,
          historicalLow = historicalLow,
          historicalHigh = historicalHigh,
        }
      end
    end
  end

  self.auctionatorTrendCache[itemKey] = { stats = stats, checkedAt = now }
  return stats
end

function LF:DescribeVolatility(volatility)
  if type(volatility) ~= "number" then
    return nil
  end

  local percent = math.floor(volatility * 100 + 0.5)
  if volatility < 0.10 then
    return "Low", percent
  elseif volatility < 0.25 then
    return "Medium", percent
  end
  return "High", percent
end
