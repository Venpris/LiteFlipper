local _, ns = ...
local LF = ns.LF

-- Price history window, plus the "History" button LiteFlipper adds to
-- Auctionator's buy panels (the modern auction house build of Auctionator
-- records the same per-day prices as the Classic one, but its buy panel has no
-- button to show them).
--
-- Nothing here is taken from Auctionator: the window is LiteFlipper's own, and
-- the data is read from Auctionator's in-memory price database at runtime,
-- merged with the prices LiteFlipper records itself.

local DAY_SECONDS = 86400
local FRAME_WIDTH = 470
local FRAME_HEIGHT = 452
local ROW_HEIGHT = 20
local VISIBLE_ROWS = 13
local LIST_TOP = -138

local COLUMNS = {
  { key = "date", label = "Date", width = 112, justify = "LEFT" },
  { key = "low", label = "Low", width = 96, justify = "RIGHT" },
  { key = "high", label = "High", width = 96, justify = "RIGHT" },
  { key = "available", label = "Available", width = 64, justify = "RIGHT" },
  { key = "change", label = "Change", width = 52, justify = "RIGHT" },
}

local function IsCopper(value)
  return type(value) == "number" and value > 0 and value < 1000000000
end

-- Coin-icon money text, matching how the auction house itself shows prices.
function LF:FormatMoneyIcons(copper)
  copper = tonumber(copper)
  if not copper or copper < 0 then
    return "-"
  end
  copper = math.floor(copper + 0.5)
  if GetMoneyString then
    local ok, text = pcall(GetMoneyString, copper, true)
    if ok and text then
      return text
    end
  end
  return self:FormatMoney(copper)
end

-- === Data ===

-- LiteFlipper's own samples for an item, regrouped onto Auctionator's day
-- numbering so both sources line up row for row. Each day gets the lowest and
-- highest "cheapest listing" seen that day and the most units seen.
local function CollectOwnDays(itemKey)
  local days = {}
  local history = LF:GetHistory()[tostring(itemKey)]
  if type(history) ~= "table" then
    return days
  end

  local function Add(day, price, units)
    if not IsCopper(price) then
      return
    end
    local entry = days[day]
    if not entry then
      entry = {}
      days[day] = entry
    end
    entry.low = entry.low and math.min(entry.low, price) or price
    entry.high = entry.high and math.max(entry.high, price) or price
    if type(units) == "number" and units > 0 then
      entry.available = entry.available and math.max(entry.available, units) or units
    end
  end

  for utcDay, bucket in pairs(history) do
    if type(bucket) == "table" then
      local hadSamples = false
      if type(bucket.scans) == "table" then
        for _, sample in ipairs(bucket.scans) do
          local cheapest = sample.avg
          if type(sample.prices) == "table" then
            for _, price in ipairs(sample.prices) do
              if IsCopper(price) and (not cheapest or price < cheapest) then
                cheapest = price
              end
            end
          end
          if sample.time and IsCopper(cheapest) then
            Add(LF:GetAuctionatorDay(sample.time), cheapest, sample.units)
            hadSamples = true
          end
        end
      end

      -- Older buckets only kept a running minimum for the (UTC) day.
      if not hadSamples and IsCopper(bucket.min) and tonumber(utcDay) then
        local midday = tonumber(utcDay) * DAY_SECONDS + (DAY_SECONDS / 2)
        Add(LF:GetAuctionatorDay(midday), bucket.min, bucket.supplyUnits)
      end
    end
  end

  return days
end

