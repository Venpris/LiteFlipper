local _, ns = ...
local LF = ns.LF

local AH_CUT = 0.05

local ROW_HEIGHT = 22
local DEFAULT_PAGE_SIZE = 14
local FRAME_WIDTH = 740
local FRAME_HEIGHT = 430
local COLUMN_GAP = 4

local CRAFT_COLUMNS = {
  { key = "rank", label = "#", width = 30, justify = "RIGHT" },
  { key = "icon", label = "", width = 22, justify = "LEFT" },
  { key = "item", label = "Craft", width = 230, justify = "LEFT" },
  { key = "made", label = "Made", width = 40, justify = "RIGHT" },
  { key = "mats", label = "Mat Cost", width = 80, justify = "RIGHT" },
  { key = "matspct", label = "Mats%", width = 48, justify = "RIGHT" },
  { key = "value", label = "Sale (net)", width = 80, justify = "RIGHT" },
  { key = "profit", label = "Profit", width = 80, justify = "RIGHT" },
  { key = "pct", label = "Cost%", width = 48, justify = "RIGHT" },
}

local CRAFT_SORT_VALUES = {
  item = function(row) return string.lower(row.displayName or row.recipe.name or "") end,
  made = function(row) return row.recipe.numMade or 1 end,
  mats = function(row) return row.matNow end,
  matspct = function(row) return row.matsPct end,
  value = function(row) return row.netValue end,
  profit = function(row) return row.profit end,
  pct = function(row) return row.pct end,
}

local function SortCraftRows(rows, key, ascending)
  local getValue = CRAFT_SORT_VALUES[key]
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
      return string.lower(left.displayName or left.recipe.name or "")
        < string.lower(right.displayName or right.recipe.name or "")
    end
    if ascending then
      return leftValue < rightValue
    end
    return leftValue > rightValue
  end)
end

local function ExtractItemId(link)
  if type(link) ~= "string" then
    return nil
  end
  return tonumber(string.match(link, "item:(%d+)"))
end

local function ExtractItemName(link)
  if type(link) ~= "string" then
    return nil
  end
  return string.match(link, "%[(.-)%]")
end

local function IsHeaderType(skillType)
  return skillType == "header" or skillType == "subheader"
end

-- Unpack a compact ns.RecipeData entry into the same shape as recorded ones.
local function StaticToRecipe(entry)
  local reagents = {}
  for _, pair in ipairs(entry.r or {}) do
    table.insert(reagents, { id = pair[1], count = pair[2] })
  end
  return {
    product = entry.p,
    name = entry.n,
    numMade = entry.m or 1,
    reagents = reagents,
  }
end

-- Static data first, then recorded recipes overwrite so known crafts keep
-- the reagent names captured from the actual profession window.
local function BuildCombinedRecipes(staticData, stores, key)
  local combined = {}

  local static = staticData[key]
  for _, entry in ipairs((static and static.recipes) or {}) do
    combined[tostring(entry.p)] = StaticToRecipe(entry)
  end

  local store = stores[key]
  if store and type(store.recipes) == "table" then
    for productKey, recipe in pairs(store.recipes) do
      combined[productKey] = {
        product = recipe.product,
        name = recipe.name,
        numMade = recipe.numMade,
        reagents = recipe.reagents,
        known = true,
      }
    end
  end

  return combined
end

local function CountTable(t)
  local count = 0
  for _ in pairs(t or {}) do
    count = count + 1
  end
  return count
end

-- Cost% = mat cost / net sale value, so under 100 is profitable.
local function GetCraftPercentColor(pct)
  if pct <= 60 then
    return 0.20, 1.00, 0.20
  elseif pct <= 80 then
    return 0.90, 1.00, 0.20
  elseif pct <= 95 then
    return 1.00, 0.72, 0.20
  elseif pct <= 100 then
    return 1.00, 0.55, 0.20
  end
  return 1.00, 0.35, 0.35
end

