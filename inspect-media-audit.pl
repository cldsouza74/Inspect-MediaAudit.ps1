#!/usr/bin/env perl
# inspect-media-audit.pl — v1.0.0
# Copyright © 2025-2026 Clive DSouza
# SPDX-License-Identifier: MIT
#
# Perl port of Inspect-MediaAudit.ps1
# Uses Image::ExifTool directly (no subprocess) for significantly faster processing.
#
# REQUIREMENTS
#   Image::ExifTool  — cpan install Image::ExifTool
#                      or: apt install libimage-exiftool-perl
#   Win32::API       — Windows native only, for CreationTime (birthtime) support
#                      cpan install Win32::API
#                      Not needed on Linux/WSL (birthtime is not settable there)
#
# USAGE
#   perl inspect-media-audit.pl --path /path/to/photos [--dry-run] [--recurse]
#
# PLATFORM NOTES
#   Windows native Perl : full functionality including CreationTime correction
#   WSL / Linux         : all features except CreationTime (no Win32 API available)
#                         mtime (LastWriteTime) is still corrected via utime()

use strict;
use warnings;
use 5.016;

use Getopt::Long qw(GetOptions :config no_ignore_case);
use File::Find   qw(find);
use File::Basename qw(basename dirname fileparse);
use File::Spec;
use File::Copy   qw(copy);
use File::Temp   qw(tempfile);
use POSIX        qw(strftime);
use Time::Local  qw(timelocal timegm);
use Encode       qw(encode);

# ─── Image::ExifTool (required) ──────────────────────────────────────────────
eval { require Image::ExifTool; 1 }
    or die "❌ Image::ExifTool not found.\n"
         . "   Install with: cpan Image::ExifTool\n"
         . "   or: apt install libimage-exiftool-perl\n";

# ─── Win32 CreationTime support (Windows native only) ────────────────────────
#
# Perl's utime() sets atime and mtime but cannot set the Windows birthtime
# (CreationTime / lpCreationTime in NTFS). To do that we must call the Win32
# SetFileTime API directly. The sequence is:
#
#   1. CreateFileW  — open a handle with GENERIC_WRITE on the existing file
#   2. SetFileTime  — pass a FILETIME struct for creation time; NULL for the
#                     other two timestamps so they are left unchanged
#   3. CloseHandle  — release the handle
#
# FILETIME encoding:
#   A FILETIME is two 32-bit little-endian DWORDs (low, high) representing
#   100-nanosecond intervals since 1601-01-01 00:00:00 UTC.
#   Unix epoch offset = 11,644,473,600 seconds = 116,444,736,000,000,000 × 100 ns.
#   FILETIME = (unix_time + 11_644_473_600) × 10_000_000
#
# Win32::API 'P' parameter type passes a pointer to a Perl string buffer —
# we pack the 8-byte FILETIME struct into a string and pass it by reference.
# CreateFileW takes a LPCWSTR; we encode the path as UTF-16LE manually.
#
# This block is skipped entirely on Linux/WSL — no warning, no crash.
# ─────────────────────────────────────────────────────────────────────────────
my $HAS_WIN32 = 0;
my ($fn_CreateFileW, $fn_SetFileTime, $fn_CloseHandle);

if ($^O eq 'MSWin32') {
    eval {
        require Win32::API;
        # CreateFileW(LPCWSTR, DWORD, DWORD, LPSECURITY, DWORD, DWORD, HANDLE) → HANDLE
        $fn_CreateFileW = Win32::API->new('kernel32', 'CreateFileW', 'PNNNNNN', 'N')
            or die "CreateFileW load failed: $^E";
        # SetFileTime(HANDLE, FILETIME*, FILETIME*, FILETIME*) → BOOL
        $fn_SetFileTime = Win32::API->new('kernel32', 'SetFileTime',  'NPPP',   'I')
            or die "SetFileTime load failed: $^E";
        # CloseHandle(HANDLE) → BOOL
        $fn_CloseHandle = Win32::API->new('kernel32', 'CloseHandle',  'N',      'I')
            or die "CloseHandle load failed: $^E";
        $HAS_WIN32 = 1;
    };
    if ($@) {
        warn "⚠️  Win32::API unavailable — CreationTime will not be set.\n";
        warn "   Install with: cpan Win32::API\n";
    }
}

