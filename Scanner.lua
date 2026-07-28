local _, ns = ...
local LF = ns.LF

local ROW_HEIGHT = 22
local DEFAULT_PAGE_SIZE = 14
local FRAME_WIDTH = 820
local FRAME_HEIGHT = 430
local COLUMN_GAP = 4
local AUCTION_JOB_BATCH_SIZE = 100
local AUCTION_JOB_FRAME_BUDGET_MS = 8
local ASYNC_THRESHOLD = 100
local RESULT_CACHE_VERSION = 1

local COLUMNS = {
  { key = "rank", label = "#", width = 30, justify = "RIGHT" },
  { key = "icon", label = "", width = 22, justify = "LEFT" },
  { key = "item", label = "Item", width = 210, justify = "LEFT" },
  { key = "qty", label = "Qty", width = 36, justify = "RIGHT" },
  { key = "lots", label = "Lots", width = 34, justify = "RIGHT" },
  { key = "unit", label = "Unit", width = 70, justify = "RIGHT" },
  { key = "market", label = "Market", width = 70, justify = "RIGHT" },
  { key = "pct", label = "%", width = 38, justify = "RIGHT" },
  { key = "profit", label = "Profit", width = 74, justify = "RIGHT" },
  { key = "seen", label = "Seen", width = 46, justify = "RIGHT" },
  { key = "trend", label = "Trend", width = 46, justify = "LEFT" },
}

local RESULT_SORT_VALUES = {
  item = function(row) return string.lower(row.name or "") end,
  qty = function(row) return row.stackSize end,
  lots = function(row) return row.auctionCount or 1 end,
  unit = function(row) return row.unitBuyout end,
  market = function(row) return row.marketValue end,
  pct = function(row)
    return row.marketValue and row.marketValue > 0 and (row.unitBuyout / row.marketValue) or nil
  end,
  profit = function(row) return row.profit end,
  seen = function(row) return row.visibleSupplyUnits or row.stackSize end,
  trend = function(row) return row.supplyTrend end,
}

local function SortRows(rows, key, ascending)
  local getValue = RESULT_SORT_VALUES[key]
  if not getValue then
    return
  end

  table.sort(rows, function(left, right)
    local leftValue = getValue(left)
    local rightValue = getValue(right)
    if leftValue == nil and rightValue ~= nil then
      return false
    elseif rightValue == nil and leftValue ~= nil then
      return true
    elseif leftValue == rightValue then
      return string.lower(left.name or "") < string.lower(right.name or "")
    end
    if ascending then
      return leftValue < rightValue
    end
    return leftValue > rightValue
  end)
end

local function GetBrowseCount()
  if GetNumAuctionItems then
    return GetNumAuctionItems("list") or 0
  end
  return 0
end

local function GetBrowseItem(index)
  if not GetAuctionItemInfo then
    return nil
  end

  local name, texture, count, quality, canUse, level, levelColHeader, minBid, minIncrement, buyoutPrice, bidAmount,
    highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo = GetAuctionItemInfo("list", index)

  if not name or not buyoutPrice or buyoutPrice <= 0 then
    return nil
  end

  local itemLink = GetAuctionItemLink and GetAuctionItemLink("list", index) or nil
  if not itemLink then
    return nil
  end

  local stackSize = count and count > 0 and count or 1

  return {
    index = index,
    name = name,
    texture = texture,
    itemLink = itemLink,
    itemId = itemId,
    stackSize = stackSize,
    buyout = buyoutPrice,
    unitBuyout = math.floor(buyoutPrice / stackSize),
    owner = ownerFullName or owner,
    quality = quality or 1,
  }
end

local function IsUsableAuction(auction)
  return type(auction) == "table"
    and type(auction.itemLink) == "string"
    and string.find(auction.itemLink, "item:", 1, true) ~= nil
    and type(auction.unitBuyout) == "number"
    and auction.unitBuyout > 0
    and type(auction.stackSize) == "number"
    and auction.stackSize > 0
end

local function FormatSignedMoney(value)
  value = tonumber(value)
  if not value then
    return "-"
  end
  if value < 0 then
    return "-" .. LF:FormatMoney(math.abs(value))
  end
  return LF:FormatMoney(value)
end

local function RowOnClick(self)
  local deal = self.deal
  if not deal then
    return
  end

  if ChatEdit_GetActiveWindow() then
    ChatEdit_InsertLink(deal.itemLink or deal.name)
  elseif deal.itemLink then
    HandleModifiedItemClick(deal.itemLink)
  end
end

