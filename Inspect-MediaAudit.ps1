# Inspect-MediaAudit.ps1
# Copyright © 2025 Clive DSouza
# Licensed under the MIT License — see LICENSE file in repo root

#Requires -Version 7.0
<#
╔══════════════════════════════════════════════════════════════════════════════════╗
║                           Inspect-MediaAudit.ps1                                 ║
║        Signature Check + Metadata Repair + Timestamp Correction Tool             ║
╠══════════════════════════════════════════════════════════════════════════════════╣
║ FLOWCHART                                                                        ║
║                                                                                  ║
║ ┌──────────────────────────────┐                                                 ║
║ │ Accept -Path, -DryRun, -Recurse │                                              ║
║ └──────────────────────────────┘                                                 ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌──────────────────────────────────────┐                                         ║
║ │ Recursively collect valid media files │                                        ║
║ └──────────────────────────────────────┘                                         ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌────────────────────────────────────────────────┐                              ║
║ │ For each file:                                │                              ║
║ │  - Validate header vs extension                │                              ║
║ │  - Rename if mismatched                        │                              ║
║ │  - Extract EXIF/QuickTime/NTFS timestamps      │                              ║
║ │  - Determine oldest valid date                 │                              ║
║ │  - Set DateTaken → CreationTime → LastWriteTime│                              ║
║ │  - Tag provenance type                         │                              ║
║ │  - Rename file based on oldest timestamp       │                              ║
║ └────────────────────────────────────────────────┘                              ║
║           │                                                                      ║
║           ▼                                                                      ║
║ ┌──────────────────────────────────────────────┐                                 ║
║ │ Log summary + per-source provenance stats     │                                 ║
╚══════════════════════════════════════════════════════════════════════════════════╝
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({ if (-not (Test-Path $_)) { throw "Path not found: $_" }; $true })]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$Recurse
)

function ConvertTo-LongPath {
    param([string]$Path)
    if ($Path -like '\\?\\*') { return $Path }
    $abs = [System.IO.Path]::GetFullPath($Path)
    if ($abs.Length -ge 240) { "\\?\$abs" } else { $abs }
}

$longPath = ConvertTo-LongPath $Path
$validExtensions = @(
    '.qt','.jfif','.jpg','.jpeg','.png','.gif','.bmp','.tiff','.tif','.heic',
    '.mpg','.mp4','.mov','.avi','.mkv','.nef','.cr2','.dng','.crw','.webp','.wmv'
)

$processedCount = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new()
@(
    'Processed','DateTakenSet','DateCreatedSet','DateModifiedSet',
    'SignatureMismatchCount','SignatureRenamedCount','Skipped','Failed','DryRun',
    'EXIF-only','QuickTime-only','Fallback-only','Mixed-sources','Unknown',
    'Renamed','WithCounter'
) | ForEach-Object { $processedCount[$_] = 0 }

$startTime = Get-Date
$searchOption = if ($Recurse) {
    [System.IO.SearchOption]::AllDirectories
} else {
    [System.IO.SearchOption]::TopDirectoryOnly
}
Write-Host "`n📂 Scanning '$Path' ($searchOption mode)" -ForegroundColor Cyan

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
$script:CounterRef = [ref]0

