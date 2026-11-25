local _, ns = ...
local LF = ns.LF

local ROW_HEIGHT = 22
local DEFAULT_PAGE_SIZE = 14
local FRAME_WIDTH = 720
local FRAME_HEIGHT = 430
local COLUMN_GAP = 4

local BAG_COLUMNS = {
  { key = "rank", label = "#", width = 30, justify = "RIGHT" },
  { key = "icon", label = "", width = 22, justify = "LEFT" },
  { key = "item", label = "Item", width = 230, justify = "LEFT" },
  { key = "qty", label = "Qty", width = 44, justify = "RIGHT" },
  { key = "unit", label = "Unit", width = 80, justify = "RIGHT" },
  { key = "total", label = "AH Total", width = 90, justify = "RIGHT" },
  { key = "low", label = "Cur. low", width = 80, justify = "RIGHT" },
  { key = "vendor", label = "Vendor", width = 80, justify = "RIGHT" },
}

local function GetBagSlotCount(bag)
  if C_Container and C_Container.GetContainerNumSlots then
    return C_Container.GetContainerNumSlots(bag) or 0
  end
  if GetContainerNumSlots then
    return GetContainerNumSlots(bag) or 0
  end
  return 0
end

local function GetBagItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then
      return info.itemID, info.stackCount or 1, info.hyperlink, info.isBound
    end
    return nil
  end
  if GetContainerItemInfo then
    local _, itemCount, _, _, _, _, itemLink, _, _, itemID = GetContainerItemInfo(bag, slot)
    return itemID, itemCount or 1, itemLink, nil
  end
  return nil
end

function LF:BagScan()
  if not self.db then
    return
  end

  local itemsById = {}
  local order = {}
  local boundSkipped = 0

  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, GetBagSlotCount(bag) do
      local itemId, count, link, isBound = GetBagItem(bag, slot)
      if itemId then
        if isBound then
          boundSkipped = boundSkipped + 1
        else
          local key = tostring(itemId)
          local entry = itemsById[key]
          if not entry then
            entry = { itemId = itemId, count = 0 }
            itemsById[key] = entry
            table.insert(order, entry)
          end
          entry.count = entry.count + (count or 1)
          entry.link = entry.link or link
        end
      end
    end
  end

  if #order == 0 then
    self:Print("No sellable items found in your bags"
      .. (boundSkipped > 0 and (" (" .. boundSkipped .. " soulbound stack(s) skipped)") or "") .. ".")
    return
  end

  local rows = {}
  for _, entry in ipairs(order) do
    local name, resolvedLink, _, _, _, _, _, _, _, _, vendorSell = self:GetItemInfo(entry.link or entry.itemId)
    local link = entry.link or resolvedLink
    name = name
      or (link and string.match(link, "%[(.-)%]"))
      or self:GetItemName(entry.itemId)
      or ("item " .. entry.itemId)

    local marketValue = self:GetMarketValue(link or entry.itemId)
    table.insert(rows, {
      itemId = entry.itemId,
      link = link,
      name = name,
      count = entry.count,
      marketValue = marketValue,
      totalValue = marketValue and (marketValue * entry.count) or nil,
      currentLow = self:GetLatestScanMinPrice(entry.itemId),
      vendorTotal = (vendorSell and vendorSell > 0) and (vendorSell * entry.count) or nil,
    })
  end

  table.sort(rows, function(left, right)
    if (left.totalValue or 0) == (right.totalValue or 0) then
      return left.name < right.name
    end
    return (left.totalValue or 0) > (right.totalValue or 0)
  end)

  self:ShowBagResults(rows, boundSkipped)
end

-- === Results UI ===

local function BagRowOnClick(self, button)
  local row = self.bagRow
  if not row then
    return
  end

  if button == "RightButton" then
    if LF.ShowPriceHistory then
      LF:ShowPriceHistory(row.itemId, { name = row.name, link = row.link })
    end
    return
  end

  LF:HandleItemClick(row.link)
end

local function BagRowOnEnter(self)
  local row = self.bagRow
  if not row then
    return
  end

  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  if row.link then
    GameTooltip:SetHyperlink(row.link)
  else
    GameTooltip:SetText(row.name)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Right-click for price history.", 0.65, 0.65, 0.65)
  GameTooltip:Show()
end

local function BagRowOnLeave()
  GameTooltip:Hide()
end

