local _, ns = ...
local LF = ns.LF

function LF:InstallTooltip()
  GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
    if not LF.db or not LF.db.tooltip then
      return
    end

    local _, itemLink = tooltip:GetItem()
    if not itemLink then
      return
    end

    local marketValue, observedDays, sampleType = LF:GetMarketValue(itemLink, false)
    local currentAuctionPrice = LF:GetLatestScanMinPrice(itemLink) or LF:GetAuctionatorPrice(itemLink, false)
    local trend, latestSupply, averageSupply = LF:GetSupplyTrend(itemLink)
    local pricePosition, recentLow, aboveLow = LF:GetPricePosition(itemLink, currentAuctionPrice or marketValue)
    local trendStats = LF:GetPriceTrend(itemLink)
    local craftCost, craftYield
    local itemId = tonumber(LF:GetItemKey(itemLink))
    local recipe = itemId and LF.GetCraftIndex and LF:GetCraftIndex()[itemId] or nil
    if recipe and LF.GetRecipeCraftCost then
      craftCost, craftYield = LF:GetRecipeCraftCost(recipe)
    end

    if not marketValue and not trend and not pricePosition and not trendStats and not craftCost then
      return
    end

    tooltip:AddLine(" ")
    if craftCost then
      local craftText = LF:FormatMoney(craftCost)
      if craftYield and craftYield > 1 then
        craftText = craftText .. " (" .. LF:FormatMoney(math.ceil(craftCost / craftYield)) .. " each)"
      end
      tooltip:AddDoubleLine("Cost to craft", craftText, 0.31, 0.70, 1, 1, 1, 1)
    end
    if marketValue then
      tooltip:AddDoubleLine("Market value", LF:FormatMoney(marketValue), 0.31, 0.70, 1, 1, 1, 1)
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

    if trendStats then
      local sign = trendStats.change < 0 and "-" or "+"
      local percent = math.floor(math.abs(trendStats.change) * 100 + 0.5)
      local r, g, b = 0.8, 0.8, 0.8
      if trendStats.label == "Rising" then
        r, g, b = 0.4, 1, 0.4
      elseif trendStats.label == "Falling" then
        r, g, b = 1, 0.45, 0.45
      end
      tooltip:AddDoubleLine("Price trend", trendStats.label .. " (" .. sign .. percent .. "% over " .. trendStats.span .. "d)", 0.31, 0.70, 1, r, g, b)

      local volLabel, volPercent = LF:DescribeVolatility(trendStats.volatility)
      if volLabel then
        tooltip:AddDoubleLine("Volatility", volLabel .. " (±" .. volPercent .. "%)", 0.31, 0.70, 1, 0.8, 0.8, 0.8)
      end
      if trendStats.historicalLow and trendStats.historicalHigh then
        tooltip:AddDoubleLine("History low/high", LF:FormatMoney(trendStats.historicalLow) .. " / " .. LF:FormatMoney(trendStats.historicalHigh), 0.31, 0.70, 1, 0.8, 0.8, 0.8)
      end
    end

    if trend then
      local detail = latestSupply .. " units"
      if averageSupply then
        detail = detail .. " vs " .. averageSupply .. " avg"
      end
      tooltip:AddDoubleLine("Supply trend", trend .. " (" .. detail .. ")", 0.31, 0.70, 1, 0.8, 0.8, 0.8)
    end
    if pricePosition then
      local change = aboveLow or 0
      local sign = change < 0 and "-" or "+"
      local percent = math.floor(math.abs(change) * 100 + 0.5)
      tooltip:AddDoubleLine("Recent low today", pricePosition .. " (" .. sign .. percent .. "% vs " .. LF:FormatMoney(recentLow) .. ")", 0.31, 0.70, 1, 0.8, 0.8, 0.8)
    end
    tooltip:Show()
  end)
end