local function GetMatsPercentColor(pct)
  if pct <= 95 then
    return 0.20, 1.00, 0.20
  elseif pct >= 105 then
    return 1.00, 0.55, 0.20
  end
  return 0.85, 0.85, 0.85
end

-- === Vendor prices ===

function LF:RecordMerchantPrices()
  if not self.db or not GetMerchantNumItems then
    return
  end

  self.db.vendorPrices = self.db.vendorPrices or {}
  local recorded = 0

  for index = 1, GetMerchantNumItems() do
    local info = { GetMerchantItemInfo(index) }
    local price, quantity, numAvailable = info[3], info[4], info[5]
    -- The modern classic client returns extendedCost 8th; the old API
    -- returned it 7th. Either way a truthy value means non-copper cost.
    local extendedCost = info[8]
    if extendedCost == nil then
      extendedCost = info[7]
    end

    local itemId = ExtractItemId(GetMerchantItemLink and GetMerchantItemLink(index))
    if itemId
      and type(price) == "number" and price > 0
      and numAvailable == -1
      and extendedCost ~= true then
      local units = (type(quantity) == "number" and quantity > 0) and quantity or 1
      self.db.vendorPrices[tostring(itemId)] = math.ceil(price / units)
      recorded = recorded + 1
    end
  end

  if recorded > 0 then
    self:Debug("Recorded vendor prices for " .. recorded .. " item(s).")
  end
end

-- === Recipe snapshots ===

function LF:SnapshotTradeSkill()
  if not self.db or not GetTradeSkillLine then
    return
  end

  local profName = GetTradeSkillLine()
  if not profName or profName == "UNKNOWN" then
    return
  end

  local numSkills = GetNumTradeSkills and GetNumTradeSkills() or 0
  if numSkills == 0 then
    return
  end

  local profKey = string.lower(profName)
  self.db.craftRecipes = self.db.craftRecipes or {}
  local store = self.db.craftRecipes[profKey] or {}
  store.name = profName
  store.recipes = store.recipes or {}
  self.db.craftRecipes[profKey] = store

  local added = 0
  for index = 1, numSkills do
    local skillName, skillType = GetTradeSkillInfo(index)
    if skillName and not IsHeaderType(skillType) then
      local productLink = GetTradeSkillItemLink(index)
      local productId = ExtractItemId(productLink)
      if productId then
        local numMade = 1
        if GetTradeSkillNumMade then
          local minMade = GetTradeSkillNumMade(index)
          if type(minMade) == "number" and minMade > 0 then
            numMade = minMade
          end
        end

        local reagents = {}
        local complete = true
        for reagentIndex = 1, (GetTradeSkillNumReagents(index) or 0) do
          local reagentName, _, reagentCount = GetTradeSkillReagentInfo(index, reagentIndex)
          local reagentLink = GetTradeSkillReagentItemLink(index, reagentIndex)
          local reagentId = ExtractItemId(reagentLink)
          if reagentId and type(reagentCount) == "number" and reagentCount > 0 then
            table.insert(reagents, {
              id = reagentId,
              name = reagentName or ExtractItemName(reagentLink) or ("item " .. reagentId),
              count = reagentCount,
            })
          else
            complete = false
          end
        end

        if complete and #reagents > 0 then
          local key = tostring(productId)
          if not store.recipes[key] then
            added = added + 1
          end
          store.recipes[key] = {
            product = productId,
            name = ExtractItemName(productLink) or skillName,
            numMade = numMade,
            reagents = reagents,
          }
        end
      end
    end
  end

  store.updatedAt = time()
  -- Recorded recipes feed the product -> recipe index used for recursive
  -- reagent costing, so rebuild it on the next lookup.
  self.craftIndex = nil

  if added > 0 then
    self:Print("Recorded " .. added .. " new " .. profName .. " recipe(s), "
      .. CountTable(store.recipes) .. " total. Try /lf craft " .. profKey .. ".")
  end