# ─── ANSI colour helpers ─────────────────────────────────────────────────────
# Windows cmd.exe does not process ANSI sequences by default; pwsh and Windows
# Terminal do. On Linux/WSL they always work. Safe to emit unconditionally.
sub _red    { "\e[31m$_[0]\e[0m" }
sub _green  { "\e[32m$_[0]\e[0m" }
sub _yellow { "\e[33m$_[0]\e[0m" }
sub _cyan   { "\e[36m$_[0]\e[0m" }
sub _gray   { "\e[90m$_[0]\e[0m" }

# ─── Supported extensions ────────────────────────────────────────────────────
my %VALID_EXT = map { $_ => 1 } qw(
    .jpg .jpeg .png .gif .bmp .tif .tiff .heic .webp .jfif
    .mov .mp4 .avi .mkv .wmv .qt .mpg
    .nef .cr2 .dng .crw
);

# Video extensions trigger QuickTime:CreateDate extraction instead of EXIF DateTimeOriginal
my %VIDEO_EXT = map { $_ => 1 } qw(.mov .mp4 .avi .mkv .wmv .qt .mpg);

# ─── Argument parsing ────────────────────────────────────────────────────────
my ($opt_path, $opt_dry_run, $opt_recurse, $opt_help);
GetOptions(
    'path=s'   => \$opt_path,
    'dry-run'  => \$opt_dry_run,
    'recurse'  => \$opt_recurse,
    'help'     => \$opt_help,
) or die "Usage: $0 --path <dir> [--dry-run] [--recurse]\n";

if ($opt_help) {
    print <<'USAGE';
inspect-media-audit.pl — media signature check, timestamp repair, and rename

USAGE:
  perl inspect-media-audit.pl --path <dir> [--dry-run] [--recurse]

OPTIONS:
  --path <dir>   Root folder containing media files (required)
  --dry-run      Preview all actions without writing or renaming any files
  --recurse      Scan all subdirectories recursively

SUPPORTED FORMATS:
  Images : .jpg .jpeg .png .gif .bmp .tif .tiff .heic .webp .jfif
  Raw    : .nef .cr2 .dng .crw
  Video  : .mov .mp4 .avi .mkv .wmv .qt .mpg

REQUIREMENTS:
  Image::ExifTool  (required)  cpan install Image::ExifTool
  Win32::API       (optional)  cpan install Win32::API  [Windows only]
USAGE
    exit 0;
}

# Accept path as a positional argument if --path was not given
$opt_path //= $ARGV[0];
die "Usage: $0 --path <dir> [--dry-run] [--recurse]\n" unless defined $opt_path;
die "❌ Path not found: $opt_path\n" unless -d $opt_path;

# ─── File collection ─────────────────────────────────────────────────────────
my @files_to_process;
my $total_count = 0;

if ($opt_recurse) {
    find(sub {
        return unless -f $_;
        $total_count++;
        my ($ext) = /(\.[^.]+)$/;
        push @files_to_process, $File::Find::name
            if defined $ext && $VALID_EXT{lc $ext};
    }, $opt_path);
} else {
    opendir my $dh, $opt_path or die "Cannot open directory: $!\n";
    while (my $entry = readdir $dh) {
        next if $entry =~ /^\./;
        my $full = File::Spec->catfile($opt_path, $entry);
        next unless -f $full;
        $total_count++;
        my ($ext) = $entry =~ /(\.[^.]+)$/;
        push @files_to_process, $full
            if defined $ext && $VALID_EXT{lc $ext};
    }
    closedir $dh;
}

my $filtered_count = scalar @files_to_process;

