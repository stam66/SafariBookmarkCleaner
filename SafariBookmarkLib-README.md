# SafariBookmarkLib

A LiveCode / HyperXTalk library (script-only stack) that finds stale Safari bookmarks and moves them into two folders, **For deletion** and **Review**, so you can look through them in Safari and delete what you agree with. You build the interface; the library does the work.

Pure LiveCode script. The only outside help is two command-line tools that ship with every Mac, called through `shell()`: `plutil` (converts Safari's binary plist to and from XML) and `curl` (fetches the URLs). No Python, no JavaScript, no externals, no Internet library needed.

## Why the bookmarks file is edited directly

Safari's AppleScript dictionary has no bookmark objects at all (only a "show bookmarks" command), and iOS gives apps no access to Safari bookmarks. The only way to add folders and move bookmarks programmatically is to edit `~/Library/Safari/Bookmarks.plist` while Safari is quit. The library makes a timestamped backup first, rebuilds the file, validates it with `plutil -lint`, and only then replaces the original. iCloud syncs the change to your other devices.

## Requirements

- macOS. Safari must be quit when you apply changes (the library refuses otherwise).
- **Full Disk Access** for whichever app runs the stack (LiveCode IDE, HyperXTalk, or your built standalone): System Settings > Privacy & Security > Full Disk Access. Without it the bookmarks file cannot be read, and `bmcLoadBookmarks()` / `bmcScan` return an error saying so.

## Using it

```
start using stack "SafariBookmarkLib"      -- or add it to your standalone's stack files
```

### Typical flow

```
-- Scan button
on mouseUp
   put empty into field "Log"
   bmcScan the long id of this card         -- progress messages are sent to this card
   if the result is not empty then
      answer the result
      exit mouseUp
   end if
   put bmcSummary() into field "Log"
   enable button "Apply"
end mouseUp

-- Card script: called after every batch of URLs
on bmcProgress pDone, pTotal, pLines
   set the thumbPosition of scrollbar "Progress" to round(100 * pDone / pTotal)
   put pLines & return after field "Log"    -- category TAB reason TAB url, one per URL
end bmcProgress

-- Apply button
on mouseUp
   if bmcSafariIsRunning() then
      answer "Quit Safari first, then click Apply again."
      exit mouseUp
   end if
   answer "Move the flagged bookmarks into 'For deletion' and 'Review'?" with "Cancel" or "Move"
   if it is "Cancel" then exit mouseUp
   put bmcApply() into tResult               -- "OK ..." or "ERROR ..."
   answer tResult
end mouseUp

-- Save report button
on mouseUp
   ask file "Save report as:" with "Safari stale bookmarks.csv"
   if it is not empty then put bmcReportCSV() into URL ("binfile:" & it)
end mouseUp
```

## Handlers

All public names begin with `bmc`.

| Handler | What it does |
|---|---|
| `bmcScan [pProgressTarget]` | Loads the bookmarks, tests every unique URL, stores the verdicts. `the result` is empty on success or an error message. Sends `bmcProgress pDone, pTotal, pLines` to the target after every batch. |
| `bmcApply([pDeleteName], [pReviewName])` | Moves every flagged bookmark into the two folders (default names "For deletion" and "Review"), each with sub-folders by reason. Returns `OK ...` or `ERROR ...`. Refuses while Safari is running. Reading List items are never moved. |
| `bmcSummary()` | Text summary of the last scan: counts per category and reason. |
| `bmcReportCSV()` | CSV of every flagged bookmark, one row per bookmark. |
| `bmcVerdict(pURL)` | `category TAB reason TAB detail TAB httpCode TAB finalURL` for one URL. |
| `bmcVerdicts()` | Array of all verdicts keyed by URL. |
| `bmcBookmarks()` | The loaded bookmarks, one per line: `uuid TAB url TAB folderPath TAB title TAB inReadingList`. |
| `bmcSafariIsRunning()` | true / false. |
| `bmcLastBackup()` | Path of the backup written by the last `bmcApply`. |
| `bmcSetOption pName, pValue` | `"parallel"` simultaneous fetches (32), `"batch"` URLs per progress message (64), `"timeout"` seconds per URL (20). |
| `bmcSetBookmarksFile pPath` | Work on a copy of a bookmarks file instead of Safari's own (for testing). Empty restores the default. |
| `bmcCategories()` | `DELETE,REVIEW,OK` |

Lower level, also public: `bmcLoadBookmarks()`, `bmcCheckURLs pURLs, [pProgressTarget]`, `bmcClassify(pURL, pHTTPCode, pFinalURL, pCurlExit, pBodyFile)`.

## How URLs are classified

| Category | Reason | Trigger |
|---|---|---|
| DELETE | Domain gone (DNS) | the host name no longer resolves |
| DELETE | HTTP 404 / 410 | server says not found / gone |
| DELETE | Parked / for sale | page text matches domain-parking patterns |
| DELETE | Page says not found | 200 response but the page title says "not found" / "404" |
| DELETE | Junk link | chrome:, chrome-extension:, javascript:, about: links |
| REVIEW | Blocked or login required | 401, 403, 406, 418, 429 (often bot protection on sites that work in a real browser) |
| REVIEW | Never loads | timed out |
| REVIEW | Unreachable | connection refused or dropped |
| REVIEW | Server error / bad gateway | 5xx |
| REVIEW | Redirects elsewhere | final URL is on a different domain (includes legitimate rebrands) |
| REVIEW | Site up, resource gone | the bookmarked page redirected to the site's home page |
| REVIEW | Page text says removed | 200 response but the body says the page was removed |
| REVIEW | Bad certificate | TLS failure |
| REVIEW | Nearly empty page | 200 response with almost no content and no title |
| REVIEW | Not a web link | feed:, ftp: and other non-http schemes |
| OK | OK | loads normally |

## Notes

- Timing on a 3,950-bookmark file: reading and parsing the plist takes about 30 seconds (it is done once for the scan and again for the apply, so offsets are never stale); testing 1,780 unique URLs takes 4 to 6 minutes with the default settings. The `shell()` call blocks for the length of each batch, so the UI updates between batches, not during them.
- The network layer is one private function, `checkBatch`, which writes a numbered URL list and runs curl in parallel through `xargs`. If you would rather use tsNet (commercial LiveCode only; it is itself a libcurl wrapper), that is the one function to replace. It must return, per URL, the HTTP status, the final URL after redirects, and a curl-style exit code (6 = DNS failure, 28 = timeout, 0 = completed).
- Undo: quit Safari and copy the backup (path from `bmcLastBackup()`) back over `~/Library/Safari/Bookmarks.plist`.
- One LiveCode pitfall found while building this: `does not contain` is not valid syntax. The engine rejects the whole script silently when a script-only stack is loaded as a library, so nothing in it is callable. Use `not (x contains y)`.
