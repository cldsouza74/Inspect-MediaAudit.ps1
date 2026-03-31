# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),  
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.4.0] - 2026-03-31

### Added
- **`install.sh`** — one-command installer for Linux, macOS, and WSL. Checks Perl
  version, installs cpanm if missing, runs `cpanm --installdeps .`, copies scripts
  and `VERSION` to `~/bin` (or `/usr/local/bin` with `--system`), updates PATH in
  `.bashrc`/`.zshrc`, and verifies the install before exit.
- **`Install.ps1`** — one-command installer for Windows (PowerShell 7+). Checks PS
  version, exiftool, and Perl; installs CPAN dependencies; copies scripts to `~/bin`
  or `C:\tools\media-audit` with `-System`; adds install dir to user or system PATH.
- **Test suite** — 41 tests across 6 files covering: magic-number signature detection,
  EXIF date extraction and sanity filtering, canonical rename and collision suffixing,
  SHA256 deduplication, year-folder sorting, and failure handling regressions. All
  tests run in temp directories — no fixture files modified.
- **`t/fixtures/`** — 8 binary fixture files committed to the repo: valid JPEG with
  EXIF, PNG with wrong extension, no-metadata JPEG, future-date EXIF, corrupt-date
  EXIF (year 0001), duplicate pair, and a pre-canonical file.
- **GitHub Actions CI** — runs `prove -lr t/` on ubuntu-latest and macos-latest on
  every push and pull request to main.
- **`cpanfile`** — formal dependency manifest. `cpanm --installdeps .` installs all
  required and optional modules. Web UI deps gated behind `feature 'web'`.

### Changed
- **Single `VERSION` file** — version number moved from hardcoded strings in each
  script to a single `VERSION` file at the repo root. All three scripts read it at
  startup via `FindBin`. Bumping the version now requires editing one file.
- **`install.sh` copies `VERSION`** alongside scripts so `FindBin` resolves correctly
  when scripts are run from `~/bin` after installation.

---

## [1.3.2] - 2026-03-31

### Changed — all scripts
- **Consistent summary header**: all three scripts now open their summary block with
  `Script` (name + version) and `Runtime` as the first two lines, followed by a `─`
  divider before the per-file counters. Runtime is now always printed in `media-audit.pl`
  and `media-audit.ps1` regardless of `--dry-run` / `-DryRun`.

---

## [1.3.1] - 2026-03-31

### Added — sort-by-year.pl
- **Runtime and throughput in summary**: `Runtime` and `Throughput (files/sec)` lines added
  to the end-of-run summary. Errors line is now highlighted in red when non-zero, and a
  trailing `⚠️  N file(s) could not be moved` reminder is printed when there are failures.
- **`MANUAL.md`** — comprehensive user manual covering all three scripts: full parameter
  reference, plain-language step-by-step workflow, output interpretation, and a Q&A
  troubleshooting section.

---

## [1.3.0] - 2026-03-31

### Added
- **`sort-by-year.pl`** — companion script that sorts media files in-place into
  `PATH/YYYY/` subfolders. Takes a single `--path` argument — no separate src/dest
  needed. Supports `--dry-run`, `--recurse`, collision handling (`.001`/`.002` suffixes),
  year sanity check (1970–2100), per-file `[XX.X%] SRC/DST` output, and a full summary.
  Already-sorted year folders are automatically skipped in both modes — safe to re-run.
  Extracts year from canonical `YYYYMMDD_HHmmss.ext` filenames — no metadata reads.

---

## [1.2.2] - 2026-03-31

### Fixed — media-audit.pl
- **Dedup crash on I/O error**: `Digest::SHA->addfile()` throws on read errors (e.g. USB
  drive hiccup or corrupt file) rather than returning an error code. Without an `eval`
  wrapper, a single unreadable file crashed the entire dedup phase mid-run. Now catches
  the exception, logs a `⚠️ Checksum skipped` warning for the affected file, and
  continues checksumming the remaining files.

---

## [1.2.1] - 2026-03-31

### Fixed — media-audit.ps1
- **`-Dedup` never ran** (critical): `$Dedup` was not imported via `$using:Dedup` in the
  parallel scriptblock. Inside the runspace it evaluated to `$null`/`$false`, so
  `$pFiles.Add()` never executed and `$processedFiles` was always empty. The dedup phase
  ran but found 0 files, reported "No duplicates found" on every run regardless of actual
  duplicates present.
- **SHA256 engine leak on exception**: `$sha256Engine.Dispose()` was not in a `finally`
  block — if any file threw during checksumming the engine handle was never released.
  Wrapped checksum loop in `try/finally` to guarantee disposal.