print _cyan("\n📂 Scanning '$opt_path'" . ($opt_recurse ? ' (recursive)' : '') . "\n");

if ($filtered_count == 0) {
    print _yellow("⚠️  No supported media files found in '$opt_path'. Nothing to do.\n");
    exit 0;
}

if ($opt_dry_run) {
    print _yellow("DRY RUN: Simulating for $filtered_count/$total_count files...\n");
} else {
    print _cyan("🔧 Processing $filtered_count/$total_count files...\n");
}

# ─── Shared counters ─────────────────────────────────────────────────────────
my %C = map { $_ => 0 } qw(
    Processed  DateTakenSet  DateModifiedSet  BirthTimeSet
    SignatureMismatch  SignatureRenamed  Skipped  Failed
    Renamed  WithCounter
    EXIF-only  QuickTime-only  Fallback-only  Mixed-sources  Unknown
);

# Progress: always print first 10 files, then every ~1% (min 1, capped at 100)
my $report_every = $filtered_count <= 10 ? 1
                 : $filtered_count <= 1000 ? int($filtered_count * 0.01) || 1
                 : 100;

# ─── ExifTool instance — reused across all files ──────────────────────────────
# One instance is far cheaper than spawning a subprocess per file.
# QuickTimeUTC: treat QT timestamps as UTC and convert to local on read.
# This matches the PS script's '-api QuickTimeUTC' subprocess flag.
my $et = Image::ExifTool->new();
$et->Options(QuickTimeUTC => 1);

# ─── Sanity bounds for date selection ────────────────────────────────────────
# Lower bound: 1970-01-01 — no consumer camera existed before this.
# Upper bound: tomorrow — guards against cameras with clocks set to the future.
# Corrupt EXIF data can produce year 0001 or 9999; these are excluded so they
# don't become the canonical "oldest" and produce filenames like 00010101_000000.jpg.
my $MIN_SANE = timelocal(0, 0, 0, 1, 0, 70);   # 1970-01-01 00:00:00 local
my $MAX_SANE = time() + 86_400;                  # now + 1 day

# ─── Main processing loop ─────────────────────────────────────────────────────
my $start_time = time();
my $file_index = 0;