$filesToProcess | ForEach-Object -Parallel {

    $fileLongPath   = $_
    $processedCount = $using:processedCount
    $progressLock   = $using:progressLock
    $totalFiles     = $using:filteredCount
    $reportInterval = $using:reportInterval
    $DryRun         = $using:DryRun
    $actionPrefix   = $using:actionPrefix

    $index = [System.Threading.Interlocked]::Increment($using:CounterRef)
    $percent = [math]::Round(($index / $totalFiles) * 100, 1)
    $percentString = "{0,5:N1}" -f $percent
    $actions = @()

    try {
        $null = $processedCount.AddOrUpdate('Processed', 1, { param($k, $v) $v + 1 })
        $normalPath = if ($fileLongPath.StartsWith('\\?\')) { $fileLongPath.Substring(4) } else { $fileLongPath }
        $fileInfo = [System.IO.FileInfo]$normalPath

        # FIX (Bug 1+2): Rewrote magic-number detection using if/elseif chains instead
        # of 'switch -regex ($bytes)'. When PowerShell switch receives a [byte[]], it
        # iterates individual elements — so $_ inside each case was a single scalar byte,
        # not the full array. That made $_[0]/$_[1] always return the same scalar (or
        # $null), so every format check silently failed and the function returned $null
        # for all files. Also fixed the ftyp/WEBP branches: the original used
        # '-join "" -match "ftyp"' which joins bytes as decimal integers (e.g.
        # "102116121112"), never matching ASCII text. Now uses GetString() to decode.
        function Get-TrueExtension {
            param([byte[]]$bytes)
            if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8)                       { return '.jpg'  }
            if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50)                       { return '.png'  }
            if ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49)                       { return '.gif'  }
            if (($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x49) -or
                ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x4D))                     { return '.tif'  }
            if ($bytes.Length -ge 12 -and
                [Text.Encoding]::ASCII.GetString($bytes[4..7]) -eq 'ftyp') {
                $brand = [Text.Encoding]::ASCII.GetString($bytes[8..11]).Trim()
                return switch ($brand) {
                    'heic'  { '.heic' }
                    'mif1'  { '.heic' }
                    'mp41'  { '.mp4'  }
                    'mp42'  { '.mp4'  }
                    'qt  '  { '.mov'  }
                    default { '.mp4'  }
                }
            }
            if ($bytes.Length -ge 12 -and
                [Text.Encoding]::ASCII.GetString($bytes[8..11]) -eq 'WEBP')       { return '.webp' }
            return $null
        }

        # === Header read for signature check ===
        $bytes = [byte[]]::new(12)
        try {
            $stream = $fileInfo.OpenRead()
            $null = $stream.Read($bytes, 0, 12)
            $stream.Close()
        } catch {
            $actions += "❌ Read error: $($fileInfo.Name)"
            $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
            return
        }

        $trueExt = Get-TrueExtension $bytes
        $actualExt = $fileInfo.Extension.ToLower()

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
                } catch {
                    $actions += "❌ Rename failed: $($_.Exception.Message)"
                    $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
                }
            }
        }

        # === Timestamp extraction ===
        $dateTaken    = $null
        $mediaCreated = $null
        $dateCreated  = $fileInfo.CreationTime.ToLocalTime()
        $dateModified = $fileInfo.LastWriteTime.ToLocalTime()
        $isVideo      = $fileInfo.Extension -match '\.(qt|mpg|mp4|mov|avi|mkv|wmv)$'

        if ($isVideo) {
            try {
                $exifOut = & exiftool -api QuickTimeUTC -s -QuickTime:CreateDate "$normalPath"
                if ($exifOut -match 'Create\s*Date\s*:\s*(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})') {
                    $mediaCreated = [datetime]::ParseExact($matches[1], 'yyyy:MM:dd HH:mm:ss', $null).ToLocalTime()
                }
            } catch {}
        } else {
            # Removed the 'EXIF:' group prefix so XMP and other metadata groups are
            # also searched — broader coverage with no downside since exiftool is already required.
            try {
                $exifOut = & exiftool -s -DateTimeOriginal "$normalPath"
                if ($exifOut -match 'DateTimeOriginal\s*:\s*(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})') {
                    $dateTaken = [datetime]::ParseExact($matches[1], 'yyyy:MM:dd HH:mm:ss', $null).ToLocalTime()
                }
            } catch {}
        }

        # FIX (Bug 8): Removed Shell.Application COM fallback for reading DateTaken.
        # Shell.Application is STA-threaded; ForEach-Object -Parallel dispatches work on
        # MTA thread-pool workers, causing a COM apartment mismatch. The exiftool call
        # above (now without the EXIF: group restriction) covers the same metadata
        # including XMP:DateTimeOriginal, making the COM fallback unnecessary.

        # === Timestamp selection ===
        $candidateDates = @()
        if ($dateTaken)    { $candidateDates += $dateTaken }
        if ($mediaCreated) { $candidateDates += $mediaCreated }
        $candidateDates += $dateCreated, $dateModified
        $oldestDate = ($candidateDates | Where-Object { $_ -is [datetime] } | Sort-Object)[0]

        # FIX (Bug 6): Rewrote provenance classification. The original conditions for
        # 'EXIF-only' and 'QuickTime-only' required -not $dateCreated -and -not $dateModified,
        # but those variables are always populated from the filesystem (never null/false),
        # so those two branches were permanently unreachable — every file with EXIF data
        # fell into 'Mixed-sources' instead. Classification now uses only the presence of
        # extracted metadata (dateTaken / mediaCreated) to determine the source type.
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

        # === Metadata write-back ===
        # FIX (Bug 8 follow-on): Replaced Shell.Application COM write for DateTaken with
        # an exiftool call. COM objects are STA-threaded and must not be created in the
        # MTA thread-pool workers used by ForEach-Object -Parallel. Using exiftool is also
        # more reliable across file formats and has no 260-char path restriction.
        if (-not $isVideo -and -not $dateTaken) {
            $exifDate = $oldestDate.ToString('yyyy:MM:dd HH:mm:ss')
            try {
                if (-not $DryRun) {
                    & exiftool -overwrite_original "-DateTimeOriginal=$exifDate" "-CreateDate=$exifDate" "$normalPath" 2>&1 | Out-Null
                }
                $actions += "$actionPrefix DateTaken to $($oldestDate.ToString('yyyy-MM-dd'))"
                $null = $processedCount.AddOrUpdate('DateTakenSet', 1, { param($k, $v) $v + 1 })
            } catch {
                $actions += "❌ Failed to set DateTaken: $($_.Exception.Message)"
            }
        }

        if ($dateCreated -ne $oldestDate) {
            if (-not $DryRun) { $fileInfo.CreationTime = $oldestDate }
            $actions += "$actionPrefix DateCreated to $($oldestDate.ToString('yyyy-MM-dd'))"
            $null = $processedCount.AddOrUpdate('DateCreatedSet', 1, { param($k, $v) $v + 1 })
        }

        if ($dateModified -ne $oldestDate) {
            if (-not $DryRun) { $fileInfo.LastWriteTime = $oldestDate }
            $actions += "$actionPrefix DateModified to $($oldestDate.ToString('yyyy-MM-dd'))"
            $null = $processedCount.AddOrUpdate('DateModifiedSet', 1, { param($k, $v) $v + 1 })
        }

        # === Rename file based on timestamp ===
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
                # FIX (Race condition): Replaced Test-Path + Move-Item with a try/catch
                # retry loop. Test-Path is not atomic — two parallel threads could both
                # pass the existence check and then collide on the rename. Catching
                # IOException and incrementing the suffix counter is race-safe.
                $count = 0
                $moved = $false
                while (-not $moved -and $count -le 999) {
                    if ($count -gt 0) {
                        $newName    = "${base}.$($count.ToString('000'))${ext}"
                        $targetPath = Join-Path $fileInfo.Directory.FullName $newName
                    }
                    try {
                        Move-Item -LiteralPath $fileInfo.FullName -Destination $targetPath -ErrorAction Stop
                        $moved = $true
                    } catch [System.IO.IOException] {
                        $count++
                    } catch {
                        $actions += "❌ Rename failed → $($fileInfo.Name): $($_.Exception.Message)"
                        $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
                        break
                    }
                }
                if ($moved) {
                    $actions += "Renamed → $($fileInfo.Name) → $newName"
                    $null = $processedCount.AddOrUpdate('Renamed', 1, { param($k, $v) $v + 1 })
                    if ($count -gt 0) {
                        $null = $processedCount.AddOrUpdate('WithCounter', 1, { param($k, $v) $v + 1 })
                    }
                }
            }
        }

        # === Progress output ===
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
        $null = $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 })
        $progressLock.WaitOne() | Out-Null
        try {
            $currentCount = $processedCount['Processed']
            Write-Host "[$currentCount/$totalFiles] Failed: $($fileInfo.Name) [$($_.Exception.Message)]" -ForegroundColor Red
        } finally {
            $progressLock.ReleaseMutex() | Out-Null
        }
    }
} -ThrottleLimit ([System.Environment]::ProcessorCount)