end

function LF:SnapshotTradeSkillSession()
  if not GetTradeSkillLine then
    return
  end

  local profName = GetTradeSkillLine()
  if not profName or profName == "UNKNOWN" then
    return
  end

  local numSkills = GetNumTradeSkills and GetNumTradeSkills() or 0
  if numSkills == 0 then
    return
  end

  -- Only run the expand/restore dance once per window open. Expanding and
  -- collapsing both fire TRADE_SKILL_UPDATE, so re-running it from those
  -- events would loop forever; later updates just merge what is visible.
  if self.tradeSkillSessionSeen then
    self:SnapshotTradeSkill()
    return
  end
  self.tradeSkillSessionSeen = true

  local collapsedHeaders = {}
  for index = 1, numSkills do
    local name, skillType, _, isExpanded = GetTradeSkillInfo(index)
    if name and IsHeaderType(skillType) and not isExpanded then
      collapsedHeaders[name] = true
    end
  end

  if next(collapsedHeaders) and ExpandTradeSkillSubClass then
    ExpandTradeSkillSubClass(0)
  end

  self:SnapshotTradeSkill()

  if next(collapsedHeaders) and CollapseTradeSkillSubClass then
    -- Bottom-up so collapsing a header does not shift the indices of the
    -- headers we still need to visit.
    for index = GetNumTradeSkills(), 1, -1 do
      local name, skillType = GetTradeSkillInfo(index)
      if name and IsHeaderType(skillType) and collapsedHeaders[name] then
        CollapseTradeSkillSubClass(index)
      end
    end
  end
end

-- === Craft valuation ===

-- Product id -> recipe across every profession, static plus recorded, so
-- reagent costing can see that intermediate mats (bars, bolts, essences) are
-- themselves craftable.
function LF:GetCraftIndex()
  if self.craftIndex then
    return self.craftIndex
  end

  local index = {}
  for _, profession in pairs(ns.RecipeData or {}) do
    if type(profession) == "table" then
      for _, entry in ipairs(profession.recipes or {}) do
        if not index[entry.p] then
          index[entry.p] = StaticToRecipe(entry)
        end
      end
    end
  end
  for _, store in pairs((self.db and self.db.craftRecipes) or {}) do
    if type(store) == "table" and type(store.recipes) == "table" then
      for _, recipe in pairs(store.recipes) do
        if recipe.product then
          index[recipe.product] = recipe
        end
      end
    end
  end

  self.craftIndex = index
  return index
end

-- Returns { now, normal, source, craftParts, craftNumMade } for one reagent
-- unit, or nil when no price can be derived.
--
-- now is the cheapest way to obtain the reagent right now: current scan low,
-- market value, unlimited vendor supply, or crafting it from its own
-- reagents - recursively, so a Dark Iron Bar falls back to Dark Iron Ore
-- prices whenever smelting is cheaper than buying bars. normal is the same
-- using market values only. When crafting wins, craftParts carries the
-- sub-reagent breakdown for the tooltip tree. visited guards against recipe
-- cycles (essence transmutes go both ways).
function LF:GetReagentCostInfo(itemId, visited)
  visited = visited or {}

  local memo = self.craftCostMemo
  local isTopLevel = next(visited) == nil
  if memo and memo[itemId] ~= nil then
    if memo[itemId] == false then
      return nil
    end
    return memo[itemId]
  end

  local vendor = self.db and self.db.vendorPrices and self.db.vendorPrices[tostring(itemId)]
  local market = self:GetMarketValue(itemId)
  local current = self:GetLatestScanMinPrice(itemId)

  local now = current or market
  local normal = market or current
  local source = current and "scan" or "market"

  if vendor then
    if not now or vendor < now then
      now = vendor
      source = "vendor"
    end
    if not normal or vendor < normal then
      normal = vendor
    end
  end

  local craftParts
  local craftNumMade
  local recipe = self:GetCraftIndex()[tonumber(itemId) or itemId]
  if recipe and not visited[itemId] then
    visited[itemId] = true
    local craftNow = 0
    local craftNormal = 0
    local parts = {}
    local complete = true
    for _, reagent in ipairs(recipe.reagents or {}) do
      local sub = self:GetReagentCostInfo(reagent.id, visited)
      if not sub then
        complete = false
        break
      end
      craftNow = craftNow + (sub.now * reagent.count)
      craftNormal = craftNormal + (sub.normal * reagent.count)
      table.insert(parts, { id = reagent.id, name = reagent.name, count = reagent.count, info = sub })
    end
    visited[itemId] = nil

    if complete and #parts > 0 then
      local made = recipe.numMade or 1
      craftNow = math.ceil(craftNow / made)
      craftNormal = math.ceil(craftNormal / made)
      if not now or craftNow < now then
        now = craftNow
        source = "craft"
        craftParts = parts
        craftNumMade = made
      end
      if not normal or craftNormal < normal then
        normal = craftNormal
      end
    end
  end

  if not now then
    if memo and isTopLevel then
      memo[itemId] = false
    end
    return nil
  end

  local result = {
    now = now,
    normal = normal or now,
    source = source,
    craftParts = craftParts,
    craftNumMade = craftNumMade,
  }
  if memo and isTopLevel then
    memo[itemId] = result
  end
  return result