for my $filepath (@files_to_process) {
    $file_index++;
    $C{Processed}++;

    my $pct      = sprintf('%5.1f', ($file_index / $filtered_count) * 100);
    my $filename = basename($filepath);
    my $dir      = dirname($filepath);
    my @actions;
    my $failed = 0;

    # ── STEP 1: Magic number / signature check ────────────────────────────
    # Read the first 12 bytes of the file and compare against known format
    # signatures. This catches files with wrong extensions — e.g. a JPEG saved
    # as .mov, or a QuickTime file labelled .mp4 — regardless of the filename.
    my $true_ext = eval { _detect_true_ext($filepath) };
    if ($@) {
        push @actions, "❌ Read error: " . ($@ =~ s/\n/ /gr);
        $failed = 1;
        $C{Failed}++;
    } else {
        my (undef, undef, $cur_ext) = fileparse($filename, qr/\.[^.]*/);
        if (defined $true_ext && lc($cur_ext) ne $true_ext) {
            $C{SignatureMismatch}++;
            my ($stem) = $filename =~ /^(.+)\.[^.]+$/;
            my $new_name = $stem . $true_ext;
            my $new_path = File::Spec->catfile($dir, $new_name);
            if ($opt_dry_run) {
                push @actions, "🔍 Signature mismatch → Would rename to $new_name";
            } else {
                if (rename $filepath, $new_path) {
                    push @actions, "✅ Extension corrected: $filename → $new_name";
                    $C{SignatureRenamed}++;
                    # Refresh both variables — subsequent steps operate on the new path.
                    # (Mirrors the PS script Bug 5 fix: stale $fileInfo after rename.)
                    $filepath = $new_path;
                    $filename = $new_name;
                } else {
                    push @actions, "❌ Extension rename failed: $!";
                    $failed = 1;
                    $C{Failed}++;
                }
            }
        }
    }

    # Re-derive extension after any rename
    my (undef, undef, $ext) = fileparse($filename, qr/\.[^.]*/);
    my $is_video = exists $VIDEO_EXT{lc $ext};

    # ── STEP 2: Timestamp extraction (tiered) ────────────────────────────
    #
    # Tier 1a — EXIF/XMP DateTimeOriginal (images)
    #   Image::ExifTool searches all metadata groups without a group prefix,
    #   so XMP:DateTimeOriginal and IPTC dates are also found automatically.
    #   This matches the PS script's removal of the 'EXIF:' group restriction.
    #
    # Tier 1b — QuickTime:CreateDate (videos)
    #   QuickTimeUTC option (set globally) interprets the raw QT timestamp as
    #   UTC and converts to local time, matching '-api QuickTimeUTC' in the PS
    #   script. The spec mandates UTC but many cameras write local time instead;
    #   the option is the best-effort standard interpretation.
    #
    # Tier 2 — Filesystem mtime (LastWriteTime) — always available as fallback.
    #   Note: stat()[9] = mtime on both Linux and Windows Perl.
    #         stat()[10] = inode-change-time on Linux; CreationTime on Windows Perl.
    #   We only use mtime here; CreationTime is handled separately below.
    #
    $et->ExtractInfo($filepath);   # reads all metadata once; cached for GetValue calls

    my ($date_taken, $media_created);  # Unix timestamps (undef if not found)

    if ($is_video) {
        my $raw = $et->GetValue('CreateDate', 'PrintConv');
        $media_created = _parse_exif_date($raw) if defined $raw;
    } else {
        my $raw = $et->GetValue('DateTimeOriginal', 'PrintConv');
        $date_taken = _parse_exif_date($raw) if defined $raw;
    }

    my $fs_mtime = (stat $filepath)[9];   # LastWriteTime (always defined for real files)

    # ── STEP 3: Date sanity filter + oldest-date selection ────────────────
    my @candidates = grep { defined $_ } ($date_taken, $media_created, $fs_mtime);
    my @sane       = grep { $_ >= $MIN_SANE && $_ <= $MAX_SANE } @candidates;
    my $oldest;

    if (@sane) {
        $oldest = (sort { $a <=> $b } @sane)[0];
    } elsif (@candidates) {
        # All dates are outside the sane range — fall back to raw oldest and warn.
        $oldest = (sort { $a <=> $b } @candidates)[0];
        push @actions, "⚠️  All dates outside sane range — using raw oldest: "
            . strftime('%Y-%m-%d', localtime($oldest));
    }

    unless (defined $oldest) {
        push @actions, "❌ No valid date found — skipping";
        $C{Skipped}++;
        _print_line($pct, $file_index, $filtered_count, \@actions, $filename, 0);
        next;
    }

    # ── STEP 4: Provenance classification ────────────────────────────────
    # Classification is based solely on which embedded metadata sources were
    # found — filesystem dates are always present and are not counted as
    # "rich" metadata. (Matches the PS script Bug 6 fix.)
    my $provenance =
          ($date_taken && $media_created) ? 'Mixed-sources'
        : $date_taken                     ? 'EXIF-only'
        : $media_created                  ? 'QuickTime-only'
        : $fs_mtime                       ? 'Fallback-only'
        :                                   'Unknown';
    $C{$provenance}++;
    push @actions, "[Source] Provenance → $provenance";

    # ── STEP 5: Write DateTimeOriginal for images that lack it ────────────
    # Only images (not videos), and only when no DateTimeOriginal was found.
    # Image::ExifTool writes directly to a temp file then replaces the original,
    # so no external process is spawned and no '_original' backup is created.
    if (!$is_video && !$date_taken) {
        my $exif_date = strftime('%Y:%m:%d %H:%M:%S', localtime($oldest));
        if ($opt_dry_run) {
            push @actions, "Would set DateTaken to " . strftime('%Y-%m-%d', localtime($oldest));
        } else {
            $et->SetNewValue('DateTimeOriginal', $exif_date);
            $et->SetNewValue('CreateDate',       $exif_date);

            # Write to a temp file in the same directory (atomic rename on same FS).
            # Specifying an explicit destination prevents ExifTool from creating an
            # '_original' backup, replicating the PS script's -overwrite_original flag.
            my (undef, $tmp_path) = tempfile(
                'audit_XXXXXX', DIR => $dir, SUFFIX => '.tmp', UNLINK => 0
            );
            my $result = $et->WriteInfo($filepath, $tmp_path);

            if ($result == 1) {
                # Replace original. rename() is atomic on same filesystem.
                # On Windows, rename over an existing file may fail — fall back to copy+delete.
                unless (rename $tmp_path, $filepath) {
                    if (copy($tmp_path, $filepath)) { unlink $tmp_path }
                    else {
                        unlink $tmp_path;
                        push @actions, "❌ Failed to replace file after metadata write: $!";
                        $failed = 1;
                        $C{Failed}++;
                    }
                }
                unless ($failed) {
                    push @actions, "Fixed DateTaken to " . strftime('%Y-%m-%d', localtime($oldest));
                    $C{DateTakenSet}++;
                }
            } else {
                unlink $tmp_path if -e $tmp_path;
                my $err = $et->GetValue('Error') // 'unknown error';
                push @actions, "❌ Failed to set DateTaken: $err";
                $failed = 1;
                $C{Failed}++;
            }

            # Clear pending write values so they don't bleed into the next file
            $et->SetNewValue();
        }
    }

    # ── STEP 6: Correct filesystem mtime (LastWriteTime) ─────────────────
    # utime(atime, mtime, file) — we set both atime and mtime to $oldest.
    # This is the only timestamp utime can set; CreationTime requires Win32 API.
    if ($fs_mtime != $oldest) {
        if ($opt_dry_run) {
            push @actions, "Would fix LastWriteTime to " . strftime('%Y-%m-%d', localtime($oldest));
        } else {
            if (utime($oldest, $oldest, $filepath)) {
                push @actions, "Fixed LastWriteTime to " . strftime('%Y-%m-%d', localtime($oldest));
                $C{DateModifiedSet}++;
            } else {
                push @actions, "❌ Failed to set LastWriteTime: $!";
                $failed = 1;
            }
        }
    }

    # ── STEP 7: Correct CreationTime (birthtime) via Win32 API ───────────
    # Available on Windows native Perl only. Skipped silently on Linux/WSL
    # because the Linux kernel does not expose a birthtime-setting syscall.
    #
    # On Windows Perl, stat()[10] maps to the C runtime's st_ctime which
    # corresponds to the NTFS CreationTime (not inode-change-time as on Linux).
    # We compare it to $oldest to decide whether a correction is needed.
    if ($^O eq 'MSWin32') {
        my $fs_ctime = (stat $filepath)[10];
        if (defined $fs_ctime && $fs_ctime != $oldest) {
            if ($opt_dry_run) {
                push @actions, "Would fix CreationTime to " . strftime('%Y-%m-%d', localtime($oldest));
            } else {
                my ($ok, $err) = _set_win32_birthtime($filepath, $oldest);
                if ($ok) {
                    push @actions, "Fixed CreationTime to " . strftime('%Y-%m-%d', localtime($oldest));
                    $C{BirthTimeSet}++;
                } else {
                    push @actions, "❌ Failed to set CreationTime: $err";
                    $failed = 1;
                }
            }
        }
    }

    # ── STEP 8: Timestamp-based rename ───────────────────────────────────
    # Target: yyyyMMdd_HHmmss.ext — same format as the PS script.
    # Collision handling: check existence before attempting rename; retry with
    # .001/.002/... suffix up to .999. If all suffixes are exhausted, log failure.
    # Using -e check + rename is safe here because we are single-threaded.
    my $new_base = strftime('%Y%m%d_%H%M%S', localtime($oldest));
    my $new_name = $new_base . lc($ext);

    if ($filename ne $new_name) {
        if ($opt_dry_run) {
            push @actions, "Would rename → $filename → $new_name";
        } else {
            my ($moved, $suffix) = (0, 0);
            while (!$moved && $suffix <= 999) {
                my $candidate = $suffix == 0
                    ? $new_name
                    : $new_base . sprintf('.%03d', $suffix) . lc($ext);
                my $dest = File::Spec->catfile($dir, $candidate);

                if (-e $dest) {
                    # Collision — try next suffix
                    $suffix++;
                    next;
                }

                if (rename $filepath, $dest) {
                    push @actions, "Renamed → $filename → $candidate";
                    $C{Renamed}++;
                    $C{WithCounter}++ if $suffix > 0;
                    $moved = 1;
                } else {
                    # rename failed for a reason other than collision
                    push @actions, "❌ Rename failed: $!";
                    $failed = 1;
                    $C{Failed}++;
                    last;
                }
            }

            if (!$moved && !$failed) {
                # Suffix space exhausted — same as PS script's elseif ($count -gt 999) branch
                push @actions, "❌ Rename failed: no unique name available after 999 attempts";
                $failed = 1;
                $C{Failed}++;
            }
        }
    }

    # ── STEP 9: Progress output ───────────────────────────────────────────
    _print_line($pct, $file_index, $filtered_count, \@actions, $filename, $failed)
        if $file_index <= 10 || $file_index % $report_every == 0;
}

