## Author

Clive DSouza
Email: cldsouza74 [at] gmail [dot] com

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Requires ExifTool](https://img.shields.io/badge/Requires-ExifTool-green)](https://exiftool.org/)
[![Version](https://img.shields.io/badge/version-1.2.0-blue.svg)](CHANGELOG.md)

> **Also available as a faster, cross-platform Perl script:** [media-audit.pl](media-audit.pl) — see [README-perl.md](README-perl.md) for details.

# media-audit.ps1

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

## What's New in v1.2.0

Four new capabilities bringing the PowerShell script to full feature parity with `media-audit.pl`:

- **`-Dedup` — SHA256 size-bucketed deduplication**: groups files by byte-size first (free — no I/O), then SHA256-checksums only same-size groups. On typical photo libraries where fewer than 10% of files share a size, this avoids ~90% of checksum I/O. The keeper is chosen by provenance rank (EXIF > QuickTime > Mixed > Fallback > Unknown). Dry-run safe.
- **`-fast` on all exiftool reads**: stops metadata scanning after the first block, giving a 2–3× speedup with no loss of capture-date accuracy.
- **MAX_SANE extended to 5 years**: the previous 1-day future bound caused false "⚠️ All dates outside sane range" warnings on valid files when the system clock lagged or a camera clock was marginally ahead. Now accepts dates up to 5 years in the future.
- **Missing-file skip**: files that disappear between enumeration and processing (e.g. renamed by a previous interrupted run) are now detected before the magic-number read, logged as `⚠️ File no longer exists — skipping`, and counted as `Skipped` instead of `Failed`.

See [CHANGELOG.md](CHANGELOG.md) for the complete history including v1.1.1 and v1.1.0 fixes.

---

## Features

- **ExifTool pre-flight:** Verifies `exiftool` is on PATH before processing any files — fails fast with a clear message rather than silently failing thousands of files.
- **Fast reads:** `-fast` flag on all `exiftool` read calls stops scanning after the first metadata block — 2–3× faster on large libraries.
- **Signature validation:** Checks file extensions against actual content via magic-number analysis (JPEG, PNG, GIF, TIFF, MP4, MOV, HEIC, WebP).
- **Missing-file skip:** Files deleted between enumeration and processing are counted as `Skipped`, not `Failed`.
- **Metadata extraction:** Reads capture dates from EXIF, XMP, QuickTime, and NTFS filesystem timestamps.
- **Date sanity filtering:** Rejects corrupt EXIF dates (before 1970 or more than 5 years in the future) before selecting the canonical timestamp.
- **Timestamp correction:** Sets `DateTimeOriginal`, `CreationTime`, and `LastWriteTime` to the oldest valid timestamp found.
- **Automatic renaming:** Renames files to `yyyyMMdd_HHmmss.ext` based on canonical timestamp, with race-safe collision suffixing (`.001`, `.002`, …).
- **Provenance tagging:** Classifies metadata source per file — EXIF-only, QuickTime-only, Fallback-only, Mixed-sources, Unknown.
- **Dry run mode:** Simulates all actions and reports what would change — no files are written, renamed, or deleted.
- **Parallel processing:** Uses all logical CPU cores via `ForEach-Object -Parallel` with thread-safe counters and proper resource cleanup.
- **Size-bucketed deduplication (`-Dedup`):** Groups by byte-size first, checksums only same-size groups (~90% I/O reduction), deletes duplicates keeping the file with the best provenance. Progress shown for both checksum and delete phases.
- **Comprehensive reporting:** Color-coded progress output and a detailed summary on completion including dedup stats.

---

## When to Use This Script

Use **media-audit.ps1** when you need to:

- Audit and repair large libraries of photos and videos.
- Correct file extensions that don't match the actual file content.
- Normalize inconsistent or missing metadata (date taken, creation time, etc.).
- Rename files based on canonical timestamps for easier sorting and deduplication.
- Prepare media collections for backup, archive, or sharing with accurate metadata.

Ideal for photographers, archivists, and IT professionals managing large or messy media folders.

---

## Requirements

- **Windows** — uses Windows NTFS file attributes for timestamp correction
- **PowerShell 7.0 or higher** — [Download PowerShell 7+](https://github.com/PowerShell/PowerShell/releases)
- **ExifTool** — required for all metadata reads and writes — [Download ExifTool](https://exiftool.org/)

> The script checks for ExifTool automatically on startup and exits with a clear error if it is not found. To verify manually: `exiftool -ver`

---

## Usage

```powershell
# Always preview first — no files are changed with -DryRun:
.\media-audit.ps1 -Path "D:\Pictures" -DryRun -Recurse

# Apply changes to top-level folder only:
.\media-audit.ps1 -Path "C:\MediaLibrary"

# Apply changes recursively through all subfolders:
.\media-audit.ps1 -Path "D:\Photos" -Recurse

# Preview deduplication (shows what would be deleted, nothing removed):
.\media-audit.ps1 -Path "D:\Photos" -DryRun -Recurse -Dedup

# Full run with deduplication:
.\media-audit.ps1 -Path "D:\Photos" -Recurse -Dedup
```

### Parameters

| Parameter  | Required | Description |
|------------|----------|-------------|
| `-Path`    | Yes | Root folder containing media files |
| `-DryRun`  | No  | Preview actions — no files written, renamed, or deleted |
| `-Recurse` | No  | Scan all subdirectories recursively |
| `-Dedup`   | No  | Run SHA256 deduplication phase after the main scan |

### Supported Formats

| Type   | Extensions |
|--------|-----------|
| Images | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.tif` `.tiff` `.heic` `.webp` `.jfif` |
| Raw    | `.nef` `.cr2` `.dng` `.crw` |
| Video  | `.mov` `.mp4` `.avi` `.mkv` `.wmv` `.qt` `.mpg` |

---

## How It Works

For each media file the script:

1. **Pre-flight check** — verifies `exiftool` is on PATH; exits immediately with instructions if not.
2. **Reads the first 12 bytes** and compares the magic number against known format signatures to detect extension mismatches.
3. **Renames the file** if the extension doesn't match the actual format (e.g. a `.jpg` file that is actually a PNG).
4. **Extracts timestamps** from EXIF/XMP (`DateTimeOriginal`) for images, or `QuickTime:CreateDate` for videos, with NTFS filesystem dates as fallback.
5. **Filters out implausible dates** — any date before 1970 or more than 5 years in the future is rejected as likely corrupt, with a warning in the output.
6. **Selects the oldest** of all remaining valid dates as the canonical capture timestamp.
7. **Writes `DateTimeOriginal`** back into the file via exiftool (images without an existing timestamp only). Exit code is verified.
8. **Corrects `CreationTime`** and `LastWriteTime` on the filesystem to match.
9. **Renames the file** to `yyyyMMdd_HHmmss.ext` (e.g. `20231225_143022.jpg`). Collisions get a numeric suffix: `20231225_143022.001.jpg`.
10. **Tags the provenance** of the chosen timestamp (EXIF-only, QuickTime-only, Fallback-only, Mixed-sources).

If `-Dedup` is specified, a second phase runs after all files are processed:

11. **Groups files by byte-size** (free — no disk I/O). Only groups of 2+ identically-sized files are candidates.
12. **SHA256-checksums** only the candidate files (typically ~10% of the library).
13. **Deletes duplicates** within each identical-checksum group, keeping the file with the highest provenance rank. Progress is shown for both the checksum and delete steps.

---

## Reading the Output

Each processed file prints one progress line:

```
[ 12.5%] (125/1000) [Source] Provenance → EXIF-only; Fixed DateCreated to 2023-12-25; Renamed → IMG_0042.jpg → 20231225_143022.jpg - IMG_0042.jpg
```

| Color | Meaning |
|-------|---------|
| Green | Normal processing |
| Red   | One or more failures on this file |
| Gray  | File skipped |

The final summary shows totals for every counter including per-provenance breakdowns and a full failure count.

---

## Troubleshooting

**Script exits immediately with "exiftool not found"**
ExifTool is not on your PATH. Download from [exiftool.org](https://exiftool.org), place `exiftool.exe` in a folder on your PATH, then verify with `exiftool -ver`. The script checks for this automatically before touching any files.

**"Path not found" on launch**
The `-Path` argument doesn't exist or is mis-typed. Verify with: `Test-Path "D:\YourFolder"`.

**0 files processed — "No supported media files found"**
No files in the folder match the supported extensions. The script lowercases extensions before comparing, so casing is not an issue. Check that your files are one of the supported formats listed above.

**DateTaken not being written / failures on write**
ExifTool could not write to the file — it may be read-only, open in another app, or in an unsupported raw format. Red lines in the output show per-file error messages. Check the Failures counter in the summary.

**Files show a warning "All dates outside sane range"**
The file has corrupt or missing EXIF dates (e.g. year 0001 or 9999 from a faulty camera). The script falls back to the raw oldest date available and logs a warning. The file is still processed.

**Most files show "Fallback-only" provenance**
Files have no embedded EXIF or QuickTime metadata — common with screenshots and downloaded images. The script still normalises filesystem timestamps correctly.

**Many files getting `.001`, `.002` suffixes**
Multiple files share the same timestamp to the second (e.g. burst photos). Each unique second gets one file; collisions get a suffix. This is expected behaviour.

**CreationTime or LastWriteTime not being set**
The file is read-only or you lack write permission. Red lines in the output show the specific error. Check file permissions.

---

## Notes & Recommendations

- **Always run `-DryRun` first** to preview changes before any files are modified.
- **Back up your media** before running bulk fixes on an important library.
- **ExifTool is required** — the script will not start without it.

---

## License

MIT © 2025-2026 Clive DSouza — see [LICENSE](LICENSE) for details.
