"""Regenerates two tables inside AltBot.lua from the QuestChromeCraft addon's QuestData_RU.lua:
  NS.QUEST_ZONE      quest id -> zone id          (between the QUESTZONE markers)
  NS.QUEST_TITLE_RU  quest id -> Russian title    (between the QUESTTITLES markers)
Run: python tools/questzone_generate.py"""
import re

import os
HERE = os.path.dirname(os.path.abspath(__file__))
# QuestChromeCraft is a separate addon: point ALTBOT_QCC at its QuestData_RU.lua
QCC = os.environ.get("ALTBOT_QCC", os.path.join(HERE, "..", "..", "QuestChromeCraft", "QuestData_RU.lua"))
LUA = os.path.join(HERE, "..", "AltBot.lua")

data = open(QCC, encoding="utf-8").read()
zones, titles = {}, {}
# the Title value is already a Lua string literal in the source: copied as written
pat = re.compile(r'\["(\d+)"\]=\{\["Title"\]="((?:[^"\\]|\\.)*)".*?\["ZoneId"\]=(-?\d+)', re.S)
for m in pat.finditer(data):
    qid, title, zone = int(m.group(1)), m.group(2), int(m.group(3))
    if zone != 0:
        zones[qid] = zone
    if title:
        titles[qid] = title


def block(name, items, fmt):
    lines = [name + " = {"]
    row = "    "
    for qid in sorted(items):
        entry = fmt % (qid, items[qid])
        if len(row) + len(entry) > 118:
            lines.append(row.rstrip())
            row = "    "
        row += entry
    lines.append(row.rstrip())
    lines.append("}")
    return "\n".join(lines)


def put(src, marker, body):
    begin = "-- BEGIN GENERATED " + marker
    end_ = "-- END GENERATED " + marker
    i = src.index(begin)
    j = src.index(end_)
    head = src[i:src.index("\n", i)]
    return src[:i] + head + "\n" + body + "\n" + src[j:]


src = open(LUA, encoding="utf-8").read()
src = put(src, "QUESTZONE", block("NS.QUEST_ZONE", zones, "[%d]=%d,"))
src = put(src, "QUESTTITLES", block("NS.QUEST_TITLE_RU", titles, '[%d]="%s",'))
open(LUA, "w", encoding="utf-8", newline="").write(src)
print(len(zones), "zones,", len(titles), "titles")
