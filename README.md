# LiteFlipper

LiteFlipper is a small Classic Era auction helper for players who want market-value tooltips and basic flipping hints without replacing the auction house or mailbox UI.

## What it does

- Adds market value, cost-to-craft, and `Recent low today` lines to item tooltips when those values are known.
- Reads Auctionator prices when Auctionator exposes them.
- Keeps its own rolling daily history in `LiteFlipperDB`.
- Tracks daily supply snapshots from your scans and labels supply trend as `Up`, `Flat`, `Down`, or `New`.
- Compares current prices against recent lows and labels them as `At low`, `Near low`, or `Above low`.
- Scans the currently visible auction browse results and lists buyouts that are below your configured market threshold, or browses all rows without threshold filters.
- Filters out deals when the item has too few visible units in the scan, which helps hide one-off BoEs and other very thin markets.
- Shows scan results in a paged, sortable table with item icons, hoverable item tooltips, colored under-market percentages, unit price, market value, profit, visible supply, and trend.
- Groups matching deal rows by item, unit price, and seller so repeated single-stack postings appear as one result with total quantity and lot count.
- Both results windows have a search box that live-filters rows by item name, and `/lf price <name>` looks up saved prices for any item from chat.
- Records outlier-trimmed listing prices from each scan, then uses the rolling 7-day scan history for market value before falling back to Auctionator's daily price history, its last-seen price, and older daily data. When Auctionator has enough history, LiteFlipper caps scan-derived market value at the observed historical high.
- Reads Auctionator's 21-day price history (the data behind its History button) to show `Price trend`, `Volatility`, and historical low/high lines in tooltips, so you can hold items that are trending up instead of selling into a dip.
- Persists the latest AH result snapshot LiteFlipper can see, replacing it whenever current AH rows update, so `/lf scan` can fall back to that snapshot when no current rows are available.
- Ships static recipe data for every Classic Era profession (about 1,400 recipes generated from the game's own database files), so crafting scans cover all craftable items, not just the ones your characters know.
- Remembers which recipes your characters actually know whenever you open a profession window, and remembers vendor prices whenever you visit a merchant.
- Ranks recipes by crafting profit with `/lf craft <profession>`: material cost uses the cheapest of the current scan price, market value, and vendor price, and the sale value is the product's current auction-house price minus the 5% auction house cut. The sortable table includes `Mats%` so you can spot when materials are underpriced. Recipes known to your characters show in white; unknown ones are greyed out.
- The craft tree has a `Find` button for each non-vendor material. With the auction house open, it searches Auctionator's Shopping tab for that exact item; the player reviews and confirms the purchase there. Blizzard's Browse tab is used as a fallback when Auctionator is unavailable.
- Material costing is recursive: if a reagent is itself craftable (bars, bolts, essences), LiteFlipper compares buying it against crafting it from its own materials and uses the cheaper path, all the way down the tree. The row tooltip shows crafted reagents with their sub-materials indented beneath them.
- Market values weight each listing once, no matter the stack size, and anchor outlier detection on the lower median unique unit price - so one repeated price wall cannot drag the market value up.

## Commands

- `/lf scan` - scan the current auction house browse results, or show the saved LiteFlipper scan if no current rows are available.
- `/lf browse` - show auction rows without threshold, profit, or visible-supply filters. Add text like `/lf browse copper` to pre-fill the table search.
- `/lf craft alchemy` (or `/lf scan alchemy`) - rank recorded alchemy recipes by crafting profit. Any profession name or prefix works.
- `/lf alch`, `/lf eng`, `/lf ench`, `/lf bs`, `/lf tailor` - open the corresponding profession's crafting results directly.
- `/lf craft` - list professions with recorded recipes.
- `/lf price silk` (or `/lf search`) - look up saved prices for items matching a name, item link, or item id: market value, current scan low, vendor price, price trend, and historical low/high.
- `/lf trend silk` (or `/lf history`) - price trend, volatility, historical low/high, and the day-by-day price history Auctionator has recorded for matching items.
- `/lf bags` - value the sellable items currently in your bags: quantity, unit market value, total AH value, current scan low, and vendor sell value. Soulbound items are skipped.
- `/lf uses briarthorn` (or `/lf mat`) - show every recipe across all professions that uses a material, with crafting margins, in the crafting window.
- `/lf tree copper tube` (or `/lf plan`) - open the buy-vs-craft material tree planner for a craftable item.
- `/lf threshold 80` - flag auctions at or below 80% of market value.
- `/lf profit 1` - require at least 1g estimated unit profit.
- `/lf supply 5` - require at least 5 visible units for an item to appear in deal results, or use `0` to disable.
- `/lf hovertooltip` - toggle LiteFlipper market/trend lines on item hover tooltips. Use `/lf hovertooltip on` or `/lf hovertooltip off` to set it directly. `/lf tooltip` is also supported as an alias.
- `/lf help` - show commands.

## Install

Copy the `LiteFlipper` folder into:

`World of Warcraft/_classic_era_/Interface/AddOns/`

Auctionator is optional, but the addon is much more useful with Auctionator installed because it can seed market values from Auctionator's stored price data.

## Notes

LiteFlipper intentionally does not skin, replace, or automate the auction house. It only reads visible auction rows and saved price data, then shows you candidates.

Crafting scans cover all recipes from the bundled `RecipeData.lua` (generated from wago.tools DB2 exports of the Classic Era client) plus anything recorded from your profession windows. "Known" status comes from opening a profession window at least once on the crafting character; Enchanting recipes are always shown as unknown because its window uses the separate crafting API that LiteFlipper does not read. Recipes whose product or reagents have no recorded price yet are skipped and counted in the summary; scan the auction house (or a full Auctionator scan) to fill in prices.
