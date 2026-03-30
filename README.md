## Author

Clive DSouza
Email: cldsouza74 [at] gmail [dot] com

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Requires ExifTool](https://img.shields.io/badge/Requires-ExifTool-green)](https://exiftool.org/)
[![Version](https://img.shields.io/badge/version-1.1.0-blue.svg)](CHANGELOG.md)

# Inspect-MediaAudit.ps1

A high-performance, parallelized PowerShell 7+ script for bulk auditing, repair, and normalization of media file metadata and filenames.
It validates media signatures, extracts/corrects timestamps, writes metadata, and renames files using a canonical timestamp.

---

## In Plain English

If you have a folder full of photos and videos that are a mess — wrong dates, random names like `IMG_4892.jpg`, or files pretending to be a format they're not — this script fixes all of that in one pass.

**It solves three problems:**

**1. Files wearing the wrong label**
Some files have the wrong extension — a photo saved as `.mov`, or a video labelled `.jpg`. The script reads the actual contents of each file to check what it really is, and renames it to the correct extension if it doesn't match.

**2. Dates are wrong, missing, or inconsistent**
Every photo and video carries hidden date information ("when was this taken?"). That date can live in several places — embedded EXIF metadata, QuickTime tags, or the filesystem — and they often disagree. The script reads all of them, picks the oldest (most likely the original capture date), and makes every date field agree.

**3. Filenames are meaningless**
`IMG_4892.jpg` tells you nothing. The script renames every file to its capture date and time — `20231225_143022.jpg` — so your library sorts in chronological order and duplicates are easy to spot.

**Safe to run:** use `-DryRun` first and the script will tell you exactly what it *would* change, without touching a single file.

---

## What's New in v1.1.0

- **Signature detection now actually works** — the magic-number check was silently disabled due to a PowerShell `switch`/array iteration bug; rewritten with `if/elseif` chains.
- **EXIF/QuickTime/XMP date extraction broadened** — removed the `EXIF:` group restriction so XMP-embedded dates are also found.
- **DateTaken write-back now uses exiftool** — the previous Shell.Application COM approach caused threading errors in parallel execution and has been replaced.
- **Provenance stats are now accurate** — EXIF-only and QuickTime-only categories were previously unreachable due to a logic bug; now correctly classified.
- **Parallel rename collisions are race-safe** — replaced the non-atomic `Test-Path` check with a `try/catch IOException` retry loop.
- **Stale file path bug fixed** — after a signature rename, subsequent operations now target the correct (new) filename.

See [CHANGELOG.md](CHANGELOG.md) for full details.

---

## Features

- **Signature validation:** Checks file extensions against actual content via magic-number analysis (JPEG, PNG, GIF, TIFF, MP4, MOV, HEIC, WebP).
- **Metadata extraction:** Reads capture dates from EXIF, XMP, QuickTime, and NTFS filesystem timestamps.
- **Timestamp correction:** Sets `DateTimeOriginal`, `CreationTime`, and `LastWriteTime` to the oldest valid timestamp found.
- **Automatic renaming:** Renames files to `yyyyMMdd_HHmmss.ext` based on canonical timestamp, with collision-safe suffixing (`.001`, `.002`, …).
- **Provenance tagging:** Classifies metadata source per file — EXIF-only, QuickTime-only, Fallback-only, Mixed-sources, Unknown.
- **Dry run mode:** Simulates all actions and reports what would change — no files are written or renamed.
- **Parallel processing:** Uses all logical CPU cores via `ForEach-Object -Parallel` with thread-safe counters.
- **Comprehensive reporting:** Color-coded progress output and a detailed summary on completion.

---

## When to Use This Script

Use **Inspect-MediaAudit.ps1** when you need to:

- Audit and repair large libraries of photos and videos.
- Correct file extensions that don't match the actual file content.
- Normalize inconsistent or missing metadata (date taken, creation time, etc.).
- Rename files based on canonical timestamps for easier sorting and deduplication.
- Prepare media collections for backup, archive, or sharing with accurate metadata.

Ideal for photographers, archivists, and IT professionals managing large or messy media folders.

---

## Requirements

- **Windows** — uses Windows NTFS file attributes for timestamp correction
- **PowerShell 7.0 or higher**
  [Download PowerShell 7+](https://github.com/PowerShell/PowerShell/releases)
- **ExifTool** — required for all metadata reads and writes
  [Download ExifTool](https://exiftool.org/)

> **Verify ExifTool is on your PATH** by running `exiftool -ver` in a PowerShell window before using this script.

---

## Usage

```powershell
# Preview all changes without modifying any files (always do this first):
.\Inspect-MediaAudit.ps1 -Path "D:\Pictures" -DryRun -Recurse

# Apply changes to top-level folder only:
.\Inspect-MediaAudit.ps1 -Path "C:\MediaLibrary"

# Apply changes recursively through all subfolders:
.\Inspect-MediaAudit.ps1 -Path "D:\Photos" -Recurse
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path`   | Yes | Root folder containing media files |
| `-DryRun` | No  | Preview actions — no files written or renamed |
| `-Recurse`| No  | Scan all subdirectories recursively |

### Supported Formats

| Type | Extensions |
|------|-----------|
| Images | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.tif` `.tiff` `.heic` `.webp` `.jfif` |
| Raw | `.nef` `.cr2` `.dng` `.crw` |
| Video | `.mov` `.mp4` `.avi` `.mkv` `.wmv` `.qt` `.mpg` |

---

## How It Works

For each media file the script:

1. **Reads the first 12 bytes** and compares the magic number against known format signatures to detect extension mismatches.
2. **Renames the file** if the extension doesn't match the actual format (e.g. `.jpg` file that is actually a PNG).
3. **Extracts timestamps** from EXIF/XMP (`DateTimeOriginal`) for images, or `QuickTime:CreateDate` for videos, with NTFS filesystem dates as fallback.
4. **Selects the oldest** of all available dates as the canonical capture timestamp.
5. **Writes `DateTimeOriginal`** back into the file via exiftool (images without an existing timestamp only).
6. **Corrects `CreationTime`** and `LastWriteTime` on the filesystem to match.
7. **Renames the file** to `yyyyMMdd_HHmmss.ext` (e.g. `20231225_143022.jpg`). Collisions get a numeric suffix: `20231225_143022.001.jpg`.
8. **Tags the provenance** of the chosen timestamp (EXIF-only, QuickTime-only, Fallback-only, Mixed-sources).

---

## Reading the Output

Each processed file prints one line:

```
[ 12.5%] (125/1000) [Source] Provenance → EXIF-only; Fixed DateCreated to 2023-12-25; Renamed → IMG_0042.jpg → 20231225_143022.jpg - IMG_0042.jpg
```

Colors: **Green** = normal, **Red** = failure, **Gray** = skipped.

The final summary shows totals for every counter including per-provenance breakdowns.

---

## Troubleshooting

**"exiftool is not recognized"**
ExifTool is not on your PATH. Download from [exiftool.org](https://exiftool.org), place `exiftool.exe` in a folder on your PATH, then verify: `exiftool -ver`.

**"Path not found" on launch**
The `-Path` argument doesn't exist. Verify with: `Test-Path "D:\YourFolder"`.

**0 files processed**
Check that your files use supported extensions (listed above). The script lowercases extensions before comparing, so casing is not an issue.

**DateTaken not being written**
ExifTool could not write to the file — it may be read-only, open in another app, or an unsupported raw format. Check the Failures counter and the red lines in output for per-file errors.

**Most files show "Fallback-only" provenance**
Files have no embedded EXIF or QuickTime metadata — common with screenshots and downloaded images. The script still normalises filesystem timestamps correctly.

**Many files getting `.001`, `.002` suffixes**
Multiple files share the same timestamp to the second (e.g. burst photos). Each unique second gets one file; collisions get a suffix. This is expected behaviour.

---

## Notes & Recommendations

- **Always run `-DryRun` first** to preview changes before any files are modified.
- **Back up your media** before running bulk fixes on an important library.
- **ExifTool is required** — without it, metadata reads and writes will not work.

---

## License

MIT © 2025-2026 Clive DSouza — see [LICENSE](LICENSE) for details.
