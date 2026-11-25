-- Offline check of the WoW Forever port. Run from the addon folder:
--   python -I dev/runlua.py dev/test_forever.lua "ADDON_DIR=<path to LiteFlipper>"
-- It catches Lua errors and logic mistakes; it cannot prove the real client accepts every
-- widget call.
local stub = dofile(ADDON_DIR .. "/dev/wowstub.lua")

local failures = 0
local function check(condition, label)
  if condition then
    print("  ok   " .. label)
  else
    failures = failures + 1
    print("  FAIL " .. label)
  end
end
local function section(name) print("\n== " .. name) end
local function lastChat(pattern)
  for index = #stub.chat, 1, -1 do
    if stub.chat[index]:find(pattern) then return stub.chat[index] end
  end
  return nil
end

stub.items[12360] = { name = "Arcanite Bar", sell = 5000 }
stub.items[12359] = { name = "Thorium Bar", sell = 600 }
stub.items[12363] = { name = "Arcane Crystal", sell = 2000 }
stub.items[3371] = { name = "Empty Vial", sell = 1 }
stub.items[2447] = { name = "Peacebloom", sell = 10 }
stub.items[765] = { name = "Silverleaf", sell = 10 }
stub.items[247755] = { name = "Forever Test Tonic", sell = 25 }
stub.items[9999999] = { name = "Unlisted Widget", sell = 1 }

local auctionator = stub.installAuctionator()
local today = math.floor((stub.now - auctionator.Constants.SCAN_DAY_0) / 86400)
auctionator.Database.db["12360"] = {
  m = 339900,
  h = { [tostring(today)] = 342000, [tostring(today - 1)] = 350000, [tostring(today - 2)] = 330000,
        [tostring(today - 4)] = 310000 },
  l = { [tostring(today)] = 339900 },
  a = { [tostring(today)] = 80, [tostring(today - 1)] = 64, [tostring(today - 2)] = 70 },
}
stub.ahPrices[12360] = 339900
stub.ahAges[12360] = 0

section("load")
local ns = stub.loadAddon(ADDON_DIR, "LiteFlipper")
local LF = ns.LF
check(LF ~= nil, "namespace created")
stub.fire("ADDON_LOADED", "LiteFlipper")
check(LiteFlipperDB ~= nil and LF.db == LiteFlipperDB, "saved variables initialised")
check(type(SlashCmdList.LITEFLIPPER) == "function", "slash command registered")
check(#stub.tooltipCalls == 1 and stub.tooltipCalls[1].dataType == Enum.TooltipDataType.Item,
  "tooltip hook uses TooltipDataProcessor")
stub.fire("PLAYER_LOGIN")
check(LF:GetMarketScopeKey() == "PvE::Alliance", "market scope is ruleset + faction: " .. tostring(LF:GetMarketScopeKey()))
check(LF.auctionatorScanListenerInstalled == true, "listening for Auctionator scans")
local slash = SlashCmdList.LITEFLIPPER

section("recipe data")
local recipeCount, withSpell = 0, 0
for _, profession in pairs(ns.RecipeData) do
  for _, entry in ipairs(profession.recipes) do
    recipeCount = recipeCount + 1
    if entry.s then withSpell = withSpell + 1 end
  end
end
check(recipeCount > 1500 and withSpell == recipeCount, recipeCount .. " recipes, all with spell ids")
check(LF:GetCraftIndex()[12360] ~= nil, "Arcanite Bar is craftable in the index")
check(LF:GetVendorPrice(3371) ~= nil, "bundled vendor price for Empty Vial")