-- Day-by-day rows for the history table, newest first:
-- { day, timestamp, age, low, high, available, change, source }.
function LF:GetPriceHistoryRows(itemLinkOrId, dbKey)
  local itemKey = self:GetItemKey(itemLinkOrId)
  if not itemKey then
    return {}
  end

  local byDay = {}

  local points = self:GetAuctionatorHistory(itemKey, nil, dbKey)
  for _, point in ipairs(points or {}) do
    byDay[point.rawDay] = {
      day = point.rawDay,
      low = point.low,
      high = point.high,
      available = point.available,
      source = "Auctionator",
    }
  end

  for day, own in pairs(CollectOwnDays(itemKey)) do
    local row = byDay[day]
    if row then
      -- Auctionator's figures stay; LiteFlipper only fills gaps.
      if not row.available then
        row.available = own.available
      end
    else
      byDay[day] = {
        day = day,
        low = own.low,
        high = own.high,
        available = own.available,
        source = "LiteFlipper",
      }
    end
  end

  local rows = {}
  local today = self:GetAuctionatorDay()
  local dayZero = self:GetAuctionatorDayZero()
  for day, row in pairs(byDay) do
    row.age = today - day
    -- Midday keeps the calendar date stable across daylight-saving changes.
    row.timestamp = dayZero + day * DAY_SECONDS + (DAY_SECONDS / 2)
    table.insert(rows, row)
  end

  table.sort(rows, function(left, right)
    return left.day > right.day
  end)

  -- Change in the day's low against the previous recorded day.
  for index, row in ipairs(rows) do
    local previous = rows[index + 1]
    if previous and previous.low and previous.low > 0 and row.low then
      row.change = (row.low - previous.low) / previous.low
    end
  end

  return rows
end

-- === Window ===

local function FormatDate(row)
  local text = date and date("%a, %b %d", row.timestamp) or ("day " .. tostring(row.day))
  if row.age == 0 then
    text = text .. " (today)"
  end
  return text
end

local function FormatChange(change)
  if type(change) ~= "number" then
    return "-", 0.6, 0.6, 0.6
  end
  local percent = math.floor(math.abs(change) * 100 + 0.5)
  if percent == 0 then
    return "0%", 0.8, 0.8, 0.8
  elseif change > 0 then
    return "+" .. percent .. "%", 1, 0.45, 0.45
  end
  return "-" .. percent .. "%", 0.4, 1, 0.4
end

local function FormatMarketSource(source)
  if source == "scan" then
    return "LiteFlipper scan average"
  elseif source == "scan-capped" then
    return "LiteFlipper scan average, capped at the history high"
  elseif source == "ah-history" then
    return "Auctionator daily average"
  elseif source == "auctionator" then
    return "Auctionator last price"
  elseif source == "day" then
    return "LiteFlipper daily average"
  end
  return source or "history"
end

