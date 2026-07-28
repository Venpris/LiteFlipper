local _, ns = ...
local LF = ns.LF

local DAY_SECONDS = 86400
local MAX_SCAN_SAMPLES_PER_DAY = 80
local OUTLIER_LOW_MULTIPLIER = 0.50
local OUTLIER_HIGH_MULTIPLIER = 2.00

local function Today()
  return math.floor(time() / DAY_SECONDS)
end

local function IsCopper(value)
  return type(value) == "number" and value > 0 and value < 1000000000
end

-- Canonical outlier-resistant average, used for every market value
-- calculation: within a single scan, across scan samples, and across day
-- buckets. Takes an array of { price, units } samples.
--
-- The anchor is the lower median UNIQUE unit price, so one repeated wall at
-- the same price cannot move the outlier fence by sheer listing count. Stack
-- size is still ignored, because weighting by units lets one seller reposting
-- 50 full stacks outweigh the real market. Anything outside [0.5x, 2x] of the
-- anchor is discarded, then the surviving listings are averaged per listing.
function LF:GetRobustMarketAverage(samples)
  local sorted = {}
  local uniqueSeen = {}
  local uniquePrices = {}

  for _, sample in ipairs(samples or {}) do
    local price = tonumber(sample.price)
    local units = tonumber(sample.units) or 1
    if price and price > 0 and units > 0 then
      table.insert(sorted, { price = price })
      if not uniqueSeen[price] then
        uniqueSeen[price] = true
        table.insert(uniquePrices, price)
      end
    end
  end

  if #sorted == 0 then
    return nil
  end

  table.sort(sorted, function(left, right)
    return left.price < right.price
  end)
  table.sort(uniquePrices)

  local anchorPrice = uniquePrices[math.ceil(#uniquePrices / 2)]

  local lowFence = anchorPrice * OUTLIER_LOW_MULTIPLIER
  local highFence = anchorPrice * OUTLIER_HIGH_MULTIPLIER
  local total = 0
  local included = 0
  local includedPrices = {}

  for _, sample in ipairs(sorted) do
    if sample.price >= lowFence and sample.price <= highFence then
      total = total + sample.price
      included = included + 1
      table.insert(includedPrices, sample.price)
    end
  end

  if included == 0 then
    return math.floor(anchorPrice), 1, { math.floor(anchorPrice) }
  end

  return math.floor(total / included), included, includedPrices
end

local function DailyTypical(bucket)
  if not bucket then
    return nil
  end

  local total = 0
  local count = 0

  if bucket.min and bucket.min > 0 then
    total = total + bucket.min
    count = count + 1
  end

  if bucket.low and bucket.low > 0 then
    total = total + bucket.low
    count = count + 1
  end

  if bucket.high and bucket.high > 0 then
    total = total + bucket.high
    count = count + 1
  end

  if count == 0 then
    return nil
  end

  return math.floor(total / count)
end

local function FormatMarketSource(source)
  if source == "scan-capped" then
    return "scan capped"
  elseif source == "ah-history" then
    return "AH history"
  end

  return source or "history"
end

local function ScanSampleAverage(history, daysToAverage)
  if not history then
    return nil
  end

  local samples = {}
  local today = Today()

  for offset = 0, daysToAverage - 1 do
    local bucket = history[tostring(today - offset)]
    if bucket and type(bucket.scans) == "table" then
      for _, sample in ipairs(bucket.scans) do
        if sample and type(sample.prices) == "table" then
          for _, price in ipairs(sample.prices) do
            if price and price > 0 then
              table.insert(samples, { price = price, units = 1 })
            end
          end
        elseif sample and sample.avg and sample.avg > 0 then
          table.insert(samples, { price = sample.avg, units = sample.units or 1 })
        end
      end
    end
  end

  return LF:GetRobustMarketAverage(samples)
end

local function CapToHistoricalHigh(value, itemLinkOrId)
  if not value or not LF.GetPriceTrend then
    return value
  end

  local trendStats = LF:GetPriceTrend(itemLinkOrId)
  if trendStats and trendStats.historicalHigh and value > trendStats.historicalHigh then
    return trendStats.historicalHigh, true
  end

  return value, false
end

function LF:GetMarketValue(itemLinkOrId, allowSavedVariableScan)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  local history = self:GetHistory()[itemKey]
  local today = Today()
  local daysToAverage = self.db.daysToAverage or 7

  local scanAverage, scanCount = ScanSampleAverage(history, daysToAverage)
  if scanAverage then
    local cappedAverage, capped = CapToHistoricalHigh(scanAverage, itemLinkOrId)
    return cappedAverage, scanCount, capped and "scan-capped" or "scan"
  end

  -- Auctionator's own daily history is a multi-day average, so prefer it
  -- over the single last-seen spot price below.
  local historyValue, historyDays = self:GetAuctionatorHistoryValue(itemLinkOrId)
  if historyValue then
    return historyValue, historyDays, "ah-history"
  end

  local auctionatorPrice = self:GetAuctionatorPrice(itemLinkOrId, allowSavedVariableScan)
  if auctionatorPrice then
    return auctionatorPrice, 1, "auctionator"
  end

  if history then
    local dayTypicals = {}
    for offset = 0, daysToAverage - 1 do
      local bucket = history[tostring(today - offset)]
      local typical = DailyTypical(bucket)
      if typical then
        table.insert(dayTypicals, { price = typical, units = 1 })
      end
    end

    local dayAverage = self:GetRobustMarketAverage(dayTypicals)
    if dayAverage then
      return dayAverage, #dayTypicals, "day"
    end
  end

  return nil
end

function LF:RecordScanPriceSample(itemKey, averagePrice, auctionCount, unitCount, listingPrices)
  if not itemKey or not IsCopper(averagePrice) or not self.db then
    return
  end

  local history = self:GetHistory()
  history[itemKey] = history[itemKey] or {}

  local day = tostring(Today())
  local bucket = history[itemKey][day] or { seen = 0 }
  bucket.seen = (bucket.seen or 0) + (auctionCount or 1)
  bucket.min = bucket.min and math.min(bucket.min, averagePrice) or averagePrice
  bucket.scans = bucket.scans or {}

  local scan = {
    time = time(),
    avg = math.floor(averagePrice),
    auctions = auctionCount or 1,
    units = unitCount or auctionCount or 1,
  }
  if type(listingPrices) == "table" and #listingPrices > 0 then
    scan.prices = {}
    for _, price in ipairs(listingPrices) do
      if IsCopper(price) then
        table.insert(scan.prices, math.floor(price))
      end
    end
  end

  table.insert(bucket.scans, scan)

  while #bucket.scans > MAX_SCAN_SAMPLES_PER_DAY do
    table.remove(bucket.scans, 1)
  end

  history[itemKey][day] = bucket
end

function LF:PruneHistory()
  if not self.db then
    return
  end

  local oldest = Today() - math.max(7, (self.db.daysToAverage or 7)) - 3

  local function PruneStore(store)
    for itemKey, itemHistory in pairs(store) do
      if type(itemHistory) == "table" then
        for day in pairs(itemHistory) do
          if tonumber(day) and tonumber(day) < oldest then
            itemHistory[day] = nil
          end
        end
        if not next(itemHistory) then
          store[itemKey] = nil
        end
      end
    end
  end

  if type(self.db.history) == "table" then
    PruneStore(self.db.history)
  end
  for _, store in pairs(self.db.historyByScope or {}) do
    if type(store) == "table" then
      PruneStore(store)
    end
  end
end

-- Deletes all market history recorded before cutoffTime for the current
-- realm/faction scope. Day buckets are rebuilt from the surviving scan
-- samples because min/low/high are running aggregates that could otherwise
-- carry pre-cutoff prices forward.
function LF:PurgeHistoryBefore(cutoffTime)
  local history = self:GetHistory()
  local removedSamples = 0
  local clearedItems = 0

  for itemKey, itemHistory in pairs(history) do
    if type(itemHistory) == "table" then
      for day, bucket in pairs(itemHistory) do
        local kept = {}
        if type(bucket) == "table" and type(bucket.scans) == "table" then
          for _, sample in ipairs(bucket.scans) do
            if (sample.time or 0) >= cutoffTime then
              table.insert(kept, sample)
            else
              removedSamples = removedSamples + 1
            end
          end
        end

        if #kept == 0 then
          itemHistory[day] = nil
        else
          local rebuilt = { seen = 0, scans = kept }
          for _, sample in ipairs(kept) do
            rebuilt.seen = rebuilt.seen + (sample.auctions or 1)
            rebuilt.min = rebuilt.min and math.min(rebuilt.min, sample.avg) or sample.avg
          end
          if bucket.lastSupplyScan and bucket.lastSupplyScan >= cutoffTime then
            rebuilt.supplyAuctions = bucket.supplyAuctions
            rebuilt.supplyUnits = bucket.supplyUnits
            rebuilt.lastSupplyScan = bucket.lastSupplyScan
          end
          itemHistory[day] = rebuilt
        end
      end

      if not next(itemHistory) then
        history[itemKey] = nil
        clearedItems = clearedItems + 1
      end
    end
  end

  return removedSamples, clearedItems
end

function LF:GetSupplyTrend(itemLinkOrId)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  local history = self:GetHistory()[itemKey]
  if not history then
    return nil
  end

  local today = Today()
  local latest
  local latestOffset

  for offset = 0, (self.db.daysToAverage or 7) - 1 do
    local bucket = history[tostring(today - offset)]
    if bucket and bucket.supplyUnits and bucket.supplyUnits > 0 then
      latest = bucket.supplyUnits
      latestOffset = offset
      break
    end
  end

  if not latest then
    return nil
  end

  local total = 0
  local count = 0
  for offset = latestOffset + 1, (self.db.daysToAverage or 7) - 1 do
    local bucket = history[tostring(today - offset)]
    if bucket and bucket.supplyUnits and bucket.supplyUnits > 0 then
      total = total + bucket.supplyUnits
      count = count + 1
    end
  end

  if count == 0 then
    return "New", latest, nil, 0
  end

  local average = total / count
  local change = average > 0 and ((latest - average) / average) or 0
  local threshold = self.db.supplyTrendThreshold or 0.20
  local label = "Flat"

  if change >= threshold then
    label = "Up"
  elseif change <= -threshold then
    label = "Down"
  end

  return label, latest, math.floor(average + 0.5), count, change
end

function LF:GetPricePosition(itemLinkOrId, currentUnitBuyout)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return nil
  end

  local history = self:GetHistory()[itemKey]
  if not history then
    return nil
  end

  local today = Today()
  local recentLow
  local latestMin
  local observedDays = 0

  for offset = 0, (self.db.daysToAverage or 7) - 1 do
    local bucket = history[tostring(today - offset)]
    if bucket and bucket.min and bucket.min > 0 then
      observedDays = observedDays + 1
      recentLow = recentLow and math.min(recentLow, bucket.min) or bucket.min
      if not latestMin then
        latestMin = bucket.min
      end
    end
  end

  local price = currentUnitBuyout or latestMin
  if not price or not recentLow or recentLow <= 0 then
    return nil
  end

  local ratio = price / recentLow
  local aboveLow = ratio - 1
  local label = "Above low"

  if aboveLow <= 0.01 then
    label = "At low"
  elseif aboveLow <= (self.db.nearDailyLowThreshold or 0.10) then
    label = "Near low"
  end

  return label, recentLow, aboveLow, observedDays
end

function LF:GetLatestScanMinPrice(itemLinkOrId)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey or not self.lastScan or type(self.lastScan.auctions) ~= "table" then
    return nil
  end

  if not self.lastScanMinPrices and self.BuildLastScanIndex then
    self:BuildLastScanIndex()
  end

  return self.lastScanMinPrices and self.lastScanMinPrices[tostring(itemKey)] or nil
end

local function AddPriceMatch(matches, seen, itemId, name)
  local key = tostring(itemId)
  if not seen[key] then
    seen[key] = true
    table.insert(matches, { itemId = tonumber(key), name = name })
  end
end

-- Resolves a query to { itemId, name } matches, exact name matches first.
-- An item link or numeric id resolves directly; otherwise names are matched
-- against the last scan, the bundled recipe database, and recorded recipes.
function LF:FindItemsByQuery(query)
  query = string.match(query or "", "^%s*(.-)%s*$")
  if query == "" then
    return {}
  end

  local matches = {}
  local seen = {}

  local directKey = self:GetItemKey(query)
  if directKey then
    local name = GetItemInfo and GetItemInfo(tonumber(directKey)) or nil
    AddPriceMatch(matches, seen, directKey, name or ("item " .. directKey))
    return matches
  end

  local lowered = string.lower(query)

  if GetItemInfo then
    local name, link = GetItemInfo(query)
    if name and link then
      local itemId = self:GetItemKey(link)
      if itemId then
        AddPriceMatch(matches, seen, itemId, name)
      end
    end
  end

  if self.lastScan and type(self.lastScan.auctions) == "table" then
    for _, auction in ipairs(self.lastScan.auctions) do
      local itemId = auction.itemId or self:GetItemKey(auction.itemLink)
      if itemId and auction.name and string.find(string.lower(auction.name), lowered, 1, true) then
        AddPriceMatch(matches, seen, itemId, auction.name)
      end
    end
  end

  for _, profession in pairs(ns.RecipeData or {}) do
    for _, entry in ipairs(profession.recipes or {}) do
      if string.find(string.lower(entry.n), lowered, 1, true) then
        AddPriceMatch(matches, seen, entry.p, entry.n)
      end
    end
  end

  for _, store in pairs((self.db and self.db.craftRecipes) or {}) do
    if type(store) == "table" and type(store.recipes) == "table" then
      for _, recipe in pairs(store.recipes) do
        if recipe.name and string.find(string.lower(recipe.name), lowered, 1, true) then
          AddPriceMatch(matches, seen, recipe.product, recipe.name)
        end
        for _, reagent in ipairs(recipe.reagents or {}) do
          if reagent.name and string.find(string.lower(reagent.name), lowered, 1, true) then
            AddPriceMatch(matches, seen, reagent.id, reagent.name)
          end
        end
      end
    end
  end

  table.sort(matches, function(left, right)
    local leftExact = string.lower(left.name) == lowered
    local rightExact = string.lower(right.name) == lowered
    if leftExact ~= rightExact then
      return leftExact
    end
    return string.lower(left.name) < string.lower(right.name)
  end)

  return matches
end

function LF:PriceLookup(query)
  query = string.match(query or "", "^%s*(.-)%s*$")
  if query == "" then
    self:Print("Usage: /lf price <item name, item link, or item id>")
    return
  end

  local matches = self:FindItemsByQuery(query)

  if #matches == 0 then
    self:Print("No items match '" .. query .. "'. Names come from your scans and the recipe database.")
    return
  end

  local MAX_RESULTS = 8
  for index = 1, math.min(#matches, MAX_RESULTS) do
    local match = matches[index]
    local link = GetItemInfo and select(2, GetItemInfo(match.itemId)) or nil
    local label = link or match.name

    local marketValue, _, source = self:GetMarketValue(match.itemId)
    local current = self:GetLatestScanMinPrice(match.itemId)
    local vendor = self.db and self.db.vendorPrices and self.db.vendorPrices[tostring(match.itemId)]

    local parts = {}
    if marketValue then
      table.insert(parts, "market " .. self:FormatMoney(marketValue) .. " (" .. FormatMarketSource(source) .. ")")
    end
    if current then
      table.insert(parts, "current low " .. self:FormatMoney(current))
    end
    if vendor then
      table.insert(parts, "vendor " .. self:FormatMoney(vendor))
    end

    local trendStats = self:GetPriceTrend(match.itemId)
    if trendStats then
      local sign = trendStats.change < 0 and "-" or "+"
      local percent = math.floor(math.abs(trendStats.change) * 100 + 0.5)
      table.insert(parts, "trend " .. string.lower(trendStats.label) .. " " .. sign .. percent
        .. "% over " .. trendStats.span .. "d, low " .. self:FormatMoney(trendStats.historicalLow)
        .. ", high " .. self:FormatMoney(trendStats.historicalHigh))
    end

    if #parts == 0 then
      self:Print(label .. ": no price data yet.")
    else
      self:Print(label .. ": " .. table.concat(parts, ", "))
    end
  end

  if #matches > MAX_RESULTS then
    self:Print("... and " .. (#matches - MAX_RESULTS) .. " more match(es). Narrow the search.")
  end
end

-- "/lf trend <item>" - trend, volatility, historical low/high, and the
-- day-by-day price history Auctionator has recorded (the same data behind
-- its History button).
function LF:TrendLookup(query)
  query = string.match(query or "", "^%s*(.-)%s*$")
  if query == "" then
    self:Print("Usage: /lf trend <item name, item link, or item id>")
    return
  end

  local matches = self:FindItemsByQuery(query)

  if #matches == 0 then
    self:Print("No items match '" .. query .. "'. Names come from your scans and the recipe database.")
    return
  end

  local MAX_RESULTS = 4
  for index = 1, math.min(#matches, MAX_RESULTS) do
    local match = matches[index]
    local link = GetItemInfo and select(2, GetItemInfo(match.itemId)) or nil
    local label = link or match.name

    local stats = self:GetPriceTrend(match.itemId)
    if not stats then
      self:Print(label .. ": not enough Auctionator history yet (needs 3+ scanned days).")
    else
      local sign = stats.change < 0 and "-" or "+"
      local percent = math.floor(math.abs(stats.change) * 100 + 0.5)
      local volLabel, volPercent = self:DescribeVolatility(stats.volatility)
      self:Print(label .. ": " .. string.lower(stats.label) .. " " .. sign .. percent .. "% over "
        .. stats.span .. "d, volatility " .. string.lower(volLabel or "?") .. " (+/-" .. (volPercent or 0)
        .. "%), " .. stats.days .. "-day avg " .. self:FormatMoney(stats.average)
        .. ", low " .. self:FormatMoney(stats.historicalLow)
        .. ", high " .. self:FormatMoney(stats.historicalHigh))
    end

    -- Day-by-day detail for the top match only, to keep chat readable.
    if index == 1 then
      local points = self:GetAuctionatorHistory(match.itemId, (self.db and self.db.trendDays) or 21)
      if points then
        local pieces = {}
        for _, point in ipairs(points) do
          local dayLabel = point.age == 0 and "today" or (point.age .. "d ago")
          table.insert(pieces, dayLabel .. " " .. self:FormatMoney(point.typical))
        end

        for start = 1, #pieces, 4 do
          local chunk = {}
          for i = start, math.min(start + 3, #pieces) do
            table.insert(chunk, pieces[i])
          end
          self:Print("  " .. table.concat(chunk, " | "))
        end
      end
    end
  end

  if #matches > MAX_RESULTS then
    self:Print("... and " .. (#matches - MAX_RESULTS) .. " more match(es). Narrow the search.")
  end
end

function LF:IsDeal(unitBuyout, itemLinkOrId)
  local marketValue, observedDays = self:GetMarketValue(itemLinkOrId)
  if not marketValue or not unitBuyout or unitBuyout <= 0 then
    return false
  end

  local thresholdPrice = marketValue * (self.db.dealThreshold or 0.8)
  local minPrice = marketValue * (self.db.dealMinThreshold or 0)
  local profit = marketValue - unitBuyout

  return unitBuyout <= thresholdPrice
    and unitBuyout >= minPrice
    and profit >= (self.db.minProfitCopper or 0), marketValue, profit, observedDays
end
