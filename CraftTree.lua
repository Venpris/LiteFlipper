local _, ns = ...
local LF = ns.LF

local AH_CUT = 0.05
local MAX_DEPTH = 6

local FRAME_WIDTH = 700
local FRAME_HEIGHT = 480
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 14
local INDENT_PER_DEPTH = 16

local function FormatCount(count)
  local rounded = math.floor(count + 0.5)
  if math.abs(count - rounded) < 0.05 then
    return tostring(rounded)
  end
  return string.format("%.1f", count)
end

-- Cheapest way to buy one unit outright: current scan low, market value, or
-- unlimited vendor supply.
local function GetBuyInfo(itemId)
  local vendor = LF:GetVendorPrice(itemId)
  local market = LF:GetMarketValue(itemId)
  local current = LF:GetLatestScanMinPrice(itemId)

  local unit = current or market
  local source = current and "scan" or "market"
  if vendor and (not unit or vendor < unit) then
    unit = vendor
    source = "vendor"
  end

  if not unit then
    return nil
  end
  return unit, source
end

local function ResolveNodeName(itemId, name, recipe)
  return name
    or (recipe and recipe.name)
    or LF:GetItemName(itemId)
    or ("item " .. itemId)
end

-- One node per reagent slot in the tree. countPerCraft is how many units the
-- parent recipe consumes per craft; neededUnits (filled in during flatten) is
-- how many units the current plan needs in total.
local function BuildNode(itemId, name, countPerCraft, visited, depth)
  local recipe = LF:GetCraftIndex()[tonumber(itemId) or itemId]
  local node = {
    itemId = itemId,
    name = ResolveNodeName(itemId, name, recipe),
    countPerCraft = countPerCraft,
    depth = depth,
    children = {},
  }

  node.buyUnit, node.buySource = GetBuyInfo(itemId)

  if recipe and not visited[itemId] and depth < MAX_DEPTH then
    node.numMade = recipe.numMade or 1
    visited[itemId] = true
    for _, reagent in ipairs(recipe.reagents or {}) do
      table.insert(node.children, BuildNode(reagent.id, reagent.name, reagent.count, visited, depth + 1))
    end
    visited[itemId] = nil
  end

  return node
end

-- Bottom-up pass: derive each node's craft cost from its children, pick a
-- default mode (cheapest) where the user has not chosen one, and clamp
-- choices that price data can no longer support.
local function ComputeCosts(node)
  if #node.children > 0 then
    local total = 0
    local complete = true
    for _, child in ipairs(node.children) do
      ComputeCosts(child)
      if not child.effectiveUnit then
        complete = false
      elseif complete then
        total = total + (child.effectiveUnit * child.countPerCraft)
      end
    end
    node.craftUnit = complete and math.ceil(total / (node.numMade or 1)) or nil
  else
    node.craftUnit = nil
  end

  if node.mode == nil then
    if node.buyUnit and node.craftUnit then
      node.mode = node.craftUnit < node.buyUnit and "craft" or "buy"
    elseif node.craftUnit then
      node.mode = "craft"
    elseif node.buyUnit then
      node.mode = "buy"
    end
  elseif node.mode == "craft" and not node.craftUnit and node.buyUnit then
    node.mode = "buy"
  elseif node.mode == "buy" and not node.buyUnit and node.craftUnit then
    node.mode = "craft"
  end

  node.effectiveUnit = (node.mode == "craft") and node.craftUnit or node.buyUnit
end

local function ClearModes(node)
  node.mode = nil
  for _, child in ipairs(node.children) do
    ClearModes(child)
  end
end

-- Rows shown are the reagents of every node currently set to "craft";
-- children of "buy" nodes stay hidden because you are not crafting those.
local function FlattenNode(node, list, neededUnits)
  node.neededUnits = neededUnits
  node.totalCost = node.effectiveUnit and math.floor((node.effectiveUnit * neededUnits) + 0.5) or nil
  table.insert(list, node)
  if node.mode == "craft" then
    for _, child in ipairs(node.children) do
      FlattenNode(child, list, neededUnits / (node.numMade or 1) * child.countPerCraft)
    end
  end