function LF:RenderBagPage()
  local frame = self.bagFrame
  if not frame then
    return
  end

  local rows = frame.bagRows or {}
  local totalRows = #rows
  local pageSize = frame.pageSize or DEFAULT_PAGE_SIZE
  local totalPages = totalRows > 0 and math.ceil(totalRows / pageSize) or 1
  frame.currentPage = math.max(1, math.min(frame.currentPage or 1, totalPages))

  local firstIndex = ((frame.currentPage - 1) * pageSize) + 1
  for rowIndex, row in ipairs(frame.rows) do
    local dataIndex = firstIndex + rowIndex - 1
    local data = rows[dataIndex]
    row.bagRow = data

    if data then
      row.cells.rank:SetText(dataIndex .. ".")
      row.cells.item:SetText(data.name)
      row.cells.qty:SetText(tostring(data.count))
      row.cells.unit:SetText(data.marketValue and self:FormatMoney(data.marketValue) or "-")
      row.cells.total:SetText(data.totalValue and self:FormatMoney(data.totalValue) or "-")
      row.cells.low:SetText(data.currentLow and self:FormatMoney(data.currentLow) or "-")
      row.cells.vendor:SetText(data.vendorTotal and self:FormatMoney(data.vendorTotal) or "-")
      if data.marketValue then
        row.cells.item:SetTextColor(1, 1, 1)
      else
        row.cells.item:SetTextColor(0.55, 0.55, 0.55)
      end
      row.icon:SetTexture(self:GetItemIcon(data.itemId))
      row:Show()
    else
      for _, cell in pairs(row.cells) do
        cell:SetText("")
        cell:SetTextColor(1, 1, 1)
      end
      row.icon:SetTexture(nil)
      row:Hide()
    end
  end

  frame.pageText:SetText(string.format("Page %d/%d  %d item(s)", frame.currentPage, totalPages, totalRows))
  if frame.currentPage > 1 then
    frame.prevButton:Enable()
  else
    frame.prevButton:Disable()
  end
  if frame.currentPage < totalPages then
    frame.nextButton:Enable()
  else
    frame.nextButton:Disable()
  end
end

function LF:CreateBagFrame()
  local frame = CreateFrame("Frame", "LiteFlipperBagFrame", UIParent, "BasicFrameTemplateWithInset")
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
  frame.title:SetText("LiteFlipper Bags")

  frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.summary:SetPoint("TOPLEFT", 16, -34)
  frame.summary:SetPoint("RIGHT", -16, 0)
  frame.summary:SetJustifyH("LEFT")

  frame.headers = {}
  local xOffset = 16
  for _, column in ipairs(BAG_COLUMNS) do
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", xOffset, -58)
    header:SetWidth(column.width)
    header:SetJustifyH(column.justify or "LEFT")
    header:SetText(column.label)
    header:SetTextColor(1, 0.82, 0)
    frame.headers[column.key] = header
    xOffset = xOffset + column.width + COLUMN_GAP
  end

  frame.pageSize = math.min(self.db.resultsPageSize or DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE)
  frame.rows = {}
  for index = 1, frame.pageSize do
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 16, -78 - ((index - 1) * ROW_HEIGHT))
    row:SetPoint("RIGHT", -16, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", BagRowOnClick)
    row:SetScript("OnEnter", BagRowOnEnter)
    row:SetScript("OnLeave", BagRowOnLeave)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.cells = {}
    xOffset = 0
    for _, column in ipairs(BAG_COLUMNS) do
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
    LF:RenderBagPage()
  end)

  frame.nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.nextButton:SetSize(80, 22)
  frame.nextButton:SetPoint("LEFT", frame.prevButton, "RIGHT", 8, 0)
  frame.nextButton:SetText("Next")
  frame.nextButton:SetScript("OnClick", function()
    frame.currentPage = (frame.currentPage or 1) + 1
    LF:RenderBagPage()
  end)

  frame.pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.pageText:SetPoint("LEFT", frame.nextButton, "RIGHT", 12, 0)
  frame.pageText:SetText("Page 1/1  0 item(s)")

  self.bagFrame = frame
end

function LF:ShowBagResults(rows, boundSkipped)
  local frame = self.bagFrame
  if not frame then
    return
  end

  local grandTotal = 0
  local pricedCount = 0
  for _, row in ipairs(rows) do
    if row.totalValue then
      grandTotal = grandTotal + row.totalValue
      pricedCount = pricedCount + 1
    end
  end

  frame.summary:SetText(string.format(
    "%d sellable item(s) in bags, %d with prices, est. AH value %s%s. Grey names have no price data yet.",
    #rows,
    pricedCount,
    self:FormatMoney(grandTotal),
    (boundSkipped or 0) > 0 and (", " .. boundSkipped .. " soulbound stack(s) skipped") or ""
  ))

  frame.bagRows = rows
  frame.currentPage = 1
  self:RenderBagPage()
  frame:Show()
end
