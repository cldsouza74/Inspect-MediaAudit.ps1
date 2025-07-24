## Author

Clive DSouza  
Email: cldsouza74 [at] gmail [dot] com

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Requires ExifTool](https://img.shields.io/badge/Requires-ExifTool-green)](https://exiftool.org/)

# Inspect-MediaAudit.ps1

A high-performance, parallelized PowerShell 7+ script for bulk auditing, repair, and normalization of media file metadata and filenames.  
It validates media signatures, extracts/corrects timestamps, writes metadata, and renames files using a canonical timestamp.

---

## Features

- **Signature validation:** Checks if file extensions match actual content ("magic number").
- **Metadata extraction:** Reads dates from EXIF (images), QuickTime (videos), and NTFS (fallback).
- **Timestamp correction:** Sets DateTaken, CreationTime, and LastWriteTime to oldest valid timestamp.
- **Automatic renaming:** Renames files to `yyyyMMdd_HHmmss.ext` based on timestamp, avoiding collisions.
- **Provenance tagging:** Classifies metadata source (EXIF-only, QuickTime-only, Fallback, Mixed, Unknown).
- **Dry run mode:** Safely simulates all changes before applying.
- **Comprehensive reporting:** Color-coded progress and detailed summary.

---
## When to use this script?

Use **Inspect-MediaAudit.ps1** when you need to:

- Audit and repair large libraries of photos and videos.
- Correct file extensions that don’t match the actual file content.
- Normalize inconsistent or missing metadata (date taken, creation time, etc.).
- Rename files based on canonical timestamps for easier sorting and deduplication.
- Prepare media collections for backup, archive, or sharing with accurate metadata.

This script is ideal for photographers, archivists, IT professionals, or anyone who manages large or messy media folders.

---

## Requirements

- **Windows** (PowerShell script uses Windows-specific features)
- **PowerShell 7.0 or higher**  
  [Download PowerShell 7+](https://github.com/PowerShell/PowerShell/releases)
- **ExifTool** (for accurate metadata extraction)  
  [Download ExifTool](https://exiftool.org/)

  > **Make sure `exiftool` is available in your system PATH**  
  > (Test by running `exiftool -ver` in a PowerShell window.)

---

## Usage

```powershell
# Simulate changes (Dry Run) for all media files under D:\Pictures, recursively:
.\Inspect-MediaAudit.ps1 -Path "D:\Pictures" -DryRun -Recurse

# Actually fix (write metadata/rename) media files in C:\MediaLibrary (non-recursive):
.\Inspect-MediaAudit.ps1 -Path "C:\MediaLibrary"
```

### Parameters

- `-Path` (Required): Root folder containing media files.
- `-DryRun` (Optional): Preview actions without making changes.
- `-Recurse` (Optional): Scan subdirectories recursively.

### Supported Formats

- **Images:** .jpg, .jpeg, .png, .gif, .bmp, .tif, .tiff, .heic, .webp, .jfif, .nef, .cr2, .dng, .crw
- **Videos:** .mov, .mp4, .avi, .mkv, .wmv, .qt, .mpg

---

## Notes & Recommendations

- **Always use `-DryRun` first** to preview changes—no files will be modified.
- **Backup your media** before running bulk metadata fixes.
- **ExifTool is essential** for reading and updating metadata.  
  Without it, some features (especially for videos) will not work.
- **NTFS/Windows-only:** Uses Windows Shell COM for some metadata operations.

---

## Example

```powershell
# Safe simulation:
.\Inspect-MediaAudit.ps1 -Path "D:\Photos" -DryRun -Recurse

# Apply changes:
.\Inspect-MediaAudit.ps1 -Path "D:\Photos" -Recurse
```

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## New to GitHub?

1. [Create a new repository](https://github.com/new) (give it a name and description).
2. Upload your `Inspect-MediaAudit.ps1`, `README.md`, and `LICENSE` files.
3. Click "Commit changes" to save.
4. Optionally add tags like `PowerShell`, `metadata`, `exiftool`, `media-library`.

Need more help? Just ask!