end

function LF:OpenCraftTree(recipeOrItemId)
  if not self.db then
    return
  end

  local itemId = tonumber(type(recipeOrItemId) == "table" and recipeOrItemId.product or recipeOrItemId)
  local recipe = itemId and self:GetCraftIndex()[itemId] or nil
  if not recipe then
    self:Print("That item is not craftable.")
    return
  end

  local root = BuildNode(itemId, recipe.name, 1, {}, 0)
  if #root.children == 0 then
    self:Print("No reagent data for " .. (recipe.name or ("item " .. itemId)) .. ".")
    return
  end

  self.craftTreeRoot = root
  local frame = self.craftTreeFrame
  if not frame and self.CreateCraftTreeFrame then
    self:CreateCraftTreeFrame()
    frame = self.craftTreeFrame
  end
  if frame then
    if frame.scrollFrame then
      frame.scrollFrame:SetVerticalScroll(0)
      if FauxScrollFrame_SetOffset then
        FauxScrollFrame_SetOffset(frame.scrollFrame, 0)
      end
    end
    self:RefreshCraftTree()
    frame:Show()
  else
    self:Print("Craft tree UI is not available.")
  end
end

function LF:RefreshCraftTree()
  local frame = self.craftTreeFrame
  local root = self.craftTreeRoot
  if not frame or not root then
    return
  end

  ComputeCosts(root)
  -- The whole page exists to price crafting the root, so it is always in
  -- craft mode regardless of what would be cheaper.
  root.mode = "craft"
  root.effectiveUnit = root.craftUnit

  local rows = {}
  local matTotal = 0
  local matComplete = true
  for _, child in ipairs(root.children) do
    FlattenNode(child, rows, child.countPerCraft)
    if child.totalCost then
      matTotal = matTotal + child.totalCost
    else
      matComplete = false
    end
  end
  frame.flatRows = rows

  local numMade = root.numMade or 1
  local productValue = self:GetCurrentAuctionPrice(root.itemId)
  local netValue = productValue and math.floor(productValue * numMade * (1 - AH_CUT)) or nil

  frame.productIcon:SetTexture(self:GetItemIcon(root.itemId))
  frame.productName:SetText(root.name .. (numMade > 1 and ("  (makes " .. numMade .. ")") or ""))
  frame.saleLine:SetText("Sale after 5% AH cut: " .. (netValue and self:FormatMoney(netValue) or "no price data"))

  if matComplete then
    local profit = netValue and (netValue - matTotal) or nil
    local profitText
    if profit then
      profitText = (profit < 0 and "-" or "") .. self:FormatMoney(math.abs(profit))
      if profit >= 0 then
        profitText = "|cff33ff33" .. profitText .. "|r"
      else
        profitText = "|cffff5555" .. profitText .. "|r"
      end
    end
    frame.costLine:SetText("Selected materials: " .. self:FormatMoney(matTotal)
      .. (profitText and ("    Est. profit: " .. profitText) or ""))
  else
    frame.costLine:SetText("Selected materials: incomplete price data")
  end

  self:RenderCraftTreePage()
end

local function TreeRowOnClick(self, button)
  local node = self.node
  if not node then
    return
  end

  if button == "RightButton" then
    if LF.ShowPriceHistory then
      LF:ShowPriceHistory(node.itemId, { name = node.name })
    end
    return
  end

  LF:HandleItemClick(LF:GetItemLink(node.itemId))
end

local function TreeRowOnEnter(self)
  local node = self.node
  if not node then
    return
  end

  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText(node.name, 1, 1, 1)
  if node.buyUnit then
    GameTooltip:AddDoubleLine("Buy (" .. (node.buySource or "market") .. ")",
      LF:FormatMoney(node.buyUnit) .. " each", 0.31, 0.70, 1, 1, 1, 1)
  else
    GameTooltip:AddDoubleLine("Buy", "no price data", 0.31, 0.70, 1, 0.6, 0.6, 0.6)
  end
  if node.craftUnit then
    GameTooltip:AddDoubleLine("Craft from reagents",
      LF:FormatMoney(node.craftUnit) .. " each", 0.31, 0.70, 1, 1, 1, 1)
  elseif #node.children > 0 then
    GameTooltip:AddDoubleLine("Craft from reagents", "incomplete price data", 0.31, 0.70, 1, 0.6, 0.6, 0.6)
  end
  if node.buyUnit and node.craftUnit then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Use the Buy/Craft button to switch how", 0.75, 0.75, 0.75)
    GameTooltip:AddLine("this material is obtained.", 0.75, 0.75, 0.75)
  end
  GameTooltip:AddLine("Right-click for price history.", 0.65, 0.65, 0.65)
  GameTooltip:Show()
