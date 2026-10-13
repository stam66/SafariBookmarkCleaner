#!/usr/bin/env python3
"""Move stale bookmarks into review folders inside Safari's Bookmarks.plist.

Usage:  python3 apply_to_safari.py <results.json> [--dry-run]

Safari MUST be quit first. A timestamped backup of Bookmarks.plist is written
next to the original before anything is changed. Reading List items are never
moved. Each stale bookmark is moved (not copied) into
  Bookmarks Menu / Stale - Delete / <reason>
  Bookmarks Menu / Stale - Review / <reason>
so you can glance through them in Safari and delete the folders when happy.
"""
import plistlib, sys, json, os, uuid, shutil, subprocess, time, re

PLIST = os.path.expanduser("~/Library/Safari/Bookmarks.plist")
DELETE_FOLDER, REVIEW_FOLDER = "Stale - Delete", "Stale - Review"

def folder(title):
    return {"Title": title, "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": str(uuid.uuid4()).upper(), "Children": []}

def bucket(reason):
    r = reason.lower()
    if "dns" in r: return "Domain gone (DNS)"
    if "parked" in r: return "Parked / for sale"
    if "soft 404" in r: return "Page says not found"
    if r.startswith("http 404") or r.startswith("http 410"): return "HTTP 404 / 410"
    if "blocked" in r: return "Blocked or login required (403 etc)"
    if "server error" in r: return "Server error / bad gateway"
    if "timeout" in r: return "Never loads"
    if "unreachable" in r: return "Unreachable"
    if "another domain" in r: return "Redirects elsewhere"
    if "home page" in r: return "Site up, resource gone"
    if "tls" in r: return "Bad certificate"
    if "not found / removed" in r: return "Page text says removed"
    return "Other"

def main():
    results = json.load(open(sys.argv[1]))
    dry = "--dry-run" in sys.argv
    verdict = {r["url"]: (r["category"], bucket(r["reason"])) for r in results if r["category"] in ("DELETE", "REVIEW")}
    if not dry and subprocess.run(["pgrep", "-x", "Safari"], capture_output=True).returncode == 0:
        sys.exit("Safari is running. Quit Safari first, then re-run.")
    with open(PLIST, "rb") as f: root = plistlib.load(f)

    moved = {"DELETE": {}, "REVIEW": {}}
    def prune(node, in_reading_list=False):
        kids = node.get("Children")
        if kids is None: return
        keep = []
        for c in kids:
            t = c.get("WebBookmarkType")
            if t == "WebBookmarkTypeList":
                prune(c, in_reading_list or c.get("Title") == "com.apple.ReadingList")
                keep.append(c)
            elif t == "WebBookmarkTypeLeaf" and not in_reading_list and c.get("URLString") in verdict:
                cat, b = verdict[c["URLString"]]
                moved[cat].setdefault(b, []).append(c)
            else:
                keep.append(c)
        node["Children"] = keep
    prune(root)

    menu = next(c for c in root["Children"] if c.get("Title") == "BookmarksMenu")
    menu.setdefault("Children", [])
    for cat, title in (("DELETE", DELETE_FOLDER), ("REVIEW", REVIEW_FOLDER)):
        if not moved[cat]: continue
        top = folder(title)
        for b in sorted(moved[cat]):
            sub = folder(f"{b} ({len(moved[cat][b])})"); sub["Children"] = moved[cat][b]; top["Children"].append(sub)
        menu["Children"].insert(0, top)

    for cat in moved:
        n = sum(len(v) for v in moved[cat].values())
        print(f"{cat}: {n} bookmarks ->", {k: len(v) for k, v in sorted(moved[cat].items())})
    if dry:
        print("dry run: nothing written"); return
    backup = PLIST.replace(".plist", f".backup-{time.strftime('%Y%m%d-%H%M%S')}.plist")
    shutil.copy2(PLIST, backup); print("backup:", backup)
    with open(PLIST, "wb") as f: plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
    print("written:", PLIST)

if __name__ == "__main__": main()
