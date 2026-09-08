local ADDON_NAME, ns = ...

local LF = {}
ns.LF = LF

LF.name = ADDON_NAME
LF.version = "0.1.0"

local DEFAULTS = {
  daysToAverage = 7,
  dealThreshold = 0.80,
  dealMinThreshold = 0,
  minProfitCopper = 10000,
  scanMinSupplyUnits = 5,
  resultsPageSize = 14,
  supplyTrendThreshold = 0.20,
  nearDailyLowThreshold = 0.10,
  tooltip = true,
  debug = false,
  historyByScope = {},
  lastScans = {},
  craftRecipes = {},
  vendorPrices = {},
}

local function CopyDefaults(target, defaults)
  for key, value in pairs(defaults) do
    if target[key] == nil then
      if type(value) == "table" then
        target[key] = {}
        CopyDefaults(target[key], value)
      else
        target[key] = value
      end
    elseif type(value) == "table" and type(target[key]) == "table" then
      CopyDefaults(target[key], value)
    end
  end
end

function LF:Print(message)
  DEFAULT_CHAT_FRAME:AddMessage("|cff4fb3ffLiteFlipper|r: " .. tostring(message))
end

function LF:Debug(message)
  if self.db and self.db.debug then
    self:Print("|cffaaaaaa" .. tostring(message) .. "|r")
  end
end

function LF:FormatMoney(copper)
  copper = tonumber(copper)
  if not copper or copper < 0 then
    return "-"
  end
  if copper == 0 then
    return "0c"
  end

  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local copperOnly = copper % 100

  if gold > 0 then
    return string.format("%dg %02ds %02dc", gold, silver, copperOnly)
  elseif silver > 0 then
    return string.format("%ds %02dc", silver, copperOnly)
  end

  return string.format("%dc", copperOnly)
end

function LF:GetItemKey(itemLinkOrId)
  if not itemLinkOrId then
    return nil
  end

  if type(itemLinkOrId) == "number" then
    return tostring(itemLinkOrId)
  end

  local itemId = string.match(itemLinkOrId, "item:(%d+)")
  if itemId then
    return itemId
  end

  if tonumber(itemLinkOrId) then
    return tostring(itemLinkOrId)
  end

  return nil
end

local function NormalizeRealmName(realm)
  return (string.gsub(tostring(realm), "[%s%-']", ""))
end

function LF:GetMarketScopeKey()
  if self.marketScopeKey then
    return self.marketScopeKey
  end

  local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
    or (GetRealmName and GetRealmName())
  local localizedFaction, englishFaction
  if UnitFactionGroup then
    localizedFaction, englishFaction = UnitFactionGroup("player")
  end
  local faction = englishFaction or localizedFaction

  if not realm or realm == "" or not faction then
    return nil
  end

  self.marketScopeKey = NormalizeRealmName(realm) .. "::" .. tostring(faction)
  return self.marketScopeKey
end

function LF:GetHistory()
  if not self.db then
    return {}
  end

  local scopeKey = self:GetMarketScopeKey()
  if not scopeKey then
    self.transientHistory = self.transientHistory or {}
    return self.transientHistory
  end

  self.db.historyByScope = self.db.historyByScope or {}
  self.db.historyByScope[scopeKey] = self.db.historyByScope[scopeKey] or {}
  return self.db.historyByScope[scopeKey]
end

function LF:MigrateDatabase()
  local scopeKey = self:GetMarketScopeKey()
  if not self.db or not scopeKey then
    return
  end

  -- Re-key snapshots saved before realm names were normalized, so data written
  -- on a fresh login (localized realm name) is found again after a reload.
  self.db.lastScans = self.db.lastScans or {}
  for key, scan in pairs(self.db.lastScans) do
    local realm, faction = string.match(key, "^(.-)::(.*)$")
    if realm and faction then
      local normalizedKey = NormalizeRealmName(realm) .. "::" .. faction
      if normalizedKey ~= key then
        local existing = self.db.lastScans[normalizedKey]
        if not existing or (scan.scannedAt or 0) > (existing.scannedAt or 0) then
          self.db.lastScans[normalizedKey] = scan
        end
        self.db.lastScans[key] = nil
      end
    end
  end

  -- Move the old account-wide history under this realm/faction.
  self.db.historyByScope = self.db.historyByScope or {}
  if type(self.db.history) == "table" then
    if next(self.db.history) and not self.db.historyByScope[scopeKey] then
      self.db.historyByScope[scopeKey] = self.db.history
    end
    self.db.history = nil
  end

  -- Fold any history recorded before the scope key was known into this scope.
  if self.transientHistory and next(self.transientHistory) then
    local history = self:GetHistory()
    for itemKey, itemHistory in pairs(self.transientHistory) do
      history[itemKey] = history[itemKey] or itemHistory
    end
    self.transientHistory = nil
  end
end

