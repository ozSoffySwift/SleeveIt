#!/usr/bin/env python3
"""Polite crawl of api.sleeveyourgames.com/game/{id} — owner-approved data import.

Writes NDJSON lines {"id": n, "status": code, "data": {...}} to games.ndjson.
Resumable: already-fetched ids are skipped on rerun.
"""
import json, os, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "syg-games.ndjson")
MAX_ID = 9907
WORKERS = 3
UA = "SleeveIt-catalog-import/1.0 (approved by site owner; contact: ozsoffy@gmail.com)"

done = set()
if os.path.exists(OUT):
    with open(OUT) as f:
        for line in f:
            try:
                done.add(json.loads(line)["id"])
            except Exception:
                pass
print(f"resuming: {len(done)} already fetched", flush=True)

lock_write = __import__("threading").Lock()
out = open(OUT, "a")
counts = {"ok": 0, "miss": 0, "err": 0}

def fetch(gid: int):
    if gid in done:
        return
    url = f"https://api.sleeveyourgames.com/game/{gid}"
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=25) as r:
                data = json.loads(r.read().decode("utf-8"))
                # keep only the fields the transformer needs — not descriptions
                slim = {k: data.get(k) for k in (
                    "id", "name", "year", "publisher", "edition", "base_game_id",
                    "bgg_id", "is_verified", "cards")}
                with lock_write:
                    out.write(json.dumps({"id": gid, "status": 200, "data": slim}) + "\n")
                    counts["ok"] += 1
                return
        except urllib.error.HTTPError as e:
            if e.code in (404, 500):
                with lock_write:
                    out.write(json.dumps({"id": gid, "status": e.code}) + "\n")
                    counts["miss"] += 1
                return
            time.sleep(2)
        except Exception:
            if attempt == 2:
                with lock_write:
                    out.write(json.dumps({"id": gid, "status": 0}) + "\n")
                    counts["err"] += 1
                return
            time.sleep(2)

ids = [i for i in range(1, MAX_ID + 1) if i not in done]
start = time.time()
with ThreadPoolExecutor(max_workers=WORKERS) as pool:
    for n, _ in enumerate(pool.map(fetch, ids), 1):
        if n % 250 == 0:
            with lock_write:
                out.flush()
            rate = n / (time.time() - start)
            eta = (len(ids) - n) / rate / 60 if rate else 0
            print(f"{n}/{len(ids)} ({rate:.1f}/s, eta {eta:.0f}m) ok={counts['ok']} miss={counts['miss']} err={counts['err']}", flush=True)
        time.sleep(0.08)  # gentle global pacing on top of 3 workers

out.close()
print(f"DONE ok={counts['ok']} miss={counts['miss']} err={counts['err']}", flush=True)
