#!/usr/bin/env python3
"""Transforms the crawled SleeveYourGames data into SleeveIt's catalog schema.

Policy:
- Hand-curated entries in the existing catalog stay authoritative; an SYG game
  whose normalised title matches an existing title/alias is skipped.
- Card groups map to the SMALLEST sleeve standard that fits (sleeve >= card,
  within a slack cap) — a fit too loose is left unmatched rather than wrongly
  recommended. Unmatched dimension stats are printed so the standards list can
  be extended deliberately.
- Every imported game carries source provenance ("source": "syg", plus the SYG
  id and bgg id). Swift's Codable ignores unknown JSON keys, so these ride
  along without schema changes.
"""
import json, re, sys, collections

CRAWL = "syg-games.ndjson"
CATALOG_IN = sys.argv[1] if len(sys.argv) > 1 else "catalog-v6.json"
CATALOG_OUT = sys.argv[2] if len(sys.argv) > 2 else "catalog-v7.json"

# The canonical sleeve lineup (Mayday / Sleeve Kings / Gamegenic product sizes).
# id, name, w, h, tagline, blurb
NEW_STANDARDS = [
    ("mini-chimera",    "Mini Chimera",      43, 65,  None, None),  # == existing "mini"
    ("card-45x68",      "Mini European Plus",45, 68,  "45×68 decks", "Slightly wider than Mini European."),
    ("card-46x71",      "Small Square-ish",  46, 71,  "46×71 decks", "Between the mini and standard families."),
    ("card-50x75",      "Small (50×75)",     50, 75,  "50×75 decks", "Small cards common in older Euros."),
    ("card-55x80",      "Compact (55×80)",   55, 80,  "55×80 decks", "Compact cards between mini and bridge."),
    ("card-56x87",      "Bridge (56×87)",    56, 87,  "56×87 decks", "Classic bridge cards."),
    ("card-61x103",     "Space (61×103)",    61, 103, "61×103 decks", "Tall narrow cards."),
    ("card-63x112",     "Tarot Narrow",      63.5, 112, "63.5×112 decks", "Narrow tarot cards."),
    ("card-65x92",      "Euro Plus (65×92)", 65, 92,  "65×92 decks", "Slightly taller than standard."),
    ("card-70x110",     "Magnum (70×110)",   70, 110, "70×110 decks", "Between Euro and Tarot."),
    ("card-73x73",      "Square (73×73)",    73, 73,  "73×73 square decks", "Mid square cards."),
    ("card-80x80",      "Square (80×80)",    80, 80,  "80×80 square decks", "Large square cards."),
    ("card-82x82",      "Square (82×82)",    82, 82,  "82×82 square decks", "Extra-large square cards."),
    ("card-87x112",     "Magnum Gold",       87, 112, "87×112 decks", "Oversized cards (Fluxx-style boxes and big-box games)."),
    ("card-92x92",      "Square (92×92)",    92, 92,  "92×92 square decks", "Jumbo square cards."),
    ("card-100x130",    "Jumbo (100×130)",   100, 130, "100×130 decks", "Very large display cards."),
    # Second wave, driven by the crawl's unmatched-dimensions histogram.
    ("square-53",       "Mini Square (53×53)", 53, 53, "51–53mm square decks", "Small square cards (tile-laying and kids' games)."),
    ("square-65",       "Square (65×65)",    65, 65,  "60–65mm square decks", "The most common square card size."),
    ("card-44x80",      "Slim (44×80)",      44, 80,  "43×80 decks", "Narrow ticket-style cards."),
    ("card-75x105",     "Large (75×105)",    75, 105, "75×105 decks", "Large cards between Euro and Dixit sizes."),
    ("card-80x120",     "Dixit (80×120)",    80, 120, "80×120 decks", "Dixit-size story cards."),
    ("card-88x125",     "Jumbo (88×125)",    88, 125, "88×125 decks", "Jumbo cards."),
    ("card-90x140",     "Super Jumbo (90×140)", 90, 140, "90×140 decks", "Oversized display cards."),
]
SLACK = 6.5  # max mm of looseness per dimension for a "fit"

def normalize(title):
    t = title.lower()
    t = re.sub(r"\(.*?\)", "", t)
    t = re.sub(r"[–—-].*$", "", t) if " – " in t or " — " in t or " - " in t else t
    t = re.sub(r"[^a-z0-9 ]", " ", t)
    words = [w for w in t.split() if w not in ("the", "a", "an")]
    return " ".join(words)

catalog = json.load(open(CATALOG_IN))
existing_keys = set()
for g in catalog["games"]:
    existing_keys.add(normalize(g["title"]))
    for a in g.get("aliases", []):
        existing_keys.add(normalize(a))

sizes = [(s["id"], float(s["widthMM"]), float(s["heightMM"])) for s in catalog["sizes"]]
for sid, name, w, h, tag, blurb in NEW_STANDARDS:
    if sid == "mini-chimera":  # duplicate of existing "mini"
        continue
    if not any(s[0] == sid for s in sizes):
        catalog["sizes"].append({
            "id": sid, "name": name, "widthMM": w, "heightMM": h,
            "tagline": tag or "", "blurb": blurb or "", "examples": []
        })
        sizes.append((sid, w, h))

