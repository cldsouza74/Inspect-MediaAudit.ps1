## Author

Clive DSouza
Email: cldsouza74 [at] gmail [dot] com

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Perl 5.16+](https://img.shields.io/badge/Perl-5.16%2B-blue.svg)](https://www.perl.org/)
[![Requires Image::ExifTool](https://img.shields.io/badge/Requires-Image%3A%3AExifTool-green)](https://exiftool.org/)
[![Version](https://img.shields.io/badge/version-1.1.0-blue.svg)](CHANGELOG.md)

# inspect-media-audit.pl

A fast, cross-platform Perl port of [Inspect-MediaAudit.ps1](README.md).

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
- **Signature validation:** checks file extensions against actual content via magic-number analysis (JPEG, PNG, GIF, TIFF, MP4, MOV, HEIC, WebP)
- **Metadata extraction:** reads capture dates from EXIF, XMP, QuickTime, and NTFS filesystem timestamps
- **Date sanity filtering:** rejects corrupt EXIF dates (before 1970 or in the future) before selecting the canonical timestamp
- **Timestamp correction:** writes `DateTimeOriginal` for images missing it; sets `mtime` via `utime()`; sets NTFS `CreationTime` via Win32 API on Windows native Perl
- **Automatic renaming:** renames files to `yyyyMMdd_HHmmss.ext`, with collision suffixing (`.001`, `.002`, …)
- **Deduplication:** after renaming, computes SHA256 checksums and removes byte-identical duplicate files — keeps the copy with the richest metadata provenance
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

### Install Win32::API (Windows only, optional)

```powershell
cpan Win32::API
```

If `Win32::API` is not installed the script still works fully — it just skips the CreationTime correction step and logs a one-time warning on startup.

---

## Usage

```bash
# Always preview first — no files are changed with --dry-run:
perl inspect-media-audit.pl --path /path/to/photos --dry-run --recurse

# Apply changes to top-level folder only:
perl inspect-media-audit.pl --path /path/to/photos

# Apply changes recursively through all subfolders:
perl inspect-media-audit.pl --path /path/to/photos --recurse

# Preview deduplication (see what would be deleted — nothing is removed):
perl inspect-media-audit.pl --path /path/to/photos --recurse --dedup --dry-run

# Apply changes AND remove duplicates in one pass:
perl inspect-media-audit.pl --path /path/to/photos --recurse --dedup
```

On WSL, Windows drives are mounted under `/mnt/`:

```bash
perl inspect-media-audit.pl --path /mnt/e/Photos --dry-run --recurse --dedup
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `--path` | Yes | Root folder containing media files |
| `--dry-run` | No | Preview actions — no files written, renamed, or deleted |
| `--recurse` | No | Scan all subdirectories recursively |
| `--dedup` | No | After renaming, find and remove duplicate files by SHA256 checksum |

### Supported Formats

| Type | Extensions |
|---|---|
| Images | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.tif` `.tiff` `.heic` `.webp` `.jfif` |
| Raw | `.nef` `.cr2` `.dng` `.crw` |
| Video | `.mov` `.mp4` `.avi` `.mkv` `.wmv` `.qt` `.mpg` |

---

## How It Works

For each media file the script:

1. **Reads the first 12 bytes** and compares against known format signatures to detect extension mismatches.
2. **Renames the file** if the extension doesn't match the actual format (e.g. a `.jpg` file that is actually a PNG).
3. **Calls `Image::ExifTool->ExtractInfo()`** — reads all metadata from the file in one pass, cached in memory.
4. **Extracts timestamps** — `DateTimeOriginal` for images, `QuickTime:CreateDate` (UTC-corrected) for videos, with filesystem `mtime` as fallback.
5. **Filters out implausible dates** — anything before 1970 or after tomorrow is rejected as likely corrupt, with a warning.
6. **Selects the oldest** remaining valid date as the canonical capture timestamp.
7. **Writes `DateTimeOriginal`** back into the file via `Image::ExifTool->WriteInfo()` for images that lack it. Writes to a temp file then renames — no `_original` backup created.
8. **Sets `mtime`** (LastWriteTime) via `utime()`.
9. **Sets `CreationTime`** (NTFS birthtime) via Win32 API on Windows native Perl — see platform notes below.
10. **Renames the file** to `yyyyMMdd_HHmmss.ext`. Collisions get a numeric suffix: `20231225_143022.001.jpg`.
11. **Tags the provenance** of the chosen timestamp — EXIF-only, QuickTime-only, Fallback-only, Mixed-sources.
12. **Deduplication** (`--dedup` only) — after all files are processed, computes SHA256 of every file and groups identical files by checksum. Within each group, keeps the file with the richest provenance; deletes the rest. See Deduplication section below.

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
perl inspect-media-audit.pl --path /mnt/e/Photos --recurse --dedup --dry-run

# Apply when happy with the preview
perl inspect-media-audit.pl --path /mnt/e/Photos --recurse --dedup
```

**Performance note:** checksumming reads every byte of every file. On a slow external drive or NAS, this adds time proportional to your total library size. On a fast local SSD it's negligible.

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
| Metadata read/write | `exiftool` subprocess per file | `Image::ExifTool` direct API |
| Speed (10k files) | Hours | Minutes |
| Parallel processing | Yes (compensates for subprocess cost) | Not needed |
| Cross-platform | Windows only (NTFS timestamps) | Windows / Linux / macOS / WSL |
| CreationTime | `FileInfo.CreationTime` (.NET) | `Win32::API` SetFileTime |
| CreationTime on Linux | N/A | Skipped (OS limitation) |
| Deduplication | No | Yes — `--dedup` (SHA256, keeps richest provenance) |

Both scripts produce identical output and support the same `--dry-run` and `--recurse` flags.

---

## Notes & Recommendations

- **Always run `--dry-run` first** to preview changes before any files are modified.
- **Back up your media** before running bulk fixes on an important library.
- **No external `exiftool` binary required** — `Image::ExifTool` is a pure-Perl library.

---

## License

MIT © 2025-2026 Clive DSouza — see [LICENSE](LICENSE) for details.
