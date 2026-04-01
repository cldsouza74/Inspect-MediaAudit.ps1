## Author

Clive DSouza
Email: cldsouza74 [at] gmail [dot] com

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Perl 5.16+](https://img.shields.io/badge/Perl-5.16%2B-blue.svg)](https://www.perl.org/)
[![Requires Image::ExifTool](https://img.shields.io/badge/Requires-Image%3A%3AExifTool-green)](https://exiftool.org/)
[![Version](https://img.shields.io/badge/version-1.2.0-blue.svg)](CHANGELOG.md)

# media-audit.pl

A fast, cross-platform Perl script for bulk media repair. Part of the [media-audit](README.md) project — see the main README for a full side-by-side comparison with the PowerShell version.

Uses `Image::ExifTool` directly as a library — no subprocess spawning — making it significantly faster than the PowerShell version on large libraries.

---

## Why Perl?

The PowerShell script works well but spawns a new `exiftool` process for every file. On a library of 10,000 files that process-per-file overhead adds up to hours. This Perl port calls `Image::ExifTool` as a direct API — the same library that powers the `exiftool` command-line tool — so metadata reads and writes become in-process function calls instead of shell subprocesses.

**Rough speed comparison:**

| Library size | PowerShell | Perl |
|---|---|---|
| 500 files | 5–15 min | < 1 min |
| 5,000 files | 1–3 hours | 5–10 min |
| 50,000 files | all day | ~1 hour |

The Perl version is also cross-platform — it runs on Windows, Linux, macOS, and WSL with identical behaviour, except for CreationTime correction which requires Windows native Perl (see below).

---

## In Plain English

Same job as the PowerShell version — fixes three problems in one pass:

**1. Files wearing the wrong label**
Reads the actual contents of each file to check what it really is, and renames it to the correct extension if it doesn't match (e.g. a JPEG saved as `.mov`).

**2. Dates are wrong, missing, or inconsistent**
Reads capture dates from EXIF, QuickTime tags, and the filesystem. Picks the oldest valid date and makes every date field agree.

**3. Filenames are meaningless**
`IMG_4892.jpg` tells you nothing. Renames every file to `20231225_143022.jpg` so your library sorts in chronological order.

**Safe to run:** use `--dry-run` first — the script will tell you exactly what it *would* change without touching any file.

---

## Features

- **No subprocess overhead:** `Image::ExifTool` is used as a direct Perl library — no `exiftool` process spawned per file
- **FastScan mode:** `Image::ExifTool` stops reading after the first metadata block — 2-3× faster with no loss of capture-date accuracy
- **Optional parallel processing:** `--jobs N` splits work across N worker processes via `Parallel::ForkManager`; gracefully falls back to single-threaded if the module is absent; displays a live global `Overall: [XX.X%] (N/Total)` progress line updated every second
- **Signature validation:** checks file extensions against actual content via magic-number analysis (JPEG, PNG, GIF, TIFF, MP4, MOV, HEIC, WebP)
- **Metadata extraction:** reads capture dates from EXIF, XMP, QuickTime, and NTFS filesystem timestamps
- **Date sanity filtering:** rejects corrupt EXIF dates (before 1970 or more than 5 years in the future) before selecting the canonical timestamp
- **Timestamp correction:** writes `DateTimeOriginal` for images missing it; sets `mtime` via `utime()`; sets NTFS `CreationTime` via Win32 API on Windows native Perl
- **Automatic renaming:** renames files to `yyyyMMdd_HHmmss.ext`, with collision suffixing (`.001`, `.002`, …)
- **Deduplication:** after renaming, groups by file size first then SHA256-checksums only size-matched groups (~90% of I/O avoided); removes byte-identical duplicates, keeping the copy with the richest metadata provenance
- **Missing-file handling:** files that no longer exist at scan time (e.g. from an interrupted prior run) are silently skipped rather than counted as failures
- **Provenance tagging:** classifies metadata source per file — EXIF-only, QuickTime-only, Fallback-only, Mixed-sources, Unknown
- **Dry run mode:** simulates all actions including deduplication and reports what would change — no files written, renamed, or deleted
- **Comprehensive reporting:** colour-coded progress and a detailed summary on completion

---

## Requirements

| Requirement | Notes |
|---|---|
| **Perl 5.16+** | Included on Linux/macOS; [download for Windows](https://strawberryperl.com/) |
| **Image::ExifTool** | Required — see install instructions below |
| **Digest::SHA** | Required for `--dedup` — core Perl module, included since Perl 5.10 |
| **Parallel::ForkManager** | Optional — enables `--jobs N`; `cpan Parallel::ForkManager` |
| **Win32::API** | Optional — Windows native only, for CreationTime support |

### Install Image::ExifTool

```bash
# Linux (Debian/Ubuntu)
apt install libimage-exiftool-perl

# Linux (any) / macOS / Windows
cpan Image::ExifTool

# macOS with Homebrew
brew install exiftool
```

### Install Parallel::ForkManager (optional, any platform)

```bash
cpan Parallel::ForkManager
```

If not installed, the script runs single-threaded. `--jobs N` will print a one-time warning and continue.

### Install Win32::API (Windows only, optional)

```powershell
cpan Win32::API
```

If `Win32::API` is not installed the script still works fully — it just skips the CreationTime correction step and logs a one-time warning on startup.

---

## Usage

```bash
# Always preview first — no files are changed with --dry-run:
perl media-audit.pl --path /path/to/photos --dry-run --recurse

# Apply changes to top-level folder only:
perl media-audit.pl --path /path/to/photos

# Apply changes recursively through all subfolders:
perl media-audit.pl --path /path/to/photos --recurse

# Use 4 parallel workers (requires Parallel::ForkManager):
perl media-audit.pl --path /path/to/photos --recurse --jobs 4

# Preview deduplication (see what would be deleted — nothing is removed):
perl media-audit.pl --path /path/to/photos --recurse --dedup --dry-run

# Apply changes AND remove duplicates in one pass:
perl media-audit.pl --path /path/to/photos --recurse --dedup
```

On WSL, Windows drives are mounted under `/mnt/`:

```bash
perl media-audit.pl --path /mnt/e/Photos --dry-run --recurse --dedup
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `--path` | Yes | Root folder containing media files |
| `--dry-run` | No | Preview actions — no files written, renamed, or deleted |
| `--recurse` | No | Scan all subdirectories recursively |
| `--dedup` | No | After renaming, find and remove duplicate files by SHA256 checksum |
| `--jobs N` | No | Number of parallel worker processes (default: 1); requires `Parallel::ForkManager` |
| `--log [FILE]` | No | Write all failures and the final summary to FILE. Omit FILE to auto-name `media-audit-YYYYMMDD-HHMMSS.log` next to the script |

### Supported Formats

| Type | Extensions |
|---|---|
| Images | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.tif` `.tiff` `.heic` `.webp` `.jfif` |
| Raw | `.nef` `.cr2` `.dng` `.crw` |
| Video | `.mov` `.mp4` `.avi` `.mkv` `.wmv` `.qt` `.mpg` |

---

## How It Works

For each media file the script:

1. **Checks file existence** — if the file no longer exists at the collected path (e.g. renamed by a previous interrupted run), it is logged as a skip rather than a failure.
2. **Reads the first 12 bytes** and compares against known format signatures to detect extension mismatches.
3. **Renames the file** if the extension doesn't match the actual format (e.g. a `.jpg` file that is actually a PNG).
4. **Calls `Image::ExifTool->ExtractInfo()`** with `FastScan => 1` — stops after the first metadata block for 2-3× faster reads with no loss of capture-date accuracy.
5. **Extracts timestamps** — `DateTimeOriginal` for images, `QuickTime:CreateDate` (UTC-corrected) for videos, with filesystem `mtime` as fallback.
6. **Filters out implausible dates** — anything before 1970 or more than 5 years in the future is rejected as likely corrupt, with a warning.
7. **Selects the oldest** remaining valid date as the canonical capture timestamp.
8. **Writes `DateTimeOriginal`** back into the file via `Image::ExifTool->WriteInfo()` for images that lack it. Writes to a temp file then renames — no `_original` backup created.
9. **Sets `mtime`** (LastWriteTime) via `utime()`.
10. **Sets `CreationTime`** (NTFS birthtime) via Win32 API on Windows native Perl — see platform notes below.
11. **Renames the file** to `yyyyMMdd_HHmmss.ext`. Collisions get a numeric suffix: `20231225_143022.001.jpg`.
12. **Tags the provenance** of the chosen timestamp — EXIF-only, QuickTime-only, Fallback-only, Mixed-sources.
13. **Deduplication** (`--dedup` only) — groups files by size first (no I/O), then SHA256-checksums only size-matched groups. Within each duplicate group, keeps the file with the richest provenance; deletes the rest. See Deduplication section below.

---

## Deduplication

Use `--dedup` to find and remove byte-identical duplicate files in one pass.

**Why run it after renaming (not before)?**
Before renaming, two copies of the same photo might have completely different names — `IMG_4892.jpg` and `photo_copy.jpg`. After renaming they both become `20231225_143022.jpg` and `20231225_143022.001.jpg` — the `.001` suffix makes the collision immediately visible. More importantly, checksums are compared on the normalized files so there's no risk of a filename mismatch causing a duplicate to be missed.

**What gets kept:**

Within each duplicate group the keeper is selected by:

1. **Richest provenance** (best embedded metadata wins):

| Provenance | Priority |
|---|---|
| EXIF-only / QuickTime-only | 1 — keep (has embedded capture date) |
| Mixed-sources | 2 |
| Fallback-only | 3 |
| Unknown | 4 — least preferred |

2. **Shortest filename** — no `.001` suffix means it arrived first in the rename loop
3. **Alphabetical path** — stable tiebreak

**Example output:**

```
  [DEDUP] Group (SHA256: a3f1c8e2d94b7f01…) — 2 duplicate(s)
    KEEP   → 20231225_143022.jpg  [EXIF-only]
    DELETED → 20231225_143022.001.jpg  (3.4 MB)
```

**Always preview first:**

```bash
# See exactly what would be deleted — nothing is removed
perl media-audit.pl --path /mnt/e/Photos --recurse --dedup --dry-run

# Apply when happy with the preview
perl media-audit.pl --path /mnt/e/Photos --recurse --dedup
```

**Performance note:** the script groups files by size first — only files that share an identical byte-count are checksummed. On a typical photo library this avoids checksumming ~90% of files. Full content reads only happen when there are actual size collisions. On a slow NAS the I/O cost is still proportional to the total size of size-matched files, but this is far less than checksumming everything.

---

## Platform Notes: CreationTime

`CreationTime` (NTFS birthtime) cannot be set through any standard POSIX call — there is no `utime()` equivalent for birthtime. This script solves it per platform:

| Platform | mtime corrected | CreationTime corrected |
|---|---|---|
| Windows native Perl | ✅ `utime()` | ✅ `Win32::API` → `SetFileTime` |
| WSL (Linux Perl + `/mnt/e/`) | ✅ `utime()` | ❌ Linux kernel has no birthtime-set syscall |
| Linux / macOS native | ✅ `utime()` | ❌ Not supported by the OS |

On Windows native Perl with `Win32::API` installed, the script:
1. Opens a file handle with `CreateFileW` (GENERIC_WRITE)
2. Converts the Unix timestamp to a Windows `FILETIME` struct (100-nanosecond intervals since 1601-01-01, packed as two little-endian 32-bit integers)
3. Calls `SetFileTime` passing the creation-time `FILETIME` and `NULL` for the other two timestamps (leaving mtime/atime unchanged)
4. Closes the handle

On Linux/WSL the CreationTime step is silently skipped — all other steps run normally.

---

## Reading the Output

Each processed file prints one progress line:

```
[ 12.5%] (125/1000) [Source] Provenance → EXIF-only; Fixed DateTaken to 2023-12-25; Renamed → IMG_0042.jpg → 20231225_143022.jpg - IMG_0042.jpg
```

| Colour | Meaning |
|---|---|
| Green | Normal processing |
| Red | One or more failures on this file |
| Gray | File skipped |

In parallel mode (`--jobs N`), per-file lines are prefixed with `[J1]`, `[J2]`, etc. and may arrive out of file order. A separate global progress line is printed to stderr and updated every second:

```
  Overall: [ 42.3%] (17450/41385)
```

The final summary shows totals for every counter including per-provenance breakdowns.

---

## Troubleshooting

**"Image::ExifTool not found"**
Install with `cpan Image::ExifTool` or `apt install libimage-exiftool-perl`, then re-run.

**"Win32::API unavailable — CreationTime will not be set"**
This is a warning, not an error. The script continues and sets all other timestamps. To also fix CreationTime on Windows, install `Win32::API` with `cpan Win32::API`.

**"Path not found"**
The `--path` argument doesn't exist or is mis-typed. On WSL remember to use `/mnt/e/` not `E:\`.

**0 files processed**
No files match the supported extensions. Check the folder path and that your files use one of the supported formats listed above.

**Most files show "Fallback-only" provenance**
Files have no embedded EXIF or QuickTime metadata — common with screenshots and downloaded images. The script still normalises filesystem timestamps correctly.

**Many files getting `.001`, `.002` suffixes**
Multiple files share the same timestamp to the second (e.g. burst photos). Expected behaviour. Run `--dedup` afterwards to remove any that are byte-identical — burst photos will have different content and will not be deleted.

**"No duplicates found" but I expected some**
`--dedup` compares full file content by SHA256. Files must be byte-for-byte identical to be flagged — different resolution, compression, or metadata makes them distinct even if they look the same visually.

---

## Comparison: Perl vs PowerShell

| Feature | PowerShell (.ps1) | Perl (.pl) |
|---|---|---|
| Metadata read/write | `exiftool` subprocess per file | `Image::ExifTool` direct API — no subprocess |
| Speed (10k files) | ~30–60 min | ~5–10 min |
| FastScan | `-fast` flag on all reads | `FastScan => 1` in ExifTool API |
| Parallel processing | Yes — all cores via `ForEach-Object -Parallel` | Optional — `--jobs N` via `Parallel::ForkManager` |
| Cross-platform | Windows only | Windows / Linux / macOS / WSL |
| Deduplication | `-Dedup` — size-bucketed SHA256 | `--dedup` — size-bucketed SHA256 |
| Missing-file skip | Yes | Yes |
| CreationTime | `FileInfo.CreationTime` (.NET) | `Win32::API` SetFileTime |
| CreationTime on Linux | N/A | Skipped (OS limitation) |
| External binary needed | `exiftool` on PATH | None — `Image::ExifTool` is pure Perl |

Both scripts produce equivalent output and support the same dry-run, recurse, and dedup workflow.

---

## Notes & Recommendations

- **Always run `--dry-run` first** to preview changes before any files are modified.
- **Back up your media** before running bulk fixes on an important library.
- **No external `exiftool` binary required** — `Image::ExifTool` is a pure-Perl library.

---

## License

MIT © 2025-2026 Clive DSouza — see [LICENSE](LICENSE) for details.