# === Final summary ===
$endTime = Get-Date
$elapsed = New-TimeSpan $startTime $endTime

# FIX (Bug 7): Wrapped string concatenation in parentheses. Without them, PowerShell's
# argument parser treats "`n", "+", and ('═' * 50) as three separate positional values,
# printing a literal " + " between them rather than concatenating into one string.
Write-Host ("`n" + ('═' * 50)) -ForegroundColor Cyan
Write-Host ("{0,-30}: {1}" -f "Total files scanned", $totalCount)
Write-Host ("{0,-30}: {1}" -f "Files matching extensions", $filteredCount)

if ($DryRun) {
    Write-Host "DRY RUN SUMMARY — No changes applied" -ForegroundColor Yellow
} else {
    Write-Host ("{0,-30}: {1}" -f "Processing time", $elapsed.ToString('hh\:mm\:ss'))
}

Write-Host ("{0,-30}: {1}" -f "DateTaken metadata set",      $processedCount['DateTakenSet'])
Write-Host ("{0,-30}: {1}" -f "DateCreated adjusted",        $processedCount['DateCreatedSet'])
Write-Host ("{0,-30}: {1}" -f "DateModified adjusted",       $processedCount['DateModifiedSet'])
Write-Host ("{0,-30}: {1}" -f "Files renamed by timestamp",  $processedCount['Renamed'])
Write-Host ("{0,-30}: {1}" -f "Timestamp rename w/ suffix",  $processedCount['WithCounter'])
Write-Host ("{0,-30}: {1}" -f "Signature mismatches",        $processedCount['SignatureMismatchCount'])
Write-Host ("{0,-30}: {1}" -f "Signature-based renames",     $processedCount['SignatureRenamedCount'])
Write-Host ("{0,-30}: {1}" -f "Files skipped",               $processedCount['Skipped'])
Write-Host ("{0,-30}: {1}" -f "Failures",                    $processedCount['Failed'])
Write-Host ("{0,-30}: {1}" -f "EXIF-only sources",           $processedCount['EXIF-only'])
Write-Host ("{0,-30}: {1}" -f "QuickTime-only sources",      $processedCount['QuickTime-only'])
Write-Host ("{0,-30}: {1}" -f "Fallback-only sources",       $processedCount['Fallback-only'])
Write-Host ("{0,-30}: {1}" -f "Mixed-source files",          $processedCount['Mixed-sources'])
Write-Host ("{0,-30}: {1}" -f "Unknown provenance",          $processedCount['Unknown'])
Write-Host ('═' * 50) -ForegroundColor Cyan
<#
Inspect-MediaAudit.ps1
──────────────────────────────
Performs header validation, timestamp extraction, metadata correction, and rename operations across media files.

