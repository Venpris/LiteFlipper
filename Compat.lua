local _, ns = ...
local LF = ns.LF

-- The WoW Forever client is built on the modern API: the old global item,
-- merchant and chat helpers that the Classic Era version of LiteFlipper used
-- are gone. Everything client-specific goes through the wrappers in this file,
-- which prefer the modern namespaced call and fall back to the old global.

local QUESTION_MARK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- name, link, quality, itemLevel, minLevel, type, subType, stackCount,
-- equipLoc, texture, sellPrice, ...
function LF:GetItemInfo(item)
  if item == nil then
    return nil
  end
  if C_Item and C_Item.GetItemInfo then
    return C_Item.GetItemInfo(item)
  end
  if GetItemInfo then
    return GetItemInfo(item)
  end
  return nil
end

function LF:GetItemIcon(itemId)
  local icon
  if itemId then
    if C_Item and C_Item.GetItemIconByID then
      icon = C_Item.GetItemIconByID(itemId)
    elseif GetItemIcon then
      icon = GetItemIcon(itemId)
    end
  end
  return icon or QUESTION_MARK_ICON
end

function LF:RequestItemData(itemId)
  itemId = tonumber(itemId)
  if itemId and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, itemId)
  end
end

-- Item names come from three places, cheapest first: the bundled recipe data,
-- names remembered from earlier sessions, and the game client (which only
-- answers once it has the item cached, so a miss also asks it to load unless
-- quiet is set).
function LF:GetItemName(itemId, quiet)
  itemId = tonumber(itemId)
  if not itemId then
    return nil
  end

  local bundled = ns.ItemNames and ns.ItemNames[itemId]
  if bundled then
    return bundled
  end

  local remembered = self.db and self.db.itemNames and self.db.itemNames[itemId]
  if remembered then
    return remembered
  end

  local name
  if C_Item and C_Item.GetItemNameByID then
    name = C_Item.GetItemNameByID(itemId)
  end
  if not name then
    name = self:GetItemInfo(itemId)
  end

  if name and name ~= "" then
    if self.db and self.db.itemNames then
      self.db.itemNames[itemId] = name
    end
    return name
  end

  -- quiet: just report what is known. Used when walking thousands of rows,
  -- where asking the client to load every unknown item would flood it.
  if not quiet then
    self:RequestItemData(itemId)
  end
  return nil
end

function LF:GetItemLink(itemId)
  local _, link = self:GetItemInfo(itemId)
  return link
end

local function IsRealLink(link)
  return type(link) == "string" and string.find(link, "|H", 1, true) ~= nil
end

-- Text to show for a row: a clickable-looking coloured link when the client has
-- one, otherwise the plain name. Fills in row.name / row.itemLink once known.
function LF:GetRowDisplayText(row)
  if IsRealLink(row.itemLink) then
    return row.itemLink
  end

  local itemId = tonumber(row.itemId or self:GetItemKey(row.itemLink))
  if itemId then
    local name, link = self:GetItemInfo(itemId)
    if name and not row.name then
      row.name = name
    end
    if IsRealLink(link) then
      return link
    end
    if not row.name then
      row.name = self:GetItemName(itemId)
    end
  end

  return row.name or (itemId and ("item " .. itemId)) or "Unknown item"
end

-- Something GameTooltip:SetHyperlink accepts for this row.
function LF:GetRowHyperlink(row)
  if IsRealLink(row.itemLink) then
    return row.itemLink
  end
  local itemId = tonumber(row.itemId or self:GetItemKey(row.itemLink))
  if itemId then
    return "item:" .. itemId
  end
  return nil
end

local function GetActiveChatEditBox()
  if ChatFrameUtil and ChatFrameUtil.GetActiveWindow then
    return ChatFrameUtil.GetActiveWindow()
  end
  if ChatEdit_GetActiveWindow then
    return ChatEdit_GetActiveWindow()
  end
  return nil
end