function LF:RenderHistoryRows()
  local frame = self.historyFrame
  if not frame then
    return
  end

  local rows = frame.historyRows or {}
  local scrollFrame = frame.scrollFrame
  if scrollFrame and FauxScrollFrame_Update then
    FauxScrollFrame_Update(scrollFrame, #rows, VISIBLE_ROWS, ROW_HEIGHT)
  end

  local offset = (scrollFrame and FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(scrollFrame)) or 0
  for rowIndex, rowFrame in ipairs(frame.rows) do
    local row = rows[offset + rowIndex]
    rowFrame.historyRow = row

    if row then
      rowFrame.cells.date:SetText(FormatDate(row))
      rowFrame.cells.low:SetText(self:FormatMoneyIcons(row.low))
      rowFrame.cells.high:SetText(self:FormatMoneyIcons(row.high))
      rowFrame.cells.available:SetText(row.available and tostring(row.available) or "-")
      local changeText, r, g, b = FormatChange(row.change)
      rowFrame.cells.change:SetText(changeText)
      rowFrame.cells.change:SetTextColor(r, g, b)
      if row.source == "Auctionator" then
        rowFrame.cells.date:SetTextColor(1, 1, 1)
      else
        rowFrame.cells.date:SetTextColor(0.62, 0.82, 1)
      end
      rowFrame.stripe:SetShown((offset + rowIndex) % 2 == 0)
      rowFrame:Show()
    else
      rowFrame:Hide()
    end
  end
end

function LF:RefreshHistoryFrame()
  local frame = self.historyFrame
  if not frame or not frame.itemId then
    return
  end

  local itemId = frame.itemId
  local name = frame.itemName or self:GetItemName(itemId) or ("item " .. itemId)
  frame.itemName = frame.itemName or self:GetItemName(itemId, true)

  local quality = frame.itemQuality
  if not quality and C_Item and C_Item.GetItemQualityByID then
    quality = C_Item.GetItemQualityByID(itemId)
  end
  local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  if color and color.hex then
    frame.nameText:SetText(color.hex .. name .. "|r")
  else
    frame.nameText:SetText(name)
  end
  frame.icon:SetTexture(frame.itemIcon or self:GetItemIcon(itemId))

  local rows = self:GetPriceHistoryRows(itemId, frame.dbKey)
  frame.historyRows = rows

  -- Summary: the LiteFlipper figures the tooltip shows, in one place.
  local marketValue, _, marketSource = self:GetMarketValue(itemId)
  local currentLow = self:GetLatestScanMinPrice(itemId) or self:GetAuctionatorPrice(itemId)

  local line1 = {}
  if currentLow then
    table.insert(line1, "Current low: |cffffffff" .. self:FormatMoneyIcons(currentLow) .. "|r")
  end
  if marketValue then
    table.insert(line1, "Market value: |cffffffff" .. self:FormatMoneyIcons(marketValue) .. "|r")
  end
  frame.summary1:SetText(#line1 > 0 and table.concat(line1, "     ") or "No current price recorded.")

  local line2
  local trendStats = self:GetPriceTrend(itemId)
  if trendStats then
    local sign = trendStats.change < 0 and "-" or "+"
    local percent = math.floor(math.abs(trendStats.change) * 100 + 0.5)
    local trendColor = "|cffcccccc"
    if trendStats.label == "Rising" then
      trendColor = "|cff66ff66"
    elseif trendStats.label == "Falling" then
      trendColor = "|cffff7373"
    end
    line2 = "Trend: " .. trendColor .. trendStats.label .. " " .. sign .. percent .. "%|r over "
      .. trendStats.span .. "d"
    local volLabel, volPercent = self:DescribeVolatility(trendStats.volatility)
    if volLabel then
      line2 = line2 .. "     Volatility: |cffffffff" .. volLabel .. "|r (+/-" .. volPercent .. "%)"
    end
  elseif marketValue then
    line2 = "Market value from: " .. FormatMarketSource(marketSource)
  else
    line2 = "Trend needs at least 3 recorded days."
  end
  frame.summary2:SetText(line2)

  if #rows > 0 then
    local lowest, highest
    for _, row in ipairs(rows) do
      if row.low then
        lowest = lowest and math.min(lowest, row.low) or row.low
      end
      if row.high then
        highest = highest and math.max(highest, row.high) or row.high
      end
    end
    frame.summary3:SetText(#rows .. " day(s) recorded.     Lowest: |cffffffff"
      .. self:FormatMoneyIcons(lowest) .. "|r     Highest: |cffffffff"
      .. self:FormatMoneyIcons(highest) .. "|r")
    frame.emptyText:Hide()
  else
    frame.summary3:SetText("")
    frame.emptyText:Show()
  end

  self:RenderHistoryRows()
end

local function ScrollHistoryByWheel(delta)
  local frame = LF.historyFrame
  local scrollFrame = frame and frame.scrollFrame
  if not scrollFrame then
    return
  end

  local rows = frame.historyRows or {}
  local maxScroll = math.max(0, (#rows - VISIBLE_ROWS) * ROW_HEIGHT)
  local current = scrollFrame:GetVerticalScroll() or 0
  scrollFrame:SetVerticalScroll(math.max(0, math.min(maxScroll, current - (delta * ROW_HEIGHT * 3))))
end

local function HistoryRowOnEnter(self)
  local row = self.historyRow
  if not row then
    return
  end

  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(FormatDate(row), 1, 1, 1)
  if row.age and row.age > 0 then
    GameTooltip:AddLine(row.age .. " day(s) ago", 0.75, 0.75, 0.75)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Lowest price that day", LF:FormatMoneyIcons(row.low), 0.31, 0.70, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Highest price that day", LF:FormatMoneyIcons(row.high), 0.31, 0.70, 1, 1, 1, 1)
  if row.available then
    GameTooltip:AddDoubleLine("Most units available", tostring(row.available), 0.31, 0.70, 1, 1, 1, 1)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Each scan notes the item's cheapest listing. Low and High are the", 0.65, 0.65, 0.65)
  GameTooltip:AddLine("smallest and largest of those across the day's scans.", 0.65, 0.65, 0.65)
  GameTooltip:AddLine("Recorded by " .. (row.source or "LiteFlipper") .. ".", 0.65, 0.65, 0.65)
  GameTooltip:Show()
end

local function HideTooltip()
  GameTooltip:Hide()
end

function LF:CreateHistoryFrame()
  if self.historyFrame then
    return self.historyFrame
  end

  local frame = CreateFrame("Frame", "LiteFlipperHistoryFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
  frame:SetPoint("CENTER")
  frame:Hide()
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(dragged)
    dragged:StopMovingOrSizing()
    -- Once you place the window yourself it stays where you put it.
    dragged.userPlaced = true
  end)

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if frame.TitleBg then
    frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 6, 0)
  else
    frame.title:SetPoint("TOPLEFT", 12, -6)
  end
  frame.title:SetText("LiteFlipper Price History")

  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetSize(32, 32)
  frame.icon:SetPoint("TOPLEFT", 18, -32)

  frame.nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  frame.nameText:SetPoint("LEFT", frame.icon, "RIGHT", 10, 0)
  frame.nameText:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
  frame.nameText:SetJustifyH("LEFT")
  if frame.nameText.SetWordWrap then
    frame.nameText:SetWordWrap(false)
  end

  -- Hovering the icon or name shows the normal item tooltip.
  frame.itemButton = CreateFrame("Button", nil, frame)
  frame.itemButton:SetPoint("TOPLEFT", frame.icon, "TOPLEFT", 0, 0)
  frame.itemButton:SetPoint("BOTTOMRIGHT", frame.nameText, "BOTTOMRIGHT", 0, -8)
  frame.itemButton:SetScript("OnEnter", function(button)
    if frame.itemId then
      GameTooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT")
      GameTooltip:SetHyperlink(frame.itemLink or ("item:" .. frame.itemId))
      GameTooltip:Show()
    end
  end)
  frame.itemButton:SetScript("OnLeave", HideTooltip)
  frame.itemButton:SetScript("OnClick", function()
    if frame.itemId then
      LF:HandleItemClick(frame.itemLink or LF:GetItemLink(frame.itemId))
    end
  end)

  local function SummaryLine(offsetY)
    local line = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    line:SetPoint("TOPLEFT", 18, offsetY)
    line:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
    line:SetJustifyH("LEFT")
    if line.SetWordWrap then
      line:SetWordWrap(false)
    end
    return line
  end
  frame.summary1 = SummaryLine(-72)
  frame.summary2 = SummaryLine(-88)
  frame.summary3 = SummaryLine(-104)

  local xOffset = 18
  for _, column in ipairs(COLUMNS) do
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", xOffset, LIST_TOP + 16)
    header:SetWidth(column.width)
    header:SetJustifyH(column.justify)
    header:SetText(column.label)
    header:SetTextColor(1, 0.82, 0)
    xOffset = xOffset + column.width + 4
  end

  frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame, "FauxScrollFrameTemplate")
  frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, LIST_TOP)
  frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -30, LIST_TOP - (VISIBLE_ROWS * ROW_HEIGHT))
  frame.scrollFrame:SetScript("OnVerticalScroll", function(scrollFrame, offset)
    FauxScrollFrame_OnVerticalScroll(scrollFrame, offset, ROW_HEIGHT, function()
      LF:RenderHistoryRows()
    end)
  end)
  frame.scrollFrame:EnableMouseWheel(true)
  frame.scrollFrame:SetScript("OnMouseWheel", function(_, delta)
    ScrollHistoryByWheel(delta)
  end)

  frame.rows = {}
  for index = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 16, LIST_TOP - ((index - 1) * ROW_HEIGHT))
    row:SetPoint("RIGHT", -34, 0)
    row:SetScript("OnEnter", HistoryRowOnEnter)
    row:SetScript("OnLeave", HideTooltip)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
      ScrollHistoryByWheel(delta)
    end)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.04)

    row.cells = {}
    local cellOffset = 2
    for _, column in ipairs(COLUMNS) do
      local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cell:SetPoint("LEFT", row, "LEFT", cellOffset, 0)
      cell:SetWidth(column.width)
      cell:SetHeight(ROW_HEIGHT)
      cell:SetJustifyH(column.justify)
      cell:SetJustifyV("MIDDLE")
      if cell.SetWordWrap then
        cell:SetWordWrap(false)
      end
      row.cells[column.key] = cell
      cellOffset = cellOffset + column.width + 4
    end

    frame.rows[index] = row
  end

  frame.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  frame.emptyText:SetPoint("TOPLEFT", frame, "TOPLEFT", 30, LIST_TOP - 40)
  frame.emptyText:SetPoint("RIGHT", frame, "RIGHT", -40, 0)
  frame.emptyText:SetJustifyH("CENTER")
  frame.emptyText:SetText("No prices recorded for this item yet.\n\nRun an Auctionator scan, or search for the item at the auction house, and it will show up here.")
  frame.emptyText:Hide()

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 18, 16)
  frame.footer:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
  frame.footer:SetJustifyH("LEFT")
  frame.footer:SetText("One row per day you scanned. White dates come from Auctionator's price database, blue ones from LiteFlipper's own records.")

  -- Escape closes it, like other panels.
  if UISpecialFrames then
    table.insert(UISpecialFrames, "LiteFlipperHistoryFrame")
  end

  self.historyFrame = frame
  return frame
