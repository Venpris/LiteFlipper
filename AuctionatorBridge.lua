local _, ns = ...
local LF = ns.LF

local DAY_SECONDS = 86400
local AUCTIONATOR_CACHE_SECONDS = 900
local AUCTIONATOR_MISS_CACHE_SECONDS = 60
local AUCTIONATOR_TREND_CACHE_SECONDS = 600
local AUCTIONATOR_SEARCH_SOURCE = "Auctionator search"
local AUCTIONATOR_FULL_SCAN_SOURCE = "Auctionator full scan"

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

local function AddCandidate(candidates, value, label)
  if IsCopper(value) then
    table.insert(candidates, { price = math.floor(value), label = label })
  end
end

local function AddApiCandidate(candidates, fn, label, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    AddCandidate(candidates, result, label)
  end
end

local function GetAuctionInfoValue(info, key, fallbackIndex)
  if type(info) ~= "table" then
    return nil
  end

  local constants = Auctionator
    and Auctionator.Constants
    and Auctionator.Constants.AuctionItemInfo
  local index = constants and constants[key] or fallbackIndex

  return index and info[index] or nil
end

local function NormalizeAuctionatorEntry(entry)
  if type(entry) ~= "table" then
    return nil
  end

  local info = entry.info or entry.auctionInfo
  local itemLink = entry.itemLink
  local buyout = GetAuctionInfoValue(info, "Buyout", 10)
  local stackSize = GetAuctionInfoValue(info, "Quantity", 3) or 1

  if not buyout or buyout <= 0 or not stackSize or stackSize <= 0 then
    return nil
  end

  local itemId = GetAuctionInfoValue(info, "ItemID", 17)
  if (not itemId or itemId == 0) and itemLink then
    itemId = tonumber(string.match(itemLink, "item:(%d+)"))
  end

  local name = info and info[1] or nil
  if GetItemInfo then
    local lookup = itemLink or itemId
    if lookup then
      local resolvedName, resolvedLink, resolvedQuality, _, _, _, _, _, _, resolvedTexture = GetItemInfo(lookup)
      name = name or resolvedName
      itemLink = itemLink or resolvedLink
      info = info or {}
      info[2] = info[2] or resolvedTexture
      info[4] = info[4] or resolvedQuality
    end
  end

  if type(itemLink) ~= "string" or not string.find(itemLink, "item:", 1, true) or not name then
    return nil
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
    owner = GetAuctionInfoValue(info, "Owner", 14),
    quality = (info and info[4]) or 1,
  }
end

local function NormalizeAuctionatorEntries(entries)
  local auctions = {}

  for _, entry in ipairs(entries or {}) do
    local auction = NormalizeAuctionatorEntry(entry)
    if auction then
      table.insert(auctions, auction)
    end
  end

  return auctions
end

local function ScanTableForPrices(root, itemKey, depth, seen, candidates, path)
  if type(root) ~= "table" or depth > 5 or seen[root] then
    return
  end

  seen[root] = true

  local keys = { itemKey, tonumber(itemKey), "item:" .. itemKey }

  for _, lookupKey in ipairs(keys) do
    local direct = root[lookupKey]
    if direct ~= nil then
      if IsCopper(direct) then
        AddCandidate(candidates, direct, path .. "[" .. tostring(lookupKey) .. "]")
      elseif type(direct) == "table" then
        AddCandidate(candidates, direct.minBuyout, path .. ".minBuyout")
        AddCandidate(candidates, direct.minbuyout, path .. ".minbuyout")
        AddCandidate(candidates, direct.min, path .. ".min")
        AddCandidate(candidates, direct.minimum, path .. ".minimum")
        AddCandidate(candidates, direct.price, path .. ".price")
        AddCandidate(candidates, direct.marketValue, path .. ".marketValue")
        AddCandidate(candidates, direct.market, path .. ".market")
        AddCandidate(candidates, direct.historical, path .. ".historical")
        AddCandidate(candidates, direct.low, path .. ".low")
        AddCandidate(candidates, direct.high, path .. ".high")
        AddCandidate(candidates, direct.average, path .. ".average")
        AddCandidate(candidates, direct.avg, path .. ".avg")
      end
    end
  end

  for key, value in pairs(root) do
    if type(key) == "string" and string.find(string.lower(key), "auctionator", 1, true) then
      ScanTableForPrices(value, itemKey, depth + 1, seen, candidates, path .. "." .. key)
    elseif depth > 0 and depth < 2 and type(value) == "table" then
      ScanTableForPrices(value, itemKey, depth + 1, seen, candidates, path .. "." .. tostring(key))
    end
  end
