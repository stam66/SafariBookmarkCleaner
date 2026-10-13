script "SafariBookmarkLib"
/*
SafariBookmarkLib - LiveCode / HyperXTalk library for finding stale Safari bookmarks
and moving them into "For deletion" and "Review" folders.  macOS only.

Pure LiveCode script.  The only outside help is two command-line tools that ship with
every Mac, called through shell():  plutil (binary plist <-> XML) and curl (fetching URLs).
Safari has no AppleScript access to bookmarks, so the bookmarks file is edited directly;
Safari must be quit while that happens and a backup is always written first.

Use:   start using stack "SafariBookmarkLib"     (or include it in your standalone)

PUBLIC HANDLERS  (all names begin with bmc)
  bmcScan [pProgressTarget]            Load bookmarks, test every unique URL, store verdicts.
                                       Returns empty on success or an error message.
                                       While scanning it sends  bmcProgress pDone, pTotal, pLines
                                       to pProgressTarget (a control or stack) after every batch,
                                       where pLines is one line per URL just tested:
                                       category TAB reason TAB url
  bmcApply [pDeleteName], [pReviewName]  Move flagged bookmarks into the two folders.
                                       Returns "OK ..." or "ERROR ...".  Refuses while Safari runs.
  bmcSummary()                         Text summary of the last scan.
  bmcReportCSV()                       CSV of every flagged bookmark (one row per bookmark).
  bmcVerdict(pURL)                     category TAB bucket TAB detail TAB httpCode TAB finalURL
  bmcVerdicts()                        Array of all verdicts keyed by URL.
  bmcBookmarks()                       The loaded bookmarks, one per line:
                                       uuid TAB url TAB folderPath TAB title TAB inReadingList
  bmcSafariIsRunning()                 true / false
  bmcBackupFolder()                    ~/Library/Application Support/SafariBookmarkCleaner/Backups
  bmcBackups()                         Backups in that folder, newest first (full paths, one per line).
  bmcLastBackup()                      Path of the backup made by the last bmcApply.
  bmcRestore([pBackupPath])            Copy a backup (default: the newest) back over the bookmarks
                                       file.  Returns "OK ..." or "ERROR ...".  Refuses while Safari runs.
  bmcSetBookmarksFile pPath            Work on another plist (testing).  Empty = Safari's own.
  bmcSetOption pName, pValue           "parallel" (32)  "batch" (64)  "timeout" seconds (20)
  bmcCategories()                      "DELETE,REVIEW,OK"

Lower level, also public:  bmcLoadBookmarks(), bmcCheckURLs pURLs, [pProgressTarget],
  bmcClassify(pURL, pHTTPCode, pFinalURL, pCurlExit, pBodyFile)
*/

constant kDefaultDeleteName = "For deletion"
constant kDefaultReviewName = "Review"
constant kUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