end

local function TreeRowOnLeave()
  GameTooltip:Hide()
end

local function IsAuctionHouseOpen()
  return LF:IsAuctionHouseOpen()
end

-- Blizzard's own Buy tab, for when Auctionator is not installed.
local function SearchBlizzardAuctionHouse(name)
  local frame = AuctionHouseFrame
  local searchBar = frame and frame.SearchBar
  if not (searchBar and searchBar.SetSearchText and searchBar.StartSearch) then
    return false
  end

  if frame.SetDisplayMode and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
    frame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
  end
  searchBar:SetSearchText(name)
  searchBar:StartSearch()
  return true
end

function LF:FindCraftMaterialAtAuctionHouse(node)
  if not node then
    return
  end
  if not IsAuctionHouseOpen() then
    self:Print("Open the auction house first, then click Find beside " .. node.name .. ".")
    return
  end

  local auctionatorApi = Auctionator and Auctionator.API and Auctionator.API.v1
  if auctionatorApi and type(auctionatorApi.MultiSearchExact) == "function" then
    local ok, errorMessage = pcall(auctionatorApi.MultiSearchExact, self.name, { node.name })
    if ok then
      self:Print("Searching Auctionator's Shopping tab for " .. node.name .. ".")
      return
    end
    self:Debug("Auctionator Shopping search failed: " .. tostring(errorMessage))
  end

  -- Auctionator is optional. Fall back to Blizzard's Buy tab when its
  -- Shopping search API is unavailable.
  local ok, searched = pcall(SearchBlizzardAuctionHouse, node.name)
  if not ok or not searched then
    self:Print("The auction house search is not available in this auction-house UI.")
    return
  end

  self:Print("Searching the auction house Buy tab for " .. node.name .. ". Review the results and confirm the purchase there.")
end