end

local function FormatCount(count)
  local rounded = math.floor(count + 0.5)
  if math.abs(count - rounded) < 0.05 then
    return tostring(rounded)
  end
  return string.format("%.1f", count)
end

-- Flattens the cost tree into indented tooltip lines. Sub-reagents only
-- appear where crafting was actually the cheapest option.
local function AddReagentLines(lines, id, name, needed, info, depth)
  table.insert(lines, {
    name = name or (GetItemInfo and GetItemInfo(id)) or ("item " .. id),
    countText = FormatCount(needed),
    total = math.floor((info.now * needed) + 0.5),
    source = info.source,
    depth = depth,
  })
  if info.source == "craft" and info.craftParts and depth < 3 then
    for _, part in ipairs(info.craftParts) do
      AddReagentLines(lines, part.id, part.name, needed * part.count / (info.craftNumMade or 1), part.info, depth + 1)
    end
  end
end

function LF:GetCurrentAuctionPrice(itemLinkOrId)
  return self:GetLatestScanMinPrice(itemLinkOrId)
    or (self.GetAuctionatorPrice and self:GetAuctionatorPrice(itemLinkOrId, false))
end

function LF:GetRecipeCraftCost(recipe)
  if not recipe then
    return nil
  end

  local total = 0
  for _, reagent in ipairs(recipe.reagents or {}) do
    local info = self:GetReagentCostInfo(reagent.id)
    if not info then
      return nil
    end
    total = total + (info.now * reagent.count)
  end

  return total > 0 and total or nil, recipe.numMade or 1
end

function LF:EvaluateCraft(recipe)
  local productValue = self:GetCurrentAuctionPrice(recipe.product)
  if not productValue then
    return nil
  end

  local netValue = math.floor(productValue * (recipe.numMade or 1) * (1 - AH_CUT))
  local matNow = 0
  local matNormal = 0
  local reagentLines = {}

  for _, reagent in ipairs(recipe.reagents or {}) do
    local info = self:GetReagentCostInfo(reagent.id)
    if not info then
      return nil
    end
    matNow = matNow + (info.now * reagent.count)
    matNormal = matNormal + (info.normal * reagent.count)
    AddReagentLines(reagentLines, reagent.id, reagent.name, reagent.count, info, 0)
  end

  if matNow <= 0 or netValue <= 0 then
    return nil
  end

  return {
    recipe = recipe,
    displayName = (GetItemInfo and GetItemInfo(recipe.product)) or recipe.name,
    productValue = productValue,
    netValue = netValue,
    matNow = matNow,
    matNormal = matNormal,
    profit = netValue - matNow,
    pct = matNow / netValue,
    matsPct = matNormal > 0 and (matNow / matNormal) or nil,
    reagentLines = reagentLines,
  }
