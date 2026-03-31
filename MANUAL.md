# media-audit — User Manual

> **Three scripts. One job: fix your photo library.**

---

## Table of Contents

1. [Overview](#overview)
2. [Setup and Installation](#setup-and-installation)
3. [Recommended Workflow](#recommended-workflow)
4. [Script: media-audit.pl](#script-media-auditpl)
5. [Script: media-audit.ps1](#script-media-auditps1)
6. [Script: sort-by-year.pl](#script-sort-by-yearpl)
7. [End-to-End Example](#end-to-end-example)
8. [Understanding the Output](#understanding-the-output)
9. [Common Questions](#common-questions)

---

## Overview

These scripts fix the three things that make large photo and video libraries a mess:

| Problem | What the scripts do |
|---|---|
| Files with wrong extensions | Read the first bytes of every file and rename it to the correct extension if it doesn't match |
| Dates that are wrong, missing, or inconsistent | Read every date source (EXIF, QuickTime, filesystem), pick the oldest valid one, and make them all agree |
| Meaningless filenames like `IMG_4892.jpg` | Rename every file to `20231225_143022.jpg` so your library sorts chronologically |

An optional deduplication step (`--dedup` / `-Dedup`) removes byte-identical copies after renaming.

After auditing, `sort-by-year.pl` moves files into `YYYY/` subfolders so your library is organised by year.

---

## Setup and Installation

### Perl scripts (media-audit.pl, sort-by-year.pl)

Perl 5.16+ is required. It is pre-installed on Linux and macOS. On Windows, install [Strawberry Perl](https://strawberryperl.com/).

**Required module:**

```bash
# Linux (Debian/Ubuntu)
sudo apt install libimage-exiftool-perl

# macOS
brew install exiftool

# Any platform via CPAN
cpan Image::ExifTool
```

**Optional module — parallel processing (`--jobs N`):**

```bash
cpan Parallel::ForkManager
```

If not installed, the script runs single-threaded and prints a one-time warning. Everything still works.

**Optional module — NTFS CreationTime on Windows native Perl:**

```powershell
cpan Win32::API
```

Not needed on Linux/macOS/WSL — `mtime` is corrected on all platforms.

---

### PowerShell script (media-audit.ps1)

- **PowerShell 7.0+** — [Download here](https://github.com/PowerShell/PowerShell/releases)
- **ExifTool** — [Download here](https://exiftool.org/) — place `exiftool.exe` somewhere on your `PATH`

Verify both are working:

```powershell
$PSVersionTable.PSVersion   # must be 7.0 or higher
exiftool -ver               # must print a version number
```

---

## Recommended Workflow

Always follow this order. Running in the wrong order is safe but less effective.

```
1. media-audit.pl / media-audit.ps1    — fix extensions, dates, names, dedup
2. sort-by-year.pl                     — move files into YYYY/ subfolders
```

**Why this order?** `sort-by-year.pl` reads years directly from filenames in the canonical `YYYYMMDD_HHmmss.ext` format. Files must be renamed by media-audit first.

**The golden rule: always dry-run first.**

```bash
# Step 1 — preview the audit (nothing is changed)
perl media-audit.pl --path /mnt/e/Photos --dry-run --recurse

# Step 2 — apply the audit
perl media-audit.pl --path /mnt/e/Photos --recurse --jobs 4 --dedup

# Step 3 — preview the sort (nothing is moved)
perl sort-by-year.pl --path /mnt/e/Photos --dry-run

# Step 4 — apply the sort
perl sort-by-year.pl --path /mnt/e/Photos
```

---

## Script: media-audit.pl

The main audit tool. Runs on Linux, macOS, Windows, and WSL. Significantly faster than the PowerShell version because it calls `Image::ExifTool` as a library rather than spawning a process per file.

### Synopsis

```bash
perl media-audit.pl --path <dir> [OPTIONS]
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `--path <dir>` | **Yes** | Folder containing your media files |
| `--dry-run` | No | Show what would happen — no files are changed |
| `--recurse` | No | Process all subfolders recursively |
| `--dedup` | No | After renaming, find and delete duplicate files by content (SHA256) |
| `--jobs N` | No | Run N parallel worker processes; requires `Parallel::ForkManager` |

### Examples

```bash
# Preview everything, recurse into subfolders
perl media-audit.pl --path /mnt/e/Photos --dry-run --recurse

# Apply changes, 4 parallel workers
perl media-audit.pl --path /mnt/e/Photos --recurse --jobs 4

# Apply changes + remove exact duplicates
perl media-audit.pl --path /mnt/e/Photos --recurse --jobs 4 --dedup

# Top-level folder only (no subfolders)
perl media-audit.pl --path /mnt/e/Photos/unsorted
```

### What it does per file

1. Checks the file still exists (skips with a warning if it was deleted since the scan started)
2. Reads the first 12 bytes to check the file's actual format against its extension
3. Renames to the correct extension if there's a mismatch (e.g. a JPEG saved as `.mov`)
4. Reads all available date sources: EXIF `DateTimeOriginal`, QuickTime `CreateDate`, filesystem `mtime`
5. Filters out implausible dates (before 1970 or more than 5 years in the future)
6. Picks the oldest remaining valid date as the canonical timestamp
7. Writes `DateTimeOriginal` back into the file if it's missing
8. Sets filesystem `mtime` to the canonical date
9. Sets NTFS `CreationTime` via Win32 API (Windows native Perl only)
10. Renames the file to `YYYYMMDD_HHmmss.ext`

Then (if `--dedup`):

11. Groups all processed files by size — same-size groups are duplicate candidates
12. SHA256-checksums only the candidates (~10% of files in a typical library)
13. Within each duplicate group, keeps the file with the richest metadata provenance and deletes the rest

### Supported formats

| Type | Extensions |
|---|---|
| Images | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.tif` `.tiff` `.heic` `.webp` `.jfif` |
| Raw | `.nef` `.cr2` `.dng` `.crw` |
| Video | `.mov` `.mp4` `.avi` `.mkv` `.wmv` `.qt` `.mpg` |

### Speed reference

| Library size | Single-threaded | With `--jobs 4` |
|---|---|---|
| 500 files | < 1 min | < 1 min |
| 5,000 files | 5–10 min | 2–3 min |
| 50,000 files | ~60 min | ~15 min |

---

## Script: media-audit.ps1

The Windows-native PowerShell version. Does the same job as `media-audit.pl` but uses PowerShell's native parallel processing (all CPU cores automatically) and requires `exiftool.exe` on your PATH.

### Synopsis

```powershell
.\media-audit.ps1 -Path <dir> [OPTIONS]
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-Path <dir>` | **Yes** | Folder containing your media files |
| `-DryRun` | No | Show what would happen — no files are changed |
| `-Recurse` | No | Process all subfolders recursively |
| `-Dedup` | No | After renaming, find and delete duplicate files by content (SHA256) |

### Examples

```powershell
# Preview everything, recurse into subfolders
.\media-audit.ps1 -Path "D:\Photos" -DryRun -Recurse

# Apply changes
.\media-audit.ps1 -Path "D:\Photos" -Recurse

# Apply changes + remove exact duplicates
.\media-audit.ps1 -Path "D:\Photos" -Recurse -Dedup

# Top-level folder only
.\media-audit.ps1 -Path "D:\Photos\unsorted"
```

### What it does per file

Same steps as `media-audit.pl`. Key differences:

- Uses `exiftool` as a subprocess (one process per file) rather than a library call — slower but requires no Perl
- Parallel processing is always on — all logical CPU cores used automatically
- `CreationTime` is set via .NET `FileInfo.CreationTime` — works on all NTFS volumes without any extra modules
- Does not support `--jobs` — parallelism is always at maximum

### Prerequisites check

The script verifies `exiftool` is on PATH on startup. If it is not found, it prints a clear error message with installation instructions and exits — no files are touched.

---

## Script: sort-by-year.pl

Companion script that moves media files into year subfolders. Runs **after** `media-audit.pl` or `media-audit.ps1`.

Files must already be named in the canonical `YYYYMMDD_HHmmss.ext` format — the year is read directly from the filename with no metadata access.

```
/Photos/test/20231225_143022.jpg   →   /Photos/test/2023/20231225_143022.jpg
/Photos/test/20190814_092301.mp4   →   /Photos/test/2019/20190814_092301.mp4
```

### Synopsis

```bash
perl sort-by-year.pl --path <dir> [OPTIONS]
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `--path <dir>` | **Yes** | Folder to sort — year subfolders are created inside this folder |
| `--dry-run` | No | Show what would be moved — no files are touched |
| `--recurse` | No | Also sort files in subdirectories of `--path` |

### Examples

```bash
# Preview what would move (always do this first)
perl sort-by-year.pl --path /mnt/e/Photos --dry-run

# Apply — sort top-level files only
perl sort-by-year.pl --path /mnt/e/Photos

# Sort files in subdirectories too
perl sort-by-year.pl --path /mnt/e/Photos --recurse

# Preview recursive sort
perl sort-by-year.pl --path /mnt/e/Photos --dry-run --recurse
```

### Safe to re-run

Already-sorted year folders (`2019/`, `2023/`, etc.) are automatically skipped when using `--recurse`. Running the script twice on the same folder will not double-move files.

### Collision handling

If a file with the same name already exists in the target year folder, a numeric suffix is appended rather than overwriting:

```
2023/20231225_143022.jpg        ← existing file, kept as-is
2023/20231225_143022.001.jpg    ← new file, renamed automatically
```

### What the output looks like

```
[ 12.5%] (125/1000) Moved
            SRC: /Photos/test/20231225_143022.jpg
            DST: /Photos/test/2023/20231225_143022.jpg

[ 13.0%] (130/1000) ⚠️  Skipping (not in YYYYMMDD_HHmmss format): random-photo.jpg
```

### Summary line

At the end of every run:

```
══════════════════════════════════════════════════
Files found             : 1000
Moved                   : 982
Skipped                 : 15
Collision renames       : 3
Errors                  : 0
Runtime                 : 4s
Throughput              : 245 files/sec
══════════════════════════════════════════════════
```

---

## End-to-End Example

This is the complete workflow for cleaning up a large photo library.

```bash
# ── 1. AUDIT — preview first ────────────────────────────────────────────────
perl media-audit.pl --path /mnt/e/Photos --dry-run --recurse --dedup

# ── 2. AUDIT — apply when satisfied with the preview ─────────────────────────
# Use tee to keep a log of everything that happened:
perl media-audit.pl --path /mnt/e/Photos --recurse --jobs 4 --dedup \
    | tee /tmp/audit-log.txt

# ── 3. REVIEW — check for any failures ───────────────────────────────────────
grep '❌' /tmp/audit-log.txt

# ── 4. SORT — preview year-folder organisation ───────────────────────────────
perl sort-by-year.pl --path /mnt/e/Photos --dry-run

# ── 5. SORT — apply ───────────────────────────────────────────────────────────
perl sort-by-year.pl --path /mnt/e/Photos
```

After this, your library looks like:

```
/Photos/
    2019/
        20190814_092301.mp4
        20190920_184512.jpg
    2022/
        20220104_130045.jpg
        ...
    2023/
        20231225_143022.jpg
        ...
```

---

## Understanding the Output

### Progress lines (media-audit.pl)

```
[ 12.5%] (125/1000) [Source] Provenance → EXIF-only; Fixed mtime; Renamed IMG_0042.jpg → 20231225_143022.jpg
```

| Part | Meaning |
|---|---|
| `[12.5%] (125/1000)` | Percentage and count through the file list |
| `[Source]` | Where the canonical date came from: EXIF, QuickTime, filesystem, or mixed |
| `Provenance →` | Classification of the metadata quality: EXIF-only, QuickTime-only, Mixed-sources, Fallback-only |
| `Fixed mtime` | The filesystem modification time was updated |
| `Renamed ...` | The file was renamed to the canonical format |

In parallel mode (`--jobs N`), lines are prefixed with `[J1]`, `[J2]`, etc. Files may appear out of order — that is expected. A global progress line updates every second:

```
  Overall: [ 42.3%] (17450/41385)
```

### Colour coding

| Colour | Meaning |
|---|---|
| Green | Normal — file processed successfully |
| Red | Failure — one or more steps failed for this file |
| Yellow | Warning — file skipped or a non-critical issue |
| Cyan | Information — headers and summary |

### Provenance labels

| Label | Meaning |
|---|---|
| `EXIF-only` | Canonical date came from embedded EXIF — most reliable |
| `QuickTime-only` | Canonical date came from QuickTime container tags — most reliable for video |
| `Mixed-sources` | Multiple date sources agreed; EXIF and/or QuickTime both contributed |
| `Fallback-only` | No embedded metadata; filesystem `mtime` used — least reliable |
| `Unknown` | No usable date found at all |

### Final summary (media-audit.pl)

```
══════════════════════════════════════════════════════════════════
Files processed         : 41385
Renamed                 : 39201
Metadata written        : 28934
mtime fixed             : 38100
CreationTime fixed      : 38100   (Windows only)
Skipped                 : 142
Failed                  : 41
Duplicates found        : 8201
Duplicates deleted      : 7893
Space freed             : 12.4 GB
──────────────────────────────────────────────────────────────────
EXIF-only               : 29105
QuickTime-only          : 6711
Mixed-sources           : 2204
Fallback-only           : 3323
Unknown                 : 42
══════════════════════════════════════════════════════════════════
```

---

## Common Questions

**A file shows `⚠️ All dates outside sane range` — what does that mean?**

All date values found for that file were either before 1970 or more than 5 years in the future — typical of cameras with dead batteries, corrupt EXIF, or files created by software that writes placeholder dates like `0001-01-01` or `9999-12-31`. The script falls back to the raw oldest date and logs a warning. The file is still processed and renamed.

**Most of my files show "Fallback-only" — is something wrong?**

No. "Fallback-only" means the files have no embedded EXIF or QuickTime metadata — common with screenshots, downloaded images, and some older cameras. The script still normalises the filesystem timestamp and renames the file to the canonical format.

**Files are getting `.001`, `.002` suffixes — is that a problem?**

Multiple files share the same timestamp to the second (common with burst mode or phones that shoot faster than once per second). The script appends a numeric suffix rather than overwriting. These are not duplicates — run `--dedup` if you want to remove any that are byte-for-byte identical (burst photos will have different content and will not be deleted).

**The script found failures — what should I do?**

Check the lines marked `❌` in the output. Common causes:

| Error message | Cause | Action |
|---|---|---|
| `Cannot open: No such file` | File disappeared between scan and processing | Ignore — counted as Skip in modern versions |
| `Bad IFD or truncated file` | Corrupt TIFF/JPEG — damaged metadata | Inspect the file; it may be partially recoverable with ExifTool directly |
| `Not a valid JPG` | Corrupt JPEG | Check the file with an image viewer; it may be unrecoverable |
| `ExifTool write failed` | File is read-only or locked by another app | Close other apps, check file permissions |

**sort-by-year.pl says files are "not in YYYYMMDD_HHmmss format" — why?**

These files were not renamed by `media-audit` yet (or were skipped because of failures). Run `media-audit` first, then sort. Files that genuinely have no reliable date cannot be sorted by year automatically.

**Can I run the scripts on the same folder twice safely?**

Yes. Both scripts are designed to be re-run:

- `media-audit.pl` / `.ps1`: files already named in canonical format are still processed for metadata corrections; any file that has already been renamed correctly will not be renamed again (no-op rename).
- `sort-by-year.pl`: year-named folders (`2019/`, `2023/`, etc.) are automatically skipped in `--recurse` mode, so already-sorted files are never double-moved.

**Should I back up my files first?**

Yes. Both scripts modify files in-place. The `--dry-run` flag shows you everything that would happen without touching any file — always use it first. For your first run on any important library, keep a backup until you have verified the results.

---

## License

MIT © 2025-2026 Clive DSouza — see [LICENSE](LICENSE) for details.