function LF:RestoreLastScan()
  if not self.db then
    return
  end

  local scopeKey = self:GetMarketScopeKey()
  if not scopeKey then
    return
  end

  self.db.lastScans = self.db.lastScans or {}

  local savedScan = self.db.lastScans[scopeKey]
  if type(savedScan) == "table" and type(savedScan.auctions) == "table" and #savedScan.auctions > 0 then
    self.lastScan = savedScan
    if #savedScan.auctions >= 100 and self.BuildLastScanIndexAsync then
      self:BuildLastScanIndexAsync()
    else
      self:BuildLastScanIndex()
    end
    self:Debug("Restored last scan for " .. scopeKey .. ".")
  end
end

function LF:BuildLastScanIndex()
  self.lastScanMinPrices = {}

  if not self.lastScan or type(self.lastScan.auctions) ~= "table" then
    return
  end

  for _, auction in ipairs(self.lastScan.auctions) do
    local itemKey = auction.itemId or self:GetItemKey(auction.itemLink)
    local unitBuyout = auction.unitBuyout
    if itemKey and unitBuyout and unitBuyout > 0 then
      itemKey = tostring(itemKey)
      self.lastScanMinPrices[itemKey] = self.lastScanMinPrices[itemKey]
        and math.min(self.lastScanMinPrices[itemKey], unitBuyout)
        or unitBuyout
    end
  end
end

function LF:SaveLastScan()
  if not self.db or not self.lastScan or not self.lastScan.auctions then
    return
  end

  if #self.lastScan.auctions >= 100 and self.BuildLastScanIndexAsync then
    self:BuildLastScanIndexAsync()
  else
    self:BuildLastScanIndex()
  end

  local scopeKey = self:GetMarketScopeKey()
  if not scopeKey then
    return
  end

  self.db.lastScans = self.db.lastScans or {}
  self.db.lastScans[scopeKey] = self.lastScan
end