local function ScrollCraftTreeByWheel(delta)
  local frame = LF.craftTreeFrame
  local scrollFrame = frame and frame.scrollFrame
  if not scrollFrame then
    return
  end

  local rows = frame.flatRows or {}
  local maxScroll = math.max(0, (#rows - VISIBLE_ROWS) * ROW_HEIGHT)
  local current = scrollFrame:GetVerticalScroll() or 0
  scrollFrame:SetVerticalScroll(math.max(0, math.min(maxScroll, current - (delta * ROW_HEIGHT * 3))))
end

function LF:RenderCraftTreePage()
  local frame = self.craftTreeFrame
  if not frame then
    return
  end

  local rows = frame.flatRows or {}
  local totalRows = #rows
  local scrollFrame = frame.scrollFrame
  if scrollFrame and FauxScrollFrame_Update then
    FauxScrollFrame_Update(scrollFrame, totalRows, VISIBLE_ROWS, ROW_HEIGHT)
  end

  local offset = (scrollFrame and FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(scrollFrame)) or 0
  local firstIndex = offset + 1
  for rowIndex, row in ipairs(frame.rows) do
    local node = rows[firstIndex + rowIndex - 1]
    row.node = node

    if node then
      local indent = (math.max(node.depth - 1, 0)) * INDENT_PER_DEPTH

      row.icon:ClearAllPoints()
      row.icon:SetPoint("LEFT", row, "LEFT", 98 + indent, 0)
      row.nameText:ClearAllPoints()
      row.nameText:SetPoint("LEFT", row, "LEFT", 122 + indent, 0)
      row.nameText:SetPoint("RIGHT", row, "RIGHT", -250, 0)

      local hasBoth = node.buyUnit and node.craftUnit
      row.modeButton:SetText(node.mode == "craft" and "Craft" or (node.mode == "buy" and "Buy" or "-"))
      if hasBoth then
        row.modeButton:Enable()
      else
        row.modeButton:Disable()
      end

      if IsAuctionHouseOpen() and node.buySource ~= "vendor" then
        row.buyButton:Enable()
      else
        row.buyButton:Disable()
      end

      row.nameText:SetText(FormatCount(node.neededUnits or 0) .. "x " .. node.name)
      if node.effectiveUnit then
        row.nameText:SetTextColor(1, 1, 1)
      else
        row.nameText:SetTextColor(0.55, 0.55, 0.55)
      end
      row.unitText:SetText(node.effectiveUnit and self:FormatMoney(node.effectiveUnit) or "-")
      row.totalText:SetText(node.totalCost and self:FormatMoney(node.totalCost) or "-")
      row.sourceText:SetText(node.mode == "craft" and "craft" or (node.buySource or "-"))
      row.icon:SetTexture(self:GetItemIcon(node.itemId))
      row:Show()
    else
      row:Hide()
    end
  end

  if frame.countText then
    frame.countText:SetText(string.format("%d material(s)", totalRows))
  end
end

function LF:CreateCraftTreeFrame()
  local frame = CreateFrame("Frame", "LiteFlipperCraftTreeFrame", UIParent, "BasicFrameTemplateWithInset")
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
  frame.title:SetText("LiteFlipper Craft Tree")

  frame.productIcon = frame:CreateTexture(nil, "ARTWORK")
  frame.productIcon:SetSize(28, 28)
  frame.productIcon:SetPoint("TOPLEFT", 18, -32)

  frame.productName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  frame.productName:SetPoint("TOPLEFT", frame.productIcon, "TOPRIGHT", 8, -2)
  frame.productName:SetJustifyH("LEFT")

  frame.saleLine = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.saleLine:SetPoint("TOPLEFT", 18, -66)
  frame.saleLine:SetJustifyH("LEFT")

  frame.costLine = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.costLine:SetPoint("TOPLEFT", 18, -80)
  frame.costLine:SetJustifyH("LEFT")

  frame.resetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.resetButton:SetSize(90, 22)
  frame.resetButton:SetPoint("TOPRIGHT", -12, -30)
  frame.resetButton:SetText("Cheapest")
  frame.resetButton:SetScript("OnClick", function()
    if LF.craftTreeRoot then
      ClearModes(LF.craftTreeRoot)
      LF:RefreshCraftTree()
    end
  end)
  frame.resetButton:SetScript("OnEnter", function(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText("Reset every material to its cheapest option.")
    GameTooltip:Show()
  end)
  frame.resetButton:SetScript("OnLeave", TreeRowOnLeave)

  local headerLabels = {
    { text = "Get", x = 16, width = 40, justify = "LEFT" },
    { text = "AH", x = 66, width = 36, justify = "LEFT" },
    { text = "Material", x = 122, width = 200, justify = "LEFT" },
  }
  for _, label in ipairs(headerLabels) do
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", label.x, -100)
    header:SetWidth(label.width)
    header:SetJustifyH(label.justify)
    header:SetText(label.text)
    header:SetTextColor(1, 0.82, 0)
  end
  local rightHeaders = {
    { text = "Source", x = -34, width = 60 },
    { text = "Total", x = -102, width = 90 },
    { text = "Unit", x = -196, width = 80 },
  }
  for _, label in ipairs(rightHeaders) do
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", label.x, -100)
    header:SetWidth(label.width)
    header:SetJustifyH("RIGHT")
    header:SetText(label.text)
    header:SetTextColor(1, 0.82, 0)
  end

  frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame, "FauxScrollFrameTemplate")
  frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -116)
  frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 42)
  frame.scrollFrame:SetScript("OnVerticalScroll", function(scrollFrame, offset)
    FauxScrollFrame_OnVerticalScroll(scrollFrame, offset, ROW_HEIGHT, function()
      LF:RenderCraftTreePage()
    end)
  end)
  if frame.scrollFrame.EnableMouseWheel then
    frame.scrollFrame:EnableMouseWheel(true)
    frame.scrollFrame:SetScript("OnMouseWheel", function(scrollFrame, delta)
      ScrollCraftTreeByWheel(delta)
    end)
  end

  frame.rows = {}
  for index = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 16, -116 - ((index - 1) * ROW_HEIGHT))
    row:SetPoint("RIGHT", -34, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", TreeRowOnClick)
    row:SetScript("OnEnter", TreeRowOnEnter)
    row:SetScript("OnLeave", TreeRowOnLeave)
    if row.EnableMouseWheel then
      row:EnableMouseWheel(true)
      row:SetScript("OnMouseWheel", function(_, delta)
        ScrollCraftTreeByWheel(delta)
      end)
    end
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.modeButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.modeButton:SetSize(46, 18)
    row.modeButton:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.modeButton:SetScript("OnClick", function(button)
      local parent = button:GetParent()
      local node = parent and parent.node
      if node and node.buyUnit and node.craftUnit then
        node.mode = (node.mode == "craft") and "buy" or "craft"
        LF:RefreshCraftTree()
      end
    end)

    row.buyButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.buyButton:SetSize(40, 18)
    row.buyButton:SetPoint("LEFT", row, "LEFT", 50, 0)
    row.buyButton:SetText("Find")
    row.buyButton:SetScript("OnClick", function(button)
      local parent = button:GetParent()
      LF:FindCraftMaterialAtAuctionHouse(parent and parent.node)
    end)
    row.buyButton:SetScript("OnEnter", function(button)
      GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
      GameTooltip:SetText("Find this material at the auction house.")
      GameTooltip:AddLine("Opens an exact search in Auctionator's Shopping tab. The auction house must be open.", 0.75, 0.75, 0.75, true)
      GameTooltip:Show()
    end)
    row.buyButton:SetScript("OnLeave", TreeRowOnLeave)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 98, 0)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row, "LEFT", 122, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -250, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetHeight(ROW_HEIGHT)
    if row.nameText.SetWordWrap then
      row.nameText:SetWordWrap(false)
    end

    row.unitText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.unitText:SetPoint("RIGHT", row, "RIGHT", -162, 0)
    row.unitText:SetWidth(80)
    row.unitText:SetJustifyH("RIGHT")

    row.totalText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.totalText:SetPoint("RIGHT", row, "RIGHT", -68, 0)
    row.totalText:SetWidth(90)
    row.totalText:SetJustifyH("RIGHT")

    row.sourceText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.sourceText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.sourceText:SetWidth(60)
    row.sourceText:SetJustifyH("RIGHT")
    row.sourceText:SetTextColor(0.75, 0.75, 0.75)

    frame.rows[index] = row
  end

  frame.countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.countText:SetPoint("BOTTOMLEFT", 16, 18)
  frame.countText:SetText("0 material(s)")

  self.craftTreeFrame = frame
end

function LF:CraftTreeLookup(query)
  query = string.match(query or "", "^%s*(.-)%s*$")
  if query == "" then
    self:Print("Usage: /lf tree <item name, item link, or item id>")
    return
  end

  local matches = self:FindItemsByQuery(query)
  if #matches == 0 then
    self:Print("No items match '" .. query .. "'.")
    return
  end

  -- Prefer an exact name match, then the first craftable match.
  local lowered = string.lower(query)
  local target
  for _, match in ipairs(matches) do
    if string.lower(match.name) == lowered and self:GetCraftIndex()[match.itemId] then
      target = match
      break
    end
  end
  if not target then
    for _, match in ipairs(matches) do
      if self:GetCraftIndex()[match.itemId] then
        target = match
        break
      end
    end
  end

  if not target then
    self:Print("No craftable item matches '" .. query .. "'.")
    return
  end

  self:OpenCraftTree(target.itemId)
end

local auctionHouseEventFrame = CreateFrame("Frame")
auctionHouseEventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
auctionHouseEventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
auctionHouseEventFrame:SetScript("OnEvent", function()
  if LF.craftTreeFrame and LF.craftTreeFrame:IsShown() then
    LF:RenderCraftTreePage()
  end
end)
