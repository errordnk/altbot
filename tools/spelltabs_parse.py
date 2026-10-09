import re, json, sys, collections
BS = chr(92)
classes = ["warrior","paladin","hunter","rogue","priest","death-knight","shaman","mage","warlock","druid"]
import os
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("ALTBOT_WH_CACHE", os.path.join(HERE, "cache")) + "/"

def rows(path):
    s = open(path, encoding='utf-8').read()
    m = re.search(r'listviewspells\s*=\s*\[', s)
    if not m:
        return []
    i = m.end() - 1
    depth = 0
    j = i
    instr = False
    esc = False
    while j < len(s):
        ch = s[j]
        if instr:
            if esc:
                esc = False
            elif ch == BS:
                esc = True
            elif ch == '"':
                instr = False
        else:
            if ch == '"':
                instr = True
            elif ch == '[':
                depth += 1
            elif ch == ']':
                depth -= 1
                if depth == 0:
                    break
        j += 1
    arr = s[i:j + 1]
    arr = re.sub(r'(?<=[,{])([A-Za-z_]+):', r'"\1":', arr)
    arr = re.sub(r'"popularity":[^,}]*', '"popularity":0', arr)
    try:
        return json.loads(arr)
    except Exception as e:
        print("json fail", path, e, file=sys.stderr)
        return []

out = {}
for c in classes:
    cnt = collections.Counter()
    names = collections.defaultdict(lambda: {"skills": set(), "level": 999, "schools": 0})
    for k in ("abilities", "talents"):
        rs = rows(SRC + "wh_%s_%s.html" % (k, c))
        for r in rs:
            sk = r.get("skill") or [0]
            sk0 = sk[0] if isinstance(sk, list) else sk
            d = names[r["name"]]
            d["skills"].add(sk0)
            d["level"] = min(d["level"], r.get("level") or 0)
            d["schools"] |= r.get("schools") or 0
            cnt[(k, sk0)] += 1
    print(c, dict(cnt))
    out[c] = {n: {"skills": sorted(v["skills"]), "level": v["level"], "schools": v["schools"]} for n, v in names.items()}
json.dump(out, open(SRC + "wh_all.json", "w"))