# ─── Summary ─────────────────────────────────────────────────────────────────
my $elapsed = time() - $start_time;
my $elapsed_str = sprintf('%02d:%02d:%02d',
    int($elapsed / 3600), int(($elapsed % 3600) / 60), $elapsed % 60);

print _cyan("\n" . ('═' x 50) . "\n");
printf "%-32s: %s\n", 'Total files scanned',        $total_count;
printf "%-32s: %s\n", 'Files matching extensions',  $filtered_count;
print  _yellow("DRY RUN — no changes applied\n") if $opt_dry_run;
printf "%-32s: %s\n", 'Processing time',             $elapsed_str unless $opt_dry_run;
printf "%-32s: %s\n", 'DateTaken metadata set',      $C{DateTakenSet};
printf "%-32s: %s\n", 'LastWriteTime adjusted',      $C{DateModifiedSet};
printf "%-32s: %s\n", 'CreationTime adjusted',       $C{BirthTimeSet};
printf "%-32s: %s\n", 'Files renamed by timestamp',  $C{Renamed};
printf "%-32s: %s\n", 'Timestamp rename w/ suffix',  $C{WithCounter};
printf "%-32s: %s\n", 'Signature mismatches',        $C{SignatureMismatch};
printf "%-32s: %s\n", 'Signature-based renames',     $C{SignatureRenamed};
printf "%-32s: %s\n", 'Files skipped',               $C{Skipped};
printf "%-32s: %s\n", 'Failures',                    $C{Failed};
printf "%-32s: %s\n", 'EXIF-only sources',           $C{'EXIF-only'};
printf "%-32s: %s\n", 'QuickTime-only sources',      $C{'QuickTime-only'};
printf "%-32s: %s\n", 'Fallback-only sources',       $C{'Fallback-only'};
printf "%-32s: %s\n", 'Mixed-source files',          $C{'Mixed-sources'};
printf "%-32s: %s\n", 'Unknown provenance',          $C{Unknown};
print  _cyan('═' x 50 . "\n");

