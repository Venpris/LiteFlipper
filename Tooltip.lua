local _, ns = ...
local LF = ns.LF

local LABEL_R, LABEL_G, LABEL_B = 0.31, 0.70, 1

-- Only the main hover tooltip and the click-to-pin item tooltip get LiteFlipper
-- lines; comparison and embedded tooltips stay untouched.
local function IsSupportedTooltip(tooltip)
  return tooltip == GameTooltip or (ItemRefTooltip and tooltip == ItemRefTooltip)
end

local function ResolveTooltipItem(tooltip, data)
  local link
  if TooltipUtil and TooltipUtil.GetDisplayedItem then
    local ok, _, displayedLink = pcall(TooltipUtil.GetDisplayedItem, tooltip)
    if ok then
      link = displayedLink
    end
  elseif tooltip.GetItem then
    local ok, _, displayedLink = pcall(tooltip.GetItem, tooltip)
    if ok then
      link = displayedLink
    end
  end

  if type(link) == "string" and string.find(link, "item:", 1, true) then
    return link
  end

  -- Recipes and some bag slots report no link; the tooltip data still carries
  -- the item id.
  if type(data) == "table" and type(data.id) == "number" then
    return data.id
  end

  return nil
end

local function AddMarketLines(tooltip, item)
  local marketValue, observedDays, sampleType = LF:GetMarketValue(item, false)
  local currentAuctionPrice = LF:GetLatestScanMinPrice(item) or LF:GetAuctionatorPrice(item, false)
  local trend, latestSupply, averageSupply = LF:GetSupplyTrend(item)
  local pricePosition, recentLow, aboveLow = LF:GetPricePosition(item, currentAuctionPrice or marketValue)
  local trendStats = LF:GetPriceTrend(item)
  local craftCost, craftYield
  local itemId = tonumber(LF:GetItemKey(item))
  local recipe = itemId and LF.GetCraftIndex and LF:GetCraftIndex()[itemId] or nil
  if recipe and LF.GetRecipeCraftCost then
    craftCost, craftYield = LF:GetRecipeCraftCost(recipe)
  end

  if not marketValue and not currentAuctionPrice and not trend and not pricePosition
    and not trendStats and not craftCost then
    return
  end

  tooltip:AddLine(" ")
  if craftCost then
    local craftText = LF:FormatMoney(craftCost)
    if craftYield and craftYield > 1 then
      craftText = craftText .. " (" .. LF:FormatMoney(math.ceil(craftCost / craftYield)) .. " each)"
    end
    tooltip:AddDoubleLine("Cost to craft", craftText, LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
  end
  if marketValue then
    tooltip:AddDoubleLine("Market value", LF:FormatMoney(marketValue), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
  end
  if marketValue and observedDays and observedDays > 1 then
    local sampleLabel = "day avg"
    if sampleType == "scan" then
      sampleLabel = "scan avg"
    elseif sampleType == "scan-capped" then
      sampleLabel = "scan avg capped"
    elseif sampleType == "ah-history" then
      sampleLabel = "AH day avg"
    end
    tooltip:AddDoubleLine("Market sample", observedDays .. " " .. sampleLabel, 0.65, 0.65, 0.65, 0.65, 0.65, 0.65)
  end
  if currentAuctionPrice and currentAuctionPrice ~= marketValue then
    tooltip:AddDoubleLine("Current low", LF:FormatMoney(currentAuctionPrice), LABEL_R, LABEL_G, LABEL_B, 1, 1, 1)
  end

  if trendStats then
    local sign = trendStats.change < 0 and "-" or "+"
    local percent = math.floor(math.abs(trendStats.change) * 100 + 0.5)
    local r, g, b = 0.8, 0.8, 0.8
    if trendStats.label == "Rising" then
      r, g, b = 0.4, 1, 0.4
    elseif trendStats.label == "Falling" then
      r, g, b = 1, 0.45, 0.45
    end
    tooltip:AddDoubleLine("Price trend", trendStats.label .. " (" .. sign .. percent .. "% over " .. trendStats.span .. "d)", LABEL_R, LABEL_G, LABEL_B, r, g, b)

    local volLabel, volPercent = LF:DescribeVolatility(trendStats.volatility)
    if volLabel then
      tooltip:AddDoubleLine("Volatility", volLabel .. " (+/-" .. volPercent .. "%)", LABEL_R, LABEL_G, LABEL_B, 0.8, 0.8, 0.8)
    end
    if trendStats.historicalLow and trendStats.historicalHigh then
      tooltip:AddDoubleLine("History low/high", LF:FormatMoney(trendStats.historicalLow) .. " / " .. LF:FormatMoney(trendStats.historicalHigh), LABEL_R, LABEL_G, LABEL_B, 0.8, 0.8, 0.8)
    end
  end

  if trend then
    local detail = latestSupply .. " units"
    if averageSupply then
      detail = detail .. " vs " .. averageSupply .. " avg"
    end
    tooltip:AddDoubleLine("Supply trend", trend .. " (" .. detail .. ")", LABEL_R, LABEL_G, LABEL_B, 0.8, 0.8, 0.8)
  end
  if pricePosition then
    local change = aboveLow or 0
    local sign = change < 0 and "-" or "+"
    local percent = math.floor(math.abs(change) * 100 + 0.5)
    tooltip:AddDoubleLine("Recent low today", pricePosition .. " (" .. sign .. percent .. "% vs " .. LF:FormatMoney(recentLow) .. ")", LABEL_R, LABEL_G, LABEL_B, 0.8, 0.8, 0.8)
  end
end

local function OnItemTooltip(tooltip, data)
  if not LF.db or not LF.db.tooltip or not IsSupportedTooltip(tooltip) then
    return
  end

  local item = ResolveTooltipItem(tooltip, data)
  if not item then
    return
  end

  -- A mistake here would otherwise raise an error on every single item hover,
  -- so the first failure is reported once and later ones stay quiet.
  local ok, errorMessage = pcall(AddMarketLines, tooltip, item)
  if not ok and not LF.tooltipErrorReported then
    LF.tooltipErrorReported = true
    LF:Print("Tooltip lines hit an error (shown once per session): " .. tostring(errorMessage))
  end
end

function LF:InstallTooltip()
  if self.tooltipInstalled then
    return
  end

  -- Modern clients (including WoW Forever) build tooltips from structured
  -- data and expose a post-processing hook; OnTooltipSetItem no longer exists
  -- there. The old script hook is kept as a fallback for older clients.
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
    self.tooltipInstalled = true
  elseif GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
      OnItemTooltip(tooltip, nil)
    end)
    self.tooltipInstalled = true
  else
    self:Debug("No item tooltip hook is available on this client.")
  end
end
