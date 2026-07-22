#!/usr/bin/env python3
"""Third pass: capture full expansion objects (they are not standalone games —
their ids 404 on /game/{id}; the data lives only in the base game's payload).

Fetches only the bases known (from syg-links.ndjson) to have expansions and
writes {"base": id, "expansions": [full objects]} to syg-expansions.ndjson.
"""
import json, os, time, urllib.request, threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "syg-expansions.ndjson")
UA = "SleeveIt-catalog-import/1.0 (approved by site owner; contact: ozsoffy@gmail.com)"

bases = []
for line in open(os.path.join(HERE, "syg-links.ndjson")):
    r = json.loads(line)
    if r.get("expansions"):
        bases.append(r["base"])

done = set()
if os.path.exists(OUT):
    for line in open(OUT):
        try:
            done.add(json.loads(line)["base"])
        except Exception:
            pass
todo = [b for b in bases if b not in done]
print(f"{len(bases)} bases with expansions, {len(todo)} to fetch", flush=True)

lock = threading.Lock()
out = open(OUT, "a")

def fetch(gid):
    url = f"https://api.sleeveyourgames.com/game/{gid}"
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=25) as r:
                data = json.loads(r.read().decode("utf-8"))
                slim = [{k: e.get(k) for k in (
                    "id", "name", "year", "publisher", "bgg_id", "is_verified", "cards")}
                    for e in (data.get("expansions") or [])]
                with lock:
                    out.write(json.dumps({"base": gid, "expansions": slim}) + "\n")
                return
        except Exception:
            if attempt == 2:
                with lock:
                    out.write(json.dumps({"base": gid, "expansions": [], "err": True}) + "\n")
                return
            time.sleep(2)

start = time.time()
with ThreadPoolExecutor(max_workers=3) as pool:
    for n, _ in enumerate(pool.map(fetch, todo), 1):
        if n % 250 == 0:
            with lock:
                out.flush()
            print(f"{n}/{len(todo)} ({n / (time.time() - start):.1f}/s)", flush=True)
        time.sleep(0.08)
out.close()
print("DONE", flush=True)