# ─── Subroutines ─────────────────────────────────────────────────────────────

# detect_true_ext: read first 12 bytes and identify the actual file format.
# Returns the correct extension string (e.g. '.jpg') or undef if unknown.
# The same magic-number logic as the PowerShell version, now without the
# switch-on-array bug or the decimal-join encoding bug.
sub _detect_true_ext {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot open: $!\n";
    my $buf = '';
    read $fh, $buf, 12;
    close $fh;
    return undef if length($buf) < 2;

    # JPEG: FF D8
    return '.jpg'  if substr($buf,0,2) eq "\xFF\xD8";
    # PNG:  89 50 4E 47
    return '.png'  if substr($buf,0,2) eq "\x89\x50";
    # GIF:  47 49 46 38
    return '.gif'  if substr($buf,0,2) eq "\x47\x49";
    # TIFF: 49 49 (LE) or 4D 4D (BE)
    return '.tif'  if substr($buf,0,2) eq "\x49\x49" || substr($buf,0,2) eq "\x4D\x4D";

    if (length($buf) >= 12) {
        # ISO Base Media container (MP4 / MOV / HEIC): 'ftyp' at bytes 4–7.
        # Brand at bytes 8–11 identifies the specific sub-format.
        # Brand is 4 bytes, right-padded with spaces (e.g. 'qt  ') — trim before comparing.
        if (substr($buf,4,4) eq 'ftyp') {
            my $brand = substr($buf,8,4);
            $brand =~ s/\s+$//;
            return '.heic' if $brand =~ /^(heic|mif1)$/;
            return '.mov'  if $brand eq 'qt';
            return '.mp4'  if $brand =~ /^(mp41|mp42|isom|avc1|M4V )$/;
            return '.mp4';  # unknown ISO brand — treat as MP4
        }
        # WebP: 'RIFF' at 0–3, 'WEBP' at 8–11
        return '.webp' if substr($buf,8,4) eq 'WEBP';
    }

    return undef;  # unknown format — leave extension as-is
}

