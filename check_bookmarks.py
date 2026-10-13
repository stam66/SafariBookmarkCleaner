#!/usr/bin/env python3
"""Scan Safari bookmarks and classify each unique URL as OK / DELETE / REVIEW.

Usage:  python3 check_bookmarks.py <Bookmarks.plist> <results.json> [workers]

Read-only: never touches Safari's files. Output is a JSON list of records.
"""
import plistlib, sys, json, re, socket, ssl, time, html
import urllib.request, urllib.error
from urllib.parse import urlsplit
from concurrent.futures import ThreadPoolExecutor, as_completed
import subprocess, tempfile, os

def system_ca_file():
    """python.org builds ship no CA bundle; export the macOS system roots instead."""
    if ssl.create_default_context().cert_store_stats()["x509_ca"] > 0: return None
    pem = os.path.join(tempfile.gettempdir(), "macos-roots.pem")
    with open(pem, "w") as f:
        for kc in ("/System/Library/Keychains/SystemRootCertificates.keychain", "/Library/Keychains/System.keychain"):
            r = subprocess.run(["security", "find-certificate", "-a", "-p", kc], capture_output=True, text=True)
            f.write(r.stdout)
    return pem
CA_FILE = system_ca_file()

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
TIMEOUT = 20
MAX_BODY = 150_000

PARKED = re.compile(r"""
    domain\s+(name\s+)?(is|may\s+be)\s+for\s+sale | buy\s+this\s+domain |
    this\s+domain\s+(name\s+)?(has\s+expired|is\s+parked|is\s+available) |
    parked\s+(free|domain|by) | sedoparking | sedo\.com | hugedomains | afternic |
    dan\.com/buy | domain\s+parking | make\s+an\s+offer\s+on\s+this\s+domain |
    godaddy\.com/forsale | undeveloped\.com | bodis\.com | parkingcrew |
    the\s+domain\s+.{0,60}\s+is\s+for\s+sale | related\s+searches.{0,200}sponsored\s+listings
""", re.I | re.X | re.S)
HARD_404_TITLE = re.compile(r"\b(404|not\s+found|page\s+(does\s*n.t|doesn't|cannot\s+be\s+found)|no\s+longer\s+(exists|available))\b", re.I)
SOFT_404_BODY = re.compile(r"(page\s+(you\s+(requested|are\s+looking\s+for)\s+)?(could\s+not\s+be|cannot\s+be|was\s+not)\s+found|"
                           r"this\s+page\s+(doesn.t|does\s+not)\s+exist|page\s+not\s+found|"
                           r"error\s+404|article\s+(not\s+found|has\s+been\s+removed)|"
                           r"(has\s+been|was)\s+(removed|deleted)|no\s+longer\s+available)", re.I)
TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)

def norm_host(h):
    h = (h or "").lower()
    return h[4:] if h.startswith("www.") else h

def reg_domain(h):
    p = norm_host(h).split(".")
    return ".".join(p[-2:]) if len(p) >= 2 else norm_host(h)

