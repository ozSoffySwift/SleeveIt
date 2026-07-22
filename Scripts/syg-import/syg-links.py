#!/usr/bin/env python3
"""Second pass: recover base→expansion links dropped by the slim first crawl.

Reads the ids that returned 200 in syg-games.ndjson, re-fetches each, and
writes {"base": id, "expansions": [ids]} for games that have any.
"""
import json, os, time, urllib.request, urllib.error, threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "syg-games.ndjson")
OUT = os.path.join(HERE, "syg-links.ndjson")
UA = "SleeveIt-catalog-import/1.0 (approved by site owner; contact: ozsoffy@gmail.com)"

ok_ids = []
for line in open(SRC):
    try:
        r = json.loads(line)
        if r.get("status") == 200:
            ok_ids.append(r["id"])
    except Exception:
        pass

done = set()
if os.path.exists(OUT):
    for line in open(OUT):
        try:
            done.add(json.loads(line)["base"])
        except Exception:
            pass
todo = [i for i in ok_ids if i not in done]
print(f"{len(ok_ids)} live ids, {len(todo)} to fetch", flush=True)

lock = threading.Lock()
out = open(OUT, "a")

def fetch(gid):
    url = f"https://api.sleeveyourgames.com/game/{gid}"
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=25) as r:
                data = json.loads(r.read().decode("utf-8"))
                exps = [e.get("id") for e in (data.get("expansions") or []) if e.get("id")]
                with lock:
                    out.write(json.dumps({"base": gid, "expansions": exps}) + "\n")
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
        if n % 500 == 0:
            with lock:
                out.flush()
            rate = n / (time.time() - start)
            print(f"{n}/{len(todo)} ({rate:.1f}/s)", flush=True)
        time.sleep(0.08)
out.close()
print("DONE", flush=True)
