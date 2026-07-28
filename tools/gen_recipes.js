// Generates RecipeData.lua for LiteFlipper from wago.tools DB2 CSV exports.
//
// Usage:
//   1. Find the latest Classic Era build: https://wago.tools/api/builds (product wow_classic_era)
//   2. Download these tables as CSV into tools/db2/:
//      https://wago.tools/db2/SkillLineAbility/csv?build=<BUILD>
//      https://wago.tools/db2/SpellReagents/csv?build=<BUILD>
//      https://wago.tools/db2/SpellEffect/csv?build=<BUILD>
//      https://wago.tools/db2/ItemSparse/csv?build=<BUILD>
//   3. Update BUILD below, then run: node tools/gen_recipes.js
const fs = require('fs');
const path = require('path');

const DB2_DIR = path.join(__dirname, 'db2');
const OUT_FILE = path.join(__dirname, '..', 'RecipeData.lua');
const BUILD = '1.15.8.67156';

const SKILL_LINES = {
  171: 'Alchemy',
  164: 'Blacksmithing',
  185: 'Cooking',
  333: 'Enchanting',
  202: 'Engineering',
  129: 'First Aid',
  165: 'Leatherworking',
  186: 'Mining',
  197: 'Tailoring',
};

const SPELL_EFFECT_CREATE_ITEM = 24;

// Minimal CSV parser handling quoted fields with embedded commas/quotes.
function parseCsvLine(line) {
  const fields = [];
  let cur = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; }
        else inQuotes = false;
      } else cur += ch;
    } else if (ch === '"') inQuotes = true;
    else if (ch === ',') { fields.push(cur); cur = ''; }
    else cur += ch;
  }
  fields.push(cur);
  return fields;
}

function* csvRows(file) {
  const text = fs.readFileSync(path.join(DB2_DIR, file), 'utf8');
  const lines = text.split(/\r?\n/);
  const header = parseCsvLine(lines[0]);
  for (let i = 1; i < lines.length; i++) {
    if (!lines[i]) continue;
    const vals = parseCsvLine(lines[i]);
    const row = {};
    for (let c = 0; c < header.length; c++) row[header[c]] = vals[c];
    yield row;
  }
}

// spell -> skill line (only for the professions we care about)
const spellSkill = new Map();
for (const row of csvRows('SkillLineAbility.csv')) {
  const skill = Number(row.SkillLine);
  if (SKILL_LINES[skill]) spellSkill.set(Number(row.Spell), skill);
}
console.log('profession spells:', spellSkill.size);

// spell -> [[reagentId, count], ...]
const spellReagents = new Map();
for (const row of csvRows('SpellReagents.csv')) {
  const spellId = Number(row.SpellID);
  if (!spellSkill.has(spellId)) continue;
  const reagents = [];
  for (let i = 0; i < 8; i++) {
    const id = Number(row['Reagent_' + i]);
    const count = Number(row['ReagentCount_' + i]);
    if (id > 0 && count > 0) reagents.push([id, count]);
  }
  if (reagents.length) spellReagents.set(spellId, reagents);
}
console.log('spells with reagents:', spellReagents.size);

// spell -> { itemId, made }
const spellCreates = new Map();
for (const row of csvRows('SpellEffect.csv')) {
  const spellId = Number(row.SpellID);
  if (!spellSkill.has(spellId)) continue;
  if (Number(row.Effect) !== SPELL_EFFECT_CREATE_ITEM) continue;
  const itemId = Number(row.EffectItemType);
  if (!(itemId > 0)) continue;
  const basePointsF = Number(row.EffectBasePointsF);
  const basePoints = Number(row.EffectBasePoints);
  const dieSides = Number(row.EffectDieSides);
  let made = basePointsF > 0 ? basePointsF : basePoints + (dieSides > 0 ? 1 : 0);
  made = Math.max(1, Math.round(made));
  spellCreates.set(spellId, { itemId, made });
}
console.log('spells creating items:', spellCreates.size);

// item names
const neededItems = new Set();
for (const [spellId, creates] of spellCreates) {
  neededItems.add(creates.itemId);
  for (const [rid] of spellReagents.get(spellId) || []) neededItems.add(rid);
}
const itemNames = new Map();
for (const row of csvRows('ItemSparse.csv')) {
  const id = Number(row.ID);
  if (neededItems.has(id)) itemNames.set(id, row.Display_lang);
}
console.log('item names resolved:', itemNames.size, 'of', neededItems.size);

const JUNK_NAME = /deprecated|\[ph\]|^monster - |\btest\b|^old\b|unused/i;

// profession -> productId -> recipe (dedupe: first spell wins)
const byProfession = new Map();
let skippedJunk = 0, skippedNoReagents = 0, skippedNoName = 0;
const sortedSpells = [...spellCreates.keys()].sort((a, b) => a - b);
for (const spellId of sortedSpells) {
  const { itemId, made } = spellCreates.get(spellId);
  const reagents = spellReagents.get(spellId);
  if (!reagents) { skippedNoReagents++; continue; }
  const name = itemNames.get(itemId);
  if (!name) { skippedNoName++; continue; }
  if (JUNK_NAME.test(name)) { skippedJunk++; continue; }
  const skill = spellSkill.get(spellId);
  if (!byProfession.has(skill)) byProfession.set(skill, new Map());
  const products = byProfession.get(skill);
  if (!products.has(itemId)) products.set(itemId, { p: itemId, n: name, m: made, r: reagents });
}

// Sanity samples
const samples = [
  [171, 118, 'Minor Healing Potion'],
  [186, 2840, 'Copper Bar'],
  [197, 2996, 'Bolt of Linen Cloth'],
  [202, 8067, 'Crafted Light Shot (multi-made expected)'],
  [129, 1251, 'Linen Bandage'],
];
for (const [skill, itemId, label] of samples) {
  const rec = byProfession.get(skill) && byProfession.get(skill).get(itemId);
  console.log('sample:', label, '=>', rec ? JSON.stringify(rec) : 'MISSING');
}

const luaEscape = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
let out = 'local _, ns = ...\n\n';
out += '-- Generated from wago.tools DB2 exports for Classic Era build ' + BUILD + '\n';
out += '-- (SkillLineAbility + SpellReagents + SpellEffect + ItemSparse).\n';
out += '-- p = product item id, n = product name, m = quantity made, r = { { reagent item id, count }, ... }\n';
out += 'ns.RecipeData = {\n';
const skillIds = [...byProfession.keys()].sort((a, b) => SKILL_LINES[a].localeCompare(SKILL_LINES[b]));
let total = 0;
for (const skill of skillIds) {
  const profName = SKILL_LINES[skill];
  const recipes = [...byProfession.get(skill).values()].sort((a, b) => a.n.localeCompare(b.n));
  total += recipes.length;
  out += '  ["' + profName.toLowerCase() + '"] = {\n';
  out += '    name = "' + profName + '",\n';
  out += '    recipes = {\n';
  for (const rec of recipes) {
    const r = rec.r.map(([id, c]) => '{' + id + ',' + c + '}').join(',');
    out += '      { p = ' + rec.p + ', n = "' + luaEscape(rec.n) + '", m = ' + rec.m + ', r = {' + r + '} },\n';
  }
  out += '    },\n  },\n';
  console.log(profName + ': ' + recipes.length + ' recipes');
}
out += '}\n';
fs.writeFileSync(OUT_FILE, out);
console.log('total recipes:', total, '| skipped junk:', skippedJunk, '| no reagents:', skippedNoReagents, '| no name:', skippedNoName);
console.log('wrote', OUT_FILE);
