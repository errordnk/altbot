import json
import os
HERE = os.path.dirname(os.path.abspath(__file__))
# the downloaded Wowhead pages / parsed json live here (set ALTBOT_WH_CACHE to move them)
SRC = os.environ.get("ALTBOT_WH_CACHE", os.path.join(HERE, "cache")) + "/"
data = json.load(open(SRC + "wh_all.json"))
SPECS = {
    "warrior": ("WARRIOR", [(26, "Arms"), (256, "Fury"), (257, "Protection")]),
    "paladin": ("PALADIN", [(594, "Holy"), (267, "Protection"), (184, "Retribution")]),
    "hunter": ("HUNTER", [(50, "Beast Mastery"), (163, "Marksmanship"), (51, "Survival")]),
    "rogue": ("ROGUE", [(253, "Assassination"), (38, "Combat"), (39, "Subtlety")]),
    "priest": ("PRIEST", [(56, "Discipline"), (613, "Holy"), (78, "Shadow")]),
    "death-knight": ("DEATHKNIGHT", [(770, "Blood"), (771, "Frost"), (772, "Unholy")]),
    "shaman": ("SHAMAN", [(375, "Elemental"), (373, "Enhancement"), (374, "Restoration")]),
    "mage": ("MAGE", [(237, "Arcane"), (8, "Fire"), (6, "Frost")]),
    "warlock": ("WARLOCK", [(355, "Affliction"), (354, "Demonology"), (593, "Destruction")]),
    "druid": ("DRUID", [(574, "Balance"), (134, "Feral Combat"), (573, "Restoration")]),
}
lines = []
lines.append("-- GENERATED from Wowhead (WotLK class abilities + talent spells): which talent tree (spec) each")
lines.append("-- class spell belongs to. Keys are lowercase English spell names. Value = {tree, level, schools}: tree 1..3 = the class's trees")
lines.append("-- in order of specs[], 0 = class spell outside any tree; level = lowest rank level; schools = bitmask"+chr(10)+"-- (1 physical, 2 holy, 4 fire, 8 nature, 16 frost, 32 shadow, 64 arcane). Regenerate, do not edit by hand.")
lines.append("AltBot_SpellTabs = {")
conflicts = 0
for slug, (token, specs) in SPECS.items():
    skill_to_idx = {sid: i + 1 for i, (sid, _) in enumerate(specs)}
    lines.append("    %s = {" % token)
    lines.append("        specs = { %s }," % ", ".join('"%s"' % n for _, n in specs))
    lines.append("        spells = {")
    entries = []
    for name, info in sorted(data[slug].items(), key=lambda kv: kv[0].lower()):
        skills = info["skills"]
        idxs = sorted(set(skill_to_idx.get(s, 0) for s in skills))
        if len(idxs) > 1:
            conflicts += 1
            idxs = [i for i in idxs if i != 0] or idxs
        key = name.lower().replace("\\", "").replace('"', "")
        lvl = info["level"] if info["level"] != 999 else 0
        entries.append('["%s"]={%d,%d,%d}' % (key, idxs[0], lvl, info["schools"]))
    # wrap lines
    row = "            "
    for e in entries:
        if len(row) + len(e) > 110:
            lines.append(row.rstrip())
            row = "            "
        row += e + ", "
    lines.append(row.rstrip())
    lines.append("        },")
    lines.append("    },")
lines.append("}")
import re
LUA = os.path.join(HERE, "..", "AltBot.lua")
src = open(LUA, encoding="utf-8").read()
body = "\n".join(lines).replace("AltBot_SpellTabs = {", "NS.spellTabs = {", 1)
begin = "-- BEGIN GENERATED SPELLTABS"
end_ = "-- END GENERATED SPELLTABS"
i = src.index(begin)
j = src.index(end_)
head = src[i:src.index("\n", i)]
src = src[:i] + head + "\n" + body + "\n" + src[j:]
open(LUA, "w", encoding="utf-8", newline="").write(src)
print("conflicts", conflicts)