def fetch(url, ctx):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,*/*;q=0.8",
                                               "Accept-Language": "en-GB,en;q=0.9"})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as r:
        body = r.read(MAX_BODY)
        return r.status, r.geturl(), r.headers.get("Content-Type", ""), body

def classify(url):
    rec = {"url": url, "category": "OK", "reason": "", "http": None, "final_url": "", "title": ""}
    sp = urlsplit(url)
    if sp.scheme in ("chrome", "chrome-extension", "javascript", "about"):
        rec.update(category="DELETE", reason=f"{sp.scheme}: link, meaningless in Safari"); return rec
    if sp.scheme not in ("http", "https"):
        rec.update(category="REVIEW", reason=f"non-http scheme ({sp.scheme})"); return rec
    host = sp.hostname or ""
    try:
        socket.getaddrinfo(host, None)
    except socket.gaierror:
        rec.update(category="DELETE", reason="domain does not resolve (DNS)"); return rec
    except Exception as e:
        rec.update(category="REVIEW", reason=f"dns error: {e}"); return rec

    ctx = ssl.create_default_context(cafile=CA_FILE)
    ssl_note = ""
    last_err = None
    for attempt in range(2):
        try:
            status, final, ctype, body = fetch(url, ctx)
            break
        except urllib.error.HTTPError as e:
            rec["http"] = e.code; rec["final_url"] = e.geturl() or url
            if e.code in (404, 410):
                rec.update(category="DELETE", reason=f"HTTP {e.code} not found")
            elif e.code in (401, 403, 429, 406, 418):
                rec.update(category="REVIEW", reason=f"HTTP {e.code} (blocked, login, or bot-check)")
            elif 500 <= e.code < 600:
                rec.update(category="REVIEW", reason=f"HTTP {e.code} server error / bad gateway")
            else:
                rec.update(category="REVIEW", reason=f"HTTP {e.code}")
            return rec
        except ssl.SSLError as e:
            if ctx.check_hostname:
                ctx = ssl._create_unverified_context(); ssl_note = "bad TLS certificate; "
                continue
            last_err = f"TLS error: {e}"; break
        except urllib.error.URLError as e:
            r = e.reason
            if isinstance(r, ssl.SSLError) or "CERTIFICATE" in str(r).upper() or "SSL" in str(r).upper():
                if ctx.check_hostname:
                    ctx = ssl._create_unverified_context(); ssl_note = "bad TLS certificate; "
                    continue
            last_err = f"unreachable: {r}"
            if "timed out" in str(r).lower() or isinstance(r, socket.timeout):
                last_err = "never loads (timeout)"
            time.sleep(1)
        except (socket.timeout, TimeoutError):
            last_err = "never loads (timeout)"; time.sleep(1)
        except Exception as e:
            last_err = f"error: {type(e).__name__}: {str(e)[:80]}"; break
    else:
        rec.update(category="REVIEW", reason=ssl_note + (last_err or "unreachable")); return rec
    if last_err:
        rec.update(category="REVIEW", reason=ssl_note + last_err); return rec

    rec["http"] = status; rec["final_url"] = final
    text = ""
    if "html" in ctype.lower() or ctype == "":
        text = body.decode("utf-8", "ignore")
        m = TITLE_RE.search(text)
        if m: rec["title"] = html.unescape(re.sub(r"\s+", " ", m.group(1))).strip()[:150]
    title = rec["title"]

    if PARKED.search(text[:60000]) or PARKED.search(title):
        rec.update(category="DELETE", reason="parked / domain-for-sale placeholder"); return rec
    if HARD_404_TITLE.search(title):
        rec.update(category="DELETE", reason=f"soft 404: title '{title[:60]}'"); return rec
    if SOFT_404_BODY.search(text[:60000]):
        rec.update(category="REVIEW", reason="page text says not found / removed"); return rec

    fs = urlsplit(final)
    orig_path_meaningful = len(sp.path.strip("/")) > 0 or sp.query
    if reg_domain(fs.hostname) != reg_domain(host):
        rec.update(category="REVIEW", reason=f"redirects to another domain: {norm_host(fs.hostname)}"); return rec
    if orig_path_meaningful and not fs.path.strip("/") and not fs.query:
        rec.update(category="REVIEW", reason="site is up but resource gone (redirected to home page)"); return rec
    if ssl_note:
        rec.update(category="REVIEW", reason=ssl_note.strip("; ")); return rec
    if text and len(text) < 300 and not title:
        rec.update(category="REVIEW", reason="nearly empty page"); return rec
    return rec

def walk(node, path, out):
    t = node.get("WebBookmarkType")
    if t == "WebBookmarkTypeList":
        for c in node.get("Children", []): walk(c, path + [node.get("Title", "")], out)
    elif t == "WebBookmarkTypeLeaf":
        out.append((node.get("URLString", ""), "/".join(path), node.get("URIDictionary", {}).get("title", "")))

def main():
    plist, outfile = sys.argv[1], sys.argv[2]
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    with open(plist, "rb") as f: root = plistlib.load(f)
    leaves = []; walk(root, [], leaves)
    where = {}
    for u, p, t in leaves: where.setdefault(u, []).append({"folder": p, "title": t})
    urls = [u for u in where if u]
    print(f"{len(leaves)} bookmarks, {len(urls)} unique URLs, {workers} workers", flush=True)
    results = []; done = 0; t0 = time.time()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(classify, u): u for u in urls}
        for fut in as_completed(futs):
            u = futs[fut]
            try: rec = fut.result()
            except Exception as e: rec = {"url": u, "category": "REVIEW", "reason": f"checker crashed: {e}"}
            rec["bookmarks"] = where[u]; results.append(rec); done += 1
            if done % 100 == 0: print(f"  {done}/{len(urls)}  {time.time()-t0:.0f}s", flush=True)
    results.sort(key=lambda r: (r["category"], r["reason"], r["url"]))
    with open(outfile, "w") as f: json.dump(results, f, indent=1, ensure_ascii=False)
    from collections import Counter
    c = Counter(r["category"] for r in results)
    print("done in %.0fs:" % (time.time()-t0), dict(c))

if __name__ == "__main__": main()
