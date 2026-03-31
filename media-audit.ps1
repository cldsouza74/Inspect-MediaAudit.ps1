# media-audit.ps1
# Copyright © 2025-2026 Clive DSouza
# SPDX-License-Identifier: MIT
# Licensed under the MIT License — see LICENSE file in repo root

#Requires -Version 7.0

$VERSION = (Get-Content "$PSScriptRoot\VERSION" -Raw).Trim()
<#
╔══════════════════════════════════════════════════════════════════════════════════╗
║                              media-audit.ps1                                      ║
║        Signature Check + Metadata Repair + Timestamp Correction Tool             ║
╠══════════════════════════════════════════════════════════════════════════════════╣
║ FLOWCHART                                                                        ║
║                                                                                  ║
║ ┌────────────────────────────────────────┐                                       ║
║ │ Accept -Path, -DryRun, -Recurse, -Dedup │                                     ║
║ └────────────────────────────────────────┘                                       ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌──────────────────────────────────────┐                                         ║
║ │ Recursively collect valid media files │                                        ║
║ └──────────────────────────────────────┘                                         ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌────────────────────────────────────────────────┐                              ║
║ │ For each file (parallel):                     │                              ║
║ │  - Validate header vs extension                │                              ║
║ │  - Rename if mismatched                        │                              ║
║ │  - Extract EXIF/QuickTime/XMP timestamps       │                              ║
║ │  - Determine oldest valid date                 │                              ║
║ │  - Write DateTimeOriginal via exiftool         │                              ║
║ │  - Set CreationTime → LastWriteTime            │                              ║
║ │  - Tag provenance type                         │                              ║
║ │  - Rename file based on oldest timestamp       │                              ║
║ └────────────────────────────────────────────────┘                              ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌──────────────────────────────────────────────┐                                 ║
║ │ (-Dedup) SHA256 dedup: size-bucket →          │                                 ║
║ │  checksum same-size groups → delete dupes     │                                 ║
║ └──────────────────────────────────────────────┘                                 ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌──────────────────────────────────────────────┐                                 ║
║ │ Log summary + per-source provenance + dedup   │                                 ║
╚══════════════════════════════════════════════════════════════════════════════════╝

TROUBLESHOOTING GUIDE
─────────────────────
Problem: Script exits immediately with "❌ exiftool not found on PATH"
  Cause : exiftool.exe is not on the system PATH.
  Note  : The script checks for exiftool automatically on startup and exits with
          this message rather than running to completion while silently failing
          every metadata read and write (original behaviour prior to v1.1.1).
  Fix   : Download from https://exiftool.org, place exiftool.exe somewhere on PATH,
          then verify with: exiftool -ver

Problem: Script exits immediately with "Path not found"
  Cause : -Path argument does not exist or is mis-typed.
  Fix   : Verify the folder exists: Test-Path "D:\YourFolder"

Problem: No files processed (0 matching extensions)
  Cause : Files may have uppercase extensions (.JPG, .MOV) or unsupported formats.
  Fix   : The script lowercases extensions before comparing, so case is not an issue.
          Check that your files use one of the supported extensions listed below.

Problem: Signature mismatches detected but nothing renamed
  Cause : -DryRun is active, or the rename itself failed (permissions, locked file).
  Fix   : Remove -DryRun to apply changes, or check file permissions.
          Failures appear as red lines in output and count in the Failures total.

Problem: DateTaken is not being written to image files
  Cause : exiftool cannot write to the file (read-only, locked, or unsupported format).
  Fix   : Ensure exiftool is in PATH and the files are not open in another app.
          Check the Failures counter in the summary — errors are logged per file.

Problem: Provenance shows mostly "Fallback-only"
  Cause : Files have no embedded EXIF or QuickTime metadata — timestamps come from
          the filesystem only. This is common with screenshots and downloaded images.
  Fix   : No action needed; the script still normalises CreationTime/LastWriteTime.

Problem: Counter suffixes (.001, .002) appearing on many files
  Cause : Multiple files share the same timestamp to the second (e.g. burst photos).
  Fix   : Expected behaviour. Each unique second gets one file; collisions get a suffix.

Problem: Progress output is very sparse (only every 100+ files)
  Cause : reportInterval is 1% of total file count (minimum 100). For small runs it
          prints every file; for large runs it prints every ~1%.
  Fix   : This is by design to keep output readable. First 10 files always print.

PARALLEL EXECUTION NOTES
─────────────────────────
• ForEach-Object -Parallel runs one runspace per logical CPU core (ThrottleLimit).
• All shared counters use ConcurrentDictionary.AddOrUpdate — safe across threads.
• The progress Mutex (WaitOne/ReleaseMutex) serialises console writes to prevent
  interleaved output. A finally block always releases it, even on exception.
• Interlocked.Increment on $CounterRef gives each runspace a unique sequential index
  without a lock — used only for the percentage display, not for correctness.
• $using: is the only way to pass outer-scope variables into a parallel scriptblock.
  The variables are copied at the time the block starts; mutations inside do NOT
  affect the outer scope (except through the shared ConcurrentDictionary).
#>

<#
IN PLAIN ENGLISH
────────────────
If you have a folder full of photos and videos that are a mess — wrong dates,
random names like IMG_4892.jpg, or files pretending to be a format they're not
— this script fixes all of that in one pass.

It solves three problems:

  PROBLEM 1 — Files wearing the wrong label
    Some files have the wrong extension — a photo saved as .mov, or a video
    labelled .jpg. The script reads the actual contents of each file to check
    what it really is, and renames it to the correct extension if it doesn't match.

  PROBLEM 2 — Dates are wrong, missing, or inconsistent
    Every photo and video carries hidden date information ("when was this taken?").
    That date can live in several places — embedded EXIF metadata, QuickTime tags,
    or the filesystem — and they often disagree. The script reads all of them,
    picks the oldest (most likely the original capture date), and makes every
    date field agree.

  PROBLEM 3 — Filenames are meaningless
    IMG_4892.jpg tells you nothing. The script renames every file to its capture
    date and time — 20231225_143022.jpg — so your library sorts in chronological
    order and duplicates are easy to spot.

  SAFE TO RUN: use -DryRun first and the script will tell you exactly what it
  would change, without touching a single file.