### Fixed — media-audit.pl
- **Failures silently swallowed**: `_print_line` was throttled by `$report_every` with no
  exception for failures. A failure on file #42 with `report_every=100` was counted in
  `$C{Failed}` but never printed. Added `$failed ||` to the output condition so failures
  always print immediately regardless of the reporting interval.

---

## [1.2.0] - 2026-03-31 — media-audit.ps1

### Added
- **`-Dedup` switch** — SHA256 size-bucketed deduplication phase after the main scan.
  Files are grouped by byte-size first (free — no I/O), then SHA256-checksummed only
  within same-size groups (~90% I/O reduction on typical libraries). Keeper is chosen
  by provenance rank: EXIF-only > QuickTime-only > Mixed-sources > Fallback-only > Unknown.
  Checksum and delete phases both show live percentage progress. Fully dry-run safe.
- **`-fast` on all exiftool read calls** — stops metadata scanning after the first block,
  giving a 2–3× speedup with no loss of capture-date accuracy.
- **`$processedFiles` ConcurrentBag** — collects `{Path, Provenance}` per file across
  all parallel runspaces so the dedup phase has accurate final paths after renames.
- **`Format-Bytes` helper** — formats raw byte counts to human-readable KB/MB/GB for
  the "Space freed" line in the dedup summary.
- **`$finalPath` tracking** — file path is updated after every signature rename and
  timestamp rename so the dedup phase always references the current on-disk name.
- **Dedup stats in summary** — reports groups found, files removed (or would-delete in
  dry-run), and space freed.

### Fixed
- **MAX_SANE extended to 5 years** — `(Get-Date).AddDays(1)` upper bound caused false
  "⚠️ All dates outside sane range" warnings for valid files when the system clock lagged
  or a camera clock was marginally ahead. Changed to `(Get-Date).AddYears(5)`.
- **Missing-file skip** — files that disappear between enumeration and processing are now
  detected via `Test-Path` before the magic-number read, counted as `Skipped` rather than
  `Failed`, and logged with a visible `⚠️` warning.

---

## [1.2.0] - 2026-03-30 — media-audit.pl
### Added
- **`--jobs N` parallel processing**: optional `Parallel::ForkManager` integration splits
  the file list into N chunks processed by N worker processes simultaneously. Falls back
  to single-threaded mode with a one-time warning if the module is not installed.
  Progress lines are prefixed with `[J1]`, `[J2]`, etc. in parallel mode.
- **`FastScan => 1` ExifTool option**: stops metadata scanning after the first block,
  giving a 2-3× speedup with no loss of capture-date accuracy (DateTimeOriginal is
  always in the primary metadata block).
- **Size-bucketed deduplication**: `--dedup` now groups files by byte-count first (free
  `stat` call) and SHA256-checksums only size-matched groups. On typical photo libraries
  where < 10% of files share a size, this avoids ~90% of checksum I/O.

### Fixed
- **`MAX_SANE` too tight**: the 1-day upper bound (`time() + 86_400`) caused false
  "⚠️ All dates outside sane range" warnings for valid 2024/2025 files when the
  system clock lagged slightly or camera clocks were marginally ahead. Extended to
  5 years (`time() + 5 * 365 * 86_400`).
- **"Cannot open: No such file or directory" counted as failure**: files that no longer
  exist at their collected path (e.g. renamed by a previous interrupted run) were
  logged as `❌ Read error` and incremented the failure counter. They are now detected
  before the magic-number read, logged as `⚠️ File no longer exists — skipping`, and
  counted as `Skipped` instead of `Failed`.

---

## [1.1.1] - 2026-03-30
### Fixed
- **Pre-flight exiftool check**: script now exits immediately with a clear message if
  `exiftool` is not on PATH. Previously it ran to completion but silently failed
  metadata reads and writes on every file (errors were swallowed by `catch {}`).
- **Division by zero on empty folder**: added an early exit with a warning when no
  supported media files are found, preventing `$index / $totalFiles` from throwing.
- **File stream handle leak**: the `OpenRead()` stream was only closed on the happy
  path. If `Read()` threw an exception the handle was never released. Moved disposal
  into a `finally` block so it always runs.
- **QuickTime MOV files misdetected as MP4**: `Get-TrueExtension` trimmed the ISO
  brand string then compared against `'qt  '` (untrimmed). After `.Trim()` the brand
  is `'qt'`, so the case never matched and QuickTime files fell through to `default`
  (`.mp4`). Fixed the switch case to `'qt'`.
- **exiftool exit code not checked**: `& exiftool ... 2>&1 | Out-Null` discarded both
  output and the exit code. Write failures were counted as successes. Now checks
  `$LASTEXITCODE -ne 0` and throws so the failure is caught and logged.
