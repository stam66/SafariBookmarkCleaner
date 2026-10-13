#!/usr/bin/env python3
"""Turn results.json into stale_bookmarks.csv and a short summary."""
import json, sys, csv
from collections import Counter
res = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f); w.writerow(["category", "reason", "http", "url", "final_url", "page_title", "bookmark_title", "folder"])
    for r in res:
        if r["category"] == "OK": continue
        for b in r["bookmarks"]:
            w.writerow([r["category"], r["reason"], r.get("http"), r["url"], r.get("final_url", ""), r.get("title", ""), b["title"], b["folder"]])
c = Counter(r["category"] for r in res); print(dict(c))
for cat in ("DELETE", "REVIEW"):
    print(f"\n{cat} by reason:")
    rc = Counter(r["reason"].split(":")[0].split("(")[0].strip() for r in res if r["category"] == cat)
    for k, n in rc.most_common(): print(f"  {n:5d}  {k}")
