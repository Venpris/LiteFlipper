-- Minimal stand-in for the WoW Forever client so LiteFlipper's files can be loaded and
-- exercised offline (see dev/test_forever.lua). It deliberately defines only the modern
-- API: the Classic Era globals (GetItemInfo, GetAuctionItemInfo, ChatEdit_*, ...) are
-- absent, so any code path that still calls one fails the test.
local stub = {}

io.stdout:setvbuf("no")

local widgetMeta
local function newWidget(kind, name, parent, template)
  local w = setmetatable({
    __kind = kind, __name = name, __scripts = {}, __shown = true,
    __parent = parent, __template = template, __points = {}, __lines = {},
  }, widgetMeta)
  if template == "BasicFrameTemplateWithInset" then
    rawset(w, "TitleBg", newWidget("Texture", nil, w))
  end
  return w
end
stub.newWidget = newWidget

local methods = {}
function methods:SetScript(event, fn) self.__scripts[event] = fn end
function methods:GetScript(event) return self.__scripts[event] end
function methods:HookScript(event, fn) self.__scripts[event] = fn end
function methods:HasScript() return false end
function methods:Show() self.__shown = true; local f = self.__scripts.OnShow; if f then f(self) end end
function methods:Hide() self.__shown = false; local f = self.__scripts.OnHide; if f then f(self) end end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self.__shown end
function methods:IsVisible() return self.__shown end
function methods:SetText(t) self.__text = t end
function methods:GetText() return self.__text or "" end
function methods:SetPoint(...) self.__points[#self.__points + 1] = { ... } end
function methods:ClearAllPoints() self.__points = {} end
function methods:GetParent() return self.__parent end
function methods:GetName() return self.__name end
function methods:SetSize(w, h) self.__w, self.__h = w, h end
function methods:SetWidth(w) self.__w = w end
function methods:SetHeight(h) self.__h = h end
function methods:CreateFontString() return newWidget("FontString", nil, self) end
function methods:CreateTexture() return newWidget("Texture", nil, self) end
function methods:RegisterEvent(event)
  stub.events[event] = stub.events[event] or {}
  table.insert(stub.events[event], self)
  return true
end
function methods:SetVerticalScroll(v)
  self.__scroll = v
  local f = self.__scripts.OnVerticalScroll
  if f then f(self, v) end
end
function methods:GetVerticalScroll() return self.__scroll or 0 end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:IsEnabled() return self.__enabled ~= false end
function methods:Click(button)
  local f = self.__scripts.OnClick
  if f then f(self, button or "LeftButton") end
end
-- tooltip-ish
function methods:SetOwner() self.__lines = {} end
function methods:ClearLines() self.__lines = {} end
function methods:AddLine(text) self.__lines[#self.__lines + 1] = tostring(text) end
function methods:AddDoubleLine(left, right)
  self.__lines[#self.__lines + 1] = tostring(left) .. " = " .. tostring(right)
end
function methods:SetHyperlink(link) self.__hyperlink = link; self.__lines[#self.__lines + 1] = "<" .. tostring(link) .. ">" end
function methods:NumLines() return #self.__lines end

widgetMeta = {
  __index = function(_, key)
    local m = methods[key]
    if m then return m end
    if type(key) == "string" and key:match("^[A-Z]") then
      -- any other widget method: accept and ignore
      return function() return nil end
    end
    return nil
  end,
}

stub.events = {}
stub.frames = {}
stub.timers = {}
stub.chat = {}

function CreateFrame(kind, name, parent, template)
  local w = newWidget(kind, name, parent, template)
  stub.frames[#stub.frames + 1] = w
  if name then _G[name] = w end
  return w
end

UIParent = newWidget("Frame", "UIParent")
GameTooltip = newWidget("GameTooltip", "GameTooltip")
ItemRefTooltip = newWidget("GameTooltip", "ItemRefTooltip")
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) stub.chat[#stub.chat + 1] = msg end }
UISpecialFrames = {}
SlashCmdList = {}
NUM_BAG_SLOTS = 4
ITEM_QUALITY_COLORS = {
  [0] = { hex = "|cff9d9d9d" }, [1] = { hex = "|cffffffff" }, [2] = { hex = "|cff1eff00" },
}

C_Timer = { After = function(_, fn) stub.timers[#stub.timers + 1] = fn end }
function stub.runTimers()
  local guard = 0
  while #stub.timers > 0 and guard < 5000 do
    guard = guard + 1
    table.remove(stub.timers, 1)()
  end
end

-- Runs OnUpdate handlers, as the client does once per rendered frame.
function stub.runFrames(count)
  for _ = 1, count or 1 do
    for _, frame in ipairs(stub.frames) do
      local f = frame.__scripts.OnUpdate
      if f then f(frame, 0.016) end
    end
  end
end

function stub.fire(event, ...)
  local fired = 0
  for _, frame in ipairs(stub.events[event] or {}) do
    local f = frame.__scripts.OnEvent
    if f then
      f(frame, event, ...)
      fired = fired + 1
    end
  end
  return fired
end

stub.now = os.time()
function time(t) if t then return os.time(t) end return stub.now end
date = os.date
function debugprofilestop() return os.clock() * 1000 end
function GetMoneyString(copper) return tostring(copper) .. "c" end
function UnitFactionGroup() return "Alliance", "Alliance" end
function UnitName() return "Tester" end
function GetNormalizedRealmName() return "91" end
function GetRealmName() return "91" end
function RegionalUniqueNamesEnabled() return true end
function IsModifiedClick() return false end
function HandleModifiedItemClick(link) stub.modifiedClick = link; return true end

stub.rules = {}
Enum = {
  GameRule = { PvPRuleset = 1, RPRuleset = 2, HardcoreRuleset = 3 },
  TooltipDataType = { Item = 0, Spell = 1 },
  SpellBookSpellBank = { Player = 0 },
  CraftingReagentType = { Modifying = 0, Basic = 1 },
}
C_GameRules = { IsGameRuleActive = function(rule) return stub.rules[rule] or false end }

ChatFrameUtil = {
  GetActiveWindow = function() return stub.chatEditOpen and {} or nil end,
  InsertLink = function(link) stub.insertedLink = link; return true end,
}

-- Items: stub.items[id] = { name =, sell = }
stub.items = {}
stub.requested = {}
C_Item = {
  GetItemNameByID = function(id) local it = stub.items[id]; return it and it.name or nil end,
  GetItemIconByID = function() return 134400 end,
  GetItemQualityByID = function() return 1 end,
  GetItemInfo = function(item)
    local id = tonumber(item) or (type(item) == "string" and tonumber(item:match("item:(%d+)")))
    if not id and type(item) == "string" then
      for itemId, it in pairs(stub.items) do
        if it.name:lower() == item:lower() then id = itemId end
      end
    end
    local it = id and stub.items[id]
    if not it then return nil end
    return it.name, "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[" .. it.name .. "]|h|r", 1, 1, 1,
      "Type", "Sub", 20, "", 134400, it.sell or 0
  end,
  RequestLoadItemDataByID = function(id) stub.requested[id] = true end,
}

stub.known = {}
C_SpellBook = { IsSpellKnown = function(spell) return stub.known[spell] or false end }

-- Bags: stub.bags[bag][slot] = { itemID =, stackCount =, isBound = }
stub.bags = {}
C_Container = {
  GetContainerNumSlots = function(bag) return stub.bags[bag] and #stub.bags[bag] or 0 end,
  GetContainerItemInfo = function(bag, slot)
    local it = stub.bags[bag] and stub.bags[bag][slot]
    if not it or not it.itemID then return nil end
    local _, link = C_Item.GetItemInfo(it.itemID)
    return { itemID = it.itemID, stackCount = it.stackCount, hyperlink = link, isBound = it.isBound }
  end,
}

-- Auction house result sets
stub.browse = {}
stub.commodities = {}   -- [itemID] = { { unitPrice =, quantity =, owners = {} }, ... }
stub.itemListings = {}  -- [itemID] = { { buyoutAmount =, quantity =, owners = {} }, ... }
C_AuctionHouse = {
  GetBrowseResults = function() return stub.browse end,
  GetItemKeyInfo = function(itemKey)
    local it = stub.items[itemKey.itemID]
    if not it then return nil end
    return { itemID = itemKey.itemID, itemName = it.name, quality = 1, iconFileID = 134400 }
  end,
  GetNumCommoditySearchResults = function(id) return #(stub.commodities[id] or {}) end,
  GetCommoditySearchResultInfo = function(id, index) return stub.commodities[id][index] end,
  GetNumItemSearchResults = function(key) return #(stub.itemListings[key.itemID] or {}) end,
  GetItemSearchResultInfo = function(key, index) return stub.itemListings[key.itemID][index] end,
}
AuctionHouseFrame = newWidget("Frame", "AuctionHouseFrame")
AuctionHouseFrame.__shown = false

-- Professions and vendors
stub.recipes = {}   -- [spell] = { learned =, schematic = }
C_TradeSkillUI = {
  GetRecipeInfo = function(spell)
    local r = stub.recipes[spell]
    if not r then return nil end
    return { recipeID = spell, learned = r.learned }
  end,
  GetRecipeSchematic = function(spell) local r = stub.recipes[spell]; return r and r.schematic or nil end,
  GetBaseProfessionInfo = function() return { professionName = stub.openProfession or "Alchemy" } end,
  IsNPCCrafting = function() return false end,
}
stub.merchant = {}
function GetMerchantNumItems() return #stub.merchant end
function GetMerchantItemID(index) return stub.merchant[index].itemID end
C_MerchantFrame = { GetItemInfo = function(index) return stub.merchant[index] end }

-- Tooltip post-processing hook
stub.tooltipCalls = {}
TooltipDataProcessor = {
  AddTooltipPostCall = function(dataType, fn)
    stub.tooltipCalls[#stub.tooltipCalls + 1] = { dataType = dataType, fn = fn }
  end,
}
TooltipUtil = { GetDisplayedItem = function(tooltip) return tooltip.__itemName, tooltip.__itemLink end }

function FauxScrollFrame_Update(frame, numItems) frame.__numItems = numItems end
function FauxScrollFrame_GetOffset(frame) return frame.__offset or 0 end
function FauxScrollFrame_SetOffset(frame, offset) frame.__offset = offset end
function FauxScrollFrame_OnVerticalScroll(frame, value, itemHeight, fn)
  frame.__offset = math.floor(value / itemHeight + 0.5)
  if fn then fn(frame) end
end

-- A double of the parts of Auctionator that LiteFlipper talks to.
function stub.installAuctionator()
  local bus = { listeners = {} }
  function bus:Register(listener, eventNames)
    assert(listener.ReceiveEvent, "listener needs ReceiveEvent")
    for _, eventName in ipairs(eventNames) do
      self.listeners[eventName] = self.listeners[eventName] or {}
      table.insert(self.listeners[eventName], listener)
    end
    return self
  end
  function bus:Fire(_, eventName, ...)
    for _, listener in ipairs(self.listeners[eventName] or {}) do
      listener:ReceiveEvent(eventName, ...)
    end
    return self
  end

  local dayZero = os.time({ year = 2020, month = 1, day = 1, hour = 0 })
  stub.ahPrices = {}
  stub.ahAges = {}
  Auctionator = {
    EventBus = bus,
    Constants = { SCAN_DAY_0 = dayZero },
    Database = { db = {} },
    IncrementalScan = { Events = {
      ScanStart = "inc start", ScanComplete = "inc complete", ScanFailed = "inc failed",
      PricesProcessed = "inc processed",
    } },
    FullScan = { Events = { ScanStart = "rep start", ScanComplete = "rep complete", ScanFailed = "rep failed" } },
    Buying = { Events = { ShowCommodityBuy = "buy commodity", ShowItemBuy = "buy item" } },
    Utilities = {
      DBKeyFromItemKey = function(itemKey, callback) callback({ tostring(itemKey.itemID) }) end,
    },
    API = { v1 = {
      GetAuctionPriceByItemID = function(caller, id)
        assert(type(caller) == "string" and caller ~= "", "callerID")
        assert(type(id) == "number", "itemID must be a number")
        return stub.ahPrices[id]
      end,
      GetAuctionPriceByItemLink = function(caller, link)
        assert(type(caller) == "string" and type(link) == "string")
        return stub.ahPrices[tonumber(link:match("item:(%d+)"))]
      end,
      GetAuctionAgeByItemID = function(_, id) return stub.ahAges[id] end,
      MultiSearchExact = function(caller, terms) stub.search = terms end,
    } },
  }
  return Auctionator
end

--- Loads the addon's files in TOC order and returns its private namespace.
function stub.loadAddon(dir, name)
  local ns = {}
  local toc = assert(io.open(dir .. "/" .. name .. ".toc", "r"))
  local files = {}
  for line in toc:lines() do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
      files[#files + 1] = (line:gsub("\\", "/"))
    end
  end
  toc:close()
  for _, file in ipairs(files) do
    local chunk, err = loadfile(dir .. "/" .. file)
    if not chunk then error("load " .. file .. ": " .. tostring(err), 0) end
    local ok, runErr = xpcall(function() chunk(name, ns) end, debug.traceback)
    if not ok then error("run " .. file .. ": " .. tostring(runErr), 0) end
  end
  stub.files = files
  return ns
end

return stub