- **Null `$fileInfo` in outer catch**: if an exception occurred before the
  `[System.IO.FileInfo]` assignment, the outer catch block itself threw a
  `NullReferenceException` accessing `.Name`. Falls back to `Split-Path` on the raw
  path.
- **`ConvertTo-LongPath` wildcard bug**: `-like '\\?\\*'` used `?` as a
  single-character wildcard, matching paths like `\\X\anything`. Changed to
  `.StartsWith('\\?\')` for a literal prefix check.
- **`CreationTime`/`LastWriteTime` assignment unprotected**: direct property
  assignment threw unhandled `UnauthorizedAccessException` on read-only files. Both
  assignments are now wrapped in try/catch with per-file error logging.
- **Rename suffix exhaustion silent**: when the `.001`–`.999` suffix loop was
  exhausted the file was silently skipped with no log entry and no failure counter
  increment. Now logs the failure and increments the Failed counter.
- **Mutex never disposed**: the OS-level `Mutex` object was never released after the
  parallel block finished. Added `$progressLock.Dispose()` after `ForEach-Object`.
- **Date sanity bounds**: corrupt or camera-bug EXIF dates (year `0001`, `9999`, etc.)
  could become the canonical "oldest" date and produce nonsensical filenames. Dates
  before 1970-01-01 or after tomorrow are now excluded from selection, with a fallback
  to the raw oldest and a visible warning in the progress output.

---

## [1.1.0] - 2026-03-30
### Fixed
- **Bug 1+2 — `Get-TrueExtension` always returned `$null`**: `switch -regex ($bytes)` on
  a `[byte[]]` causes PowerShell to iterate individual byte elements, so `$_` inside each
  case was a single scalar value, not the array. All magic-number comparisons silently
  failed and signature validation was effectively disabled. Rewrote the function using
  `if/elseif` chains that operate directly on the array.
- **Bug 2 (follow-on) — ftyp/WEBP byte decoding**: The original `$_[4..7] -join ''`
  joined bytes as decimal integer strings (e.g. `"102116121112"`) instead of ASCII text,
  so the `ftyp` and `WEBP` format checks never matched. Both now use
  `[Text.Encoding]::ASCII.GetString()` for correct decoding.
- **Bug 5 — Stale `$fileInfo` after signature rename**: After a successful
  `Rename-Item` in the signature-mismatch block, `$fileInfo` and `$normalPath` still
  referenced the old (now-deleted) path. All subsequent timestamp reads, metadata
  writes, and the final rename silently operated on a non-existent file. Both
  variables are now refreshed immediately after the rename succeeds.
- **Bug 6 — Provenance "EXIF-only" and "QuickTime-only" branches unreachable**:
  The original conditions required `-not $dateCreated -and -not $dateModified`, but
  those variables are always populated from the filesystem and are never null. Every
  file with embedded EXIF or QuickTime metadata incorrectly fell into "Mixed-sources".
  Classification now depends solely on which rich metadata sources were extracted.
- **Bug 8 — Shell.Application COM in parallel threads**: `Shell.Application` is
  STA-threaded; `ForEach-Object -Parallel` runs on MTA thread-pool workers, causing
  COM apartment mismatch errors. Removed the COM fallback for reading DateTaken
  (covered by the broadened exiftool call below) and replaced the COM write with
  `exiftool -overwrite_original`, which is already a hard dependency and has no
  path-length restriction.

### Changed
- Removed `EXIF:` group prefix from the `exiftool -DateTimeOriginal` call so that XMP
  and other non-EXIF embedded date fields are also found without a second pass.
- Replaced the `Test-Path` + `Move-Item` collision-avoidance loop with a `try/catch`
  retry loop: `Test-Path` is not atomic and two parallel threads could both pass the
  check before either rename completes. Catching `IOException` and incrementing the
  suffix counter is race-safe.
- Removed unused `$VerboseFlag` and `$TotalCount` variables.
- Wrapped `Write-Host` summary-header string concatenation in parentheses to ensure
  the newline and separator string are joined before being passed as a single argument.

---

## [1.0.0] - 2025-07-24
### Added
- Initial release of `media-audit.ps1`
- Validates file signatures and corrects extensions
- Extracts and repairs EXIF/QuickTime/NTFS timestamps
- Renames files using canonical timestamp
- Provenance tagging and reporting
- Dry run mode for safe simulation
- Comprehensive progress and summary output

---

<!--
Add new release notes above this line. Use the following template for future entries:

## [x.y.z] - YYYY-MM-DD
### Added
- ...

### Changed
- ...

### Fixed
- ...
-->