local sFile                 -- plist being worked on (empty = Safari's)
local sParallel = 32
local sBatch = 64
local sTimeout = 20
local sRows                 -- uuid TAB url TAB folder TAB title TAB inRL   (one line per bookmark)
local sVerdict              -- sVerdict[url] = category TAB bucket TAB detail TAB http TAB final
local sLastBackup
local sWorkDir

---------------------------------------------------------------- options
command bmcSetBookmarksFile pPath
   put pPath into sFile
end bmcSetBookmarksFile

function bmcBookmarksFile
   if sFile is not empty then return sFile
   return specialFolderPath("home") & "/Library/Safari/Bookmarks.plist"
end bmcBookmarksFile

command bmcSetOption pName, pValue
   switch toLower(pName)
      case "parallel"
         put max(1, pValue) into sParallel
         break
      case "batch"
         put max(1, pValue) into sBatch
         break
      case "timeout"
         put max(1, pValue) into sTimeout
         break
   end switch
end bmcSetOption

function bmcCategories
   return "DELETE,REVIEW,OK"
end bmcCategories

function bmcBookmarks
   return sRows
end bmcBookmarks

function bmcVerdicts
   return sVerdict
end bmcVerdicts

function bmcVerdict pURL
   return sVerdict[pURL]
end bmcVerdict

function bmcLastBackup
   return sLastBackup
end bmcLastBackup

function bmcBackupFolder
   local tFolder
   put specialFolderPath("support") & "/SafariBookmarkCleaner/Backups" into tFolder
   if there is not a folder tFolder then
      if there is not a folder (specialFolderPath("support") & "/SafariBookmarkCleaner") then create folder (specialFolderPath("support") & "/SafariBookmarkCleaner")
      create folder tFolder
   end if
   return tFolder
end bmcBackupFolder

/* Backups newest first, full paths, one per line. */
function bmcBackups
   local tFiles, tLine, tOut
   put files(bmcBackupFolder()) into tFiles
   filter tFiles with "Bookmarks *.plist"
   sort lines of tFiles descending
   repeat for each line tLine in tFiles
      put bmcBackupFolder() & "/" & tLine & LF after tOut
   end repeat
   delete the last char of tOut
   return tOut
end bmcBackups

/* Writes a dated copy of the bookmarks file into the backup folder; returns its path or "ERROR ...". */
private function makeBackup
   local tBackup
   -- file-system friendly name: Bookmarks 2026-10-13 14-05-33.plist
   put bmcBackupFolder() & "/Bookmarks " & dateStamp() & ".plist" into tBackup
   get shell("cp -p " & q(bmcBookmarksFile()) && q(tBackup))
   if the result is not 0 then return "ERROR: could not write backup to " & tBackup & ":" && it
   return tBackup
end makeBackup

private function dateStamp
   local tDate
   convert the seconds to dateItems
   put item 1 of it & "-" & pad2(item 2 of it) & "-" & pad2(item 3 of it) & " " & pad2(item 4 of it) & "-" & pad2(item 5 of it) & "-" & pad2(item 6 of it) into tDate
   return tDate
end dateStamp

private function pad2 pN
   if the number of chars of pN < 2 then return "0" & pN
   return pN
end pad2

/* Put a backup back.  pBackupPath empty = the newest backup.  Safari must be quit. */
function bmcRestore pBackupPath
   local tFile
   if pBackupPath is empty then put line 1 of bmcBackups() into pBackupPath
   if pBackupPath is empty then return "ERROR: there is no backup to restore"
   if there is not a file pBackupPath then return "ERROR: backup not found:" && pBackupPath
   put bmcBookmarksFile() into tFile
   if sFile is empty and bmcSafariIsRunning() then return "ERROR: Safari is running. Quit Safari first, then restore again."
   get shell("plutil -lint " & q(pBackupPath))
   if the result is not 0 then return "ERROR: that backup is not a valid bookmarks file:" && it
   get shell("cp " & q(pBackupPath) && q(tFile))
   if the result is not 0 then return "ERROR: could not copy the backup over " & tFile & ":" && it
   return "OK restored " & pBackupPath & " to " & tFile
end bmcRestore

function bmcSafariIsRunning
   get shell("pgrep -x Safari")
   return the result is 0
end bmcSafariIsRunning

---------------------------------------------------------------- small helpers
private function q pText
   return quote & pText & quote
end q

private function tabItem pLine, pN
   set the itemDelimiter to tab
   return item pN of pLine
end tabItem

private function xmlEscape pText
   replace "&" with "&amp;" in pText
   replace "<" with "&lt;" in pText
   replace ">" with "&gt;" in pText
   return pText
end xmlEscape

private function xmlUnescape pText
   replace "&lt;" with "<" in pText
   replace "&gt;" with ">" in pText
   replace "&quot;" with quote in pText
   replace "&apos;" with "'" in pText
   replace "&amp;" with "&" in pText
   return pText
end xmlUnescape

private function workDir
   if sWorkDir is empty then put specialFolderPath("temporary") & "/SafariBookmarkLib" into sWorkDir
   if there is not a folder sWorkDir then create folder sWorkDir
   return sWorkDir
end workDir

private function newUUID
   return toUpper(uuid("random"))
end newUUID

---------------------------------------------------------------- reading the plist (pure LiveCode)
/* Parse the XML form of the plist, which plutil writes one element per line, tab-indented.
   Fills pDicts[id] with: start (byte of the LF before "<dict>"), end (last byte of "</dict>"),
   parent (dict id), ind (indent), type, title, url, uuid, childrenEnd (byte of the LF before
   the "</array>" closing this folder's Children).  Returns the number of dicts. */
private function parsePlistXML @pData, @pDicts
   local tLine, tOffset, tNext, tInd, tTxt, tDepth, tStack, tTop, tVal, tN
   put 0 into tOffset
   put 0 into tN
   put 0 into tDepth
   repeat for each line tLine in pData
      put tOffset + the number of bytes of tLine + 1 into tNext
      put 0 into tInd
      repeat while byte (tInd + 1) of tLine is tab
         add 1 to tInd
      end repeat
      put byte (tInd + 1) to -1 of tLine into tTxt
      if tTxt is "<dict>" then
         add 1 to tDepth
         add 1 to tN
         put tN into tStack[tDepth]["id"]
         put tInd into tStack[tDepth]["ind"]
         put tOffset into tStack[tDepth]["start"]
         put empty into tStack[tDepth]["key"]
      else if tTxt is "</dict>" then
         put tStack[tDepth] into tTop
         put tOffset + the number of bytes of tLine into tTop["end"]
         if tDepth > 1 then put tStack[tDepth - 1]["id"] into tTop["parent"]
         else put 0 into tTop["parent"]
         put tTop into pDicts[tTop["id"]]
         -- a leaf's title lives in its URIDictionary sub-dict: hand it up
         if tDepth > 1 and tStack[tDepth - 1]["key"] is "URIDictionary" then put tTop["title"] into tStack[tDepth - 1]["title"]
         delete variable tStack[tDepth]
         subtract 1 from tDepth
      else if tDepth > 0 and tInd is tStack[tDepth]["ind"] + 1 then
         if tTxt begins with "<key>" then
            put byte 6 to -7 of tTxt into tStack[tDepth]["key"]
         else if tTxt begins with "<string>" then
            put xmlUnescape(byte 9 to -10 of tTxt) into tVal
            switch tStack[tDepth]["key"]
               case "WebBookmarkType"
                  put tVal into tStack[tDepth]["type"]
                  break
               case "Title"
               case "title"
                  put tVal into tStack[tDepth]["title"]
                  break
               case "URLString"
                  put tVal into tStack[tDepth]["url"]
                  break
               case "WebBookmarkUUID"
                  put tVal into tStack[tDepth]["uuid"]
                  break
            end switch
         else if tTxt is "</array>" and tStack[tDepth]["key"] is "Children" then
            put tOffset into tStack[tDepth]["childrenEnd"]
         end if
      end if
      put tNext into tOffset
   end repeat
   return tN
end parsePlistXML

private function folderPathOf pId, @pDicts
   local tPath, tParent
   put pDicts[pId]["parent"] into tParent
   repeat while tParent > 0
      put "/" & pDicts[tParent]["title"] & tPath into tPath
      put pDicts[tParent]["parent"] into tParent
   end repeat
   return tPath
end folderPathOf

/* Reads the bookmarks file.  Returns empty on success, else an error message. */
function bmcLoadBookmarks
   local tData, tDicts, tId, tPath, tRL, tRows, tErr
   put empty into sRows
   if there is not a file bmcBookmarksFile() then
      return "ERROR: cannot see " & bmcBookmarksFile() & ". Grant Full Disk Access to the app running this stack (System Settings > Privacy & Security)."
   end if
   put shell("plutil -convert xml1 -o - " & q(bmcBookmarksFile())) into tData
   if the result is not 0 or not (tData contains "<plist") then
      return "ERROR: could not read the bookmarks file (" & word 1 to 20 of tData & "). Grant Full Disk Access to the app running this stack."
   end if
   get parsePlistXML(tData, tDicts)
   repeat for each key tId in tDicts
      if tDicts[tId]["type"] is not "WebBookmarkTypeLeaf" then next repeat
      put folderPathOf(tId, tDicts) into tPath
      put (tPath contains "/com.apple.ReadingList") into tRL
      put tDicts[tId]["uuid"] & tab & tDicts[tId]["url"] & tab & tPath & tab & tDicts[tId]["title"] & tab & tRL & LF after tRows
   end repeat
   delete the last char of tRows
   put tRows into sRows
   return empty
end bmcLoadBookmarks

---------------------------------------------------------------- scanning
/* Load + test everything.  Returns empty or an error message. */
command bmcScan pProgressTarget
   local tErr, tURLs, tSeen, tLine, tURL, tScheme
   put empty into sVerdict
   put bmcLoadBookmarks() into tErr
   if tErr is not empty then return tErr
   repeat for each line tLine in sRows
      put tabItem(tLine, 2) into tURL
      if tURL is empty or tSeen[tURL] then next repeat
      put true into tSeen[tURL]
      put toLower(char 1 to (offset(":", tURL) - 1) of tURL) into tScheme
      if tScheme is among the items of "chrome,chrome-extension,javascript,about" then
         put "DELETE" & tab & "Junk link" & tab & tScheme & ": link, meaningless in Safari" into sVerdict[tURL]
      else if tScheme is not among the items of "http,https" then
         put "REVIEW" & tab & "Not a web link" & tab & tScheme & ": link" into sVerdict[tURL]
      else
         put tURL & LF after tURLs
      end if
   end repeat
   delete the last char of tURLs
   bmcCheckURLs tURLs, pProgressTarget
   return empty
end bmcScan

/* Test a list of http(s) URLs (one per line) in batches; results go into the verdicts. */
command bmcCheckURLs pURLs, pProgressTarget
   local tTotal, tN, tBatch, tDone, tLines
   put the number of lines of pURLs into tTotal
   put 0 into tDone
   repeat with tN = 1 to tTotal step sBatch
      put line tN to (tN + sBatch - 1) of pURLs into tBatch
      if tBatch is empty then exit repeat
      put checkBatch(tBatch) into tLines
      add the number of lines of tBatch to tDone
      if pProgressTarget is not empty then
         dispatch "bmcProgress" to pProgressTarget with tDone, tTotal, tLines
         wait 0 milliseconds with messages
      end if
   end repeat
end bmcCheckURLs

/* One batch: write numbered URL list, let xargs run curl in parallel, read results back.
   Returns one line per URL: category TAB bucket TAB url */
private function checkBatch pURLs
   local tDir, tCurl, tCmd, tLines, tLine, tURL, tIndex, tMap, tSafe, tOut
   put workDir() & "/batch" into tDir
   if there is a folder tDir then get shell("rm -rf " & q(tDir))
   create folder tDir
   put 0 into tIndex
   repeat for each line tURL in pURLs
      add 1 to tIndex
      put tURL into tMap[tIndex]
      put tURL into tSafe
      replace " " with "%20" in tSafe
      replace quote with "%22" in tSafe
      replace "'" with "%27" in tSafe
      replace "\" with "%5C" in tSafe
      put tIndex && tSafe & LF after tLines
   end repeat
   put tLines into URL ("binfile:" & tDir & "/urls.txt")
   put "curl -sL --max-redirs 10 --max-time " & sTimeout & " --connect-timeout 10 -A " & q(kUA) & \
         " -o " & q("$0.body") & " -w " & q("$0\t%{http_code}\t%{url_effective}\t%{exitcode}\n") & " " & q("$1") & \
         " >> results.tsv 2>/dev/null" into tCurl
   put "cd " & q(tDir) & " && xargs -P " & sParallel & " -L 1 sh -c '" & tCurl & "' < urls.txt >/dev/null 2>&1" into tCmd
   get shell(tCmd)
   put URL ("binfile:" & tDir & "/results.tsv") into tLines
   repeat for each line tLine in tLines
      put tabItem(tLine, 1) into tIndex
      if tMap[tIndex] is empty then next repeat
      put tMap[tIndex] into tURL
      put bmcClassify(tURL, tabItem(tLine, 2), tabItem(tLine, 3), tabItem(tLine, 4), tDir & "/" & tIndex & ".body") into sVerdict[tURL]
   end repeat
   repeat for each line tURL in pURLs
      if sVerdict[tURL] is empty then put "REVIEW" & tab & "Other" & tab & "no result from curl" into sVerdict[tURL]
      put tabItem(sVerdict[tURL], 1) & tab & tabItem(sVerdict[tURL], 2) & tab & tURL & LF after tOut
   end repeat
   delete the last char of tOut
   return tOut
end checkBatch

/* Decide what a fetch result means.  Returns category TAB bucket TAB detail TAB http TAB finalURL */
function bmcClassify pURL, pCode, pFinal, pExit, pBodyFile
   local tBody, tTitle, tHost, tFinalHost, tPath, tFinalPath, tTail
   put tab & pCode & tab & pFinal into tTail
   switch pExit
      case 6
         return "DELETE" & tab & "Domain gone (DNS)" & tab & "domain does not resolve" & tTail
      case 28
         return "REVIEW" & tab & "Never loads" & tab & "timed out after" && sTimeout && "s" & tTail
      case 7
      case 56
         return "REVIEW" & tab & "Unreachable" & tab & "connection refused or dropped (curl" && pExit & ")" & tTail
      case 35
      case 51
      case 53
      case 58
      case 59
      case 60
      case 77
      case 83
      case 90
      case 91
         return "REVIEW" & tab & "Bad certificate" & tab & "TLS error (curl" && pExit & ")" & tTail
      case 47
         return "REVIEW" & tab & "Redirects elsewhere" & tab & "redirect loop" & tTail
   end switch
   if pExit is not 0 and pExit is not 23 then
      return "REVIEW" & tab & "Other" & tab & "curl error" && pExit & tTail
   end if
   if pCode is 404 or pCode is 410 then
      return "DELETE" & tab & "HTTP 404 / 410" & tab & "HTTP" && pCode && "not found" & tTail
   end if
   if pCode is among the items of "401,403,406,418,429" then
      return "REVIEW" & tab & "Blocked or login required" & tab & "HTTP" && pCode && "(blocked, login, or bot-check)" & tTail
   end if
   if pCode >= 500 then
      return "REVIEW" & tab & "Server error / bad gateway" & tab & "HTTP" && pCode & tTail
   end if
   if pCode < 200 or pCode >= 300 then
      return "REVIEW" & tab & "Other" & tab & "HTTP" && pCode & tTail
   end if
   -- 2xx: look at the page itself
   put textDecode(URL ("binfile:" & pBodyFile), "utf8") into tBody
   put char 1 to 150000 of tBody into tBody
   if matchText(tBody, "(?is)<title[^>]*>(.*?)</title>", tTitle) then
      replace LF with " " in tTitle
      replace tab with " " in tTitle
      put word 1 to -1 of tTitle into tTitle
   else
      put empty into tTitle
   end if
   if matchText(tBody, parkedRegex()) or matchText(tTitle, parkedRegex()) then
      return "DELETE" & tab & "Parked / for sale" & tab & "parked / domain-for-sale placeholder" & tTail
   end if
   if matchText(tTitle, "(?i)\b(404|not\s+found|page\s+(does\s*n.t|doesn't|cannot\s+be\s+found)|no\s+longer\s+(exists|available))\b") then
      return "DELETE" & tab & "Page says not found" & tab & "title:" && char 1 to 60 of tTitle & tTail
   end if
   if matchText(tBody, "(?i)(page\s+(you\s+(requested|are\s+looking\s+for)\s+)?(could\s+not\s+be|cannot\s+be|was\s+not)\s+found|this\s+page\s+(doesn.t|does\s+not)\s+exist|page\s+not\s+found|error\s+404|article\s+(not\s+found|has\s+been\s+removed)|(has\s+been|was)\s+(removed|deleted)|no\s+longer\s+available)") then
      return "REVIEW" & tab & "Page text says removed" & tab & "page text says not found / removed" & tTail
   end if
   put hostOf(pURL) into tHost
   put hostOf(pFinal) into tFinalHost
   put pathOf(pURL) into tPath
   put pathOf(pFinal) into tFinalPath
   if regDomain(tFinalHost) is not regDomain(tHost) then
      return "REVIEW" & tab & "Redirects elsewhere" & tab & "now redirects to" && tFinalHost & tTail
   end if
   if tPath is not empty and tFinalPath is empty then
      return "REVIEW" & tab & "Site up, resource gone" & tab & "redirected to the site's home page" & tTail
   end if
   if the number of chars of tBody < 300 and tTitle is empty then
      return "REVIEW" & tab & "Nearly empty page" & tab & "page has almost no content" & tTail
   end if
   return "OK" & tab & "OK" & tab & "loads" && pCode & tTail
end bmcClassify

private function parkedRegex
   return "(?is)domain\s+(name\s+)?(is|may\s+be)\s+for\s+sale|buy\s+this\s+domain|this\s+domain\s+(name\s+)?(has\s+expired|is\s+parked|is\s+available)|parked\s+(free|domain|by)|sedoparking|sedo\.com|hugedomains|afternic|dan\.com/buy|domain\s+parking|make\s+an\s+offer\s+on\s+this\s+domain|godaddy\.com/forsale|undeveloped\.com|bodis\.com|parkingcrew|the\s+domain\s+.{0,60}\s+is\s+for\s+sale"
end parkedRegex

private function hostOf pURL
   local tHost
   if matchText(pURL, "(?i)^[a-z][a-z0-9+.-]*://(?:[^@/?#]*@)?([^/?#:]+)", tHost) then return toLower(tHost)
   return empty
end hostOf

private function pathOf pURL
   local tPath
   if matchText(pURL, "(?i)^[a-z][a-z0-9+.-]*://[^/?#]*([^#]*)", tPath) then
      replace "/" with empty in tPath
      if tPath is "?" then put empty into tPath
      return tPath
   end if
   return empty
end pathOf

private function regDomain pHost
   if pHost begins with "www." then delete char 1 to 4 of pHost
   set the itemDelimiter to "."
   if the number of items of pHost > 2 then return item -2 to -1 of pHost
   return pHost
end regDomain

---------------------------------------------------------------- results
function bmcSummary
   local tCounts, tURL, tCat, tBucket, tKey, tOut
   repeat for each key tURL in sVerdict
      put tabItem(sVerdict[tURL], 1) into tCat
      put tabItem(sVerdict[tURL], 2) into tBucket
      add 1 to tCounts[tCat]
      add 1 to tCounts[tCat & " / " & tBucket]
   end repeat
   repeat for each item tCat in bmcCategories()
      put tCat & ":" && (tCounts[tCat] + 0) & LF after tOut
      repeat for each line tKey in the keys of tCounts
         if tKey begins with tCat & " / " then put "    " & tCounts[tKey] & "  " & char (length(tCat) + 4) to -1 of tKey & LF after tOut
      end repeat
   end repeat
   delete the last char of tOut
   return tOut
end bmcSummary

function bmcReportCSV
   local tCSV, tLine, tURL, tV
   put "category,reason,detail,http,url,final_url,bookmark_title,folder" & LF into tCSV
   repeat for each line tLine in sRows
      put tabItem(tLine, 2) into tURL
      put sVerdict[tURL] into tV
      if tV is empty or tabItem(tV, 1) is "OK" then next repeat
      put csvCell(tabItem(tV, 1)) & "," & csvCell(tabItem(tV, 2)) & "," & csvCell(tabItem(tV, 3)) & "," & csvCell(tabItem(tV, 4)) & "," & \
            csvCell(tURL) & "," & csvCell(tabItem(tV, 5)) & "," & csvCell(tabItem(tLine, 4)) & "," & csvCell(tabItem(tLine, 3)) & LF after tCSV
   end repeat
   return tCSV
end bmcReportCSV

private function csvCell pText
   replace quote with quote & quote in pText
   return quote & pText & quote
end csvCell

---------------------------------------------------------------- applying to the bookmarks file
/* Moves every DELETE / REVIEW bookmark (never Reading List items) into
   <pDeleteName> / <bucket> and <pReviewName> / <bucket>, two new folders added at the
   end of Safari's top-level bookmark list.  Writes a dated backup into bmcBackupFolder() first.
   Returns "OK ..." or "ERROR ...". */
function bmcApply pDeleteName, pReviewName
   local tFile, tData, tDicts, tId, tURL, tV, tCat, tBucket, tMoved, tCount, tRanges, tOut, tPos, tInsert, tXML, tTmp, tBackup, tR
   if pDeleteName is empty then put kDefaultDeleteName into pDeleteName
   if pReviewName is empty then put kDefaultReviewName into pReviewName
   if sVerdict is not an array then return "ERROR: nothing scanned yet"
   put bmcBookmarksFile() into tFile
   if sFile is empty and bmcSafariIsRunning() then return "ERROR: Safari is running. Quit Safari first, then apply again."
   -- re-read the file fresh so we never work from stale offsets
   put shell("plutil -convert xml1 -o - " & q(tFile)) into tData
   if the result is not 0 or not (tData contains "<plist") then return "ERROR: could not read " & tFile
   get parsePlistXML(tData, tDicts)
   if tDicts[1]["childrenEnd"] is empty then return "ERROR: unexpected bookmarks file layout"
   put 0 into tCount["DELETE"]
   put 0 into tCount["REVIEW"]
   repeat for each key tId in tDicts
      if tDicts[tId]["type"] is not "WebBookmarkTypeLeaf" then next repeat
      put sVerdict[tDicts[tId]["url"]] into tV
      if tV is empty then next repeat
      put tabItem(tV, 1) into tCat
      if tCat is "OK" then next repeat
      if folderPathOf(tId, tDicts) contains "/com.apple.ReadingList" then next repeat
      put tabItem(tV, 2) into tBucket
      put tId & LF after tMoved[tCat][tBucket]
      add 1 to tCount[tCat]
      put tDicts[tId]["start"] & tab & tDicts[tId]["end"] & LF after tRanges
   end repeat
   if tRanges is empty then return "OK nothing to move"
   -- build the two new folders out of the moved blocks
   put empty into tXML
   repeat for each item tCat in "DELETE,REVIEW"
      if tMoved[tCat] is not an array then next repeat
      if tCat is "DELETE" then put folderXML(pDeleteName, subFoldersXML(tMoved[tCat], tData, tDicts)) & LF after tXML
      else put folderXML(pReviewName, subFoldersXML(tMoved[tCat], tData, tDicts)) & LF after tXML
   end repeat
   -- rebuild the document: keep everything except the moved blocks, insert the folders before root's </array>
   sort lines of tRanges numeric by tabItem(each, 1)
   put 1 into tPos
   repeat for each line tR in tRanges
      put byte tPos to tabItem(tR, 1) - 1 of tData after tOut     -- up to (not including) the LF before <dict>
      put tabItem(tR, 2) + 1 into tPos                             -- resume after </dict>
   end repeat
   put tDicts[1]["childrenEnd"] into tInsert
   put byte tPos to tInsert of tData after tOut                     -- up to and including the LF before root </array>
   put tXML after tOut
   put byte (tInsert + 1) to -1 of tData after tOut
   -- write via a temp file, convert back to binary, check, then back up and replace
   put workDir() & "/rewritten.xml" into tTmp
   put tOut into URL ("binfile:" & tTmp)
   get shell("plutil -convert binary1 -o " & q(tTmp & ".plist") && q(tTmp) & " && plutil -lint " & q(tTmp & ".plist"))
   if the result is not 0 then return "ERROR: rebuilt file failed validation, nothing changed:" && it
   put makeBackup() into tBackup
   if tBackup begins with "ERROR" then return tBackup & " (nothing changed)"
   put tBackup into sLastBackup
   get shell("cp " & q(tTmp & ".plist") && q(tFile))
   if the result is not 0 then return "ERROR: could not replace " & tFile & ":" && it
   return "OK moved " & tCount["DELETE"] & " bookmarks to '" & pDeleteName & "' and " & tCount["REVIEW"] & " to '" & pReviewName & "'. Backup: " & tBackup
end bmcApply

private function subFoldersXML pBuckets, @pData, @pDicts
   local tBucket, tId, tBlocks, tOut, tNames
   put the keys of pBuckets into tNames
   sort lines of tNames
   repeat for each line tBucket in tNames
      put empty into tBlocks
      repeat for each line tId in pBuckets[tBucket]
         if tId is empty then next repeat
         put byte (pDicts[tId]["start"] + 1) to pDicts[tId]["end"] of pData & LF after tBlocks
      end repeat
      put folderXML(tBucket && "(" & (the number of lines of pBuckets[tBucket]) & ")", tBlocks) & LF after tOut
   end repeat
   return tOut
end subFoldersXML

private function folderXML pTitle, pChildrenXML
   return "<dict>" & LF & "<key>Children</key>" & LF & "<array>" & LF & pChildrenXML & "</array>" & LF & \
         "<key>Title</key><string>" & xmlEscape(pTitle) & "</string>" & LF & \
         "<key>WebBookmarkType</key><string>WebBookmarkTypeList</string>" & LF & \
         "<key>WebBookmarkUUID</key><string>" & newUUID() & "</string>" & LF & "</dict>"
end folderXML