section("auctionator price + history")
check(LF:GetAuctionatorPrice(12360) == 339900, "price through the public API")
local points = LF:GetAuctionatorHistory(12360)
check(points and #points == 4 and points[#points].age == 0, "4 history days, newest last")
check(points[#points].low == 339900 and points[#points].high == 342000, "today's low/high read correctly")
local trend = LF:GetPriceTrend(12360)
check(trend ~= nil and trend.historicalLow == 310000 and trend.historicalHigh == 350000, "trend stats computed")
local value, days, source = LF:GetMarketValue(12360)
check(value ~= nil and source == "ah-history", "market value falls back to Auctionator history: " .. tostring(value))

section("auctionator summary scan (browse results)")
local browse = {}
for index = 1, 320 do
  browse[#browse + 1] = {
    itemKey = { itemID = 500000 + index, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
    minPrice = 1000 + index, totalQuantity = 10 + index,
  }
end
browse[#browse + 1] = { itemKey = { itemID = 12360, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, minPrice = 339900, totalQuantity = 80 }
browse[#browse + 1] = { itemKey = { itemID = 12359, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, minPrice = 9000, totalQuantity = 400 }
browse[#browse + 1] = { itemKey = { itemID = 12363, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, minPrice = 300000, totalQuantity = 30 }
browse[#browse + 1] = { itemKey = { itemID = 0, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 55 }, minPrice = 5, totalQuantity = 1 }
auctionator.EventBus:Fire(nil, auctionator.IncrementalScan.Events.ScanStart)
check(LF.auctionatorScanActive == true, "scan-in-progress flag set")
-- browse events during the scan must be ignored
stub.browse = browse
stub.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
check(LF.lastScan == nil, "page events ignored while Auctionator scans")
auctionator.EventBus:Fire(nil, auctionator.IncrementalScan.Events.ScanComplete, browse)
check(LF.auctionatorScanActive == false, "flag cleared on completion")
check(LF.lastScan ~= nil and #LF.lastScan.auctions == 323, "snapshot saved with 323 rows (battle pet skipped)")
check(LF.lastScan.preferForDeals and LF.lastScan.summary, "snapshot marked as whole-house summary")
stub.runFrames(40)
check(LF.lastScan.historyRecorded == true, "history recorded in the background")
check(LF:GetLatestScanMinPrice(12360) == 339900, "current low from snapshot")
check(LiteFlipperDB.lastScans["PvE::Alliance"] == LF.lastScan, "snapshot persisted under the scope key")
local _, _, source2 = LF:GetMarketValue(12360)
check(source2 == "ah-history", "one day of own samples does not outrank 4 days of Auctionator history: " .. tostring(source2))
local _, _, source3 = LF:GetMarketValue(12359)
check(source3 == "scan", "items Auctionator has no history for use LiteFlipper's samples: " .. tostring(source3))
-- once LiteFlipper has as many days as Auctionator, its own samples win
do
  local own = LF:GetHistory()["12360"]
  local utcToday = math.floor(stub.now / 86400)
  for offset = 1, 3 do
    own[tostring(utcToday - offset)] = { seen = 1, min = 340000, scans = {
      { time = stub.now - offset * 86400, avg = 340000, auctions = 1, units = 5, prices = { 340000 } },
    } }
  end
  local _, _, source4 = LF:GetMarketValue(12360)
  check(source4 == "scan" or source4 == "scan-capped", "equal coverage prefers LiteFlipper's samples: " .. tostring(source4))
  for offset = 1, 3 do
    own[tostring(utcToday - offset)] = nil
  end
end

section("commodity ladder opened in the buy panel")
stub.now = stub.now + 20
stub.commodities[12360] = {
  { unitPrice = 335000, quantity = 2, owners = { "Seller" } },
  { unitPrice = 339900, quantity = 1, owners = { "player" } },
  { unitPrice = 342000, quantity = 4, owners = { "A", "B" } },
}
stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 12360)
check(LF:GetLatestScanMinPrice(12360) == 335000, "current low follows the fresher ladder")
check(#LF.lastScan.auctions == 323, "ladder did not replace the saved whole-house scan")
local bucket = LF:GetHistory()["12360"][tostring(math.floor(stub.now / 86400))]
local sample = bucket and bucket.scans and bucket.scans[#bucket.scans]
check(sample and #sample.prices == 3 and #bucket.scans == 1, "ladder merged into the same sample moment (kept the richer one)")

section("item listings")
stub.items[777] = { name = "Test Sword", sell = 100 }
stub.itemListings[777] = {
  { buyoutAmount = 50000, quantity = 1, owners = { "X" }, itemLink = "|cffffffff|Hitem:777::::::::60:::::|h[Test Sword]|h|r" },
  { buyoutAmount = 0, quantity = 1, owners = { "Y" } },
}
stub.fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 777, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, 0)
check(LF:GetLatestScanMinPrice(777) == 50000, "item listing price recorded (bid-only rows skipped)")

section("/lf scan and /lf browse")
slash("threshold 99")
slash("profit 0")
slash("supply 0")
slash("scan")
check(LF.resultsFrame:IsShown(), "results window shown")
check(lastChat("Re%-filtered") or lastChat("Re%-opened") or lastChat("Found"), "scan reported: " .. tostring(stub.chat[#stub.chat]))
check(LF.resultsFrame.rows[1].cells.item:GetText() ~= nil, "rows rendered")
slash("browse")
check(LF.resultsFrame.resultMode == "browse", "browse mode shown")
check(#LF.lastScan.auctions == 323, "browsing one item kept the saved scan")
-- row interactions
local row = LF.resultsFrame.rows[1]
row:GetScript("OnEnter")(row)
check(GameTooltip:NumLines() > 0, "row tooltip built")
row:GetScript("OnClick")(row, "LeftButton")
row:GetScript("OnClick")(row, "RightButton")
check(LF.historyFrame:IsShown(), "right-click opens price history")
LF.historyFrame:Hide()
LF.resultsFrame.searchBox:SetText("arcanite")
LF:ApplyResultsFilter()
check(#LF.resultsFrame.deals >= 1, "search filter finds Arcanite Bar by name")
LF:SetResultsSort("unit")
LF:SetResultsSort("item")

section("ordinary search results (not an Auctionator scan)")
stub.browse = { browse[321], browse[322] }
stub.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
stub.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { browse[323] })
local captured, liveCount = LF:CaptureCurrentAuctions()
check(liveCount == 3 and #captured == 3, "live rows track the search results")
slash("scan")
check(lastChat("because the current AH view only has"), "small search defers to the saved scan")

section("tooltip")
GameTooltip:ClearLines()
GameTooltip.__itemLink = select(2, C_Item.GetItemInfo(12360))
stub.tooltipCalls[1].fn(GameTooltip, { id = 12360 })
local text = table.concat(GameTooltip.__lines, "\n")
check(text:find("Market value") ~= nil, "market value line added")
check(text:find("Cost to craft") ~= nil, "craft cost line added")
check(text:find("Price trend") ~= nil, "trend line added")
check(not LF.tooltipErrorReported, "no tooltip error")
local other = stub.newWidget("GameTooltip", "ShoppingTooltip1")
other.__itemLink = GameTooltip.__itemLink
stub.tooltipCalls[1].fn(other, { id = 12360 })
check(other:NumLines() == 0, "comparison tooltips left alone")
GameTooltip:ClearLines()
GameTooltip.__itemLink = nil
stub.tooltipCalls[1].fn(GameTooltip, { id = 12359 })
check(table.concat(GameTooltip.__lines, "\n"):find("Market value") ~= nil, "falls back to the tooltip data id")
slash("hovertooltip off")
GameTooltip:ClearLines()
stub.tooltipCalls[1].fn(GameTooltip, { id = 12359 })
check(GameTooltip:NumLines() == 0, "toggle off works")
slash("hovertooltip on")

section("crafting")
slash("craft")
check(lastChat("Professions: "), "profession list printed")
slash("craft alchemy")
check(LF.craftFrame:IsShown(), "craft window shown")
check(lastChat("Alchemy: priced"), "craft summary: " .. tostring(lastChat("Alchemy: priced")))
local arcanite
for _, result in ipairs(LF.craftFrame.allResults) do
  if result.recipe.product == 12360 then arcanite = result end
end
check(arcanite ~= nil, "Arcanite Bar priced")
check(arcanite and arcanite.matNow == 9000 + 300000, "material cost uses scan lows: " .. tostring(arcanite and arcanite.matNow))
check(arcanite and not arcanite.recipe.known, "not known yet")
local craftRow = LF.craftFrame.rows[1]
craftRow:GetScript("OnEnter")(craftRow)
craftRow:GetScript("OnClick")(craftRow, "LeftButton")
check(LF.craftTreeFrame:IsShown(), "clicking a craft opens the tree")
slash("tree arcanite bar")
check(LF.craftTreeRoot and LF.craftTreeRoot.itemId == 12360, "tree for Arcanite Bar")
local treeRow = LF.craftTreeFrame.rows[1]
treeRow:GetScript("OnEnter")(treeRow)
treeRow:GetScript("OnClick")(treeRow, "LeftButton")
treeRow.modeButton:Click()
AuctionHouseFrame.__shown = true
treeRow.buyButton:Click()
check(stub.search and stub.search[1] == treeRow.node.name, "Find searches Auctionator for the material")
slash("uses thorium bar")
check(lastChat("Thorium Bar is used by"), "uses lookup: " .. tostring(lastChat("is used by")))
slash("alch")

section("profession window")
stub.openProfession = "Alchemy"
stub.recipes[17187] = { learned = true, schematic = {
  outputItemID = 12360, quantityMin = 1, quantityMax = 1,
  reagentSlotSchematics = {
    { reagentType = 1, required = true, quantityRequired = 1, reagents = { { itemID = 12359 } } },
    { reagentType = 1, required = true, quantityRequired = 1, reagents = { { itemID = 12363 } } },
    { reagentType = 0, required = false, quantityRequired = 1, reagents = { { itemID = 1 } } },
  },
} }
stub.fire("TRADE_SKILL_SHOW")
stub.fire("TRADE_SKILL_LIST_UPDATE")
stub.runTimers()
check(LiteFlipperDB.knownRecipes[17187] == true, "learned recipe noted")
local store = LiteFlipperDB.craftRecipes.alchemy
check(store and store.recipes["12360"] and #store.recipes["12360"].reagents == 2, "real reagents recorded (optional slot skipped)")
slash("craft alchemy")
arcanite = nil
for _, result in ipairs(LF.craftFrame.allResults) do
  if result.recipe.product == 12360 then arcanite = result end
end
check(arcanite and arcanite.recipe.known, "Arcanite Bar now shows as known")
stub.known[2329] = true
check(LF:IsRecipeKnown({ spell = 2329 }), "spellbook check marks recipes known without the window")

section("vendor")
stub.merchant = {
  { itemID = 3371, price = 20, stackCount = 1, numAvailable = -1, hasExtendedCost = false },
  { itemID = 12359, price = 5000, stackCount = 5, numAvailable = 2, hasExtendedCost = false },
  { itemID = 765, price = 100, stackCount = 5, numAvailable = -1, hasExtendedCost = false },
}
stub.fire("MERCHANT_SHOW")
check(LiteFlipperDB.vendorPrices["3371"] == 20, "unlimited vendor price recorded")
check(LiteFlipperDB.vendorPrices["12359"] == nil, "limited stock ignored")
check(LiteFlipperDB.vendorPrices["765"] == 20, "stack price divided per unit")

section("bags")
stub.bags[0] = { { itemID = 12360, stackCount = 3 }, { itemID = 765, stackCount = 20, isBound = true }, {} }
stub.bags[1] = { { itemID = 12360, stackCount = 2 }, { itemID = 9999999, stackCount = 1 } }
slash("bags")
check(LF.bagFrame:IsShown(), "bag window shown")
check(LF.bagFrame.bagRows[1].itemId == 12360 and LF.bagFrame.bagRows[1].count == 5, "stacks combined, most valuable first")
local bagRow = LF.bagFrame.rows[1]
bagRow:GetScript("OnEnter")(bagRow)
bagRow:GetScript("OnClick")(bagRow, "LeftButton")
check(stub.modifiedClick ~= nil, "bag row click handled through the modern click helper")

section("chat lookups")
slash("price arcanite")
check(lastChat("Arcanite Bar.*market"), "price lookup: " .. tostring(lastChat("market")))
slash("trend arcanite bar")
check(lastChat("over %d+d, volatility"), "trend lookup printed")
slash("price 12360")
slash("purge 1")
slash("help")
slash("nonsense")
check(lastChat("Unknown command"), "unknown command handled")

section("history window")
local rows = LF:GetPriceHistoryRows(12360)
check(#rows == 4, "4 days of rows: " .. #rows)
check(rows[1].age == 0 and rows[1].low == 339900 and rows[1].high == 342000 and rows[1].available == 80,
  "today's row carries Auctionator's low/high/available")
check(rows[1].source == "Auctionator" and rows[4].age == 4, "sorted newest first")
check(rows[1].change ~= nil and math.abs(rows[1].change - ((339900 - 350000) / 350000)) < 1e-9, "day-over-day change")
local ownOnly = LF:GetPriceHistoryRows(12359)
check(#ownOnly == 1 and ownOnly[1].source == "LiteFlipper" and ownOnly[1].low == 9000,
  "items Auctionator has no history for use LiteFlipper's own records")
slash("history arcanite bar")
check(LF.historyFrame:IsShown() and LF.historyFrame.itemId == 12360, "/lf history opens the window")
do
  -- Each price is split into gold / silver / copper texts so a coin type sits
  -- at the same position on every row.
  local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
  local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
  local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
  local function parts(copper)
    return table.concat({ LF:FormatMoneyParts(copper) }, "/")
  end
  check(parts(335352) == "33" .. GOLD .. "/53" .. SILVER .. "/52" .. COPPER, "money parts: gold, silver and copper")
  check(parts(350099) == "35" .. GOLD .. "/0" .. SILVER .. "/99" .. COPPER, "money parts: zero silver shows as 0")
  check(parts(395000) == "39" .. GOLD .. "/50" .. SILVER .. "/0" .. COPPER, "money parts: zero copper shows as 0")
  check(parts(350000) == "35" .. GOLD .. "/0" .. SILVER .. "/0" .. COPPER, "money parts: round gold shows 0 silver and 0 copper")
  check(parts(500) == "/5" .. SILVER .. "/0" .. COPPER, "money parts: no gold shown below 1g, copper still shown")
  check(parts(75) == "//75" .. COPPER, "money parts: copper only")
  check(parts(0) == "//0" .. COPPER, "money parts: zero shows as 0 copper")
  check(parts(nil) == "//-", "money parts: unknown price")
  check(parts(12345678):find("^1,?234|T") ~= nil, "money parts: large gold amount")
  check(LF:FormatMoneyIcons(350000) == "35" .. GOLD .. " 0" .. SILVER .. " 0" .. COPPER, "one-line price shows zero coin types too")
  check(LF:FormatMoneyIcons(75) == "75" .. COPPER and LF:FormatMoneyIcons(nil) == "-", "one-line price: copper only, and unknown")

  local first = LF.historyFrame.rows[1]
  check(first.money.low.gold:GetText() == "33" .. GOLD and first.money.low.silver:GetText() == "99" .. SILVER
    and first.money.low.copper:GetText() == "0" .. COPPER, "low price rendered per coin type")
  check(first.money.high.gold:GetText() == "34" .. GOLD and first.money.high.silver:GetText() == "20" .. SILVER
    and first.money.high.copper:GetText() == "0" .. COPPER, "high price rendered per coin type")
  local lowestSeen
  for _, historyRow in ipairs(rows) do
    if historyRow.low and (not lowestSeen or historyRow.low < lowestSeen) then
      lowestSeen = historyRow.low
    end
  end
  check(lowestSeen == 310000 and LF.historyFrame.summary3:GetText():find(
    "Lowest: |cffffffff31" .. GOLD .. " 0" .. SILVER .. " 0" .. COPPER, 1, true) ~= nil,
    "summary line uses the same price format: " .. tostring(LF.historyFrame.summary3:GetText()))

  -- Same coin type, same anchor, on every row and at a different place per type.
  local function anchorX(piece)
    local point = piece.__points[#piece.__points]
    return point[1] == "RIGHT" and point[4]
  end
  local second = LF.historyFrame.rows[2]
  local aligned = true
  for _, key in ipairs({ "low", "high" }) do
    for _, kind in ipairs({ "gold", "silver", "copper" }) do
      if not anchorX(first.money[key][kind]) or anchorX(first.money[key][kind]) ~= anchorX(second.money[key][kind]) then
        aligned = false
      end
    end
  end
  check(aligned, "coin types share a position across rows")
  check(anchorX(first.money.low.gold) < anchorX(first.money.low.silver)
    and anchorX(first.money.low.silver) < anchorX(first.money.low.copper)
    and anchorX(first.money.low.copper) < anchorX(first.money.high.gold), "gold, silver, copper run left to right")
end
check(LF.historyFrame.rows[5]:IsShown() == false, "unused rows hidden")
check(LF.historyFrame.summary3:GetText():find("4 day"), "summary counts the days")
slash("history zzzz")
check(lastChat("No items match 'zzzz'"), "unknown item reported")
LF.historyFrame:Hide()
slash("history")
check(lastChat("Usage: /lf history"), "no argument and no buy panel prints usage")
local found = false
for _, name in ipairs(UISpecialFrames) do if name == "LiteFlipperHistoryFrame" then found = true end end
check(found, "Escape closes the history window")

section("history button on Auctionator's buy panels")
local commodityPanel = CreateFrame("Frame", "AuctionatorBuyCommodityFrame")
commodityPanel.DetailsContainer = stub.newWidget("Frame", nil, commodityPanel)
local itemPanel = CreateFrame("Frame", "AuctionatorBuyItemFrame")
itemPanel.BackButton = stub.newWidget("Button", nil, itemPanel)
itemPanel.__shown = false
stub.fire("AUCTION_HOUSE_SHOW")
local buttons = {}
for _, frame in ipairs(stub.frames) do
  if frame.__kind == "Button" and frame:GetText() == "History" then buttons[frame:GetParent()] = frame end
end
check(buttons[commodityPanel] ~= nil, "button added to the commodity buy panel")
check(buttons[itemPanel] ~= nil, "button added to the item buy panel")
check(buttons[commodityPanel].__points[1][1] == "BOTTOM" and buttons[commodityPanel].__points[1][2] == commodityPanel.DetailsContainer,
  "anchored under Buy Now, left of the listings")
check(buttons[itemPanel].__points[1][2] == itemPanel.BackButton, "anchored beside Back on the item panel")
stub.fire("AUCTION_HOUSE_SHOW")
local count = 0
for _, frame in ipairs(stub.frames) do
  if frame.__kind == "Button" and frame:GetText() == "History" then count = count + 1 end
end
check(count == 2, "reopening the auction house does not duplicate buttons")

buttons[commodityPanel]:Click()
check(lastChat("Open an item in the buy panel first"), "clicking with nothing selected explains itself")
auctionator.EventBus:Fire(nil, auctionator.Buying.Events.ShowCommodityBuy,
  { itemKey = { itemID = 12360, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } },
  { itemName = "Arcanite Bar", quality = 1, iconFileID = 134400 })
buttons[commodityPanel]:Click()
check(LF.historyFrame:IsShown() and LF.historyFrame.itemId == 12360, "button opens Arcanite Bar's history")
check(LF.historyFrame.__points[1] and LF.historyFrame.__points[1][2] == AuctionHouseFrame, "window placed beside the auction house")
auctionator.EventBus:Fire(nil, auctionator.Buying.Events.ShowCommodityBuy,
  { itemKey = { itemID = 12359, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } },
  { itemName = "Thorium Bar", quality = 1, iconFileID = 134400 })
check(LF.historyFrame.itemId == 12359, "open window follows the next item you look at")
buttons[commodityPanel]:Click()
check(not LF.historyFrame:IsShown(), "clicking again closes it")
-- panel that only holds its item key (no event seen)
itemPanel.__shown = true
itemPanel.expectedItemKey = { itemID = 777, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
buttons[itemPanel]:Click()
check(LF.historyFrame:IsShown() and LF.historyFrame.itemId == 777, "falls back to the panel's own item key")
stub.fire("AUCTION_HOUSE_CLOSED")
check(not LF.historyFrame:IsShown(), "closes with the auction house")
local _, liveAfterClose = LF:CaptureCurrentAuctions()
check(liveAfterClose == 0, "live rows cleared on close")

section("replicate (every-auction) scan")
local replicate = {}
for index = 1, 150 do
  local info = {}
  info[1], info[2], info[3], info[4], info[10], info[14], info[17] =
    "Arcanite Bar", 134400, 5, 1, 5 * (340000 + index), "Seller" .. (index % 7), 12360
  replicate[#replicate + 1] = { replicateInfo = info, itemLink = select(2, C_Item.GetItemInfo(12360)), timeLeft = 3 }
end
stub.now = stub.now + 600
auctionator.EventBus:Fire(nil, auctionator.FullScan.Events.ScanComplete, replicate)
stub.runFrames(20)
check(#LF.lastScan.auctions == 150 and not LF.lastScan.summary, "replicate scan saved as individual auctions")
check(LF:GetLatestScanMinPrice(12360) == 340001, "unit price derived from stack buyout")
slash("scan")
check(LF.resultsFrame:IsShown(), "deals window still works on replicate data")

section("without Auctionator")
Auctionator = nil
LF:InvalidateAuctionatorCaches()
check(LF:GetAuctionatorPrice(12360) == nil, "no price, no error")
check(LF:GetAuctionatorHistory(12360) == nil, "no history, no error")
check(#LF:GetPriceHistoryRows(12360) >= 1, "history rows still come from LiteFlipper's own data")
LF:ShowPriceHistory(12360)
check(LF.historyFrame:IsShown(), "history window works without Auctionator")

print("")
if failures > 0 then
  error(failures .. " check(s) failed", 0)
end
print("ALL CHECKS PASSED")