end

function LF:CraftScan(professionArg)
  if not self.db then
    return
  end

  local stores = self.db.craftRecipes or {}
  local staticData = ns.RecipeData or {}

  local professionKeys = {}
  local seenKeys = {}
  for key, data in pairs(staticData) do
    if type(data) == "table" and type(data.recipes) == "table" and #data.recipes > 0 then
      seenKeys[key] = true
      table.insert(professionKeys, key)
    end
  end
  for key, store in pairs(stores) do
    if not seenKeys[key] and type(store) == "table" and type(store.recipes) == "table" and next(store.recipes) then
      seenKeys[key] = true
      table.insert(professionKeys, key)
    end
  end
  table.sort(professionKeys)

  if #professionKeys == 0 then
    self:Print("No recipe data found. Open a profession window (like Alchemy) once and LiteFlipper will remember its recipes.")
    return
  end

  local arg = string.lower(string.match(professionArg or "", "^%s*(.-)%s*$"))
  local matches = {}
  if arg ~= "" then
    for _, key in ipairs(professionKeys) do
      if key == arg then
        matches = { key }
        break
      elseif string.sub(key, 1, #arg) == arg then
        table.insert(matches, key)
      end
    end
  end

  if #matches ~= 1 then
    if arg ~= "" and #matches == 0 then
      self:Print("No profession matches '" .. arg .. "'.")
    elseif #matches > 1 then
      self:Print("'" .. arg .. "' is ambiguous: " .. table.concat(matches, ", ") .. ".")
    end
    self:Print("Professions: " .. table.concat(professionKeys, ", ") .. ". Use /lf craft <profession>.")
    return
  end

  local key = matches[1]
  local static = staticData[key]
  local store = stores[key]
  local displayName = (static and static.name) or (store and store.name) or key
  local combined = BuildCombinedRecipes(staticData, stores, key)

  -- Reagent costs are memoized per command so the recursive craft-vs-buy
  -- lookups stay cheap across a few hundred recipes.
  self.craftCostMemo = {}

  local results = {}
  local total = 0
  local skipped = 0
  local knownCount = 0

  for _, recipe in pairs(combined) do
    total = total + 1
    if recipe.known then
      knownCount = knownCount + 1
    end
    local result = self:EvaluateCraft(recipe)
    if result then
      result.professionName = displayName
      table.insert(results, result)
    else
      skipped = skipped + 1
    end
  end

  table.sort(results, function(left, right)
    if left.profit == right.profit then
      return left.pct < right.pct
    end
    return left.profit > right.profit
  end)

  self:ShowCraftResults(displayName, results, total, skipped, knownCount)
  self:Print(displayName .. ": priced " .. #results .. " of " .. total .. " recipe(s)"
    .. (skipped > 0 and (", " .. skipped .. " missing price data") or "")
    .. ", " .. knownCount .. " known to your characters.")
end

function LF:UsesLookup(query)
  if not self.db then
    return
  end

  query = string.match(query or "", "^%s*(.-)%s*$")
  if query == "" then
    self:Print("Usage: /lf uses <material name, item link, or item id>")
    return
  end

  local matches = self:FindItemsByQuery(query)
  if #matches == 0 then
    self:Print("No items match '" .. query .. "'. Names come from your scans and the recipe database.")
    return
  end

  local target
  local lowered = string.lower(query)
  for _, match in ipairs(matches) do
    if string.lower(match.name) == lowered then
      target = match
      break
    end
  end
  if not target and #matches == 1 then
    target = matches[1]
  end
  if not target then
    local names = {}
    for index = 1, math.min(#matches, 8) do
      table.insert(names, matches[index].name)
    end
    self:Print("Multiple items match '" .. query .. "': " .. table.concat(names, ", ")
      .. (#matches > 8 and ", ..." or "") .. ". Be more specific.")
    return
  end

  local stores = self.db.craftRecipes or {}
  local staticData = ns.RecipeData or {}

  local professionKeys = {}
  local seenKeys = {}
  for key in pairs(staticData) do
    seenKeys[key] = true
    table.insert(professionKeys, key)
  end
  for key, store in pairs(stores) do
    if not seenKeys[key] and type(store) == "table" and type(store.recipes) == "table" then
      seenKeys[key] = true
      table.insert(professionKeys, key)
    end
  end
  table.sort(professionKeys)

  self.craftCostMemo = {}

  local results = {}
  local total = 0
  local skipped = 0
  local knownCount = 0
  local seenProducts = {}

  for _, key in ipairs(professionKeys) do
    local combined = BuildCombinedRecipes(staticData, stores, key)
    local professionName = (staticData[key] and staticData[key].name)
      or (stores[key] and stores[key].name)
      or key
    for productKey, recipe in pairs(combined) do
      if not seenProducts[productKey] then
        local usesMat = false
        for _, reagent in ipairs(recipe.reagents or {}) do
          if reagent.id == target.itemId then
            usesMat = true
            break
          end
        end
        if usesMat then
          seenProducts[productKey] = true
          total = total + 1
          if recipe.known then
            knownCount = knownCount + 1
          end
          local result = self:EvaluateCraft(recipe)
          if result then
            result.professionName = professionName
            table.insert(results, result)
          else
            skipped = skipped + 1
          end
        end
      end
    end
  end

  local targetName = target.name or ("item " .. target.itemId)
  if total == 0 then
    self:Print("No recipes use " .. targetName .. ".")
    return
  end

  table.sort(results, function(left, right)
    if left.profit == right.profit then
      return left.pct < right.pct
    end
    return left.profit > right.profit
  end)

  local label = "Uses: " .. targetName
  self:ShowCraftResults(label, results, total, skipped, knownCount)
  self:Print(targetName .. " is used by " .. total .. " recipe(s), " .. #results .. " priced"
    .. (skipped > 0 and (", " .. skipped .. " missing price data") or "")
    .. ", " .. knownCount .. " known to your characters.")
end

-- === Results UI ===

local function CraftRowOnClick(self)
  local result = self.result
  if not result then
    return
  end

  local link = GetItemInfo and select(2, GetItemInfo(result.recipe.product)) or nil
  if link and ChatEdit_GetActiveWindow() then
    ChatEdit_InsertLink(link)
    return
  end
  if link and IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) then
    HandleModifiedItemClick(link)
    return
  end

  LF:OpenCraftTree(result.recipe)
end

local function CraftRowOnEnter(self)
  local result = self.result
  if not result then
    return
  end

  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText(result.displayName or result.recipe.name, 1, 1, 1)
  if result.professionName then
    GameTooltip:AddLine(result.professionName, 0.75, 0.75, 0.75)
  end
  if result.recipe.known then
    GameTooltip:AddLine("Known recipe", 0.20, 1.00, 0.20)
  else
    GameTooltip:AddLine("Not seen in your profession windows", 0.60, 0.60, 0.60)
  end
  if (result.recipe.numMade or 1) > 1 then
    GameTooltip:AddLine("Makes " .. result.recipe.numMade, 0.75, 0.75, 0.75)
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Reagents", 0.31, 0.70, 1)
  for _, line in ipairs(result.reagentLines or {}) do
    local label = string.rep("    ", line.depth or 0) .. line.countText .. "x " .. line.name
    if line.source == "vendor" then
      label = label .. " (vendor)"
    elseif line.source == "craft" then
      label = label .. " (crafted)"
    end
    if (line.depth or 0) > 0 then
      GameTooltip:AddDoubleLine(label, LF:FormatMoney(line.total), 0.65, 0.65, 0.65, 0.65, 0.65, 0.65)
    else
      GameTooltip:AddDoubleLine(label, LF:FormatMoney(line.total), 1, 1, 1, 1, 1, 1)
    end
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Material cost", LF:FormatMoney(result.matNow), 0.31, 0.70, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Sale after 5% AH cut", LF:FormatMoney(result.netValue), 0.31, 0.70, 1, 1, 1, 1)
  local profitR, profitG, profitB = GetCraftPercentColor(result.pct * 100)
  local profitText = (result.profit < 0 and "-" or "") .. LF:FormatMoney(math.abs(result.profit))
  GameTooltip:AddDoubleLine("Est. profit", profitText, 0.31, 0.70, 1, profitR, profitG, profitB)
  if result.matsPct then
    GameTooltip:AddDoubleLine("Mats vs normal", math.floor(result.matsPct * 100 + 0.5) .. "%", 0.31, 0.70, 1, GetMatsPercentColor(result.matsPct * 100))
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click to open the craft tree planner.", 0.75, 0.75, 0.75)
  GameTooltip:Show()
end

local function CraftRowOnLeave()
  GameTooltip:Hide()
end

function LF:RenderCraftPage()
  local frame = self.craftFrame
  if not frame then
    return
  end

  local results = frame.results or {}
  local totalResults = #results
  local pageSize = frame.pageSize or DEFAULT_PAGE_SIZE
  local totalPages = totalResults > 0 and math.ceil(totalResults / pageSize) or 1
  frame.currentPage = math.max(1, math.min(frame.currentPage or 1, totalPages))

  local firstIndex = ((frame.currentPage - 1) * pageSize) + 1
  for rowIndex, row in ipairs(frame.rows) do
    local resultIndex = firstIndex + rowIndex - 1
    local result = results[resultIndex]
    row.result = result

    if result then
      local pct = math.floor(result.pct * 100 + 0.5)
      local pctR, pctG, pctB = GetCraftPercentColor(pct)
      row.cells.rank:SetText(resultIndex .. ".")
      row.cells.item:SetText(result.displayName or result.recipe.name)
      if result.recipe.known then
        row.cells.item:SetTextColor(1, 1, 1)
      else
        row.cells.item:SetTextColor(0.55, 0.55, 0.55)
      end
      row.cells.made:SetText(tostring(result.recipe.numMade or 1))
      row.cells.mats:SetText(self:FormatMoney(result.matNow))
      row.cells.value:SetText(self:FormatMoney(result.netValue))
      row.cells.profit:SetText((result.profit < 0 and "-" or "") .. self:FormatMoney(math.abs(result.profit)))
      row.cells.pct:SetText(pct .. "%")

      if result.matsPct then
        local matsPct = math.floor(result.matsPct * 100 + 0.5)
        row.cells.matspct:SetText(matsPct .. "%")
        row.cells.matspct:SetTextColor(GetMatsPercentColor(matsPct))
      else
        row.cells.matspct:SetText("-")
        row.cells.matspct:SetTextColor(0.75, 0.75, 0.75)
      end

      row.cells.pct:SetTextColor(pctR, pctG, pctB)
      row.cells.profit:SetTextColor(pctR, pctG, pctB)
      row.icon:SetTexture((GetItemIcon and GetItemIcon(result.recipe.product)) or "Interface\\Icons\\INV_Misc_QuestionMark")
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

  frame.pageText:SetText(string.format("Page %d/%d  %d craft(s)", frame.currentPage, totalPages, totalResults))
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

function LF:SetCraftSort(key)
  local frame = self.craftFrame
  if not frame or not CRAFT_SORT_VALUES[key] then
    return
  end

  if frame.sortKey == key then
    frame.sortAscending = not frame.sortAscending
  else
    frame.sortKey = key
    frame.sortAscending = key == "item"
  end

  for columnKey, header in pairs(frame.headers or {}) do
    if header.label then
      local suffix = columnKey == frame.sortKey and (frame.sortAscending and " ^" or " v") or ""
      header.label:SetText((header.baseLabel or "") .. suffix)
    end
  end

  SortCraftRows(frame.results or {}, frame.sortKey, frame.sortAscending)
  frame.currentPage = 1
  self:RenderCraftPage()
end

function LF:CreateCraftFrame()
  local frame = CreateFrame("Frame", "LiteFlipperCraftFrame", UIParent, "BasicFrameTemplateWithInset")
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
  frame.title:SetText("LiteFlipper Crafting")

  frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.summary:SetPoint("TOPLEFT", 16, -34)
  frame.summary:SetPoint("RIGHT", -230, 0)
  frame.summary:SetJustifyH("LEFT")

  frame.searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  frame.searchBox:SetSize(140, 20)
  frame.searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -28)
  frame.searchBox:SetAutoFocus(false)
  frame.searchBox:SetScript("OnTextChanged", function()
    LF:ApplyCraftFilter()
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
  for _, column in ipairs(CRAFT_COLUMNS) do
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
    if CRAFT_SORT_VALUES[columnKey] then
      header:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      header:SetScript("OnClick", function()
        LF:SetCraftSort(columnKey)
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
    row:SetScript("OnClick", CraftRowOnClick)
    row:SetScript("OnEnter", CraftRowOnEnter)
    row:SetScript("OnLeave", CraftRowOnLeave)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.cells = {}
    xOffset = 0
    for _, column in ipairs(CRAFT_COLUMNS) do
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
    LF:RenderCraftPage()
  end)

  frame.nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.nextButton:SetSize(80, 22)
  frame.nextButton:SetPoint("LEFT", frame.prevButton, "RIGHT", 8, 0)
  frame.nextButton:SetText("Next")
  frame.nextButton:SetScript("OnClick", function()
    frame.currentPage = (frame.currentPage or 1) + 1
    LF:RenderCraftPage()
  end)

  frame.pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.pageText:SetPoint("LEFT", frame.nextButton, "RIGHT", 12, 0)
  frame.pageText:SetText("Page 1/1  0 craft(s)")

  self.craftFrame = frame
end

function LF:ShowCraftResults(professionName, results, total, skipped, knownCount)
  local frame = self.craftFrame
  if not frame then
    return
  end

  frame.summary:SetText(string.format(
    "%s: %d of %d recipe(s) priced%s, %d known (white; unknown are grey). Sale uses the current AH price minus the 5%% cut.",
    professionName,
    #results,
    total or #results,
    (skipped or 0) > 0 and (", " .. skipped .. " skipped for missing prices") or "",
    knownCount or 0
  ))

  frame.allResults = results or {}
  self:ApplyCraftFilter()
  frame:Show()
end

function LF:ApplyCraftFilter()
  local frame = self.craftFrame
  if not frame then
    return
  end

  local allResults = frame.allResults or {}
  local text = frame.searchBox
    and string.lower(string.match(frame.searchBox:GetText() or "", "^%s*(.-)%s*$"))
    or ""

  if text == "" then
    frame.results = allResults
  else
    local filtered = {}
    for _, result in ipairs(allResults) do
      local name = result.displayName or result.recipe.name or ""
      if string.find(string.lower(name), text, 1, true) then
        table.insert(filtered, result)
      end
    end
    frame.results = filtered
  end

  SortCraftRows(frame.results, frame.sortKey, frame.sortAscending)
  frame.currentPage = 1
  self:RenderCraftPage()
end

-- === Events ===

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_CLOSE")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:SetScript("OnEvent", function(_, event)
  if not LF.db then
    return
  end

  if event == "MERCHANT_SHOW" then
    LF:RecordMerchantPrices()
  elseif event == "TRADE_SKILL_CLOSE" then
    LF.tradeSkillSessionSeen = nil
  else
    LF:SnapshotTradeSkillSession()
  end
end)