# parse_exif_date: convert ExifTool date string → Unix timestamp (local time).
# ExifTool returns dates as 'YYYY:MM:DD HH:MM:SS' (possibly with timezone suffix).
# We parse with timelocal so the result is a standard Unix timestamp.
# Returns undef if the string is missing, malformed, or has an implausible year.
sub _parse_exif_date {
    my ($str) = @_;
    return undef unless defined $str && $str =~ /^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/;
    my ($Y, $M, $D, $h, $m, $s) = ($1,$2,$3,$4,$5,$6);
    return undef if $Y < 1970 || $Y > 9990;  # pre-screen wildly invalid years
    my $ts = eval { timelocal($s, $m, $h, $D, $M-1, $Y-1900) };
    return $@? undef : $ts;
}

# set_win32_birthtime: set the Windows NTFS CreationTime (birthtime) via Win32 API.
#
# Why not utime()? utime() maps to the C runtime's _utime() which sets atime and
# mtime only — there is no portable POSIX mechanism to set birthtime. On Windows
# we must call SetFileTime() via the Win32 API with an open file handle.
#
# FILETIME encoding (see header comment for derivation):
#   ft = (unix_time + 11_644_473_600) × 10_000_000  [100-ns intervals since 1601]
# Packed as two 32-bit little-endian unsigned integers (DWORD lo, DWORD hi).
# The 'use integer' pragma ensures arithmetic uses native 64-bit integers on a
# 64-bit Perl build, avoiding floating-point precision loss for large values.
#
# Returns: (1, '') on success, (0, error_message) on failure.
sub _set_win32_birthtime {
    my ($path, $unix_time) = @_;
    return (0, 'Win32::API not loaded') unless $HAS_WIN32;

    # Pack FILETIME as little-endian 64-bit (two DWORDs)
    my ($lo, $hi);
    {
        use integer;
        my $ft = ($unix_time + 11_644_473_600) * 10_000_000;
        $lo = $ft & 0xFFFF_FFFF;
        $hi = ($ft >> 32) & 0xFFFF_FFFF;
    }
    my $ft_bytes  = pack('VV', $lo, $hi);   # little-endian FILETIME struct
    my $null_time = "\x00" x 8;             # NULL FILETIME — leave this timestamp unchanged

    # CreateFileW requires a UTF-16LE wide string with a null terminator.
    # The Win32::API 'P' type passes a pointer to the string data.
    my $wide_path = encode('UTF-16LE', $path . "\x00");

    my $GENERIC_WRITE        = 0x4000_0000;
    my $FILE_SHARE_READ      = 0x0000_0001;
    my $FILE_SHARE_WRITE     = 0x0000_0002;
    my $OPEN_EXISTING        = 3;
    my $FILE_ATTRIBUTE_NORMAL = 0x0000_0080;
    my $INVALID_HANDLE       = 0xFFFF_FFFF;  # INVALID_HANDLE_VALUE as unsigned 32-bit

    my $handle = $fn_CreateFileW->Call(
        $wide_path,
        $GENERIC_WRITE,
        $FILE_SHARE_READ | $FILE_SHARE_WRITE,
        0,                      # lpSecurityAttributes = NULL (default)
        $OPEN_EXISTING,
        $FILE_ATTRIBUTE_NORMAL,
        0                       # hTemplateFile = NULL
    );

    return (0, "CreateFileW failed: $^E")
        if !defined $handle || $handle == $INVALID_HANDLE;

    # SetFileTime(handle, lpCreationTime, lpLastAccessTime, lpLastWriteTime)
    # Pass ft_bytes for creation time; null_time (NULL) for the others so they
    # are left unchanged — we already set mtime via utime() above.
    my $ok  = $fn_SetFileTime->Call($handle, $ft_bytes, $null_time, $null_time);
    my $err = $^E;
    $fn_CloseHandle->Call($handle);

    return $ok ? (1, '') : (0, "SetFileTime failed: $err");
}

