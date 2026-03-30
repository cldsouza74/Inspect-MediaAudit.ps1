# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),  
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Initial release of `Inspect-MediaAudit.ps1`
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