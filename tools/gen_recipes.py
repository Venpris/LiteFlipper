# Builds LiteFlipper's RecipeData.lua for WoW Forever.
#
# Source: the recipe tables that ship with the CraftPath addon (Data/Recipes_*.lua and
# Data/Items.lua), which were gathered from Wowhead's WoW Forever database. The Classic Era
# recipe list is not usable here: Forever adds and changes many recipes.
#
# Usage: python -I gen_recipes.py <CraftPath dir> <output RecipeData.lua> [classic RecipeData.lua]
# The optional third argument is the Classic Era LiteFlipper RecipeData.lua; it is only used
# to fill in product names for items that kept their Classic item id.
import os
import re
import sys

craftpath_dir = sys.argv[1]
out_path = sys.argv[2]
classic_path = sys.argv[3] if len(sys.argv) > 3 else None

PROFESSIONS = [
    ("alchemy", "Alchemy", "Recipes_Alchemy.lua"),
    ("blacksmithing", "Blacksmithing", "Recipes_Blacksmithing.lua"),
    ("cooking", "Cooking", "Recipes_Cooking.lua"),
    ("enchanting", "Enchanting", "Recipes_Enchanting.lua"),
    ("engineering", "Engineering", "Recipes_Engineering.lua"),
    ("first aid", "First Aid", "Recipes_FirstAid.lua"),
    ("leatherworking", "Leatherworking", "Recipes_Leatherworking.lua"),
    ("mining", "Mining", "Recipes_Mining.lua"),
    ("tailoring", "Tailoring", "Recipes_Tailoring.lua"),
]


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


items_lua = read(os.path.join(craftpath_dir, "Data", "Items.lua"))

names = {}
block = re.search(r"ns\.Data\.itemNames = \{(.*?)\n\}", items_lua, re.S)
if block:
    for item_id, name in re.findall(r'\[(\d+)\] = "((?:[^"\\]|\\.)*)"', block.group(1)):
        names[int(item_id)] = name.replace('\\"', '"').replace("\\\\", "\\")

vendor = {}
block = re.search(r"ns\.Data\.vendorBuy = \{(.*?)\n\}", items_lua, re.S)
if block:
    for item_id, price in re.findall(r"\[(\d+)\] = (\d+)", block.group(1)):
        vendor[int(item_id)] = int(price)

classic_names = {}
if classic_path and os.path.exists(classic_path):
    for item_id, name in re.findall(r'\{ p = (\d+), n = "((?:[^"\\]|\\.)*)"', read(classic_path)):
        classic_names[int(item_id)] = name.replace('\\"', '"').replace("\\\\", "\\")

out = []
out.append("local _, ns = ...")
out.append("")
out.append("-- GENERATED FILE - rebuild with tools/gen_recipes.py instead of editing by hand.")
out.append("-- WoW Forever recipes, taken from the tables bundled with the CraftPath addon")
out.append("-- (gathered from Wowhead's WoW Forever database).")
out.append("-- s = recipe spell id, p = product item id, n = product name (when known),")
out.append("-- m = quantity made, r = { { reagent item id, count }, ... }")
out.append("ns.RecipeData = {")

total = 0
unnamed = 0
used_items = set()
for key, display, filename in PROFESSIONS:
    path = os.path.join(craftpath_dir, "Data", filename)
    if not os.path.exists(path):
        continue
    rows = []
    seen_products = set()
    for line in read(path).splitlines():
        if not re.match(r"^\d+;", line):
            continue
        fields = line.split(";")
        fields += [""] * (10 - len(fields))
        spell, product, made_min, reagent_text = fields[0], fields[5], fields[6], fields[8]
        if not product:
            continue  # enchants and other recipes that make no item
        reagents = [(int(i), int(c)) for i, c in re.findall(r"(\d+):(\d+)", reagent_text)]
        if not reagents:
            continue
        product = int(product)
        if product in seen_products:
            continue  # first recipe listed for a product wins
        seen_products.add(product)
        made = int(made_min) if made_min else 1
        name = names.get(product) or classic_names.get(product)
        rows.append((name or "", product, int(spell), max(1, made), reagents, name))
        used_items.add(product)
        for item_id, _ in reagents:
            used_items.add(item_id)

    rows.sort(key=lambda row: (row[0] == "", row[0].lower(), row[1]))
    out.append("  [%s] = {" % lua_string(key))
    out.append("    name = %s," % lua_string(display))
    out.append("    recipes = {")
    for _, product, spell, made, reagents, name in rows:
        total += 1
        parts = ["s = %d" % spell, "p = %d" % product]
        if name:
            parts.append("n = %s" % lua_string(name))
        else:
            unnamed += 1
        parts.append("m = %d" % made)
        parts.append("r = {%s}" % ",".join("{%d,%d}" % pair for pair in reagents))
        out.append("      { %s }," % ", ".join(parts))
    out.append("    },")
    out.append("  },")
out.append("}")
out.append("")
out.append("-- Names for reagents and products that are known ahead of time, so searches such as")
out.append("-- /lf uses work before the client has cached the item. Anything missing is looked up")
out.append("-- from the game client when it is needed.")
out.append("ns.ItemNames = {")
merged = dict(classic_names)
merged.update(names)
named = 0
for item_id in sorted(used_items):
    if item_id in merged:
        named += 1
        out.append("  [%d] = %s," % (item_id, lua_string(merged[item_id])))
out.append("}")
out.append("")
out.append("-- Reagents that vendors sell in unlimited supply: [item id] = copper each. These are")
out.append("-- starting values; visiting a vendor in game overrides them with the real price.")
out.append("ns.VendorData = {")
for item_id in sorted(vendor):
    if item_id in used_items:
        out.append("  [%d] = %d,%s" % (item_id, vendor[item_id],
                                      (" -- " + merged[item_id]) if item_id in merged else ""))
out.append("}")
out.append("")

with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write("\n".join(out))

print("recipes: %d (without a bundled name: %d)" % (total, unnamed))
print("items referenced: %d, named: %d" % (len(used_items), named))
print("vendor prices: %d" % sum(1 for i in vendor if i in used_items))