# _print_line: emit a single colour-coded progress line.
# Red = failure, Gray = skipped, Green = normal.
sub _print_line {
    my ($pct, $idx, $total, $actions, $fname, $failed) = @_;
    my $line = "[$pct%] ($idx/$total) " . join('; ', @$actions) . " - $fname";
    my $skipped = grep { /Skipped/ } @$actions;
    if    ($failed)  { print _red($line)   . "\n" }
    elsif ($skipped) { print _gray($line)  . "\n" }
    else             { print _green($line) . "\n" }
}

__END__

=head1 NAME

inspect-media-audit.pl — Media signature check, timestamp repair, and rename

=head1 SYNOPSIS

  perl inspect-media-audit.pl --path /path/to/photos [--dry-run] [--recurse]

=head1 DESCRIPTION

For each media file in the given folder the script:

  1. Reads the first 12 bytes and checks the magic number against known signatures
     to detect extension mismatches (e.g. a JPEG saved as .mov).
  2. Renames the file to the correct extension if the signature doesn't match.
  3. Extracts capture timestamps via Image::ExifTool (no subprocess):
       - EXIF/XMP DateTimeOriginal for images
       - QuickTime:CreateDate (UTC-corrected) for videos
       - Filesystem mtime as fallback
  4. Filters out implausible dates (before 1970 or after tomorrow).
  5. Selects the oldest valid date as the canonical capture timestamp.
  6. Writes DateTimeOriginal back into the file for images that lack it.
  7. Sets filesystem mtime via utime().
  8. Sets NTFS CreationTime (birthtime) via Win32 API on Windows native Perl.
     Silently skipped on Linux/WSL where birthtime cannot be set.
  9. Renames the file to yyyyMMdd_HHmmss.ext. Collisions get a suffix: .001, .002…
  10. Tags provenance: EXIF-only, QuickTime-only, Fallback-only, Mixed-sources.

=head1 OPTIONS

=over

=item B<--path> I<dir>

Root folder containing media files. Required.

=item B<--dry-run>

Preview all actions without writing or renaming any files.

=item B<--recurse>

Scan all subdirectories recursively.

=back

=head1 REQUIREMENTS

  Image::ExifTool   cpan install Image::ExifTool
  Win32::API        cpan install Win32::API   [Windows only, optional]

=cut