local function InsertChatLink(link)
  if ChatFrameUtil and ChatFrameUtil.InsertLink then
    return ChatFrameUtil.InsertLink(link)
  end
  if ChatEdit_InsertLink then
    return ChatEdit_InsertLink(link)
  end
  return false
end

-- Row click behaviour shared by every LiteFlipper table: with a chat box open
-- the item is linked into it; otherwise the usual modified clicks apply
-- (shift-click to link, ctrl-click to preview).
function LF:HandleItemClick(link)
  if not IsRealLink(link) then
    return false
  end

  if GetActiveChatEditBox() then
    InsertChatLink(link)
    return true
  end

  if HandleModifiedItemClick then
    return HandleModifiedItemClick(link) and true or false
  end
  return false
end

function LF:IsModifiedLinkClick()
  return IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) or false
end

function LF:IsAuctionHouseOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown())
    or (AuctionFrame and AuctionFrame:IsShown())
    or false
end

function LF:IsSpellKnown(spellId)
  spellId = tonumber(spellId)
  if not spellId then
    return false
  end

  if C_SpellBook and C_SpellBook.IsSpellKnown then
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    local ok, known = pcall(C_SpellBook.IsSpellKnown, spellId, bank)
    if ok and known then
      return true
    end
  end
  if IsPlayerSpell then
    local ok, known = pcall(IsPlayerSpell, spellId)
    if ok and known then
      return true
    end
  end
  return false
end

-- === Background item-name loading ===
--
-- Many WoW Forever items are new and have no bundled name, and searching by
-- name only works for items whose name is known. After login this asks the
-- client for the missing recipe item names a few at a time and remembers the
-- answers in the saved variables, so it only has to happen once.

local NAME_BATCH_SIZE = 40
local NAME_BATCH_SECONDS = 1

function LF:WarmItemNames()
  if self.itemNameWarmupStarted or not self.db or not (C_Item and C_Item.GetItemNameByID) then
    return
  end
  self.itemNameWarmupStarted = true

  local missing = {}
  local seen = {}
  local function Consider(itemId)
    if itemId and not seen[itemId] then
      seen[itemId] = true
      if not (ns.ItemNames and ns.ItemNames[itemId]) and not self.db.itemNames[itemId] then
        table.insert(missing, itemId)
      end
    end
  end

  for _, profession in pairs(ns.RecipeData or {}) do
    for _, entry in ipairs(profession.recipes or {}) do
      Consider(entry.p)
      for _, pair in ipairs(entry.r or {}) do
        Consider(pair[1])
      end
    end
  end

  if #missing == 0 or not (C_Timer and C_Timer.After) then
    return
  end

  local index = 1
  local passes = 0
  local function Step()
    local stillMissing = {}
    local last = math.min(index + NAME_BATCH_SIZE - 1, #missing)
    for i = index, last do
      local itemId = missing[i]
      local name = C_Item.GetItemNameByID(itemId)
      if name and name ~= "" then
        LF.db.itemNames[itemId] = name
      else
        LF:RequestItemData(itemId)
        table.insert(stillMissing, itemId)
      end
    end
    index = last + 1

    -- Requested items are retried in one later pass, once the client has had
    -- time to answer.
    for _, itemId in ipairs(stillMissing) do
      LF.itemNameRetry = LF.itemNameRetry or {}
      table.insert(LF.itemNameRetry, itemId)
    end

    if index <= #missing then
      C_Timer.After(NAME_BATCH_SECONDS, Step)
    elseif LF.itemNameRetry and #LF.itemNameRetry > 0 and passes < 2 then
      passes = passes + 1
      missing = LF.itemNameRetry
      LF.itemNameRetry = nil
      index = 1
      C_Timer.After(NAME_BATCH_SECONDS * 3, Step)
    else
      LF.itemNameRetry = nil
      LF.craftIndex = nil
    end
  end

  C_Timer.After(5, Step)
end