USAGE:
    .\Inspect-MediaAudit.ps1 -Path "C:\MediaLibrary" [-DryRun] [-Recurse]

PARAMETERS:
    -Path      [Required] Root folder containing media files
    -DryRun    [Optional] Preview actions without making changes
    -Recurse   [Optional] Scan subdirectories recursively

SUPPORTED FORMATS:
    .jpg, .jpeg, .png, .gif, .bmp, .tif, .tiff, .heic, .webp
    .mov, .mp4, .avi, .mkv, .wmv, .qt
    .cr2, .nef, .dng, .crw
    .jfif, .mpg

FEATURES:
    • Header signature check via magic number analysis
    • Renaming files when extension doesn't match actual content
    • Metadata extraction via ExifTool (EXIF, QuickTime, XMP, NTFS)
    • Selection of oldest valid timestamp as canonical "DateTaken"
    • Corrections to DateCreated and LastWriteTime
    • File rename using timestamp format (yyyyMMdd_HHmmss.ext)
    • Suffix logic for timestamp collisions (.001, .002, …)
    • Provenance tagging: EXIF-only, QuickTime-only, Fallback-only, Mixed-sources, etc.
    • Thread-safe counters and color-coded progress output
    • Detailed summary report upon completion

NOTES:
    • Requires PowerShell 7+
    • Ensure ExifTool is in PATH for accurate metadata extraction
    • Use -DryRun mode for safe simulation (no writes or renames)

EXAMPLE:
    .\Inspect-MediaAudit.ps1 -Path "D:\Pictures" -DryRun -Recurse
#>
