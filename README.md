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

The scripts below assume these controls: buttons **Scan**, **Apply**, **Report**; a field **Status**; a progress scrollbar **Progress**; a DataGrid (table style) named **log** with columns `category`, `reason`, `url`, `title`, `folder`, `copies`; and a segmented control widget **Filter** whose `itemNames` are `REVIEW,DELETE,OK,ALL` (its `itemLabels` can read however you like).

While the scan runs, each finished batch is appended to the grid (category, reason and URL only). When it completes, the grid is reloaded with the full rows from `bmcResults("ALL")`, which add title, folder and copy count, and that full set is cached in the grid's `allData` custom property so the filter segments never need to call the library again. The full set is what shows by default; the segments narrow it.

```
-- Button "Scan"
on mouseUp
   local tStats
   if not bmcCanReadBookmarks() then
      answer "macOS protects Safari's bookmarks file. In the next dialog, choose Bookmarks.plist to let this app work on it." with "OK"
      if bmcChooseBookmarksFile() is empty then exit mouseUp
   end if
   set the dgData of group "log" to empty
   set the allData of group "log" to empty
   put "Reading bookmarks…" into field "Status"
   set the thumbPosition of scrollbar "Progress" to 0
   disable me
   bmcScan the long id of this card         -- bmcProgress messages come to the card
   enable me
   if the result is not empty then
      put the result into field "Status"
      answer the result
      exit mouseUp
   end if
   -- full rows (title, folder, copies) replace the progress rows, and are cached
   set the dgData of group "log" to bmcResults("ALL")
   set the allData of group "log" to the dgData of group "log"
   set the hilitedItemNames of widget "Filter" to "ALL"   -- show the full set by default
   put bmcStats() into tStats
   put tStats["total"] && "bookmarks," && tStats["unique"] && "distinct URLs," && \
         tStats["duplicates"] && "duplicate copies.  Delete:" && tStats["bookmarksDELETE"] && \
         " Review:" && tStats["bookmarksREVIEW"] && " OK:" && tStats["bookmarksOK"] into field "Status"
   enable button "Apply"
   enable button "Report"
end mouseUp

-- Card script: the library sends this after every batch of URLs
on bmcProgress pDone, pTotal, pLines
   local tData, tN, tLine, tRow
   put "Tested" && pDone && "of" && pTotal && "URLs" into field "Status"
   set the thumbPosition of scrollbar "Progress" to round(100 * pDone / pTotal)
   put the dgData of group "log" into tData
   put the number of lines of the keys of tData into tN
   set the itemDelimiter to tab
   repeat for each line tLine in pLines        -- category TAB reason TAB url
      put item 1 of tLine into tRow["category"]
      put item 2 of tLine into tRow["reason"]
      put item 3 of tLine into tRow["url"]
      add 1 to tN
      put tRow into tData[tN]
   end repeat
   set the dgData of group "log" to tData
   dispatch "ScrollLineIntoView" to group "log" with tN
end bmcProgress

-- Card script: filter from the cached full set
command filterResults pCategory
   local tAll, tRows, tN, tOut, tIndex
   put the allData of group "log" into tAll
   if tAll is not an array then exit filterResults   -- nothing scanned yet
   if pCategory is "ALL" then
      put tAll into tRows
   else
      put 0 into tOut
      repeat with tIndex = 1 to the number of lines of the keys of tAll
         if tAll[tIndex]["category"] is pCategory then
            add 1 to tOut
            put tAll[tIndex] into tRows[tOut]
         end if
      end repeat
   end if
   set the dgData of group "log" to tRows
   set the dgHilitedLines of group "log" to empty
end filterResults

-- Segmented control "Filter": the widget sends hiliteChanged when a segment is clicked
on hiliteChanged
   filterResults the hilitedItemNames of me
end hiliteChanged

-- DataGrid "log" script: double-click a row to open that bookmark in the browser
on mouseDoubleUp
   local tLine
   put the dgHilitedLines of me into tLine
   if tLine is not empty then bmcOpenURL the dgDataOfLine[tLine]["url"] of me
end mouseDoubleUp

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

Notes on the grid: the row keys are the column names, so any order of columns works and extra keys (`detail`, `http`, `uuid`, `readingList`) are simply not shown unless you add a column for them. `copies` is how many bookmarks share that URL; all copies move together when you apply. The scan tests each distinct URL once (about 1,780 for 3,700 bookmarks, because the old imports hold many copies), which is why the progress total is smaller than the bookmark count.

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