end

local function ScanAuctionatorGlobals(itemKey, candidates)
  local roots = {
    "Auctionator",
    "AUCTIONATOR_PRICE_DATABASE",
    "AUCTIONATOR_HISTORY_DATABASE",
    "AuctionatorPriceDatabase",
    "AuctionatorHistoryDatabase",
  }

  local seen = {}
  for _, name in ipairs(roots) do
    if type(_G[name]) == "table" then
      ScanTableForPrices(_G[name], itemKey, 0, seen, candidates, name)
    end
  end

  for name, value in pairs(_G) do
    local lowerName = type(name) == "string" and string.lower(name) or ""
    local looksLikePriceData = string.find(lowerName, "price", 1, true)
      or string.find(lowerName, "database", 1, true)
      or string.find(lowerName, "history", 1, true)
    if type(value) == "table" and string.find(lowerName, "auctionator", 1, true) and looksLikePriceData then
      ScanTableForPrices(value, itemKey, 0, seen, candidates, name)
    end
  end
end

function LF:GetAuctionatorPrice(itemLinkOrId, allowSavedVariableScan)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  self.auctionatorPriceCache = self.auctionatorPriceCache or {}

  local cached = self.auctionatorPriceCache[itemKey]
  local now = time()
  if cached then
    if allowSavedVariableScan == false then
      if cached.price or (now - cached.checkedAt) < AUCTIONATOR_MISS_CACHE_SECONDS then
        return cached.price, cached.label
      end
    end
    if cached.price and (now - cached.checkedAt) < AUCTIONATOR_CACHE_SECONDS then
      return cached.price, cached.label
    end
  end

  local candidates = {}

  if Auctionator and Auctionator.API and Auctionator.API.v1 then
    local api = Auctionator.API.v1
    if type(api.GetAuctionPriceByItemLink) == "function" and type(itemLinkOrId) == "string" then
      AddApiCandidate(candidates, api.GetAuctionPriceByItemLink, "Auctionator.API.v1.GetAuctionPriceByItemLink", LF.name, itemLinkOrId)
    end
    if type(api.GetAuctionPriceByItemID) == "function" then
      AddApiCandidate(candidates, api.GetAuctionPriceByItemID, "Auctionator.API.v1.GetAuctionPriceByItemID", LF.name, tonumber(itemKey))
    end
  end

  if allowSavedVariableScan ~= false then
    ScanAuctionatorGlobals(itemKey, candidates)
  end

  table.sort(candidates, function(left, right)
    return left.price < right.price
  end)

  local best = candidates[1]
  if best then
    self.auctionatorPriceCache[itemKey] = {
      price = best.price,
      label = best.label,
      checkedAt = now,
    }
    self:RecordObservation(itemKey, best.price, nil, nil)
    self:Debug("Auctionator price for " .. itemKey .. ": " .. best.price .. " from " .. best.label)
    return best.price, best.label
  end

  self.auctionatorPriceCache[itemKey] = {
    checkedAt = now,
  }

  return nil
end