def best_size(w, h):
    """Smallest standard that fits the card (normalised portrait), within slack."""
    cw, ch = min(w, h), max(w, h)
    fits = []
    for sid, sw, shh in sizes:
        ssw, ssh = min(sw, shh), max(sw, shh)
        if ssw >= cw - 0.6 and ssh >= ch - 0.6 and (ssw - cw) <= SLACK and (ssh - ch) <= SLACK:
            fits.append((ssw * ssh, sid))
    return min(fits)[1] if fits else None

# ---- Load crawl ----
rows = {}
for line in open(CRAWL):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get("status") == 200 and r.get("data"):
        rows[r["id"]] = r["data"]

print(f"crawled ok: {len(rows)}")

unmatched = collections.Counter()
skipped_dup = skipped_nocards = skipped_baddims = 0
added = []
id_map = {}  # syg id -> new catalog id

def make_decks(cards):
    decks, misses = [], 0
    for i, c in enumerate(cards or []):
        try:
            q = int(c.get("card_quantity") or 0)
            w = float(c.get("width") or 0)
            h = float(c.get("height") or 0)
        except (TypeError, ValueError):
            misses += 1
            continue
        if q <= 0 or w < 20 or h < 20 or w > 200 or h > 200:
            misses += 1
            continue
        sid = best_size(w, h)
        if sid is None:
            unmatched[(w, h)] += q
            misses += 1
            continue
        label = "Cards" if len(cards) == 1 else f"Cards ({w:g}×{h:g} mm)"
        decks.append({"label": label, "count": q, "sizeID": sid,
                      "cardWidthMM": w, "cardHeightMM": h})
    return decks, misses

for gid, g in sorted(rows.items()):
    title = (g.get("name") or "").strip()
    if not title:
        continue
    if normalize(title) in existing_keys:
        skipped_dup += 1
        continue
    decks, misses = make_decks(g.get("cards"))
    if not decks:
        skipped_nocards += 1 if not g.get("cards") else 0
        skipped_baddims += 1 if g.get("cards") else 0
        continue
    entry = {
        "id": f"syg-{gid}",
        "title": title,
        "publisher": (g.get("publisher") or "Unknown").strip() or "Unknown",
        "year": int(g.get("year") or 0) or 2000,
        "decks": decks,
        "source": "sleeveyourgames",
        "sygID": gid,
    }
    if g.get("bgg_id"):
        entry["bggID"] = str(g["bgg_id"])
    if g.get("is_verified"):
        entry["sygVerified"] = True
    id_map[gid] = entry["id"]
    added.append(entry)

# Expansions are not standalone games in the API (their ids 404 on /game/{id});
# they exist only as full objects inside the base game's payload, captured by
# the third crawl pass. Bases that were skipped as duplicates of curated games
# still get their expansions — linked to the curated entry instead.
curated_id_by_key = {}
for g in catalog["games"]:
    curated_id_by_key.setdefault(normalize(g["title"]), g["id"])
base_title_by_syg = {gid: g.get("name", "") for gid, g in rows.items()}

linked = dropped_links = exp_dup = exp_nodeck = 0
seen_exp = set()
try:
    exp_lines = list(open("syg-expansions.ndjson"))
except FileNotFoundError:
    exp_lines = []
    print("WARNING: syg-expansions.ndjson missing — no expansions imported")

for line in exp_lines:
    r = json.loads(line)
    base_gid = r["base"]
    base_catalog_id = id_map.get(base_gid) \
        or curated_id_by_key.get(normalize(base_title_by_syg.get(base_gid, "")))
    for exp in r.get("expansions", []):
        eid = exp.get("id")
        if eid is None or eid in seen_exp:
            continue
        seen_exp.add(eid)
        name = (exp.get("name") or "").strip()
        if not name:
            continue
        base_title = (base_title_by_syg.get(base_gid) or "").strip()
        # Bare names like "The City Gates" read as unrelated games in search;
        # prefix the base title unless the name already carries it.
        title = name if not base_title or base_title.lower() in name.lower() \
            else f"{base_title}: {name}"
        if normalize(title) in existing_keys or normalize(name) in existing_keys:
            exp_dup += 1
            continue
        decks, _ = make_decks(exp.get("cards"))
        if not decks:
            exp_nodeck += 1
            continue
        entry = {
            "id": f"syg-x{eid}",
            "title": title,
            "publisher": (exp.get("publisher") or "Unknown").strip() or "Unknown",
            "year": int(exp.get("year") or 0) or 2000,
            "decks": decks,
            "source": "sleeveyourgames",
            "sygID": f"x{eid}",
        }
        if exp.get("bgg_id"):
            entry["bggID"] = str(exp["bgg_id"])
        if exp.get("is_verified"):
            entry["sygVerified"] = True
        if base_catalog_id:
            entry["baseGameID"] = base_catalog_id
            linked += 1
        else:
            dropped_links += 1
        added.append(entry)

catalog["games"].extend(added)
catalog["version"] = 7
json.dump(catalog, open(CATALOG_OUT, "w"), separators=(",", ":"), ensure_ascii=False)
open(CATALOG_OUT, "a").write("\n")

print(f"added: {len(added)} (expansions linked: {linked}, unlinked: {dropped_links}, dup: {exp_dup}, no decks: {exp_nodeck})")
print(f"skipped: duplicates of curated={skipped_dup}, no cards={skipped_nocards}, bad dims only={skipped_baddims}")
print(f"total games now: {len(catalog['games'])}, sizes: {len(catalog['sizes'])}")
print("top unmatched dims (by cards):", unmatched.most_common(12))
import os
print("output size:", os.path.getsize(CATALOG_OUT), "bytes")