end

-- Auctionator files some items (random-suffix gear) under a more specific key
-- than the plain item id. Ask it which keys apply; fall back to the id.
local function ResolveDatabaseKeys(itemId, itemKey, callback)
  local utilities = Auctionator and Auctionator.Utilities
  if type(itemKey) == "table" and utilities and type(utilities.DBKeyFromItemKey) == "function" then
    local ok = pcall(utilities.DBKeyFromItemKey, itemKey, function(keys)
      if type(keys) == "table" and #keys > 0 then
        callback(keys)
      else
        callback({ tostring(itemId) })
      end
    end)
    if ok then
      return
    end
  end
  callback({ tostring(itemId) })
end

-- Opens the history window for an item. info is optional:
-- { name, link, quality, icon, itemKey, nextToAuctionHouse }.
function LF:ShowPriceHistory(itemLinkOrId, info)
  local itemId = tonumber(self:GetItemKey(itemLinkOrId))
  if not itemId then
    return false
  end
  info = info or {}

  local frame = self.historyFrame or self:CreateHistoryFrame()

  local link = info.link
  if not link and type(itemLinkOrId) == "string" and string.find(itemLinkOrId, "|H", 1, true) then
    link = itemLinkOrId
  end

  frame.itemId = itemId
  frame.itemName = info.name
  frame.itemLink = link
  frame.itemQuality = info.quality
  frame.itemIcon = info.icon
  frame.dbKey = nil
  -- Opened from the buy panel: follow the panel to the next item, and close
  -- with the auction house.
  frame.followsBuyPanel = info.nextToAuctionHouse and true or false
  frame.requestToken = (frame.requestToken or 0) + 1
  local token = frame.requestToken

  if frame.scrollFrame then
    frame.scrollFrame:SetVerticalScroll(0)
    if FauxScrollFrame_SetOffset then
      FauxScrollFrame_SetOffset(frame.scrollFrame, 0)
    end
  end

  if info.nextToAuctionHouse and not frame.userPlaced and AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
  end

  self:RefreshHistoryFrame()
  frame:Show()
  if frame.Raise then
    frame:Raise()
  end

  ResolveDatabaseKeys(itemId, info.itemKey, function(keys)
    if frame.requestToken ~= token or frame.itemId ~= itemId then
      return
    end
    for _, key in ipairs(keys) do
      if LF:HasAuctionatorHistory(key) then
        if key ~= tostring(itemId) then
          frame.dbKey = key
          LF:RefreshHistoryFrame()
        end
        return
      end
    end
  end)

  return true
