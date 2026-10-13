# Safari Bookmark Cleaner

Finds stale Safari bookmarks (dead domains, 404s, parked pages, pages that never load) and moves them into **For deletion** and **Review** folders so you can look through them in Safari and delete what you agree with. Thirty years of bookmarks, sorted in a few minutes.

- `SafariBookmarkLib.hyperxtalkscript` is the library that does the work (below). It is a script-only stack; to open it in LiveCode rather than HyperXTalk, rename it to `SafariBookmarkLib.livecodescript`.
- `SafariBookmarkCleaner.hyperxtalk` is a HyperXTalk / LiveCode stack with the interface; wire its buttons to the library with the scripts under "Typical flow".

## SafariBookmarkLib

A LiveCode / HyperXTalk library (script-only stack) that finds stale Safari bookmarks and moves them into two folders, **For deletion** and **Review**, so you can look through them in Safari and delete what you agree with. You build the interface; the library does the work.

Pure LiveCode script. The only outside help is two command-line tools that ship with every Mac, called through `shell()`: `plutil` (converts Safari's binary plist to and from XML) and `curl` (fetches the URLs). No Python, no JavaScript, no externals, no Internet library needed.

## Why the bookmarks file is edited directly

Safari's AppleScript dictionary has no bookmark objects at all (only a "show bookmarks" command), and iOS gives apps no access to Safari bookmarks. The only way to add folders and move bookmarks programmatically is to edit `~/Library/Safari/Bookmarks.plist` while Safari is quit. The library makes a dated backup first (in `~/Library/Application Support/SafariBookmarkCleaner/Backups`), rebuilds the file, validates it with `plutil -lint`, and only then replaces the original. `bmcRestore()` puts a backup back. iCloud syncs the change to your other devices.

## Requirements

- macOS. Safari must be quit when you apply changes (the library refuses otherwise).
- Access to `~/Library/Safari/Bookmarks.plist`, which macOS protects. Two ways, and the library supports both:
  1. **Let the user pick the file.** Call `bmcChooseBookmarksFile()`; it shows an Open dialog already pointed at the file. Choosing a file in an Open dialog counts as user intent, and macOS then lets the app read and write *that file* for the rest of its run. No settings, no restart. (Verified with Script Editor, an app with no Full Disk Access: before the dialog, reading failed with a permission error; after it, reading, `plutil`, and opening the file for writing all succeeded. Creating a new file beside it is still refused, which the library never needs to do.)
  2. **Full Disk Access** for the app (System Settings > Privacy & Security > Full Disk Access, add the app with the + button; it does not appear in the list by itself). Then everything works without a dialog.

  `bmcCanReadBookmarks()` tells you which situation you are in, and `bmcScan` / `bmcLoadBookmarks()` return a clear error if neither applies.

## Using it

```
start using stack "SafariBookmarkLib"      -- or add it to your standalone's stack files
```

`bmcScan` is a command: call it as `bmcScan <target>` and read `the result`. Calling it with function syntax, `bmcScan(x)`, does not work.

### Typical flow

The scripts below match the controls in `SafariBookmarkCleaner.hyperxtalk`: buttons **Scan**, **Apply**, **Report**, **Help**; fields **Status** and **Log**; progress scrollbar **Progress**.

```
-- Button "Scan"
on mouseUp
   if not bmcCanReadBookmarks() then
      answer "macOS protects Safari's bookmarks file. In the next dialog, choose Bookmarks.plist to let this app work on it." with "OK"
      if bmcChooseBookmarksFile() is empty then exit mouseUp
   end if
   put empty into field "Log"
   put "Reading bookmarks…" into field "Status"
   set the thumbPosition of scrollbar "Progress" to 0
   disable me
   bmcScan the long id of this card         -- progress messages are sent to the card
   enable me
   if the result is not empty then
      put the result into field "Status"
      answer the result
      exit mouseUp
   end if
   put bmcSummary() & return after field "Log"
   put "Scan finished. Review the log, then quit Safari and click Apply." into field "Status"
   enable button "Apply"
   enable button "Report"
end mouseUp

-- Card script: the library sends this after every batch of URLs
on bmcProgress pDone, pTotal, pLines
   put "Tested" && pDone && "of" && pTotal && "URLs" into field "Status"
   set the thumbPosition of scrollbar "Progress" to round(100 * pDone / pTotal)
   put pLines & return after field "Log"    -- category TAB reason TAB url, one line per URL
   set the scroll of field "Log" to the formattedHeight of field "Log"
end bmcProgress

-- Button "Apply"
on mouseUp
   local tResult
   if bmcSafariIsRunning() then
      answer "Quit Safari first, then click Apply again."
      exit mouseUp
   end if
   answer "Move the flagged bookmarks into 'For deletion' and 'Review'?" & return & return & \
         "A backup is written to" && bmcBackupFolder() && "first." with "Cancel" or "Move"
   if it is "Cancel" then exit mouseUp
   put bmcApply() into tResult               -- "OK ..." or "ERROR ..."
   put tResult into field "Status"
   answer tResult
end mouseUp

-- Button "Report"
on mouseUp
   ask file "Save report as:" with "Safari stale bookmarks.csv"
   if it is not empty then put bmcReportCSV() into URL ("binfile:" & it)
end mouseUp

-- A "Restore" button, if you add one
on mouseUp
   local tResult
   if bmcSafariIsRunning() then
      answer "Quit Safari first, then click Restore again."
      exit mouseUp
   end if
   answer "Put back the most recent backup?" & return & line 1 of bmcBackups() with "Cancel" or "Restore"
   if it is "Cancel" then exit mouseUp
   put bmcRestore() into tResult             -- or bmcRestore(<path from bmcBackups()>)
   answer tResult
end mouseUp
```

### Showing results in a DataGrid

The scan tests each distinct URL once (about 1,780 for 3,700 bookmarks, because the old imports hold many copies), and every copy of a URL gets the same verdict. `bmcStats()` gives the numbers for the interface and `bmcResults()` gives rows for a DataGrid, so the log field can go.

```
-- After bmcScan succeeds: counts and the grid
on showResults
   local tStats
   put bmcStats() into tStats
   put tStats["total"] && "bookmarks," && tStats["unique"] && "distinct URLs," && \
         tStats["duplicates"] && "duplicate copies." & return & \
         "Delete:" && tStats["bookmarksDELETE"] && " Review:" && tStats["bookmarksREVIEW"] && \
         " OK:" && tStats["bookmarksOK"] into field "Status"
   filterResults "DELETE"
end showResults

-- Radio buttons named "DELETE", "REVIEW", "OK" and "ALL" in a group "Filter"
on mouseUp
   filterResults the short name of the target
end mouseUp

command filterResults pCategory
   set the dgData of group "Results" to bmcResults(pCategory)
end filterResults

-- In the DataGrid's script: double-click a row to open that bookmark
on mouseDoubleUp
   local tLine
   put the dgHilitedLines of me into tLine
   if tLine is not empty then bmcOpenURL the dgDataOfLine[tLine]["url"] of me
end mouseDoubleUp
```

Set up the DataGrid as a table with columns named `category`, `reason`, `url`, `title`, `folder`, `copies` (the row keys), in that or any order. A button that opens the selected row works the same way as the double-click handler. `copies` shows how many bookmarks share that URL; they all move together when you apply.

## Handlers

All public names begin with `bmc`.

| Handler | What it does |
|---|---|
| `bmcScan [pProgressTarget]` | Loads the bookmarks, tests every unique URL, stores the verdicts. `the result` is empty on success or an error message. Sends `bmcProgress pDone, pTotal, pLines` to the target after every batch. |
| `bmcApply([pDeleteName], [pReviewName])` | Moves every flagged bookmark into the two folders (default names "For deletion" and "Review"), each with sub-folders by reason. Returns `OK ...` or `ERROR ...`. Refuses while Safari is running. Reading List items are never moved. |
| `bmcSummary()` | Text summary of the last scan: counts per category and reason. |
| `bmcStats()` | Array of counts: `total`, `unique`, `duplicates`, `readingList`, `nonWeb`, `urlsDELETE` / `urlsREVIEW` / `urlsOK`, `bookmarksDELETE` / `bookmarksREVIEW` / `bookmarksOK`. |
| `bmcResults(pCategory)` | DataGrid-ready rows, one per bookmark, for `DELETE`, `REVIEW`, `OK` or `ALL`. Each row has `category`, `reason`, `detail`, `http`, `url`, `title`, `folder`, `copies`, `readingList`, `uuid`. |
| `bmcOpenURL pURL` | Opens a bookmark in the default browser. |
| `bmcReportCSV()` | CSV of every flagged bookmark, one row per bookmark. |
| `bmcVerdict(pURL)` | `category TAB reason TAB detail TAB httpCode TAB finalURL` for one URL. |
| `bmcVerdicts()` | Array of all verdicts keyed by URL. |
| `bmcBookmarks()` | The loaded bookmarks, one per line: `uuid TAB url TAB folderPath TAB title TAB inReadingList`. |
| `bmcSafariIsRunning()` | true / false. |
| `bmcLastBackup()` | Path of the backup written by the last `bmcApply`. |
| `bmcSetOption pName, pValue` | `"parallel"` simultaneous fetches (32), `"batch"` URLs per progress message (64), `"timeout"` seconds per URL (20). |
| `bmcCanReadBookmarks()` | true if the bookmarks file can be read right now. |
| `bmcChooseBookmarksFile()` | Open dialog pointed at Safari's Bookmarks.plist. Picking it grants the app access to that file without Full Disk Access. Returns the chosen path, or empty if cancelled. |
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
- Undo: quit Safari and call `bmcRestore()`. Backups are plain copies of `Bookmarks.plist`, so you can also copy one back by hand from the Backups folder.
- One LiveCode pitfall found while building this: `does not contain` is not valid syntax. The engine rejects the whole script silently when a script-only stack is loaded as a library, so nothing in it is callable. Use `not (x contains y)`.
