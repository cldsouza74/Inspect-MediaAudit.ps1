# media-audit

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.2.0-blue.svg)](CHANGELOG.md)
[![Requires ExifTool](https://img.shields.io/badge/Requires-ExifTool-green)](https://exiftool.org/)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Perl 5.16+](https://img.shields.io/badge/Perl-5.16%2B-blue.svg)](https://www.perl.org/)

**Author:** Clive DSouza — cldsouza74 [at] gmail [dot] com

---

## What Is This?

`media-audit` is a bulk media repair tool. It fixes the three things that make large photo and video libraries a nightmare to manage — in one pass, without manual effort.

### The problem it solves

You dump a decade of phone backups, camera imports, and downloaded photos into a folder. What you get is chaos:

- Files named `IMG_4892.jpg`, `VID_20190814_092301.mp4`, `image (47).jpg` — in no particular order
- Photos dated 1970 because the camera had no idea what time it was
- Videos with an extension of `.jpg` because something renamed them wrong at some point
- The same photo appearing three or four times with slightly different names
- Metadata that disagrees with itself — the filename says one date, the EXIF says another, the filesystem says a third

`media-audit` reads every file's actual content, cross-checks all the date information it can find, picks the most trustworthy timestamp, fixes the metadata, renames the file to match, and optionally removes exact duplicates. When it's done, your library is sorted, consistent, and clean.

### What it does

**1. Fixes files wearing the wrong label**
Reads the first bytes of every file to check what it actually is — a real JPEG, PNG, MP4, HEIC, etc. If the extension doesn't match the content, it renames the file to the correct extension before doing anything else.

**2. Fixes dates that are wrong, missing, or inconsistent**
A photo's "when was this taken?" can live in three different places: embedded EXIF metadata, QuickTime tags (for videos), or the filesystem. They often disagree. The script reads all of them, filters out corrupt or implausible values (dates from 1970, year 9999, etc.), picks the oldest valid date as the most likely original capture time, and makes every date field agree.

**3. Gives files meaningful names**
`IMG_4892.jpg` tells you nothing. After running, every file is named `20231225_143022.jpg` — the date and time it was taken. Your library sorts chronologically. Duplicates become obvious at a glance.

**4. Finds and removes exact duplicates (optional)**
After fixing metadata and renaming, the `--dedup` / `-Dedup` flag compares file contents by SHA256 checksum. Files are first grouped by byte-size (fast, no I/O cost), then checksummed only within same-size groups — so on a typical library only ~10% of files are ever read for checksumming. When duplicates are found, the copy with the richest metadata is kept.

**Safe to run:** both scripts have a dry-run mode that shows you exactly what would change without touching a single file. Always use it first.

---

## Scripts

| Script | Purpose |
|---|---|
| [`media-audit.pl`](media-audit.pl) | Signature check, timestamp repair, rename, dedup — the main tool |
| [`media-audit.ps1`](media-audit.ps1) | Same as above, PowerShell version for Windows |
| [`sort-by-year.pl`](sort-by-year.pl) | Move files into `DEST/YEAR/` folders after auditing |

Run `media-audit.pl` first, then `sort-by-year.pl` to organise the results.

**Full usage instructions:** [MANUAL.md](MANUAL.md)

---

## Two Scripts, One Job

The tool ships as two scripts that do the same job — pick the one that fits your environment:

| | [media-audit.ps1](media-audit.ps1) | [media-audit.pl](media-audit.pl) |
|---|---|---|
| **Language** | PowerShell 7+ | Perl 5.16+ |
| **Platform** | Windows | Windows, Linux, macOS, WSL |
| **Metadata reads** | `exiftool` subprocess per file | `Image::ExifTool` direct API — no subprocess |
| **Speed (10k files)** | ~30–60 min | ~5–10 min |
| **Parallel processing** | Yes — all cores via `ForEach-Object -Parallel` | Optional — `--jobs N` via `Parallel::ForkManager` |
| **Deduplication** | `-Dedup` — size-bucketed SHA256 | `--dedup` — size-bucketed SHA256 |
| **FastScan** | `-fast` flag on all exiftool reads | `FastScan => 1` in ExifTool API |
| **CreationTime** | `FileInfo.CreationTime` (.NET) | `Win32::API` SetFileTime (Windows native Perl only) |
| **Missing-file skip** | Yes | Yes |
| **External binary needed** | `exiftool` on PATH | None — `Image::ExifTool` is pure Perl |
| **Full docs** | [README-ps1 →](README.md) | [README-perl →](README-perl.md) |

**Which should I use?**
- On Windows and already have PowerShell 7? Start with `media-audit.ps1` — no Perl setup needed.
- Have a large library (5,000+ files) or running on Linux/macOS/WSL? Use `media-audit.pl` — it's significantly faster because it calls ExifTool as a library instead of launching a new process per file.

---

## Quick Start

### PowerShell (Windows)

```powershell
# 1. Install ExifTool — https://exiftool.org — and verify:
exiftool -ver

# 2. Preview what would change (nothing is modified):
.\media-audit.ps1 -Path "D:\Pictures" -DryRun -Recurse

# 3. Apply fixes:
.\media-audit.ps1 -Path "D:\Pictures" -Recurse

# 4. Fix + remove exact duplicates:
.\media-audit.ps1 -Path "D:\Pictures" -Recurse -Dedup
```

→ Full PowerShell docs: [README.md](README.md) *(this file — scroll down)*

### Perl (Windows / Linux / macOS / WSL)

```bash
# 1. Install dependencies:
cpan Image::ExifTool
cpan Parallel::ForkManager   # optional — needed for --jobs N

# 2. Preview what would change (nothing is modified):
perl media-audit.pl --path /media/photos --dry-run --recurse

# 3. Apply fixes using 4 parallel workers:
perl media-audit.pl --path /media/photos --recurse --jobs 4

# 4. Fix + remove exact duplicates:
perl media-audit.pl --path /media/photos --recurse --jobs 4 --dedup
```

→ Full Perl docs: [README-perl.md](README-perl.md)

---

## Supported Formats

| Type   | Extensions |
|--------|-----------|
| Images | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.tif` `.tiff` `.heic` `.webp` `.jfif` |
| Raw    | `.nef` `.cr2` `.dng` `.crw` |
| Video  | `.mov` `.mp4` `.avi` `.mkv` `.wmv` `.qt` `.mpg` |

---

## What the Output Looks Like

Progress is printed per file as it's processed:

```
# PowerShell:
[ 12.5%] (125/1000) [Source] Provenance → EXIF-only; Fixed DateCreated to 2023-12-25; Renamed → IMG_0042.jpg → 20231225_143022.jpg

# Perl (parallel mode):
[J2] [ 12.5%] (125/1000) [EXIF-only] Fixed mtime; Renamed IMG_0042.jpg → 20231225_143022.jpg
  Overall: [ 12.5%] (125/1000)     ← global progress across all workers, updated every second
```

The final summary shows totals for every counter — files processed, metadata written, renames applied, duplicates removed, space freed, per-provenance breakdowns, and failure count.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

**v1.2.0 highlights:**
- Both scripts now at full feature parity
- Size-bucketed SHA256 deduplication (`--dedup` / `-Dedup`)
- `FastScan` / `-fast` on all metadata reads — 2–3× faster
- MAX_SANE extended from 1 day to 5 years — eliminates false "date out of range" warnings
- Missing-file skip — interrupted runs no longer produce false failures

---

## PowerShell Script — media-audit.ps1

> Full docs below. For Perl, see [README-perl.md](README-perl.md).

### Requirements

- **Windows** — uses Windows NTFS file attributes for timestamp correction
- **PowerShell 7.0 or higher** — [Download PowerShell 7+](https://github.com/PowerShell/PowerShell/releases)
- **ExifTool** — required for all metadata reads and writes — [Download ExifTool](https://exiftool.org/)

> The script checks for ExifTool automatically on startup and exits with a clear error if it is not found. Verify manually with: `exiftool -ver`

### Parameters

| Parameter  | Required | Description |
|------------|----------|-------------|
| `-Path`    | Yes | Root folder containing media files |
| `-DryRun`  | No  | Preview actions — no files written, renamed, or deleted |
| `-Recurse` | No  | Scan all subdirectories recursively |
| `-Dedup`   | No  | Run SHA256 deduplication phase after the main scan |

### Features

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

### How It Works

For each media file the script:

1. **Pre-flight check** — verifies `exiftool` is on PATH; exits immediately with instructions if not.
2. **Existence check** — skips files that disappeared since enumeration (e.g. from a previous interrupted run).
3. **Reads the first 12 bytes** and compares the magic number against known format signatures to detect extension mismatches.
4. **Renames the file** if the extension doesn't match the actual format (e.g. a `.jpg` file that is actually a PNG).
5. **Extracts timestamps** from EXIF/XMP (`DateTimeOriginal`) for images, or `QuickTime:CreateDate` for videos, with NTFS filesystem dates as fallback.
6. **Filters out implausible dates** — any date before 1970 or more than 5 years in the future is rejected as likely corrupt, with a warning in the output.
7. **Selects the oldest** of all remaining valid dates as the canonical capture timestamp.
8. **Writes `DateTimeOriginal`** back into the file via exiftool (images without an existing timestamp only). Exit code is verified.
9. **Corrects `CreationTime`** and `LastWriteTime` on the filesystem to match.
10. **Renames the file** to `yyyyMMdd_HHmmss.ext` (e.g. `20231225_143022.jpg`). Collisions get a numeric suffix: `20231225_143022.001.jpg`.
11. **Tags the provenance** of the chosen timestamp (EXIF-only, QuickTime-only, Fallback-only, Mixed-sources).

If `-Dedup` is specified, a second phase runs after all files are processed:

12. **Groups files by byte-size** (free — no disk I/O). Only groups of 2+ identically-sized files are candidates.
13. **SHA256-checksums** only the candidate files (typically ~10% of the library).
14. **Deletes duplicates** within each identical-checksum group, keeping the file with the highest provenance rank. Progress is shown for both the checksum and delete steps.

### Reading the Output

Each processed file prints one progress line:

```
[ 12.5%] (125/1000) [Source] Provenance → EXIF-only; Fixed DateCreated to 2023-12-25; Renamed → IMG_0042.jpg → 20231225_143022.jpg
```

| Color | Meaning |
|-------|---------|
| Green | Normal processing |
| Red   | One or more failures on this file |
| Gray  | File skipped |

### Troubleshooting

**Script exits immediately with "exiftool not found"**
ExifTool is not on your PATH. Download from [exiftool.org](https://exiftool.org), place `exiftool.exe` in a folder on your PATH, then verify with `exiftool -ver`.

**"Path not found" on launch**
The `-Path` argument doesn't exist or is mis-typed. Verify with: `Test-Path "D:\YourFolder"`.

**0 files processed — "No supported media files found"**
No files in the folder match the supported extensions. The script lowercases extensions before comparing, so casing is not an issue.

**DateTaken not being written / failures on write**
ExifTool could not write to the file — it may be read-only, open in another app, or in an unsupported raw format. Red lines in the output show per-file error messages.

**Files show a warning "All dates outside sane range"**
The file has corrupt or missing EXIF dates (e.g. year 0001 or 9999 from a faulty camera). The script falls back to the raw oldest date and logs a warning. The file is still processed.

**Most files show "Fallback-only" provenance**
Files have no embedded EXIF or QuickTime metadata — common with screenshots and downloaded images. Filesystem timestamps are still normalised correctly.

**Many files getting `.001`, `.002` suffixes**
Multiple files share the same timestamp to the second (e.g. burst photos). Expected behaviour — run `--dedup` afterwards if you want to remove byte-identical copies.

---

## Notes & Recommendations

- **Always run `-DryRun` first** to preview changes before any files are modified.
- **Back up your media** before running bulk fixes on an important library.
- **ExifTool is required** — the script will not start without it.

---

## License

MIT © 2025-2026 Clive DSouza — see [LICENSE](LICENSE) for details.