end

-- "/lf history <item>" opens the window for the best match; with no argument
-- it uses the item currently open in Auctionator's buy panel.
function LF:HistoryLookup(query)
  query = string.match(query or "", "^%s*(.-)%s*$")

  if query == "" then
    local item = self:GetBuyPanelItem()
    if item then
      self:ShowPriceHistory(item.itemId, item)
    else
      self:Print("Usage: /lf history <item name, item link, or item id>")
    end
    return
  end

  local matches = self:FindItemsByQuery(query)
  if #matches == 0 then
    self:Print("No items match '" .. query .. "'. Names come from your scans and the recipe database.")
    return
  end

  local target = matches[1]
  self:ShowPriceHistory(target.itemId, {
    name = target.name,
    link = string.find(query, "|H", 1, true) and query or nil,
  })

  if #matches > 1 then
    local others = {}
    for index = 2, math.min(#matches, 6) do
      table.insert(others, matches[index].name)
    end
    self:Print("Showing " .. target.name .. ". Also matching: " .. table.concat(others, ", ")
      .. (#matches > 6 and ", ..." or "") .. ".")
  end
end

-- === History button on Auctionator's buy panels ===

local buyPanelItems = {}   -- [panel frame] = item shown in it
local historyButtons = {}  -- [panel frame] = our button

local function DescribeItemKey(itemKey, itemKeyInfo)
  if type(itemKey) ~= "table" or type(itemKey.itemID) ~= "number" or itemKey.itemID <= 0 then
    return nil
  end
  itemKeyInfo = type(itemKeyInfo) == "table" and itemKeyInfo or {}
  return {
    itemId = itemKey.itemID,
    itemKey = itemKey,
    name = itemKeyInfo.itemName,
    quality = itemKeyInfo.quality,
    icon = itemKeyInfo.iconFileID,
    nextToAuctionHouse = true,
  }
end

-- The item a buy panel is showing: what Auctionator announced when it opened
-- the panel, or failing that the item key the panel itself is holding.
local function GetPanelItem(panel)
  if not panel then
    return nil
  end
  local item = buyPanelItems[panel]
  if item then
    return item
  end
  return DescribeItemKey(panel.itemKey or panel.expectedItemKey)
end

function LF:GetBuyPanelItem()
  for _, name in ipairs({ "AuctionatorBuyCommodityFrame", "AuctionatorBuyItemFrame" }) do
    local panel = _G[name]
    if panel and panel:IsShown() then
      local item = GetPanelItem(panel)
      if item then
        return item
      end
    end
  end
  return nil
end

local function HistoryButtonOnClick(button)
  local item = GetPanelItem(button:GetParent())
  if not item then
    LF:Print("Open an item in the buy panel first.")
    return
  end

  local frame = LF.historyFrame
  if frame and frame:IsShown() and frame.itemId == item.itemId then
    frame:Hide()
    return
  end

  LF:ShowPriceHistory(item.itemId, item)
end

local function CreateHistoryButton(panel)
  local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  button:SetSize(110, 22)
  button:SetText("History")
  button:SetScript("OnClick", HistoryButtonOnClick)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Price history")
    GameTooltip:AddLine("Shows this item's price on each day you scanned the auction house. (LiteFlipper)", 0.75, 0.75, 0.75, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", HideTooltip)
  return button
end

-- Adds the button to whichever of Auctionator's buy panels exist. Returns
-- true once both have one. Auctionator only creates the panels the first time
-- the auction house is shown, so this is retried until they appear.
function LF:AttachHistoryButtons()
  local commodity = _G.AuctionatorBuyCommodityFrame
  if commodity and not historyButtons[commodity] then
    local button = CreateHistoryButton(commodity)
    -- Stackable items: the empty space under "Buy Now", left of the listings.
    if commodity.DetailsContainer then
      button:SetPoint("BOTTOM", commodity.DetailsContainer, "BOTTOM", 0, 14)
    else
      button:SetPoint("BOTTOMLEFT", commodity, "BOTTOMLEFT", 60, 14)
    end
    historyButtons[commodity] = button
  end

  local item = _G.AuctionatorBuyItemFrame
  if item and not historyButtons[item] then
    local button = CreateHistoryButton(item)
    -- Single items: the listings fill the panel, so sit beside "Back".
    if item.BackButton then
      button:SetPoint("LEFT", item.BackButton, "RIGHT", 8, 0)
    else
      button:SetPoint("TOPLEFT", item, "TOPLEFT", 90, -10)
    end
    historyButtons[item] = button
  end

  return (commodity and item) and true or false
end

local function AttachWithRetries(attemptsLeft)
  local ok, done = pcall(LF.AttachHistoryButtons, LF)
  if ok and done then
    return
  end
  if not ok then
    if not LF.historyButtonErrorReported then
      LF.historyButtonErrorReported = true
      LF:Print("Could not add the History button to Auctionator's buy panel: " .. tostring(done))
    end
    return
  end
  if attemptsLeft > 0 and C_Timer and C_Timer.After then
    C_Timer.After(0.5, function()
      AttachWithRetries(attemptsLeft - 1)
    end)
  end
end

-- Auctionator announces which item a buy panel is opening on its event bus.
local function InstallBuyPanelListener()
  if LF.buyPanelListenerInstalled then
    return
  end
  if not (Auctionator and Auctionator.EventBus and Auctionator.EventBus.Register
    and Auctionator.Buying and Auctionator.Buying.Events) then
    return
  end

  local buying = Auctionator.Buying.Events
  local events = {}
  if buying.ShowCommodityBuy then
    table.insert(events, buying.ShowCommodityBuy)
  end
  if buying.ShowItemBuy then
    table.insert(events, buying.ShowItemBuy)
  end
  if #events == 0 then
    return
  end

  local listener = {}
  function listener:ReceiveEvent(eventName, rowData, itemKeyInfo)
    local panel
    if eventName == buying.ShowCommodityBuy then
      panel = _G.AuctionatorBuyCommodityFrame
    elseif eventName == buying.ShowItemBuy then
      panel = _G.AuctionatorBuyItemFrame
    end
    if not panel then
      return
    end

    local item = DescribeItemKey(type(rowData) == "table" and rowData.itemKey, itemKeyInfo)
    buyPanelItems[panel] = item
    pcall(LF.AttachHistoryButtons, LF)

    -- Keep an open history window in step with the item being looked at.
    local frame = LF.historyFrame
    if item and frame and frame:IsShown() and frame.followsBuyPanel then
      LF:ShowPriceHistory(item.itemId, item)
    end
  end

  local ok = pcall(Auctionator.EventBus.Register, Auctionator.EventBus, listener, events)
  if ok then
    LF.buyPanelListener = listener
    LF.buyPanelListenerInstalled = true
  end
end

local historyEvents = CreateFrame("Frame")
historyEvents:SetScript("OnEvent", function(_, event)
  if not LF.db then
    return
  end

  if event == "AUCTION_HOUSE_SHOW" then
    InstallBuyPanelListener()
    AttachWithRetries(20)
  elseif event == "AUCTION_HOUSE_CLOSED" then
    for panel in pairs(buyPanelItems) do
      buyPanelItems[panel] = nil
    end
    local frame = LF.historyFrame
    if frame and frame.followsBuyPanel then
      frame:Hide()
    end
  end
end)
pcall(historyEvents.RegisterEvent, historyEvents, "AUCTION_HOUSE_SHOW")
pcall(historyEvents.RegisterEvent, historyEvents, "AUCTION_HOUSE_CLOSED")