function LF:SaveAuctionatorScanSnapshot(entries, complete, recordHistory, sourceLabel, preferForDeals)
  if not self.db then
    return false
  end

  local auctions = NormalizeAuctionatorEntries(entries)
  if #auctions == 0 then
    return false
  end

  if not preferForDeals
    and self.lastScan
    and self.lastScan.preferForDeals
    and #auctions < math.max(50, math.floor((self.lastScan.count or #self.lastScan.auctions or 0) * 0.25)) then
    self:Debug("Ignored smaller Auctionator search snapshot with " .. #auctions .. " auction(s).")
    return false
  end

  self.lastScan = {
    auctions = auctions,
    count = #auctions,
    scannedAt = time(),
    sourceLabel = sourceLabel or AUCTIONATOR_SEARCH_SOURCE,
    complete = complete and true or false,
    historyRecorded = recordHistory and true or false,
    preferForDeals = preferForDeals and true or false,
  }

  if recordHistory and self.RecordAuctionObservationsAsync then
    self:RecordAuctionObservationsAsync(auctions, function()
      if self.lastScan and self.lastScan.auctions == auctions then
        self.lastScan.historyRecorded = true
        self:SaveLastScan()
      end
    end)
  elseif recordHistory and self.RecordAuctionObservations then
    self:RecordAuctionObservations(auctions)
  end

  self:SaveLastScan()
  self:Debug("Saved latest Auctionator snapshot with " .. #auctions .. " buyout auction(s).")
  return true
end

function LF:InstallAuctionatorScanListener()
  if self.auctionatorScanListenerInstalled then
    return true
  end

  if not (Auctionator and Auctionator.EventBus and Auctionator.EventBus.Register) then
    return false
  end

  local events = {}
  if Auctionator.AH and Auctionator.AH.Events then
    if Auctionator.AH.Events.ScanPageStart then
      table.insert(events, Auctionator.AH.Events.ScanPageStart)
    end
    if Auctionator.AH.Events.ScanResultsUpdate then
      table.insert(events, Auctionator.AH.Events.ScanResultsUpdate)
    end
    if Auctionator.AH.Events.ScanAborted then
      table.insert(events, Auctionator.AH.Events.ScanAborted)
    end
  end
  if Auctionator.FullScan and Auctionator.FullScan.Events then
    if Auctionator.FullScan.Events.ScanComplete then
      table.insert(events, Auctionator.FullScan.Events.ScanComplete)
    end
  end

  if #events == 0 then
    return false
  end

  local listener = {
    pending = {},
  }

  function listener:ReceiveEvent(eventName, results, complete)
    if Auctionator.AH and Auctionator.AH.Events then
      if eventName == Auctionator.AH.Events.ScanPageStart then
        -- Pages within one query arrive sequentially (0, 1, 2, ...). Anything
        -- else (a new search, or a focused single-page query from the buying
        -- tab) starts a fresh snapshot instead of appending to stale results.
        local page = tonumber(results)
        if not page or page == 0 or page ~= (self.lastPage or -1) + 1 then
          self.pending = {}
        end
        self.lastPage = page or 0
        return
      elseif eventName == Auctionator.AH.Events.ScanResultsUpdate then
        for _, entry in ipairs(results or {}) do
          table.insert(self.pending, entry)
        end

        LF:SaveAuctionatorScanSnapshot(self.pending, complete, complete, AUCTIONATOR_SEARCH_SOURCE, false)
        return
      elseif eventName == Auctionator.AH.Events.ScanAborted then
        LF:SaveAuctionatorScanSnapshot(self.pending, true, true, AUCTIONATOR_SEARCH_SOURCE, false)
        return
      end
    end

    if Auctionator.FullScan and Auctionator.FullScan.Events
      and eventName == Auctionator.FullScan.Events.ScanComplete then
      self.pending = {}
      LF:SaveAuctionatorScanSnapshot(results, true, true, AUCTIONATOR_FULL_SCAN_SOURCE, true)
    end
  end

  Auctionator.EventBus:Register(listener, events)
  self.auctionatorScanListener = listener
  self.auctionatorScanListenerInstalled = true
  self:Debug("Listening for Auctionator scan snapshots.")
  return true
end

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

local function GetAuctionatorItemData(itemKey)
  local database = Auctionator and Auctionator.Database
  local db = database and database.db
  if type(db) ~= "table" then
    return nil
  end

  local data = db[tostring(itemKey)]
  if type(data) ~= "table" or type(data.h) ~= "table" then
    return nil
  end

  return data
end

-- Reads the per-day price history Auctionator keeps for its History button
-- (21 days by default). Auctionator records the day's minimum listing price,
-- tracked as the lowest (l) and highest (h) minimum seen that day, plus the
-- largest quantity available (a). Returns points oldest first:
-- { age (days ago), low, high, typical, available }.
function LF:GetAuctionatorHistory(itemLinkOrId, maxDays)
  local itemKey = self:GetItemKey(itemLinkOrId)
  local dayZero = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
  if not itemKey or not dayZero then
    return nil
  end

  local data = GetAuctionatorItemData(itemKey)
  if not data then
    return nil
  end

  local todayRaw = math.floor((time() - dayZero) / DAY_SECONDS)
  local points = {}

  for day, high in pairs(data.h) do
    local rawDay = tonumber(day)
    local age = rawDay and (todayRaw - rawDay)
    if age and age >= 0 and (not maxDays or age < maxDays) and IsCopper(high) then
      local low = (type(data.l) == "table" and IsCopper(data.l[day]) and data.l[day]) or high
      table.insert(points, {
        age = age,
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