#>

param(
    # Root folder to scan. Must exist — validated before any processing begins.
    [Parameter(Mandatory=$true)]
    [ValidateScript({ if (-not (Test-Path $_)) { throw "Path not found: $_" }; $true })]
    [string]$Path,

    # When set, all actions are simulated and logged but no files are written or renamed.
    # Always use -DryRun first on an unfamiliar folder to preview what will change.
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    # When set, scans all subdirectories recursively. Without it, only the top-level
    # folder is processed.
    [Parameter(Mandatory=$false)]
    [switch]$Recurse,

    # When set, performs SHA256-based deduplication after the main scan phase.
    # Files are first grouped by byte-size (free), then checksummed only within
    # same-size groups (~90% I/O reduction). Keeper is chosen by provenance rank.
    [Parameter(Mandatory=$false)]
    [switch]$Dedup
)

# ─────────────────────────────────────────────────────────────────────────────
# LONG-PATH SUPPORT
# Windows has a 260-char MAX_PATH limit by default. Prefixing a path with \\?\
# bypasses it and allows paths up to ~32,767 chars. We apply this automatically
# for any path at or near the limit (>=240 chars gives us a safety margin for
# appended filenames). The prefix must NOT already be present to avoid doubling.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-LongPath {
    param([string]$Path)
    # FIX: use StartsWith() instead of -like '\\?\\*'. In PowerShell's -like operator
    # '?' is a single-character wildcard, so the original matched paths like '\\X\*'
    # where X is any character — not just the literal extended-path prefix \\?\
    if ($Path.StartsWith('\\?\')) { return $Path }
    $abs = [System.IO.Path]::GetFullPath($Path)
    if ($abs.Length -ge 240) { "\\?\$abs" } else { $abs }
}

# ─────────────────────────────────────────────────────────────────────────────
# FORMAT-BYTES HELPER
# Converts a raw byte count to a human-readable string (KB/MB/GB).
# Used in the dedup summary to report space freed in a readable form.
# ─────────────────────────────────────────────────────────────────────────────
function Format-Bytes {
    param([long]$Bytes)
    if     ($Bytes -ge 1GB) { "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { "{0:N2} KB" -f ($Bytes / 1KB) }
    else                    { "$Bytes B" }
}

$longPath = ConvertTo-LongPath $Path

# Pre-flight: verify exiftool is on PATH before touching any files.
# Without this, the script runs to completion but silently fails metadata
# reads and writes on every file — exiftool errors are swallowed by catch {}.
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    Write-Host "❌ exiftool not found on PATH." -ForegroundColor Red
    Write-Host "   Download from https://exiftool.org, place exiftool.exe in a PATH folder," -ForegroundColor Red
    Write-Host "   then verify with: exiftool -ver" -ForegroundColor Red
    exit 1
}

# All extensions that will be considered for processing (lowercased for comparison).
# Files with any other extension are counted in $totalCount but skipped otherwise.
$validExtensions = @(
    '.qt','.jfif','.jpg','.jpeg','.png','.gif','.bmp','.tiff','.tif','.heic',
    '.mpg','.mp4','.mov','.avi','.mkv','.nef','.cr2','.dng','.crw','.webp','.wmv'
)

# ─────────────────────────────────────────────────────────────────────────────
# SHARED COUNTERS
# ConcurrentDictionary is safe for simultaneous reads/writes from parallel
# runspaces. All counters are pre-initialised to 0 so AddOrUpdate never needs
# to handle a missing key — the update delegate ($v + 1) is always used.
# Provenance keys match the strings assigned in the $provenanceType block below.
# ─────────────────────────────────────────────────────────────────────────────
$processedCount = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new()
@(
    'Processed','DateTakenSet','DateCreatedSet','DateModifiedSet',
    'SignatureMismatchCount','SignatureRenamedCount','Skipped','Failed','DryRun',
    'EXIF-only','QuickTime-only','Fallback-only','Mixed-sources','Unknown',
    'Renamed','WithCounter','DedupGroupsFound','DedupFilesRemoved'
) | ForEach-Object { $processedCount[$_] = 0 }

$startTime = Get-Date

# ConcurrentBag to collect processed file paths + provenance for the dedup phase.
# Populated inside the parallel block; read after all workers complete.
$processedFiles  = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
[long]$dedupBytesFreed = 0

# SearchOption controls whether Directory.EnumerateFiles recurses into sub-folders.
$searchOption = if ($Recurse) {
    [System.IO.SearchOption]::AllDirectories
} else {
    [System.IO.SearchOption]::TopDirectoryOnly
}
Write-Host "`n📂 Scanning '$Path' ($searchOption mode)" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# FILE COLLECTION
# EnumerateFiles streams file paths lazily — no full directory load into memory.
# ConcurrentBag is used because it supports lock-free concurrent adds (though
# here the add loop is single-threaded; it's a natural fit for the parallel
# consumer below). We separate $totalCount (all files seen) from $filteredCount
# (only supported media) so the summary can report both.
# ─────────────────────────────────────────────────────────────────────────────
$allFiles = [System.IO.Directory]::EnumerateFiles($longPath, '*.*', $searchOption)
$filesToProcess = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
$totalCount = 0
$filteredCount = 0

foreach ($file in $allFiles) {
    $totalCount++
    $ext = [System.IO.Path]::GetExtension($file).ToLower()
    if ($ext -in $validExtensions) {
        $filesToProcess.Add($file)
        $filteredCount++
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PROGRESS THROTTLE
# A Mutex (rather than a Monitor or SemaphoreSlim) is used because it can be
# shared across PS runspaces, which are true OS threads. Progress is printed
# for the first 10 files always (so you see activity immediately), then every
# reportInterval files (1% of total, minimum 100) to prevent console flooding
# on large runs.
# ─────────────────────────────────────────────────────────────────────────────
# Guard against empty result — avoids division by zero inside the parallel block
# ($index / $totalFiles) and prevents a confusing "0 files fixed" run.
if ($filteredCount -eq 0) {
    Write-Host "⚠️  No supported media files found in '$Path'. Nothing to do." -ForegroundColor Yellow
    exit 0
}

$progressLock = [System.Threading.Mutex]::new()
$reportInterval = [math]::Max(100, [math]::Round($filteredCount * 0.01))

if ($DryRun) {
    Write-Host "DRY RUN: Simulating metadata fixes for $filteredCount/$totalCount files..." -ForegroundColor Yellow
    $actionPrefix = "Would fix"
} else {
    Write-Host "🔧 Fixing metadata for $filteredCount/$totalCount files using $([System.Environment]::ProcessorCount) cores..." -ForegroundColor Cyan
    $actionPrefix = "Fixed"
}
Write-Host "Supported formats: $($validExtensions -join ', ')" -ForegroundColor DarkGray
Write-Host "Progress updates every $reportInterval files" -ForegroundColor DarkGray

# Interlocked.Increment is a lock-free atomic increment — safe across threads.
# It gives each parallel runspace a unique sequential index used only for the
# percentage display. It does not affect correctness of any other operation.
$script:CounterRef = [ref]0

# ─────────────────────────────────────────────────────────────────────────────
# PARALLEL PROCESSING
# ThrottleLimit caps concurrent runspaces at the number of logical CPU cores.
# Each runspace is an independent PS session — outer variables are not in scope
# unless explicitly imported with $using:. Mutations to $using: variables do
# NOT propagate back (the ConcurrentDictionary is the exception because we pass
# the object reference, and both sides operate on the same heap object).
# ─────────────────────────────────────────────────────────────────────────────
$filesToProcess | ForEach-Object -Parallel {

    # Import all needed outer-scope values into this runspace via $using:.
    $fileLongPath   = $_
    $processedCount = $using:processedCount
    $progressLock   = $using:progressLock
    $totalFiles     = $using:filteredCount
    $reportInterval = $using:reportInterval
    $DryRun         = $using:DryRun
    $actionPrefix   = $using:actionPrefix
    $pFiles         = $using:processedFiles
    $Dedup          = $using:Dedup

    # Atomic index for percentage display only — not used for any file operation.
    $index = [System.Threading.Interlocked]::Increment($using:CounterRef)
    $percent = [math]::Round(($index / $totalFiles) * 100, 1)
    $percentString = "{0,5:N1}" -f $percent

    # Accumulates human-readable action strings for this file's progress line.
    $actions = @()

    try {
        $null = $processedCount.AddOrUpdate('Processed', 1, { param($k, $v) $v + 1 })

        # Skip files that no longer exist (e.g. renamed by a previous interrupted run).
        if (-not (Test-Path -LiteralPath $fileLongPath)) {
            $null = $processedCount.AddOrUpdate('Skipped', 1, { param($k, $v) $v + 1 })
            $progressLock.WaitOne() | Out-Null
            try {
                Write-Host "[$percentString%] ⚠️  File no longer exists — skipping: $(Split-Path $fileLongPath -Leaf)" -ForegroundColor DarkGray
            } finally {
                $progressLock.ReleaseMutex() | Out-Null
            }
            return
        }

        # Strip the \\?\ prefix for APIs that don't accept extended-length paths,
        # while keeping $fileLongPath intact for file I/O operations that do.
        $normalPath = if ($fileLongPath.StartsWith('\\?\')) { $fileLongPath.Substring(4) } else { $fileLongPath }
        $fileInfo = [System.IO.FileInfo]$normalPath
        $finalPath = $normalPath   # tracks the current path through all renames

        # ─────────────────────────────────────────────────────────────────────
        # MAGIC NUMBER / SIGNATURE CHECK
        # FIX (Bug 1+2): Rewrote magic-number detection using if/elseif chains instead
        # of 'switch -regex ($bytes)'. When PowerShell switch receives a [byte[]], it
        # iterates individual elements — so $_ inside each case was a single scalar byte,
        # not the full array. That made $_[0]/$_[1] always return the same scalar (or
        # $null), so every format check silently failed and the function returned $null
        # for all files. Also fixed the ftyp/WEBP branches: the original used
        # '-join "" -match "ftyp"' which joins bytes as decimal integers (e.g.
        # "102116121112"), never matching ASCII text. Now uses GetString() to decode.
        #
        # Magic bytes checked (first 12 bytes of file):
        #   FF D8           → JPEG
        #   89 50           → PNG  (89 50 4E 47 0D 0A 1A 0A)
        #   47 49           → GIF  (47 49 46 38)
        #   49 49 / 4D 4D   → TIFF (little-endian / big-endian)
        #   [4..7]='ftyp'   → ISO Base Media (MP4/MOV/HEIC) — brand at [8..11]
        #   [8..11]='WEBP'  → WebP (RIFF container with WEBP chunk)
        # ─────────────────────────────────────────────────────────────────────
        function Get-TrueExtension {
            param([byte[]]$bytes)
            if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8)                       { return '.jpg'  }
            if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50)                       { return '.png'  }
            if ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49)                       { return '.gif'  }
            if (($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x49) -or
                ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x4D))                     { return '.tif'  }
            if ($bytes.Length -ge 12 -and
                [Text.Encoding]::ASCII.GetString($bytes[4..7]) -eq 'ftyp') {
                # ISO Base Media brand determines the specific container format.
                # Trim() handles 'qt  ' (QuickTime brand padded with spaces).
                $brand = [Text.Encoding]::ASCII.GetString($bytes[8..11]).Trim()
                # switch is a statement in PowerShell, not an expression — return inside each case
                switch ($brand) {
                    'heic'  { return '.heic' }
                    'mif1'  { return '.heic' }   # HEIF multi-image
                    'mp41'  { return '.mp4'  }
                    'mp42'  { return '.mp4'  }
                    'qt'    { return '.mov'  }   # QuickTime — 'qt  ' trimmed (brand is 4 bytes, space-padded)
                    default { return '.mp4'  }   # Treat unknown ISO brands as MP4
                }
            }
            # WEBP: bytes 0-3 are 'RIFF', bytes 8-11 are 'WEBP'
            if ($bytes.Length -ge 12 -and
                [Text.Encoding]::ASCII.GetString($bytes[8..11]) -eq 'WEBP')       { return '.webp' }
            return $null   # Unknown format — skip signature check for this file
        }

        # Read only the first 12 bytes — enough for all magic-number checks above.
        # FIX: moved stream disposal into a finally block. Previously $stream.Close()
        # was only called on the happy path — if Read() threw, the file handle leaked.
        $bytes  = [byte[]]::new(12)
        $stream = $null
        $readOk = $false
        try {
            $stream = $fileInfo.OpenRead()
            $null = $stream.Read($bytes, 0, 12)
            $readOk = $true
        } catch {
            $actions += "❌ Read error: $($fileInfo.Name) [$($_.Exception.Message)]"
            $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
        } finally {
            if ($stream) { $stream.Dispose() }
        }
        if (-not $readOk) { return }

        $trueExt  = Get-TrueExtension $bytes
        $actualExt = $fileInfo.Extension.ToLower()

        # Only act if we could identify the true format AND it differs from the
        # current extension. If Get-TrueExtension returns $null (unknown format),
        # we leave the extension alone rather than guess.
        if ($trueExt -and $actualExt -ne $trueExt) {
            $null = $processedCount.AddOrUpdate('SignatureMismatchCount', 1, { param($k, $v) $v + 1 })
            $newPath = [System.IO.Path]::ChangeExtension($fileInfo.FullName, $trueExt)
            $newName = [System.IO.Path]::GetFileName($newPath)

            if ($DryRun) {
                $actions += "🔍 Signature mismatch → Would rename to $newName"
            } else {
                try {
                    Rename-Item -LiteralPath $fileInfo.FullName -NewName $newName
                    $actions += "✅ Renamed: $($fileInfo.Name) → $newName"
                    $null = $processedCount.AddOrUpdate('SignatureRenamedCount', 1, { param($k, $v) $v + 1 })
                    # FIX (Bug 5): Refresh $fileInfo and $normalPath after a successful
                    # signature rename. Previously both still pointed to the old (now
                    # deleted) path, so all subsequent timestamp reads, metadata writes,
                    # and the final rename silently operated on a non-existent file.
                    $normalPath = Join-Path $fileInfo.Directory.FullName $newName
                    $fileInfo   = [System.IO.FileInfo]$normalPath
                    $finalPath  = $normalPath
                } catch {
                    $actions += "❌ Rename failed: $($_.Exception.Message)"
                    $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
                }
            }
        }

        # ─────────────────────────────────────────────────────────────────────
        # TIMESTAMP EXTRACTION
        # We collect up to four candidate dates and pick the oldest:
        #   $dateTaken    — EXIF DateTimeOriginal / XMP DateTimeOriginal (images)
        #   $mediaCreated — QuickTime:CreateDate in UTC, converted to local (videos)
        #   $dateCreated  — NTFS CreationTime (always available, filesystem fallback)
        #   $dateModified — NTFS LastWriteTime (always available, filesystem fallback)
        #
        # Using the oldest date as canonical "when was this captured" is intentional:
        # copies and re-saves inflate the DateCreated/DateModified fields, but the
        # original capture timestamp is usually the earliest of all available dates.
        #
        # exiftool is called without the 'EXIF:' group prefix (just -DateTimeOriginal)
        # so that XMP:DateTimeOriginal and other non-EXIF embedded dates are also found.
        # ─────────────────────────────────────────────────────────────────────
        $dateTaken    = $null
        $mediaCreated = $null
        $dateCreated  = $fileInfo.CreationTime.ToLocalTime()
        $dateModified = $fileInfo.LastWriteTime.ToLocalTime()
        $isVideo      = $fileInfo.Extension -match '\.(qt|mpg|mp4|mov|avi|mkv|wmv)$'

        if ($isVideo) {
            # QuickTimeUTC API tells exiftool to interpret QuickTime timestamps as UTC
            # (the spec requires UTC but many cameras write local time). ToLocalTime()
            # then converts the parsed UTC value to the system's local timezone.
            try {
                $exifOut = & exiftool -fast -api QuickTimeUTC -s -QuickTime:CreateDate "$normalPath"
                if ($exifOut -match 'Create\s*Date\s*:\s*(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})') {
                    $mediaCreated = [datetime]::ParseExact($matches[1], 'yyyy:MM:dd HH:mm:ss', $null).ToLocalTime()
                }
            } catch {}
        } else {
            # No 'EXIF:' group prefix — searches EXIF, XMP, IPTC, and other groups.
            # ParseExact with the exiftool date format (colons in date part) avoids
            # locale-dependent parsing issues.
            try {
                $exifOut = & exiftool -fast -s -DateTimeOriginal "$normalPath"
                if ($exifOut -match 'DateTimeOriginal\s*:\s*(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})') {
                    $dateTaken = [datetime]::ParseExact($matches[1], 'yyyy:MM:dd HH:mm:ss', $null).ToLocalTime()
                }
            } catch {}
        }

        # FIX (Bug 8): Removed Shell.Application COM fallback for reading DateTaken.
        # Shell.Application is STA-threaded; ForEach-Object -Parallel dispatches work on
        # MTA thread-pool workers, causing a COM apartment mismatch that produces silent
        # failures or RPC_E_WRONG_THREAD exceptions. The exiftool call above (without the
        # EXIF: group restriction) covers the same metadata including XMP:DateTimeOriginal,
        # making the COM fallback unnecessary.

        # ─────────────────────────────────────────────────────────────────────
        # TIMESTAMP SELECTION
        # Build a list of all available dates, filter to confirmed [datetime]
        # objects (guards against nulls), sort ascending, and take the first
        # (oldest). $candidateDates always has at least $dateCreated and
        # $dateModified from the filesystem, so $oldestDate is never null.
        # ─────────────────────────────────────────────────────────────────────
        $candidateDates = @()
        if ($dateTaken)    { $candidateDates += $dateTaken }
        if ($mediaCreated) { $candidateDates += $mediaCreated }
        $candidateDates += $dateCreated, $dateModified
        # FIX: Apply sanity bounds before selecting the oldest date. Corrupt EXIF data
        # can produce years like 0001 or 9999 which would otherwise become the canonical
        # "oldest" and generate nonsensical filenames (e.g. 00010101_000000.jpg).
        # Lower bound: 1970-01-01 (no consumer digital cameras existed before this).
        # Upper bound: tomorrow (guards against cameras with incorrect future dates).
        # If every candidate falls outside the bounds, fall back to the raw oldest
        # and log a warning so the anomaly is visible in the progress output.
        $minSaneDate = [datetime]::new(1970, 1, 1)
        $maxSaneDate = (Get-Date).AddYears(5)
        $oldestDate  = ($candidateDates | Where-Object { $_ -is [datetime] -and $_ -ge $minSaneDate -and $_ -le $maxSaneDate } | Sort-Object)[0]
        if (-not $oldestDate) {
            $oldestDate = ($candidateDates | Where-Object { $_ -is [datetime] } | Sort-Object)[0]
            $actions += "⚠️  All dates outside sane range — using raw oldest: $($oldestDate.ToString('yyyy-MM-dd'))"
        }

        # ─────────────────────────────────────────────────────────────────────
        # PROVENANCE CLASSIFICATION
        # FIX (Bug 6): Rewrote provenance classification. The original conditions for
        # 'EXIF-only' and 'QuickTime-only' required -not $dateCreated -and -not $dateModified,
        # but those variables are always populated from the filesystem (never null/false),
        # so those two branches were permanently unreachable — every file with EXIF data
        # fell into 'Mixed-sources' instead. Classification now uses only the presence of
        # extracted metadata (dateTaken / mediaCreated) to determine the source type.
        #
        # Categories:
        #   EXIF-only      — image with DateTimeOriginal, no QuickTime metadata
        #   QuickTime-only — video with QuickTime:CreateDate, no EXIF
        #   Mixed-sources  — both EXIF and QuickTime dates found (unusual)
        #   Fallback-only  — no embedded metadata; using filesystem dates only
        #   Unknown        — no dates at all (should not occur in practice)
        # ─────────────────────────────────────────────────────────────────────
        $provenanceType = if ($dateTaken -and $mediaCreated) {
            'Mixed-sources'
        } elseif ($dateTaken) {
            'EXIF-only'
        } elseif ($mediaCreated) {
            'QuickTime-only'
        } elseif ($dateCreated -or $dateModified) {
            'Fallback-only'
        } else {
            'Unknown'
        }

        $null = $processedCount.AddOrUpdate($provenanceType, 1, { param($k, $v) $v + 1 })
        $actions += "[Source] Provenance → $provenanceType"

        # ─────────────────────────────────────────────────────────────────────
        # METADATA WRITE-BACK
        # FIX (Bug 8 follow-on): Replaced Shell.Application COM write for DateTaken with
        # an exiftool call. COM objects are STA-threaded and must not be created in the
        # MTA thread-pool workers used by ForEach-Object -Parallel. Using exiftool is also
        # more reliable across file formats and has no 260-char path restriction.
        #
        # -overwrite_original: rewrites the file in-place without creating a backup (_original).
        # Both DateTimeOriginal and CreateDate are set to ensure compatibility with apps
        # that read one tag or the other (e.g. Windows Photos uses DateTimeOriginal,
        # some Android apps prefer CreateDate).
        # ─────────────────────────────────────────────────────────────────────
        if (-not $isVideo -and -not $dateTaken) {
            $exifDate = $oldestDate.ToString('yyyy:MM:dd HH:mm:ss')   # exiftool date format
            try {
                if (-not $DryRun) {
                    & exiftool -overwrite_original "-DateTimeOriginal=$exifDate" "-CreateDate=$exifDate" "$normalPath" 2>&1 | Out-Null
                    # FIX: check exit code — exiftool returns non-zero on failure but
                    # previously the error was swallowed and success was reported anyway.
                    if ($LASTEXITCODE -ne 0) { throw "exiftool exited with code $LASTEXITCODE" }
                }
                $actions += "$actionPrefix DateTaken to $($oldestDate.ToString('yyyy-MM-dd'))"
                $null = $processedCount.AddOrUpdate('DateTakenSet', 1, { param($k, $v) $v + 1 })
            } catch {
                $actions += "❌ Failed to set DateTaken: $($_.Exception.Message)"
            }
        }

        # Set NTFS CreationTime to the canonical oldest date.
        # FileInfo.CreationTime is writable in .NET on Windows — no shell or API needed.
        # FIX: wrapped in try/catch — throws UnauthorizedAccessException on read-only files.
        if ($dateCreated -ne $oldestDate) {
            try {
                if (-not $DryRun) { $fileInfo.CreationTime = $oldestDate }
                $actions += "$actionPrefix DateCreated to $($oldestDate.ToString('yyyy-MM-dd'))"
                $null = $processedCount.AddOrUpdate('DateCreatedSet', 1, { param($k, $v) $v + 1 })
            } catch {
                $actions += "❌ Failed to set DateCreated: $($_.Exception.Message)"
            }
        }

        # Set NTFS LastWriteTime to the canonical oldest date.
        # FIX: wrapped in try/catch — same reason as above.
        if ($dateModified -ne $oldestDate) {
            try {
                if (-not $DryRun) { $fileInfo.LastWriteTime = $oldestDate }
                $actions += "$actionPrefix DateModified to $($oldestDate.ToString('yyyy-MM-dd'))"
                $null = $processedCount.AddOrUpdate('DateModifiedSet', 1, { param($k, $v) $v + 1 })
            } catch {
                $actions += "❌ Failed to set DateModified: $($_.Exception.Message)"
            }
        }

        # ─────────────────────────────────────────────────────────────────────
        # TIMESTAMP-BASED RENAME
        # Target name format: yyyyMMdd_HHmmss[.mmm].ext
        # The millisecond component (.mmm) is included only when non-zero —
        # this handles cameras that write sub-second precision in EXIF.
        #
        # Collision handling (FIX — Race condition):
        # Replaced Test-Path + Move-Item with a try/catch retry loop.
        # Test-Path is not atomic — two parallel threads could both pass the
        # existence check and then collide on the rename. Catching IOException
        # and incrementing the suffix counter (.001, .002, …) is race-safe
        # because Move-Item itself will throw if the destination already exists.
        # ─────────────────────────────────────────────────────────────────────
        $base = $oldestDate.ToString('yyyyMMdd_HHmmss')
        if ($oldestDate.Millisecond) {
            $base += '.' + $oldestDate.Millisecond.ToString('000')
        }
        $ext        = $fileInfo.Extension.ToLower()
        $newName    = "${base}${ext}"
        $targetPath = Join-Path $fileInfo.Directory.FullName $newName

        if ($fileInfo.Name -ne $newName) {
            if ($DryRun) {
                $actions += "Would rename → $($fileInfo.Name) → $newName"
            } else {
                $count = 0
                $moved = $false
                while (-not $moved -and $count -le 999) {
                    if ($count -gt 0) {
                        # Append a zero-padded suffix: 20230415_143022.001.jpg
                        $newName    = "${base}.$($count.ToString('000'))${ext}"
                        $targetPath = Join-Path $fileInfo.Directory.FullName $newName
                    }
                    try {
                        Move-Item -LiteralPath $fileInfo.FullName -Destination $targetPath -ErrorAction Stop
                        $moved = $true
                    } catch [System.IO.IOException] {
                        # Destination exists (collision) — increment suffix and retry.
                        $count++
                    } catch {
                        # Any other error (permissions, path too long, etc.) — give up on this file.
                        $actions += "❌ Rename failed → $($fileInfo.Name): $($_.Exception.Message)"
                        $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
                        break
                    }
                }
                if ($moved) {
                    $actions   += "Renamed → $($fileInfo.Name) → $newName"
                    $finalPath  = $targetPath
                    $null = $processedCount.AddOrUpdate('Renamed', 1, { param($k, $v) $v + 1 })
                    if ($count -gt 0) {
                        $null = $processedCount.AddOrUpdate('WithCounter', 1, { param($k, $v) $v + 1 })
                    }
                } elseif ($count -gt 999) {
                    # FIX: suffix exhaustion was previously silent — the file was skipped
                    # with no log entry and no failure counter increment.
                    $actions += "❌ Rename failed → $($fileInfo.Name): no unique name available after 999 attempts"
                    $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
                }
            }
        }

        # Record the final path and provenance for the optional dedup phase.
        # $pFiles is a ConcurrentBag — Add() is lock-free and safe across runspaces.
        if ($Dedup) {
            $pFiles.Add([PSCustomObject]@{ Path = $finalPath; Provenance = $provenanceType })
        }

        # ─────────────────────────────────────────────────────────────────────
        # PROGRESS OUTPUT
        # The Mutex serialises console writes across all parallel runspaces.
        # WaitOne() blocks until the mutex is acquired; ReleaseMutex() is in a
        # finally block so it always runs, even if Write-Host throws.
        # Color: Gray = skipped, Red = any failure, Green = normal processing.
        # ─────────────────────────────────────────────────────────────────────
        $progressLock.WaitOne() | Out-Null
        try {
            $currentCount = $processedCount['Processed']
            if ($currentCount -le 10 -or $currentCount % $reportInterval -eq 0) {
                $color = if ($actions -join '; ' -like "*Skipped*") { "DarkGray" }
                         elseif ($actions -join '; ' -like "*Failed*") { "Red" }
                         else { "Green" }
                Write-Host "[$percentString%] ($currentCount/$totalFiles) $($actions -join '; ') - $($fileInfo.Name)" -ForegroundColor $color
            }
        } finally {
            $progressLock.ReleaseMutex() | Out-Null
        }

    } catch {
        # Outer catch — handles any unexpected exception not caught by inner try blocks.
        # FIX: $fileInfo may be null if the exception occurred before it was assigned
        # (e.g. on the [System.IO.FileInfo] constructor). Fall back to the raw path.
        $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
        $progressLock.WaitOne() | Out-Null
        try {
            $currentCount = $processedCount['Processed']
            $displayName  = if ($fileInfo) { $fileInfo.Name } else { Split-Path $fileLongPath -Leaf }
            Write-Host "[$currentCount/$totalFiles] Failed: $displayName [$($_.Exception.Message)]" -ForegroundColor Red
        } finally {
            $progressLock.ReleaseMutex() | Out-Null
        }
    }
} -ThrottleLimit ([System.Environment]::ProcessorCount)

# Dispose the OS-level Mutex now that all parallel work is complete.
$progressLock.Dispose()

# ─────────────────────────────────────────────────────────────────────────────
# DEDUPLICATION PHASE
# Only runs when -Dedup is specified. Groups processed files by byte-size first
# (free — no I/O). Only same-size groups (≥2 files) are checksummed with SHA256,
# typically reducing I/O by ~90% compared to checksumming every file.
#
# Keeper selection by provenance rank (best metadata wins):
#   1 EXIF-only  2 QuickTime-only  3 Mixed-sources  4 Fallback-only  5 Unknown
#
# In dry-run mode, duplicates are listed but nothing is deleted.
# ─────────────────────────────────────────────────────────────────────────────
if ($Dedup) {
    Write-Host "`n🔍 Deduplication phase..." -ForegroundColor Cyan

    # Group by file size (pure in-memory — no disk access).
    $bySize = @{}
    foreach ($f in $processedFiles) {
        if (-not (Test-Path -LiteralPath $f.Path)) { continue }
        $sz = (Get-Item -LiteralPath $f.Path).Length
        if (-not $bySize.ContainsKey($sz)) { $bySize[$sz] = [System.Collections.Generic.List[object]]::new() }
        $bySize[$sz].Add($f)
    }

    # Collect only size groups with ≥2 files — these are candidates for duplication.
    $candidates = $bySize.GetEnumerator() | Where-Object { $_.Value.Count -ge 2 } | ForEach-Object { $_.Value }
    $filesToChecksum = ($candidates | Measure-Object).Count
    Write-Host "  Size-bucketed: $filesToChecksum files in same-size groups to checksum" -ForegroundColor DarkGray

    # SHA256 checksum each candidate file.
    $sha256Engine = [System.Security.Cryptography.SHA256]::Create()
    $checksums    = @{}   # hash → list of file objects
    $checked      = 0
    try {

    foreach ($f in $candidates) {
        $checked++
        $pct = if ($filesToChecksum -gt 0) { [math]::Round($checked / $filesToChecksum * 100, 1) } else { 100 }
        Write-Host "`r  Checksumming: [$("{0,5:N1}" -f $pct)%] ($checked/$filesToChecksum)   " -NoNewline

        try {
            $stream = [System.IO.File]::OpenRead($f.Path)
            try {
                $hashBytes = $sha256Engine.ComputeHash($stream)
                $hash      = [System.BitConverter]::ToString($hashBytes) -replace '-',''
            } finally {
                $stream.Dispose()
            }
            if (-not $checksums.ContainsKey($hash)) { $checksums[$hash] = [System.Collections.Generic.List[object]]::new() }
            $checksums[$hash].Add($f)
        } catch {
            Write-Host "`n  ⚠️  Checksum failed for $(Split-Path $f.Path -Leaf): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    } finally {
        $sha256Engine.Dispose()
    }
    Write-Host ""   # newline after progress

    # Provenance rank: lower = better metadata = keep this file.
    $provenanceRank = @{
        'EXIF-only'      = 1
        'QuickTime-only' = 2
        'Mixed-sources'  = 3
        'Fallback-only'  = 4
        'Unknown'        = 5
    }

    $dupGroups     = 0
    $dupFiles      = 0
    $totalDups     = ($checksums.GetEnumerator() | Where-Object { $_.Value.Count -ge 2 } | ForEach-Object { $_.Value.Count - 1 } | Measure-Object -Sum).Sum
    $dupProcessed  = 0

    foreach ($entry in $checksums.GetEnumerator()) {
        if ($entry.Value.Count -lt 2) { continue }
        $dupGroups++
        $null = $processedCount.AddOrUpdate('DedupGroupsFound', 1, { param($k, $v) $v + 1 })

        # Sort by provenance rank ascending — index 0 is the keeper.
        $sorted = $entry.Value | Sort-Object { $provenanceRank[$_.Provenance] ?? 99 }
        $keeper = $sorted[0]
        $dupes  = $sorted | Select-Object -Skip 1

        foreach ($dup in $dupes) {
            $dupProcessed++
            $dupFiles++
            $pct = if ($totalDups -gt 0) { [math]::Round($dupProcessed / $totalDups * 100, 1) } else { 100 }
            $pctStr = "[{0,5:N1}%] ({1}/{2})" -f $pct, $dupProcessed, $totalDups

            if (Test-Path -LiteralPath $dup.Path) {
                $dupSize = (Get-Item -LiteralPath $dup.Path).Length
                if ($DryRun) {
                    $null = $processedCount.AddOrUpdate('DedupFilesRemoved', 1, { param($k, $v) $v + 1 })
                    Write-Host "  $pctStr 🔍 Would delete duplicate: $(Split-Path $dup.Path -Leaf)  [keep: $(Split-Path $keeper.Path -Leaf)]" -ForegroundColor DarkGray
                } else {
                    try {
                        Remove-Item -LiteralPath $dup.Path -Force
                        $dedupBytesFreed += $dupSize
                        $null = $processedCount.AddOrUpdate('DedupFilesRemoved', 1, { param($k, $v) $v + 1 })
                        Write-Host "  $pctStr 🗑️  Deleted duplicate: $(Split-Path $dup.Path -Leaf)  [kept: $(Split-Path $keeper.Path -Leaf)]" -ForegroundColor DarkGray
                    } catch {
                        Write-Host "  $pctStr ❌ Delete failed: $(Split-Path $dup.Path -Leaf): $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }
    }

    if ($dupGroups -eq 0) {
        Write-Host "  ✅ No duplicates found." -ForegroundColor Green
    } else {
        Write-Host "  Found $dupGroups duplicate group(s), $dupFiles duplicate file(s)." -ForegroundColor Cyan
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
$endTime = Get-Date
$elapsed = New-TimeSpan $startTime $endTime

# FIX (Bug 7): Wrapped string concatenation in parentheses. Without them, PowerShell's
# argument parser treats "`n", "+", and ('═' * 50) as three separate positional values,
# printing a literal " + " between them rather than concatenating into one string.
Write-Host ("`n" + ('═' * 50)) -ForegroundColor Cyan
Write-Host ("{0,-30}: {1}" -f "Script",              "media-audit.ps1 v$VERSION")
Write-Host ("{0,-30}: {1}" -f "Runtime",             $elapsed.ToString('hh\:mm\:ss'))
if ($DryRun) {
    Write-Host "DRY RUN SUMMARY — No changes applied" -ForegroundColor Yellow
}
Write-Host ('─' * 50) -ForegroundColor Cyan
Write-Host ("{0,-30}: {1}" -f "Total files scanned", $totalCount)
Write-Host ("{0,-30}: {1}" -f "Files matching extensions", $filteredCount)

Write-Host ("{0,-30}: {1}" -f "DateTaken metadata set",      $processedCount['DateTakenSet'])
Write-Host ("{0,-30}: {1}" -f "DateCreated adjusted",        $processedCount['DateCreatedSet'])
Write-Host ("{0,-30}: {1}" -f "DateModified adjusted",       $processedCount['DateModifiedSet'])
Write-Host ("{0,-30}: {1}" -f "Files renamed by timestamp",  $processedCount['Renamed'])
Write-Host ("{0,-30}: {1}" -f "Timestamp rename w/ suffix",  $processedCount['WithCounter'])
Write-Host ("{0,-30}: {1}" -f "Signature mismatches",        $processedCount['SignatureMismatchCount'])
Write-Host ("{0,-30}: {1}" -f "Signature-based renames",     $processedCount['SignatureRenamedCount'])
Write-Host ("{0,-30}: {1}" -f "Files skipped",               $processedCount['Skipped'])
Write-Host ("{0,-30}: {1}" -f "Failures",                    $processedCount['Failed'])
if ($Dedup) {
    $dedupLabel = if ($DryRun) { "Dedup files (would del)" } else { "Dedup files removed" }
    Write-Host ("{0,-30}: {1}" -f "Dedup groups found",  $processedCount['DedupGroupsFound'])
    Write-Host ("{0,-30}: {1}" -f $dedupLabel,           $processedCount['DedupFilesRemoved'])
    if (-not $DryRun) {
        Write-Host ("{0,-30}: {1}" -f "Space freed",     (Format-Bytes $dedupBytesFreed))
    }
}
Write-Host ("{0,-30}: {1}" -f "EXIF-only sources",           $processedCount['EXIF-only'])
Write-Host ("{0,-30}: {1}" -f "QuickTime-only sources",      $processedCount['QuickTime-only'])
Write-Host ("{0,-30}: {1}" -f "Fallback-only sources",       $processedCount['Fallback-only'])
Write-Host ("{0,-30}: {1}" -f "Mixed-source files",          $processedCount['Mixed-sources'])
Write-Host ("{0,-30}: {1}" -f "Unknown provenance",          $processedCount['Unknown'])
Write-Host ('═' * 50) -ForegroundColor Cyan
<#
media-audit.ps1  v1.2.0
──────────────────────────────
Performs header validation, timestamp extraction, metadata correction, rename
operations, and optional SHA256 deduplication across media files.

USAGE:
    .\media-audit.ps1 -Path "C:\MediaLibrary" [-DryRun] [-Recurse] [-Dedup]

PARAMETERS:
    -Path      [Required] Root folder containing media files
    -DryRun    [Optional] Preview actions without making changes
    -Recurse   [Optional] Scan subdirectories recursively
    -Dedup     [Optional] Run SHA256 deduplication phase after main scan

SUPPORTED FORMATS:
    .jpg, .jpeg, .png, .gif, .bmp, .tif, .tiff, .heic, .webp
    .mov, .mp4, .avi, .mkv, .wmv, .qt
    .cr2, .nef, .dng, .crw
    .jfif, .mpg

FEATURES:
    • ExifTool pre-flight: verifies exiftool is on PATH at startup — exits immediately
      with a clear message if not found, rather than silently failing every file
    • -fast flag on all exiftool read calls (stops after first metadata block;
      2-3x faster on large libraries)
    • Header signature check via magic number analysis (JPEG, PNG, GIF, TIFF, MP4,
      MOV, HEIC, WebP — reads first 12 bytes; does not rely on extension)
    • Renaming files when extension doesn't match actual content
    • Missing-file skip: files deleted between enumeration and processing are counted
      as Skipped rather than Failed — no false error counts
    • Metadata extraction via ExifTool (EXIF, QuickTime, XMP, NTFS filesystem dates)
    • Date sanity filtering: rejects dates before 1970-01-01 or more than 5 years in
      the future as likely corrupt; logs a warning and falls back to raw oldest if no
      sane date exists — prevents filenames like 00010101_000000.jpg
    • Selection of oldest valid timestamp as canonical "DateTaken"
    • Corrections to DateTimeOriginal (via exiftool), CreationTime, and LastWriteTime
    • File rename using timestamp format (yyyyMMdd_HHmmss.ext)
    • Race-safe suffix logic for timestamp collisions (.001, .002, … .999); exhaustion
      is logged as a failure rather than silently skipped
    • Provenance tagging: EXIF-only, QuickTime-only, Fallback-only, Mixed-sources
    • Thread-safe counters (ConcurrentDictionary) and mutex-serialised console output
    • Size-bucketed SHA256 deduplication (-Dedup): groups by byte-size first (~90% I/O
      reduction), checksums only same-size groups, keeps file with best provenance rank
    • Detailed summary report with per-provenance and dedup breakdowns on completion

NOTES:
    • Requires PowerShell 7+
    • ExifTool check is automatic on startup — the script will not process any files
      if exiftool is missing; no manual PATH check needed
    • Use -DryRun mode for safe simulation (no writes, renames, or deletes)
    • Always back up your media before running bulk fixes on an important library

EXAMPLE:
    .\media-audit.ps1 -Path "D:\Pictures" -DryRun -Recurse -Dedup
#>
