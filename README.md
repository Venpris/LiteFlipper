# LiteFlipper (WoW Forever)

LiteFlipper is a small auction helper for players who want market-value tooltips, price history and basic flipping hints without replacing the auction house or mailbox UI. This is the WoW Forever port of the Classic Era addon.

## What it does

- Adds market value, current low, cost-to-craft, price trend, volatility and `Recent low today` lines to item tooltips when those values are known.
- Adds a **History** button to Auctionator's buy panel (under `Buy Now` for stackable items, next to `Back` for single items). It opens a table with the item's price on each day you scanned: lowest and highest price that day, units available, and the change from the previous day. `/lf history <item>` opens the same window anywhere, and so does right-clicking a row in any LiteFlipper table.
- Reads Auctionator's price database (the same per-day records Auctionator keeps for 21 days by default) and keeps its own rolling history in `LiteFlipperDB`.
- Picks up every Auctionator scan automatically, and also learns from ordinary searches and from items you open in the buy panel, so prices stay fresh between full scans.
- Lists items priced below your configured market threshold (`/lf scan`), or all rows without filters (`/lf browse`), in a paged, sortable table with a name search box.
- Tracks daily supply and labels the supply trend as `Up`, `Flat`, `Down`, or `New`.
- Ships recipe data for the WoW Forever professions (about 2,000 item-producing recipes) and ranks them by crafting profit with `/lf craft <profession>`. Material cost is the cheapest of the current low, market value, vendor price, or crafting the material yourself, all the way down the tree.
- Knows which recipes your characters have learned (white rows; unknown ones are grey) without needing the profession window, and reads the real reagents from the profession window when you open it.
- Remembers vendor prices whenever you visit a merchant.
- The craft tree (`/lf tree <item>`) has a `Find` button per material that searches Auctionator's Shopping tab for that exact item.

## Commands

- `/lf scan` - find deals in the current auction results, or in the saved scan if only a small result set is on screen.
- `/lf browse` - show auction rows without threshold, profit, or supply filters. `/lf browse copper` pre-fills the search.
- `/lf history silk` - open the price history window for an item. With no item, uses the one open in Auctionator's buy panel.
- `/lf price silk` (or `/lf search`) - market value, current low, vendor price, trend, and historical low/high in chat.
- `/lf trend silk` - trend, volatility, low/high and the day-by-day prices in chat.
- `/lf craft alchemy` (or `/lf scan alchemy`) - rank recipes by crafting profit. Any profession name or prefix works; `/lf alch`, `/lf eng`, `/lf ench`, `/lf bs`, `/lf lw`, `/lf tailor`, `/lf cook` are shortcuts.
- `/lf craft` - list professions with recipe data.
- `/lf bags` - value the sellable items in your bags.
- `/lf uses briarthorn` (or `/lf mat`) - every recipe that uses a material, with margins.
- `/lf tree copper tube` (or `/lf plan`) - buy-vs-craft material tree planner.
- `/lf threshold 80` - flag auctions at or below 80% of market value.
- `/lf minthreshold 10` - ignore auctions below 10% of market (0 disables).
- `/lf profit 1` - require at least 1g estimated unit profit.
- `/lf supply 5` - require at least 5 visible units, or `0` to disable.
- `/lf purge 3` - delete market history older than 3 hours for this auction house.
- `/lf hovertooltip [on|off]` - toggle LiteFlipper lines on item tooltips (`/lf tooltip` also works).
- `/lf help` - show commands.

## How the data works on WoW Forever

WoW Forever uses the modern auction house, which changes what LiteFlipper can see compared with Classic Era:

- **Scans are summaries by default.** Auctionator's normal full scan pages through the browse list and yields one row per item: its lowest price and total quantity. LiteFlipper stores that as its snapshot, so in `/lf scan` and `/lf browse` the unit price is the item's cheapest listing and `Qty` is everything on the auction house. If you turn on Auctionator's replicate scan option, LiteFlipper gets every individual auction instead, as on Classic Era.
- **Opening an item fills in the detail.** When you click an item in the Shopping tab, LiteFlipper records the whole price ladder shown in the buy panel, which gives a better average than the cheapest listing alone.
- **Market value** is an outlier-trimmed average of LiteFlipper's own samples from the last 7 days. While LiteFlipper has fewer days recorded than Auctionator (for example right after installing it), Auctionator's daily history is used instead.
- **Markets are per ruleset and faction.** Forever's auction houses are shared across realms with the same ruleset, so LiteFlipper keeps one set of data per ruleset and faction (for example `PvE::Alliance`), matching Auctionator.
- **History rows.** Each scan notes an item's cheapest listing. `Low` and `High` in the history window are the smallest and largest of those across the day's scans. White dates come from Auctionator's database; blue dates are days only LiteFlipper recorded.

LiteFlipper never sends auction house queries, buys, bids or posts anything. It only reads results that Auctionator or you requested.

## Install

The folder goes in `World of Warcraft/_forever_/Interface/AddOns/LiteFlipper`.

Auctionator is optional, but it is what performs full scans and holds the longer price history, and the History button lives on its buy panel. Without it LiteFlipper still records whatever you search for in Blizzard's own auction house UI.

## Notes

- Recipe data in `RecipeData.lua` is generated by `tools/gen_recipes.py` from the WoW Forever recipe tables bundled with the CraftPath addon. Many Forever items are new and have no bundled name; LiteFlipper asks the game for those names in the background after login and remembers them, so name searches for new items work a little after your first login.
- Recipes that make no item (most enchants) are not listed. Recipes whose product or reagents have no recorded price yet are skipped and counted in the summary.
- "Known" status is account-wide: a recipe is white once any character LiteFlipper has seen knows it.
- `dev/test_forever.lua` is an offline test that loads the addon against a fake client: `python -I dev/runlua.py dev/test_forever.lua "ADDON_DIR=<path to this folder>"`.
