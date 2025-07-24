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
$VerboseFlag = $PSCmdlet.MyInvocation.BoundParameters["Verbose"]
$script:CounterRef = [ref]0
$TotalCount = $filesToProcess.Count

$filesToProcess | ForEach-Object -Parallel {
    # === Per-file logic continues in Part 2 ===

    $fileLongPath     = $_
    $processedCount   = $using:processedCount
    $progressLock     = $using:progressLock
    $totalFiles       = $using:filteredCount
    $reportInterval   = $using:reportInterval
    $DryRun           = $using:DryRun
    $actionPrefix     = $using:actionPrefix
    $VerboseFlag      = $using:VerboseFlag

    $index = [System.Threading.Interlocked]::Increment($using:CounterRef)
    $percent = [math]::Round(($index / $totalFiles) * 100, 1)
    $percentString = "{0,5:N1}" -f $percent
    $actions = @()

    try {
        $null = $processedCount.AddOrUpdate('Processed', 1, { param($k, $v) $v + 1 }) > $null
        $normalPath = if ($fileLongPath.StartsWith('\\?\')) { $fileLongPath.Substring(4) } else { $fileLongPath }
        $fileInfo = [System.IO.FileInfo]$normalPath
function Get-TrueExtension {
        param([byte[]]$bytes)
        switch -regex ($bytes) {
            { $_[0] -eq 0xFF -and $_[1] -eq 0xD8 }      { return '.jpg' }
            { $_[0] -eq 0x89 -and $_[1] -eq 0x50 }      { return '.png' }
            { $_[0] -eq 0x47 -and $_[1] -eq 0x49 }      { return '.gif' }
            { $_[0] -eq 0x49 -and $_[1] -eq 0x49 }      { return '.tif' }
            { $_[0] -eq 0x4D -and $_[1] -eq 0x4D }      { return '.tif' }
            { $_[4..7] -join '' -match 'ftyp' } {
                $brand = [Text.Encoding]::ASCII.GetString($_[8..11])
                switch ($brand) {
                    'heic' { return '.heic' }
                    'mif1' { return '.heic' }
                    'mp41' { return '.mp4' }
                    'mp42' { return '.mp4' }
                    'qt  ' { return '.mov' }
                    default { return '.mp4' }
                }
            }
            { $_[8..11] -join '' -eq 'WEBP' }           { return '.webp' }
            default { return $null }
        }
    }

    # === Header read for signature check ===
    $bytes = [byte[]]::new(12)
    try {
        $stream = $fileInfo.OpenRead()
        $stream.Read($bytes, 0, 12) > $null
        $stream.Close()
    } catch {
        $actions += "❌ Read error: $($fileInfo.Name)"
        $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 }) > $null
        return
    }

    $trueExt = Get-TrueExtension $bytes
    $actualExt = $fileInfo.Extension.ToLower()

    if ($trueExt -and $actualExt -ne $trueExt) {
        $processedCount.AddOrUpdate('SignatureMismatchCount', 1, { param($k, $v) $v + 1 }) > $null
        $newPath = [System.IO.Path]::ChangeExtension($fileInfo.FullName, $trueExt)
        $newName = [System.IO.Path]::GetFileName($newPath)

        if ($DryRun) {
            $actions += "🔍 Signature mismatch → Would rename to $newName"
        } else {
            try {
                Rename-Item -LiteralPath $fileInfo.FullName -NewName $newName
                $actions += "✅ Renamed: $($fileInfo.Name) → $newName"
                $processedCount.AddOrUpdate('SignatureRenamedCount', 1, { param($k, $v) $v + 1 }) > $null
            } catch {
                $actions += "❌ Rename failed: $($_.Exception.Message)"
                $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 }) > $null
            }
        }
    }
    # === Timestamp extraction ===
    $dateTaken     = $null
    $mediaCreated  = $null
    $dateCreated   = $fileInfo.CreationTime.ToLocalTime()
    $dateModified  = $fileInfo.LastWriteTime.ToLocalTime()
    $isVideo       = $fileInfo.Extension -match '\.(qt|mpg|mp4|mov|avi|mkv|wmv)$'

    if ($isVideo) {
        try {
            $exifOut = & exiftool -api QuickTimeUTC -s -QuickTime:CreateDate "$normalPath"
            if ($exifOut -match 'Create\s*Date\s*:\s*(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})') {
                $mediaCreated = [datetime]::ParseExact($matches[1], 'yyyy:MM:dd HH:mm:ss', $null).ToLocalTime()
            }
        } catch {}
    } else {
        try {
            $exifOut = & exiftool -s -EXIF:DateTimeOriginal "$normalPath"
            if ($exifOut -match 'DateTimeOriginal\s*:\s*(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})') {
                $dateTaken = [datetime]::ParseExact($matches[1], 'yyyy:MM:dd HH:mm:ss', $null).ToLocalTime()
            }
        } catch {}
    }

    if (-not $dateTaken -and -not $isVideo -and $normalPath.Length -lt 260) {
        try {
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.NameSpace($fileInfo.Directory.FullName)
            $item = $folder.ParseName($fileInfo.Name)
            $comDate = $item.ExtendedProperty("System.Photo.DateTaken")
            if ($comDate -is [datetime]) { $dateTaken = $comDate }
        } finally {
            if ($shell) {
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
            }
        }
    }

        # === Timestamp selection ===
    $candidateDates = @()
    if ($dateTaken)    { $candidateDates += $dateTaken }
    if ($mediaCreated) { $candidateDates += $mediaCreated }
    $candidateDates += $dateCreated, $dateModified
    $oldestDate = ($candidateDates | Where-Object { $_ -is [datetime] } | Sort-Object)[0]

    # === Provenance classification ===
    $provenanceType = if ($dateTaken -and -not $mediaCreated -and -not $dateCreated -and -not $dateModified) {
        "EXIF-only"
    } elseif ($mediaCreated -and -not $dateTaken -and -not $dateCreated -and -not $dateModified) {
        "QuickTime-only"
    } elseif (-not $dateTaken -and -not $mediaCreated -and ($dateCreated -or $dateModified)) {
        "Fallback-only"
    } elseif ($dateTaken -or $mediaCreated) {
        "Mixed-sources"
    } else {
        "Unknown"
    }

    $processedCount.AddOrUpdate($provenanceType, 1, { param($k, $v) $v + 1 }) > $null
    $actions += "[Source] Provenance → $provenanceType"
        # === Metadata write-back ===
    if (-not $isVideo -and -not $dateTaken -and $normalPath.Length -lt 260) {
        try {
            if (-not $DryRun) {
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.NameSpace($fileInfo.Directory.FullName)
                $item = $folder.ParseName($fileInfo.Name)
                $item.ExtendedProperty("System.Photo.DateTaken") = $oldestDate
            }
            $actions += "$actionPrefix DateTaken to $($oldestDate.ToString('yyyy-MM-dd'))"
            $processedCount.AddOrUpdate('DateTakenSet', 1, { param($k, $v) $v + 1 }) > $null
        } catch {
            $actions += "❌ Failed to set DateTaken: $($_.Exception.Message)"
        }
    }

    if ($dateCreated -ne $oldestDate) {
        if (-not $DryRun) { $fileInfo.CreationTime = $oldestDate }
        $actions += "$actionPrefix DateCreated to $($oldestDate.ToString('yyyy-MM-dd'))"
        $processedCount.AddOrUpdate('DateCreatedSet', 1, { param($k, $v) $v + 1 }) > $null
    }

    if ($dateModified -ne $oldestDate) {
        if (-not $DryRun) { $fileInfo.LastWriteTime = $oldestDate }
        $actions += "$actionPrefix DateModified to $($oldestDate.ToString('yyyy-MM-dd'))"
        $processedCount.AddOrUpdate('DateModifiedSet', 1, { param($k, $v) $v + 1 }) > $null
    }

    # === Rename file based on timestamp ===
    $base = $oldestDate.ToString('yyyyMMdd_HHmmss')
    if ($oldestDate.Millisecond) {
        $base += '.' + $oldestDate.Millisecond.ToString('000')
    }
    $ext = $fileInfo.Extension.ToLower()
    $newName = "${base}${ext}"
    $targetPath = Join-Path $fileInfo.Directory.FullName $newName

    if ($fileInfo.Name -ne $newName) {
        $count = 1
        while ((Test-Path $targetPath) -and ($count -le 999)) {
            $suffix = $count.ToString('000')
            $newName = "${base}.${suffix}${ext}"
            $targetPath = Join-Path $fileInfo.Directory.FullName $newName
            $count++
        }

        if ($DryRun) {
            $actions += "Would rename → $($fileInfo.Name) → $newName"
        } else {
            try {
                Move-Item -LiteralPath $fileInfo.FullName -Destination $targetPath
                $actions += "Renamed → $($fileInfo.Name) → $newName"
                $processedCount.AddOrUpdate('Renamed', 1, { param($k, $v) $v + 1 }) > $null
                if ($count -gt 1) {
                    $processedCount.AddOrUpdate('WithCounter', 1, { param($k, $v) $v + 1 }) > $null
                }
            } catch {
                $actions += "❌ Rename failed → $($fileInfo.Name): $($_.Exception.Message)"
                $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 }) > $null
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
    $processedCount.AddOrUpdate('Failed', 1, { param($k, $v) $v + 1 }) > $null
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

Write-Host "`n" + ('═' * 50) -ForegroundColor Cyan
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
Write-Host ("{0,-30}: {1}" -f "EXIF-only sources",          $processedCount['EXIF-only'])
Write-Host ("{0,-30}: {1}" -f "QuickTime-only sources",     $processedCount['QuickTime-only'])
Write-Host ("{0,-30}: {1}" -f "Fallback-only sources",      $processedCount['Fallback-only'])
Write-Host ("{0,-30}: {1}" -f "Mixed-source files",         $processedCount['Mixed-sources'])
Write-Host ("{0,-30}: {1}" -f "Unknown provenance",         $processedCount['Unknown'])
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
    • Renaming files when extension doesn’t match actual content
    • Metadata extraction via ExifTool and COM (EXIF, QuickTime, NTFS)
    • Selection of oldest valid timestamp as canonical "DateTaken"
    • Corrections to DateCreated and LastWriteTime
    • File rename using timestamp format (yyyyMMdd_HHmmss.ext)
    • Suffix logic for timestamp collisions (.001, .002, …)
    • Provenance tagging: EXIF-only, Fallback-only, Mixed-sources, etc.
    • Thread-safe counters and color-coded progress output
    • Detailed summary report upon completion

NOTES:
    • Requires PowerShell 7+
    • Ensure ExifTool is in PATH for accurate metadata extraction
    • COM fallback is available for local NTFS-bound image files
    • Use -DryRun mode for safe simulation (no writes or renames)

EXAMPLE:
    .\Inspect-MediaAudit.ps1 -Path "D:\Pictures" -DryRun -Recurse
#>