local function RowOnEnter(self)
  local deal = self.deal
  if not deal then
    return
  end

  GameTooltip:SetOwner(self, "ANCHOR_LEFT")

  if deal.itemLink then
    GameTooltip:SetHyperlink(deal.itemLink)
  else
    GameTooltip:SetText(deal.name or "Unknown item")
  end
  if deal.auctionCount and deal.auctionCount > 1 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("LiteFlipper lots", tostring(deal.auctionCount), 0.31, 0.70, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Total quantity", tostring(deal.stackSize or 1), 0.31, 0.70, 1, 1, 1, 1)
    if deal.totalProfit then
      GameTooltip:AddDoubleLine("Est. total profit", FormatSignedMoney(deal.totalProfit), 0.31, 0.70, 1, 1, 1, 1)
    end
  end
  GameTooltip:Show()
end

local function RowOnLeave()
  GameTooltip:Hide()
end

local function GetPercentColor(pct)
  if pct <= 50 then
    return 0.20, 1.00, 0.20
  elseif pct <= 70 then
    return 0.90, 1.00, 0.20
  elseif pct <= 85 then
    return 1.00, 0.72, 0.20
  elseif pct <= 100 then
    return 1.00, 0.35, 0.20
  end
  return 0.75, 0.75, 0.75
end

local function ResetCellColor(cell)
  cell:SetTextColor(1, 1, 1)
end

local function AnnotateVisibleSupply(auctions)
  local supplyByItem = {}

  for _, auction in ipairs(auctions or {}) do
    local itemKey = IsUsableAuction(auction) and (auction.itemId or LF:GetItemKey(auction.itemLink)) or nil
    if itemKey then
      itemKey = tostring(itemKey)
      supplyByItem[itemKey] = supplyByItem[itemKey] or { auctions = 0, units = 0 }
      supplyByItem[itemKey].auctions = supplyByItem[itemKey].auctions + 1
      supplyByItem[itemKey].units = supplyByItem[itemKey].units + (auction.stackSize or 1)
    end
  end

  for _, auction in ipairs(auctions or {}) do
    local itemKey = IsUsableAuction(auction) and (auction.itemId or LF:GetItemKey(auction.itemLink)) or nil
    local supply = itemKey and supplyByItem[tostring(itemKey)] or nil
    if supply then
      auction.visibleSupplyAuctions = supply.auctions
      auction.visibleSupplyUnits = supply.units
    end
  end
end

local function GetAuctionItemKeyCached(cache, auction)
  if not IsUsableAuction(auction) then
    return nil
  end

  local cached = cache[auction]
  if cached ~= nil then
    return cached
  end

  local itemKey = auction.itemId or LF:GetItemKey(auction.itemLink)
  if itemKey then
    itemKey = tostring(itemKey)
  end
  cache[auction] = itemKey or false
  return itemKey
end

local function ShouldYieldJob(processed, startedAt)
  if processed >= AUCTION_JOB_BATCH_SIZE then
    return true
  end

  return startedAt
    and debugprofilestop
    and (debugprofilestop() - startedAt) >= AUCTION_JOB_FRAME_BUDGET_MS
end

local function StartAuctionJob(job)
  local channel = job.channel or "default"
  LF.auctionJobTokens = LF.auctionJobTokens or {}
  LF.auctionJobFrames = LF.auctionJobFrames or {}
  LF.auctionJobTokens[channel] = (LF.auctionJobTokens[channel] or 0) + 1
  job.token = LF.auctionJobTokens[channel]
  job.channel = channel

  if not LF.auctionJobFrames[channel] then
    LF.auctionJobFrames[channel] = CreateFrame("Frame")
  end

  LF.auctionJobFrames[channel]:SetScript("OnUpdate", function(frame)
    if job.token ~= LF.auctionJobTokens[channel] then
      frame:SetScript("OnUpdate", nil)
      return
    end

    local startedAt = debugprofilestop and debugprofilestop() or nil
    local processed = 0

    while job:Step() do
      processed = processed + 1
      if ShouldYieldJob(processed, startedAt) then
        return
      end
    end

    frame:SetScript("OnUpdate", nil)
    job:Finish()
  end)
end

local function GetCachedMarketValue(job, auction)
  local itemKey = GetAuctionItemKeyCached(job.itemKeyCache, auction)
  if not itemKey then
    return nil
  end

  local cached = job.marketCache[itemKey]
  if not cached then
    local value, observedDays = LF:GetMarketValue(auction.itemLink or auction.itemId)
    cached = { value = value or false, observedDays = observedDays }
    job.marketCache[itemKey] = cached
  end

  if cached.value then
    return cached.value, cached.observedDays
  end
  return nil, cached.observedDays
end

local function GetCachedSupplyTrend(job, auction)
  local itemKey = GetAuctionItemKeyCached(job.itemKeyCache, auction)
  if not itemKey then
    return nil
  end

  local cached = job.supplyTrendCache[itemKey]
  if cached == nil then
    cached = LF:GetSupplyTrend(auction.itemLink or auction.itemId) or false
    job.supplyTrendCache[itemKey] = cached
  end

  return cached ~= false and cached or nil
end

local function GetCachedPricePosition(job, auction)
  local itemKey = GetAuctionItemKeyCached(job.itemKeyCache, auction)
  if not itemKey then
    return nil
  end

  local cacheKey = itemKey .. ":" .. tostring(auction.unitBuyout or 0)
  local cached = job.pricePositionCache[cacheKey]
  if cached == nil then
    cached = LF:GetPricePosition(auction.itemLink or auction.itemId, auction.unitBuyout) or false
    job.pricePositionCache[cacheKey] = cached
  end

  return cached ~= false and cached or nil
end

local function AnnotateAuctionSupply(job, auction)
  local itemKey = GetAuctionItemKeyCached(job.itemKeyCache, auction)
  local supply = itemKey and job.supplyByItem[itemKey] or nil
  if supply then
    auction.visibleSupplyAuctions = supply.auctions
    auction.visibleSupplyUnits = supply.units
  end
end

function LF:BuildLastScanIndexAsync()
  if not self.lastScan or type(self.lastScan.auctions) ~= "table" then
    self.lastScanMinPrices = {}
    return
  end

  local scan = self.lastScan
  local job = {
    channel = "index",
    auctions = scan.auctions,
    total = #scan.auctions,
    index = 1,
    minPrices = {},
  }

  function job:Step()
    if LF.lastScan ~= scan then
      self.index = self.total + 1
      return false
    end

    local auction = self.auctions[self.index]
    if not auction then
      return false
    end

    self.index = self.index + 1
    local itemKey = auction.itemId or LF:GetItemKey(auction.itemLink)
    local unitBuyout = auction.unitBuyout
    if itemKey and unitBuyout and unitBuyout > 0 then
      itemKey = tostring(itemKey)
      self.minPrices[itemKey] = self.minPrices[itemKey]
        and math.min(self.minPrices[itemKey], unitBuyout)
        or unitBuyout
    end
    return true
  end

  function job:Finish()
    if LF.lastScan == scan then
      LF.lastScanMinPrices = self.minPrices
    end
  end

  StartAuctionJob(job)
end

local function SetFontStringText(fontString, text)
  fontString:SetText(text or "")
end

local function SetButtonEnabled(button, enabled)
  if enabled then
    button:Enable()
  else
    button:Disable()
  end
end

local function GetTotalPages(totalDeals, pageSize)
  if totalDeals <= 0 then
    return 1
  end
  return math.ceil(totalDeals / pageSize)
end

local function GetDealGroupKey(deal)
  local itemKey = deal.itemId or LF:GetItemKey(deal.itemLink) or deal.name or "unknown"
  local ownerKey = deal.owner or "unknown"
  return tostring(itemKey) .. "::" .. tostring(deal.unitBuyout or 0) .. "::" .. tostring(ownerKey)
end

local function GetAuctionIdentity(auction)
  if not auction then
    return ""
  end

  local itemKey = auction.itemId or LF:GetItemKey(auction.itemLink) or auction.name or "unknown"
  return tostring(itemKey)
    .. ":"
    .. tostring(auction.unitBuyout or 0)
    .. ":"
    .. tostring(auction.stackSize or 1)
    .. ":"
    .. tostring(auction.owner or "")
end

local function IsSameAuctionSnapshot(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end
  if #left ~= #right then
    return false
  end
  if #left == 0 then
    return true
  end

  return GetAuctionIdentity(left[1]) == GetAuctionIdentity(right[1])
    and GetAuctionIdentity(left[#left]) == GetAuctionIdentity(right[#right])
end

local function ShouldPreferSavedScan(liveCount)
  local saved = LF.lastScan
  if not saved or not saved.preferForDeals or type(saved.auctions) ~= "table" or #saved.auctions == 0 then
    return false
  end

  local savedCount = saved.count or #saved.auctions
  if not liveCount or liveCount == 0 then
    return true
  end

  return liveCount < math.max(50, math.floor(savedCount * 0.25))
end

local function GetSavedScanSummary(scan)
  if not scan then
    return "saved LiteFlipper scan"
  end

  local source = scan.sourceLabel or "saved LiteFlipper scan"
  local count = scan.count or (type(scan.auctions) == "table" and #scan.auctions) or 0
  local age = scan.scannedAt and (" from " .. LF:FormatAge(time() - scan.scannedAt) .. " ago") or ""
  return source .. " (" .. count .. " auction(s)" .. age .. ")"
end

local function GetDealCacheSignature()
  local db = LF.db or {}
  return table.concat({
    tostring(db.scanMinSupplyUnits or 0),
    tostring(db.dealThreshold or 0.8),
    tostring(db.dealMinThreshold or 0),
    tostring(db.minProfitCopper or 0),
  }, ":")
end

local function GetScanResultCache(scan)
  if type(scan) ~= "table" then
    return nil
  end

  local cache = scan.resultCache
  if type(cache) ~= "table" or cache.version ~= RESULT_CACHE_VERSION then
    cache = { version = RESULT_CACHE_VERSION }
    scan.resultCache = cache
  end
  return cache
end

local function GetCachedScanRows(scan, mode)
  local cache = GetScanResultCache(scan)
  if not cache then
    return nil
  end

  if mode == "browse" then
    return type(cache.browseRows) == "table" and cache.browseRows or nil
  end

  if cache.dealSignature == GetDealCacheSignature() then
    return type(cache.dealRows) == "table" and cache.dealRows or nil
  end
  return nil
end

local function StoreCachedScanRows(scan, mode, rows)
  local cache = GetScanResultCache(scan)
  if not cache or type(rows) ~= "table" then
    return
  end

  cache.version = RESULT_CACHE_VERSION
  if mode == "browse" then
    cache.browseRows = rows
  else
    cache.dealRows = rows
    cache.dealSignature = GetDealCacheSignature()
  end
end

local function SortDealRows(rows)
  table.sort(rows, function(left, right)
    local leftPct = left.unitBuyout / left.marketValue
    local rightPct = right.unitBuyout / right.marketValue
    if leftPct == rightPct then
      return (left.totalProfit or left.profit or 0) > (right.totalProfit or right.profit or 0)
    end
    return leftPct < rightPct
  end)
end

local function SortBrowseRows(rows)
  table.sort(rows, function(left, right)
    local leftPct = left.marketValue and (left.unitBuyout / left.marketValue) or nil
    local rightPct = right.marketValue and (right.unitBuyout / right.marketValue) or nil
    if leftPct and not rightPct then
      return true
    elseif rightPct and not leftPct then
      return false
    elseif not leftPct and not rightPct then
      return (left.name or "") < (right.name or "")
    end
    if leftPct == rightPct then
      return (left.name or "") < (right.name or "")
    end
    return leftPct < rightPct
  end)
end

local function GroupDeals(deals)
  local grouped = {}
  local order = {}

  for _, deal in ipairs(deals or {}) do
    local key = GetDealGroupKey(deal)
    local group = grouped[key]

    if not group then
      group = {}
      for field, value in pairs(deal) do
        group[field] = value
      end
      group.stackSize = 0
      group.auctionCount = 0
      group.totalBuyout = 0
      group.totalProfit = nil
      grouped[key] = group
      table.insert(order, group)
    end

    local quantity = deal.stackSize or 1
    group.stackSize = group.stackSize + quantity
    group.auctionCount = group.auctionCount + 1
    group.totalBuyout = group.totalBuyout + (deal.buyout or ((deal.unitBuyout or 0) * quantity))
    if deal.profit then
      group.totalProfit = (group.totalProfit or 0) + (deal.profit * quantity)
    end
    group.visibleSupplyUnits = math.max(group.visibleSupplyUnits or 0, deal.visibleSupplyUnits or quantity)
    group.visibleSupplyAuctions = math.max(group.visibleSupplyAuctions or 0, deal.visibleSupplyAuctions or 1)
  end

  return order
end

function LF:RenderResultsPage()
  local frame = self.resultsFrame
  if not frame then
    return
  end

  local deals = frame.deals or {}
  local totalDeals = #deals
  local pageSize = frame.pageSize or DEFAULT_PAGE_SIZE
  local totalPages = GetTotalPages(totalDeals, pageSize)
  frame.currentPage = math.max(1, math.min(frame.currentPage or 1, totalPages))

  local firstIndex = ((frame.currentPage - 1) * pageSize) + 1
  for rowIndex, row in ipairs(frame.rows) do
    local dealIndex = firstIndex + rowIndex - 1
    local deal = deals[dealIndex]
    row.deal = deal

    if deal then
      local pct = deal.marketValue and math.floor((deal.unitBuyout / deal.marketValue) * 100 + 0.5) or nil
      local pctR, pctG, pctB = 1, 1, 1
      if pct then
        pctR, pctG, pctB = GetPercentColor(pct)
      end
      SetFontStringText(row.cells.rank, dealIndex .. ".")
      SetFontStringText(row.cells.item, deal.itemLink or deal.name)
      SetFontStringText(row.cells.qty, tostring(deal.stackSize or 1))
      SetFontStringText(row.cells.lots, tostring(deal.auctionCount or 1))
      SetFontStringText(row.cells.unit, self:FormatMoney(deal.unitBuyout))
      SetFontStringText(row.cells.market, self:FormatMoney(deal.marketValue))
      SetFontStringText(row.cells.pct, pct and (pct .. "%") or "-")
      SetFontStringText(row.cells.profit, FormatSignedMoney(deal.profit))
      SetFontStringText(row.cells.seen, tostring(deal.visibleSupplyUnits or deal.stackSize or 1))
      SetFontStringText(row.cells.trend, deal.supplyTrend or "-")
      row.icon:SetTexture(deal.texture or (deal.itemId and GetItemIcon and GetItemIcon(deal.itemId)) or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.cells.pct:SetTextColor(pctR, pctG, pctB)
      row.cells.profit:SetTextColor(pctR, pctG, pctB)
      row.cells.unit:SetTextColor(pctR, pctG, pctB)
      row:Show()
    else
      for _, cell in pairs(row.cells) do
        SetFontStringText(cell, "")
        ResetCellColor(cell)
      end
      row.icon:SetTexture(nil)
      row:Hide()
    end
  end

  local rowLabel = frame.resultMode == "browse" and "listing group(s)" or "deal(s)"
  frame.pageText:SetText(string.format("Page %d/%d  %d %s", frame.currentPage, totalPages, totalDeals, rowLabel))
  SetButtonEnabled(frame.prevButton, frame.currentPage > 1)
  SetButtonEnabled(frame.nextButton, frame.currentPage < totalPages)
end

function LF:SetResultsSort(key)
  local frame = self.resultsFrame
  if not frame or not RESULT_SORT_VALUES[key] then
    return
  end

  if frame.sortKey == key then
    frame.sortAscending = not frame.sortAscending
  else
    frame.sortKey = key
    frame.sortAscending = key == "item" or key == "trend"
  end

  for columnKey, header in pairs(frame.headers or {}) do
    if header.label then
      local suffix = columnKey == frame.sortKey and (frame.sortAscending and " ^" or " v") or ""
      header.label:SetText((header.baseLabel or "") .. suffix)
    end
  end

  SortRows(frame.deals or {}, frame.sortKey, frame.sortAscending)
  frame.currentPage = 1
  self:RenderResultsPage()
end

function LF:CreateResultsFrame()
  local frame = CreateFrame("Frame", "LiteFlipperResultsFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
  frame:SetPoint("CENTER")
  frame:Hide()
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 6, 0)
  frame.title:SetText("LiteFlipper Deals")

  frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.summary:SetPoint("TOPLEFT", 16, -34)
  frame.summary:SetPoint("RIGHT", -230, 0)
  frame.summary:SetJustifyH("LEFT")

  frame.searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  frame.searchBox:SetSize(140, 20)
  frame.searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -28)
  frame.searchBox:SetAutoFocus(false)
  frame.searchBox:SetScript("OnTextChanged", function()
    LF:ApplyResultsFilter()
  end)
  frame.searchBox:SetScript("OnEnterPressed", function(box)
    box:ClearFocus()
  end)
  frame.searchBox:SetScript("OnEscapePressed", function(box)
    box:SetText("")
    box:ClearFocus()
  end)

  frame.searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.searchLabel:SetPoint("RIGHT", frame.searchBox, "LEFT", -10, 0)
  frame.searchLabel:SetText("Search")

  frame.headers = {}
  local xOffset = 16
  for _, column in ipairs(COLUMNS) do
    local columnKey = column.key
    local header = CreateFrame("Button", nil, frame)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", xOffset, -58)
    header:SetHeight(18)
    header:SetWidth(column.width)
    header.baseLabel = column.label
    header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.label:SetAllPoints()
    header.label:SetJustifyH(column.justify or "LEFT")
    header.label:SetText(column.label)
    header.label:SetTextColor(1, 0.82, 0)
    if RESULT_SORT_VALUES[columnKey] then
      header:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      header:SetScript("OnClick", function()
        LF:SetResultsSort(columnKey)
      end)
    end
    frame.headers[columnKey] = header
    xOffset = xOffset + column.width + COLUMN_GAP
  end

  frame.pageSize = math.min(self.db.resultsPageSize or DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE)
  frame.rows = {}
  for index = 1, frame.pageSize do
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 16, -78 - ((index - 1) * ROW_HEIGHT))
    row:SetPoint("RIGHT", -16, 0)
    row:SetScript("OnClick", RowOnClick)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.cells = {}
    xOffset = 0
    for _, column in ipairs(COLUMNS) do
      if column.key == "icon" then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("LEFT", row, "LEFT", xOffset + 2, 0)
        row.icon:SetSize(20, 20)
        row.iconBorder = row:CreateTexture(nil, "OVERLAY")
        row.iconBorder:SetPoint("CENTER", row.icon, "CENTER", 0, 0)
        row.iconBorder:SetSize(24, 24)
        row.iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
      else
        local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("LEFT", row, "LEFT", xOffset, 0)
        cell:SetWidth(column.width)
        cell:SetHeight(ROW_HEIGHT)
        cell:SetJustifyH(column.justify or "LEFT")
        cell:SetJustifyV("MIDDLE")
        if cell.SetWordWrap then
          cell:SetWordWrap(false)
        end
        row.cells[column.key] = cell
      end
      xOffset = xOffset + column.width + COLUMN_GAP
    end

    frame.rows[index] = row
  end

  frame.prevButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.prevButton:SetSize(80, 22)
  frame.prevButton:SetPoint("BOTTOMLEFT", 16, 14)
  frame.prevButton:SetText("Previous")
  frame.prevButton:SetScript("OnClick", function()
    frame.currentPage = math.max(1, (frame.currentPage or 1) - 1)
    LF:RenderResultsPage()
  end)

  frame.nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.nextButton:SetSize(80, 22)
  frame.nextButton:SetPoint("LEFT", frame.prevButton, "RIGHT", 8, 0)
  frame.nextButton:SetText("Next")
  frame.nextButton:SetScript("OnClick", function()
    frame.currentPage = (frame.currentPage or 1) + 1
    LF:RenderResultsPage()
  end)

  frame.pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.pageText:SetPoint("LEFT", frame.nextButton, "RIGHT", 12, 0)
  frame.pageText:SetText("Page 1/1  0 deal(s)")

  self.resultsFrame = frame
end

function LF:ShowDeals(deals, scanned, sourceLabel, mode, searchText)
  local frame = self.resultsFrame
  if not frame then
    return
  end

  deals = deals or {}

  if mode == "browse" then
    frame.title:SetText("LiteFlipper Browse")
    frame.summary:SetText(string.format(
      "%s %d auctions. Showing %d listing group(s); no threshold, profit, or supply filters.",
      sourceLabel or "Browsed",
      scanned or 0,
      #deals
    ))
  else
    frame.title:SetText("LiteFlipper Deals")
    local minSupplyUnits = self.db.scanMinSupplyUnits or 0
    local supplySummary = minSupplyUnits > 0 and (minSupplyUnits .. " visible unit(s)") or "any visible supply"
    local minThreshold = self.db.dealMinThreshold or 0
    local minThresholdSummary = minThreshold > 0
      and string.format(" (min %d%%)", math.floor(minThreshold * 100 + 0.5))
      or ""

    frame.summary:SetText(string.format(
      "%s %d auctions. %d deal(s) below %d%% market%s, at least %s profit, %s.",
      sourceLabel or "Scanned",
      scanned or 0,
      #deals,
      math.floor((self.db.dealThreshold or 0.8) * 100 + 0.5),
      minThresholdSummary,
      self:FormatMoney(self.db.minProfitCopper or 0),
      supplySummary
    ))
  end

  frame.allDeals = deals
  frame.scanned = scanned
  frame.sourceLabel = sourceLabel
  frame.resultMode = mode
  if frame.searchBox and searchText ~= nil then
    frame.searchBox:SetText(searchText)
  end
  self:ApplyResultsFilter()

  frame:Show()
end

function LF:ApplyResultsFilter()
  local frame = self.resultsFrame
  if not frame then
    return
  end

  local allDeals = frame.allDeals or {}
  local text = frame.searchBox
    and string.lower(string.match(frame.searchBox:GetText() or "", "^%s*(.-)%s*$"))
    or ""

  if text == "" then
    frame.deals = allDeals
  else
    local filtered = {}
    for _, deal in ipairs(allDeals) do
      if string.find(string.lower(deal.name or ""), text, 1, true) then
        table.insert(filtered, deal)
      end
    end
    frame.deals = filtered
  end

  SortRows(frame.deals, frame.sortKey, frame.sortAscending)
  frame.currentPage = 1
  self:RenderResultsPage()
end

function LF:FindDealsFromAuctions(auctions)
  AnnotateVisibleSupply(auctions)

  local deals = {}
  for _, auction in ipairs(auctions or {}) do
    local minSupplyUnits = self.db.scanMinSupplyUnits or 0
    if IsUsableAuction(auction) and (minSupplyUnits <= 0 or (auction.visibleSupplyUnits or 0) >= minSupplyUnits) then
      local marketValue = auction.scanMarketValue
      local observedDays = auction.scanObservedDays
      local profit = marketValue and (marketValue - auction.unitBuyout) or nil
      local ok = false

      if marketValue and auction.unitBuyout and auction.unitBuyout > 0 then
        local thresholdPrice = marketValue * (self.db.dealThreshold or 0.8)
        local minPrice = marketValue * (self.db.dealMinThreshold or 0)
        ok = auction.unitBuyout <= thresholdPrice
          and auction.unitBuyout >= minPrice
          and profit >= (self.db.minProfitCopper or 0)
      else
        ok, marketValue, profit, observedDays = self:IsDeal(auction.unitBuyout, auction.itemLink or auction.itemId)
        if marketValue then
          auction.scanMarketValue = marketValue
          auction.scanObservedDays = observedDays
        end
      end

      if ok then
        auction.marketValue = marketValue
        auction.profit = profit
        auction.observedDays = observedDays
        auction.supplyTrend = self:GetSupplyTrend(auction.itemLink or auction.itemId)
        auction.pricePosition = self:GetPricePosition(auction.itemLink or auction.itemId, auction.unitBuyout)
        table.insert(deals, auction)
      end
    end
  end

  deals = GroupDeals(deals)

  SortDealRows(deals)

  return deals
end

function LF:FindBrowseRowsFromAuctions(auctions)
  AnnotateVisibleSupply(auctions)

  local rows = {}
  for _, auction in ipairs(auctions or {}) do
    if IsUsableAuction(auction) then
      local marketValue = auction.scanMarketValue
      local observedDays = auction.scanObservedDays
      if not marketValue then
        marketValue, observedDays = self:GetMarketValue(auction.itemLink or auction.itemId)
        if marketValue then
          auction.scanMarketValue = marketValue
          auction.scanObservedDays = observedDays
        end
      end

      auction.marketValue = marketValue
      auction.profit = marketValue and (marketValue - auction.unitBuyout) or nil
      auction.observedDays = observedDays
      auction.supplyTrend = self:GetSupplyTrend(auction.itemLink or auction.itemId)
      auction.pricePosition = self:GetPricePosition(auction.itemLink or auction.itemId, auction.unitBuyout)
      table.insert(rows, auction)
    end
  end

  rows = GroupDeals(rows)

  SortBrowseRows(rows)

  return rows
end

function LF:BuildScanResultCache(scan, auctions)
  auctions = auctions or (scan and scan.auctions) or {}
  local job = {
    itemKeyCache = {},
    marketCache = {},
    supplyTrendCache = {},
    pricePositionCache = {},
    supplyByItem = {},
  }

  for _, auction in ipairs(auctions) do
    local itemKey = GetAuctionItemKeyCached(job.itemKeyCache, auction)
    if itemKey then
      local supply = job.supplyByItem[itemKey] or { auctions = 0, units = 0 }
      supply.auctions = supply.auctions + 1
      supply.units = supply.units + (auction.stackSize or 1)
      job.supplyByItem[itemKey] = supply
    end
  end

  local browseRows = {}
  local dealRows = {}
  local minSupplyUnits = self.db.scanMinSupplyUnits or 0

  for _, auction in ipairs(auctions) do
    AnnotateAuctionSupply(job, auction)

    if IsUsableAuction(auction) then
      local marketValue = auction.scanMarketValue
      local observedDays = auction.scanObservedDays
      if not marketValue then
        marketValue, observedDays = GetCachedMarketValue(job, auction)
        if marketValue then
          auction.scanMarketValue = marketValue
          auction.scanObservedDays = observedDays
        end
      end

      auction.marketValue = marketValue
      auction.profit = marketValue and (marketValue - auction.unitBuyout) or nil
      auction.observedDays = observedDays
      auction.supplyTrend = GetCachedSupplyTrend(job, auction)
      auction.pricePosition = GetCachedPricePosition(job, auction)
      table.insert(browseRows, auction)

      if marketValue and auction.unitBuyout and auction.unitBuyout > 0
        and (minSupplyUnits <= 0 or (auction.visibleSupplyUnits or 0) >= minSupplyUnits) then
        local profit = marketValue - auction.unitBuyout
        local thresholdPrice = marketValue * (self.db.dealThreshold or 0.8)
        local minPrice = marketValue * (self.db.dealMinThreshold or 0)
        if auction.unitBuyout <= thresholdPrice
          and auction.unitBuyout >= minPrice
          and profit >= (self.db.minProfitCopper or 0) then
          auction.profit = profit
          table.insert(dealRows, auction)
        end
      end
    end
  end

  browseRows = GroupDeals(browseRows)
  SortBrowseRows(browseRows)

  dealRows = GroupDeals(dealRows)
  SortDealRows(dealRows)

  if scan then
    StoreCachedScanRows(scan, "browse", browseRows)
    StoreCachedScanRows(scan, "deals", dealRows)
  end

  return dealRows, browseRows
end

function LF:CaptureCurrentAuctions()
  local count = GetBrowseCount()
  local auctions = {}

  for index = 1, count do
    local auction = GetBrowseItem(index)
    if auction then
      table.insert(auctions, auction)
    end
  end

  return auctions, count
end

function LF:RefreshLastScanSnapshot()
  if not self.db then
    return false
  end

  local count = GetBrowseCount()
  if count == 0 then
    return false
  end

  local auctions, scanned = self:CaptureCurrentAuctions()
  if #auctions == 0 then
    return false
  end

  self.lastScan = {
    auctions = auctions,
    count = scanned,
    scannedAt = time(),
    sourceLabel = "AH browse",
  }
  self:SaveLastScan()
  self:Debug("Saved latest AH snapshot with " .. #auctions .. " buyout auction(s).")
  return true
end

function LF:RecordAuctionObservations(auctions)
  local supplyByItem = {}

  for _, auction in ipairs(auctions or {}) do
    local itemKey = IsUsableAuction(auction) and (auction.itemId or self:GetItemKey(auction.itemLink)) or nil
    if itemKey then
      itemKey = tostring(itemKey)
      self:RecordObservation(itemKey, auction.unitBuyout, nil, nil)
      supplyByItem[itemKey] = supplyByItem[itemKey] or { auctions = 0, units = 0, prices = {} }
      supplyByItem[itemKey].auctions = supplyByItem[itemKey].auctions + 1
      supplyByItem[itemKey].units = supplyByItem[itemKey].units + auction.stackSize
      table.insert(supplyByItem[itemKey].prices, {
        price = auction.unitBuyout,
        units = auction.stackSize,
      })
    end
  end

  for itemKey, supply in pairs(supplyByItem) do
    self:RecordSupplySnapshot(itemKey, supply.auctions, supply.units)
    local scanAverage, _, listingPrices = self:GetRobustMarketAverage(supply.prices)
    if scanAverage then
      self:RecordScanPriceSample(itemKey, scanAverage, supply.auctions, supply.units, listingPrices)
    end
  end
end

function LF:RecordAuctionObservationsAsync(auctions, onComplete)
  auctions = auctions or {}
  local job = {
    channel = "history",
    auctions = auctions,
    total = #auctions,
    index = 1,
    phase = "record",
    itemKeyCache = {},
    supplyByItem = {},
    supplyKeys = {},
    supplyIndex = 1,
    onComplete = onComplete,
  }

  function job:Step()
    if self.phase == "record" then
      local auction = self.auctions[self.index]
      if auction then
        self.index = self.index + 1
        local itemKey = GetAuctionItemKeyCached(self.itemKeyCache, auction)
        if itemKey then
          LF:RecordObservation(itemKey, auction.unitBuyout, nil, nil)
          local supply = self.supplyByItem[itemKey]
          if not supply then
            supply = { auctions = 0, units = 0, prices = {} }
            self.supplyByItem[itemKey] = supply
            table.insert(self.supplyKeys, itemKey)
          end
          supply.auctions = supply.auctions + 1
          supply.units = supply.units + auction.stackSize
          table.insert(supply.prices, {
            price = auction.unitBuyout,
            units = auction.stackSize,
          })
        end
        return true
      end

      self.phase = "supply"
      return true
    end

    if self.phase == "supply" then
      local itemKey = self.supplyKeys[self.supplyIndex]
      if itemKey then
        self.supplyIndex = self.supplyIndex + 1
        local supply = self.supplyByItem[itemKey]
        LF:RecordSupplySnapshot(itemKey, supply.auctions, supply.units)
        local scanAverage, _, listingPrices = LF:GetRobustMarketAverage(supply.prices)
        if scanAverage then
          LF:RecordScanPriceSample(itemKey, scanAverage, supply.auctions, supply.units, listingPrices)
        end
        return true
      end

      self.phase = "done"
      return true
    end

    return false
  end

  function job:Finish()
    if self.onComplete then
      self.onComplete()
    end
  end

  if job.total >= ASYNC_THRESHOLD then
    self:Debug("Recording " .. job.total .. " auction observation(s) in the background.")
    StartAuctionJob(job)
  else
    while job:Step() do
    end
    job:Finish()
  end
end

function LF:RescoreLastScan(sourceLabel)
  if not self.lastScan or not self.lastScan.auctions or #self.lastScan.auctions == 0 then
    return false
  end

  local scan = self.lastScan
  local cached = GetCachedScanRows(scan, "deals")
  if cached then
    self:ShowDeals(cached, scan.count or #scan.auctions, sourceLabel or scan.sourceLabel or "Re-filtered")
    self:Print("Re-opened " .. #cached .. " cached deal(s) from the last LiteFlipper scan.")
    return true
  end

  local deals = self:BuildScanResultCache(scan, scan.auctions)
  self:ShowDeals(deals, scan.count or #scan.auctions, sourceLabel or scan.sourceLabel or "Re-filtered")
  self:Print("Re-filtered " .. #deals .. " deal(s) from the last LiteFlipper scan.")
  return true
end

function LF:BrowseLastScan(sourceLabel, searchText)
  if not self.lastScan or not self.lastScan.auctions or #self.lastScan.auctions == 0 then
    return false
  end

  local scan = self.lastScan
  local cached = GetCachedScanRows(scan, "browse")
  if cached then
    self:ShowDeals(cached, scan.count or #scan.auctions, sourceLabel or scan.sourceLabel or "Browsed", "browse", searchText)
    self:Print("Re-opened " .. #cached .. " cached listing group(s) from the last LiteFlipper scan.")
    return true
  end

  local _, rows = self:BuildScanResultCache(scan, scan.auctions)
  self:ShowDeals(rows, scan.count or #scan.auctions, sourceLabel or scan.sourceLabel or "Browsed", "browse", searchText)
  self:Print("Browsing " .. #rows .. " listing group(s) from the last LiteFlipper scan.")
  return true
end

function LF:BrowseAuctionHouse(searchText)
  searchText = string.match(searchText or "", "^%s*(.-)%s*$")
  local count = GetBrowseCount()
  if count == 0 then
    if self:BrowseLastScan(nil, searchText) then
      self:Print("Using " .. GetSavedScanSummary(self.lastScan) .. ".")
    else
      if self.resultsFrame then
        self.resultsFrame:Hide()
      end
      self:Print("No auction browse results found. Search or scan the auction house first, then run /lf browse.")
    end
    return
  end

  local auctions, scanned = self:CaptureCurrentAuctions()
  if #auctions == 0 then
    if self.resultsFrame then
      self.resultsFrame:Hide()
    end
    self:Print("No buyout auctions found in the current browse results.")
    return
  end

  local historyAlreadyRecorded = self.lastScan
    and self.lastScan.historyRecorded
    and IsSameAuctionSnapshot(self.lastScan.auctions, auctions)
  local previousScan = historyAlreadyRecorded and self.lastScan or nil
  if previousScan then
    local cached = GetCachedScanRows(previousScan, "browse")
    if cached then
      self:ShowDeals(cached, previousScan.count or #previousScan.auctions, "Browsed", "browse", searchText)
      self:Print("Re-opened " .. #cached .. " cached listing group(s) in " .. scanned .. " visible auction(s).")
      return
    end
  end

  if not historyAlreadyRecorded then
    self:RecordAuctionObservations(auctions)
  end

  local scan = previousScan or {
    auctions = auctions,
    count = scanned,
    scannedAt = time(),
    sourceLabel = "Browsed",
    historyRecorded = true,
  }
  self.lastScan = scan
  self:SaveLastScan()

  local _, rows = self:BuildScanResultCache(scan, auctions)
  self:ShowDeals(rows, scanned, "Browsed", "browse", searchText)
  self:Print("Browsing " .. #rows .. " listing group(s) in " .. scanned .. " visible auction(s).")
end

function LF:ScanAuctionHouse()
  local count = GetBrowseCount()
  if count == 0 or ShouldPreferSavedScan(count) then
    if self:RescoreLastScan() then
      if count == 0 then
        self:Print("Using " .. GetSavedScanSummary(self.lastScan) .. ".")
      else
        self:Print("Using " .. GetSavedScanSummary(self.lastScan) .. " because the current AH view only has " .. count .. " row(s).")
      end
    else
      if self.resultsFrame then
        self.resultsFrame:Hide()
      end
      self:Print("No auction browse results found. Search or scan the auction house first, then run /lf scan.")
    end
    return
  end

  local auctions, scanned = self:CaptureCurrentAuctions()
  if #auctions == 0 then
    if self.resultsFrame then
      self.resultsFrame:Hide()
    end
    self:Print("No buyout auctions found in the current browse results.")
    return
  end

  local historyAlreadyRecorded = self.lastScan
    and self.lastScan.historyRecorded
    and IsSameAuctionSnapshot(self.lastScan.auctions, auctions)
  local previousScan = historyAlreadyRecorded and self.lastScan or nil
  if previousScan then
    local cached = GetCachedScanRows(previousScan, "deals")
    if cached then
      self:ShowDeals(cached, previousScan.count or #previousScan.auctions, "Scanned")
      self:Print("Re-opened " .. #cached .. " cached deal(s) in " .. scanned .. " visible auction(s).")
      return
    end
  end

  if not historyAlreadyRecorded then
    self:RecordAuctionObservations(auctions)
  end

  local scan = previousScan or {
    auctions = auctions,
    count = scanned,
    scannedAt = time(),
    sourceLabel = "Scanned",
    historyRecorded = true,
  }
  self.lastScan = scan
  self:SaveLastScan()

  local deals = self:BuildScanResultCache(scan, auctions)
  self:ShowDeals(deals, scanned, "Scanned")
  self:Print("Found " .. #deals .. " deal(s) in " .. scanned .. " visible auction(s).")
end