function LF:FormatAge(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 60 then
    return math.floor(seconds) .. "s"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local function ReadToggleValue(value)
  value = string.lower(value or "")
  if value == "on" or value == "enable" or value == "enabled" or value == "1" or value == "true" then
    return true
  elseif value == "off" or value == "disable" or value == "disabled" or value == "0" or value == "false" then
    return false
  elseif value == "" then
    return nil
  end

  return "invalid"
end

local PROFESSION_SHORTCUTS = {
  alch = "alchemy",
  eng = "engineering",
  ench = "enchanting",
  bs = "blacksmithing",
  lw = "leatherworking",
  tailor = "tailoring",
}

function LF:ApplySettings(args)
  local command, value = string.match(args or "", "^(%S*)%s*(.-)%s*$")
  command = string.lower(command or "")

  if PROFESSION_SHORTCUTS[command] then
    self:CraftScan(PROFESSION_SHORTCUTS[command])
  elseif command == "threshold" then
    local number = tonumber(value)
    if not number then
      self:Print("Usage: /lf threshold 80")
      return
    end
    if number > 1 then
      number = number / 100
    end
    self.db.dealThreshold = math.max(0.01, math.min(1, number))
    self:Print("Deal threshold set to " .. math.floor(self.db.dealThreshold * 100 + 0.5) .. "% of market.")
    self:RescoreLastScan()
  elseif command == "minthreshold" then
    local number = tonumber(value)
    if not number then
      self:Print("Usage: /lf minthreshold 10 - ignore auctions below 10% of market (0 disables)")
      return
    end
    if number > 1 then
      number = number / 100
    end
    self.db.dealMinThreshold = math.max(0, math.min(1, number))
    if self.db.dealMinThreshold == 0 then
      self:Print("Minimum deal threshold disabled.")
    else
      self:Print("Deals must be at least " .. math.floor(self.db.dealMinThreshold * 100 + 0.5) .. "% of market.")
      if self.db.dealMinThreshold >= (self.db.dealThreshold or 0.8) then
        self:Print("Warning: the minimum is at or above the deal threshold of "
          .. math.floor((self.db.dealThreshold or 0.8) * 100 + 0.5)
          .. "%, so no deals will match.")
      end
    end
    self:RescoreLastScan()
  elseif command == "profit" then
    local gold = tonumber(value)
    if not gold then
      self:Print("Usage: /lf profit 1")
      return
    end
    self.db.minProfitCopper = math.max(0, math.floor(gold * 10000))
    self:Print("Minimum profit set to " .. self:FormatMoney(self.db.minProfitCopper) .. ".")
    self:RescoreLastScan()
  elseif command == "supply" then
    local units = tonumber(value)
    if not units then
      self:Print("Usage: /lf supply 5")
      return
    end
    self.db.scanMinSupplyUnits = math.max(0, math.floor(units))
    if self.db.scanMinSupplyUnits == 0 then
      self:Print("Visible supply filter disabled.")
    else
      self:Print("Visible supply filter set to at least " .. self.db.scanMinSupplyUnits .. " unit(s).")
    end
    self:RescoreLastScan()
  elseif command == "purge" then
    local hours = tonumber(value)
    if not hours or hours <= 0 then
      self:Print("Usage: /lf purge 3 - delete market history older than 3 hours (this realm/faction only)")
      return
    end
    local removedSamples, clearedItems = self:PurgeHistoryBefore(time() - hours * 3600)
    self:Print("Purged " .. removedSamples .. " scan sample(s) older than " .. self:FormatAge(hours * 3600)
      .. "; " .. clearedItems .. " item(s) now have no history.")
    self:RescoreLastScan()
  elseif command == "tooltip" or command == "hovertooltip" or command == "itemtooltip" then
    local setting = ReadToggleValue(value)
    if setting == "invalid" then
      self:Print("Usage: /lf hovertooltip [on|off]")
      return
    end
    if setting == nil then
      self.db.tooltip = not self.db.tooltip
    else
      self.db.tooltip = setting
    end
    self:Print("Item-hover market and trend lines " .. (self.db.tooltip and "enabled." or "disabled.")
      .. " LiteFlipper window tooltips still show.")
  elseif command == "debug" then
    self.db.debug = not self.db.debug
    self:Print("Debug " .. (self.db.debug and "enabled." or "disabled."))
  elseif command == "price" or command == "search" or command == "value" then
    self:PriceLookup(value)
  elseif command == "trend" or command == "history" then
    self:TrendLookup(value)
  elseif command == "bags" or command == "bag" then
    self:BagScan()
  elseif command == "browse" then
    self:BrowseAuctionHouse(value)
  elseif command == "uses" or command == "mat" or command == "mats" then
    self:UsesLookup(value)
  elseif command == "craft" then
    self:CraftScan(value)
  elseif command == "tree" or command == "plan" then
    self:CraftTreeLookup(value)
  elseif command == "scan" or command == "" then
    if value ~= "" then
      -- "/lf scan alchemy" reads as a crafting scan, so route it there.
      self:CraftScan(value)
    else
      self:ScanAuctionHouse()
    end
  elseif command == "help" then
    self:Print("/lf scan - find deals in current auction results, or show the saved scan if no current rows are available")
    self:Print("/lf browse - show auction rows without threshold, profit, or supply filters")
    self:Print("/lf craft alchemy - rank recorded alchemy recipes by crafting profit (also /lf scan alchemy)")
    self:Print("/lf alch | eng | ench | bs | lw | tailor - open that profession's crafting results")
    self:Print("/lf craft - list professions with recorded recipes")
    self:Print("/lf price silk - look up saved prices, trend, and historical low/high for matching items")
    self:Print("/lf trend silk - price trend, volatility, low/high, and day-by-day history from Auctionator's price database")
    self:Print("/lf bags - value the sellable items in your bags")
    self:Print("/lf uses briarthorn - show crafts that use a material and their margins")
    self:Print("/lf tree copper tube - open the buy-vs-craft material tree planner")
    self:Print("/lf threshold 80 - flag auctions below 80% of market")
    self:Print("/lf minthreshold 10 - ignore auctions below 10% of market (0 disables)")
    self:Print("/lf profit 1 - require at least 1g estimated profit")
    self:Print("/lf supply 5 - require at least 5 visible units in the scan, or 0 to disable")
    self:Print("/lf purge 3 - delete market history older than 3 hours (this realm/faction only)")
    self:Print("/lf hovertooltip - toggle LiteFlipper market/trend lines on item hover tooltips (also /lf tooltip)")
    self:Print("/lf hovertooltip on|off - explicitly show or hide those item-hover lines")
  else
    self:Print("Unknown command. Try /lf help.")
  end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, addonName)
  if event == "PLAYER_LOGIN" then
    -- Realm and faction are reliable here, unlike at ADDON_LOADED, so this is
    -- the earliest point the realm::faction scope key is stable.
    if LF.db then
      LF:MigrateDatabase()
      LF:PruneHistory()
      LF:RestoreLastScan()
    end
    return
  end

  if event ~= "ADDON_LOADED" then
    return
  end

  if addonName == "Auctionator" and LF.db and LF.InstallAuctionatorScanListener then
    LF:InstallAuctionatorScanListener()
    return
  end

  if addonName ~= ADDON_NAME then
    return
  end

  LiteFlipperDB = LiteFlipperDB or {}
  CopyDefaults(LiteFlipperDB, DEFAULTS)
  LF.db = LiteFlipperDB

  LF:InstallTooltip()
  LF:CreateResultsFrame()
  LF:CreateCraftFrame()
  if LF.CreateCraftTreeFrame then
    LF:CreateCraftTreeFrame()
  end
  LF:CreateBagFrame()
  if LF.InstallAuctionatorScanListener then
    LF:InstallAuctionatorScanListener()
  end

  SLASH_LITEFLIPPER1 = "/lf"
  SLASH_LITEFLIPPER2 = "/liteflipper"
  SlashCmdList.LITEFLIPPER = function(args)
    LF:ApplySettings(args)
  end

  LF:Print("Loaded. Use /lf scan after an Auctionator or auction house search.")
end)
