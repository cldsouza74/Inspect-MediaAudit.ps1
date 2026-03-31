#!/usr/bin/env perl
# inspect-media-audit.pl — v1.2.0
# Copyright © 2025-2026 Clive DSouza
# SPDX-License-Identifier: MIT
#
# Perl port of Inspect-MediaAudit.ps1
# Uses Image::ExifTool directly (no subprocess) for significantly faster processing.
#
# REQUIREMENTS
#   Image::ExifTool       — cpan install Image::ExifTool
#                           or: apt install libimage-exiftool-perl
#   Digest::SHA           — core Perl module (included since Perl 5.10)
#   Parallel::ForkManager — optional, enables --jobs N parallel processing
#                           cpan install Parallel::ForkManager
#   Win32::API            — Windows native only, for CreationTime (birthtime) support
#                           cpan install Win32::API
#                           Not needed on Linux/WSL (birthtime is not settable there)
#
# USAGE
#   perl inspect-media-audit.pl --path /path/to/photos [--dry-run] [--recurse] [--dedup] [--jobs N]
#
# PLATFORM NOTES
#   Windows native Perl : full functionality including CreationTime correction
#   WSL / Linux         : all features except CreationTime (no Win32 API available)
#                         mtime (LastWriteTime) is still corrected via utime()
#
# DEDUPLICATION NOTES
#   --dedup runs after all renaming is complete. Files are grouped by size first
#   (free stat call) — only files sharing a size are SHA256-checksummed (~90%
#   of checksumming avoided on typical photo libraries). Running after rename
#   means previously differently-named duplicates are normalized, making
#   collisions visible and ensuring checksums are on final corrected files.
#
#   Keeper selection within each duplicate group (best to worst priority):
#     1. Richest provenance: EXIF-only / QuickTime-only > Mixed-sources > Fallback-only
#     2. Shortest filename (no .001 suffix = arrived first in the rename loop)
#     3. Alphabetically first path (tiebreak)
#
#   --dedup --dry-run reports all duplicate groups without removing any files.
#   Always preview before applying.

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

# ─── Digest::SHA (core module — required for --dedup) ────────────────────────
# Digest::SHA ships with Perl 5.10+ and is available on all platforms.
eval { require Digest::SHA; 1 }
    or die "❌ Digest::SHA not found (should be a core Perl module).\n"
         . "   Try: cpan Digest::SHA\n";

# ─── Image::ExifTool (required) ──────────────────────────────────────────────
eval { require Image::ExifTool; 1 }
    or die "❌ Image::ExifTool not found.\n"
         . "   Install with: cpan Image::ExifTool\n"
         . "   or: apt install libimage-exiftool-perl\n";

# ─── Parallel::ForkManager (optional) ────────────────────────────────────────
# Enables --jobs N parallel processing. If not installed the script falls back
# to single-threaded mode with a one-time warning.
my $HAS_PARALLEL = 0;
eval { require Parallel::ForkManager; $HAS_PARALLEL = 1; };

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
# Passing 0 (not a string) for timestamps we don't want to change causes
# Win32::API to pass a NULL pointer, leaving those timestamps unchanged.
# (Passing "\x00" x 8 would be a pointer to a zero FILETIME = 1601-01-01,
# which would incorrectly reset LastAccessTime and LastWriteTime.)
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
# Terminal do. On Linux/WSL they always work.
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
my ($opt_path, $opt_dry_run, $opt_recurse, $opt_dedup, $opt_help);
my $opt_jobs = 1;
GetOptions(
    'path=s'   => \$opt_path,
    'dry-run'  => \$opt_dry_run,
    'recurse'  => \$opt_recurse,
    'dedup'    => \$opt_dedup,
    'jobs=i'   => \$opt_jobs,
    'help'     => \$opt_help,
) or die "Usage: $0 --path <dir> [--dry-run] [--recurse] [--dedup] [--jobs N]\n";

if ($opt_help) {
    print <<'USAGE';
inspect-media-audit.pl — media signature check, timestamp repair, rename, and deduplication

USAGE:
  perl inspect-media-audit.pl --path <dir> [--dry-run] [--recurse] [--dedup] [--jobs N]

OPTIONS:
  --path <dir>   Root folder containing media files (required)
  --dry-run      Preview all actions without writing, renaming, or deleting any files
  --recurse      Scan all subdirectories recursively
  --dedup        After processing, find and remove duplicate files by SHA256 checksum
  --jobs N       Number of parallel worker processes (default: 1 / single-threaded)
                 Requires Parallel::ForkManager: cpan Parallel::ForkManager

SUPPORTED FORMATS:
  Images : .jpg .jpeg .png .gif .bmp .tif .tiff .heic .webp .jfif
  Raw    : .nef .cr2 .dng .crw
  Video  : .mov .mp4 .avi .mkv .wmv .qt .mpg

REQUIREMENTS:
  Image::ExifTool        (required)  cpan install Image::ExifTool
  Parallel::ForkManager  (optional)  cpan install Parallel::ForkManager
  Win32::API             (optional)  cpan install Win32::API  [Windows only]
USAGE
    exit 0;
}

# Accept path as a positional argument if --path was not given
$opt_path //= $ARGV[0];
die "Usage: $0 --path <dir> [--dry-run] [--recurse]\n" unless defined $opt_path;
die "❌ Path not found: $opt_path\n" unless -d $opt_path;

# Clamp jobs to a valid range; warn and fall back if module is absent
$opt_jobs = 1 if $opt_jobs < 1;
if ($opt_jobs > 1 && !$HAS_PARALLEL) {
    warn "⚠️  Parallel::ForkManager not installed — falling back to single-threaded.\n";
    warn "   Install with: cpan Parallel::ForkManager\n";
    $opt_jobs = 1;
}

# ─── File collection ─────────────────────────────────────────────────────────
my @files_to_process;
my $total_count = 0;

if ($opt_recurse) {
    find(sub {
        return unless -f $_;
        return if /^\./;   # skip hidden files — consistent with non-recursive mode
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
    my $mode_str = $opt_jobs > 1 ? " using $opt_jobs parallel jobs" : '';
    print _cyan("🔧 Processing $filtered_count/$total_count files${mode_str}...\n");
}

# ─── Shared counters ─────────────────────────────────────────────────────────
my %C = map { $_ => 0 } qw(
    Processed  DateTakenSet  DateModifiedSet  BirthTimeSet
    SignatureMismatch  SignatureRenamed  Skipped  Failed
    Renamed  WithCounter
    EXIF-only  QuickTime-only  Fallback-only  Mixed-sources  Unknown
    DuplicateGroups  DuplicatesRemoved  BytesFreed
);

# Tracks final path + provenance for each successfully processed file.
# Populated during the main loop; consumed by the dedup phase.
my @processed_files;

# ─── Sanity bounds for date selection ────────────────────────────────────────
# Lower bound: 1970-01-01 — no consumer camera existed before this.
# Upper bound: 5 years ahead — the original 1-day limit caused false
# "outside sane range" warnings for valid 2024/2025 files when running on a
# system whose clock is slightly behind, or for files with minor future dates
# from cameras with slightly wrong clock settings.
my $MIN_SANE = timelocal(0, 0, 0, 1, 0, 70);        # 1970-01-01 00:00:00 local
my $MAX_SANE = time() + (5 * 365 * 86_400);           # now + 5 years

# ─── Main processing ─────────────────────────────────────────────────────────
my $start_time = time();

if ($opt_jobs > 1 && $HAS_PARALLEL) {
    # ── Parallel path ────────────────────────────────────────────────────────
    # Files are split into $opt_jobs roughly-equal chunks. Each child process
    # handles one chunk with its own Image::ExifTool instance (FastScan enabled).
    # Counters and the dedup-ready file list are returned via ForkManager's
    # finish() callback and merged into %C / @processed_files in the parent.
    #
    # Progress lines from workers interleave in the terminal — each print() is
    # an atomic write on Linux so no lines are split, but ordering reflects
    # arrival order rather than file order. Use --jobs 1 for ordered output.
    my @chunks = _split_chunks(\@files_to_process, $opt_jobs);
    my $pm = Parallel::ForkManager->new($opt_jobs);

    $pm->run_on_finish(sub {
        my ($pid, $exit_code, $ident, $signal, $core_dump, $data) = @_;
        return unless defined $data;
        $C{$_} += $data->{counts}{$_} // 0 for keys %C;
        push @processed_files, @{$data->{pfiles}};
    });

    my $job_num = 0;
    for my $chunk (@chunks) {
        $job_num++;
        my $pid = $pm->start and next;   # fork — parent skips to next chunk

        # === CHILD PROCESS — runs in a separate process after fork ===
        my %local_C  = map { $_ => 0 } keys %C;
        my @local_pfiles;
        my $local_et = Image::ExifTool->new();
        $local_et->Options(QuickTimeUTC => 1, FastScan => 1);

        my $chunk_size   = scalar @$chunk;
        my $report_every = $chunk_size <= 10   ? 1
                         : $chunk_size <= 1000 ? int($chunk_size * 0.01) || 1
                         :                       100;
        my $local_idx = 0;

        for my $filepath (@$chunk) {
            $local_idx++;
            my $pct = sprintf('%5.1f', ($local_idx / $chunk_size) * 100);

            my $result = _audit_file(
                $filepath, $local_et, $pct, $local_idx,
                $chunk_size, $report_every, $opt_dry_run, $job_num
            );

            $local_C{$_} += $result->{counts}{$_} // 0 for keys %local_C;

            push @local_pfiles, {
                path       => $result->{final_path},
                provenance => $result->{provenance},
            } if $opt_dedup && !$result->{failed}
               && defined $result->{provenance}
               && -e $result->{final_path};
        }

        $pm->finish(0, { counts => \%local_C, pfiles => \@local_pfiles });
        # Child exits here via ForkManager — no further code runs in the child
    }
    $pm->wait_all_children;

} else {
    # ── Sequential path ──────────────────────────────────────────────────────
    # FastScan => 1: ExifTool stops reading after the first metadata block.
    # Capture dates are always in the primary block — no information is lost.
    # This gives a 2-3x speedup on large libraries.
    my $et = Image::ExifTool->new();
    $et->Options(QuickTimeUTC => 1, FastScan => 1);

    my $report_every = $filtered_count <= 10   ? 1
                     : $filtered_count <= 1000 ? int($filtered_count * 0.01) || 1
                     :                           100;
    my $file_index = 0;

    for my $filepath (@files_to_process) {
        $file_index++;
        my $pct = sprintf('%5.1f', ($file_index / $filtered_count) * 100);

        my $result = _audit_file(
            $filepath, $et, $pct, $file_index,
            $filtered_count, $report_every, $opt_dry_run, 0
        );

        $C{$_} += $result->{counts}{$_} // 0 for keys %C;

        push @processed_files, {
            path       => $result->{final_path},
            provenance => $result->{provenance},
        } if $opt_dedup && !$result->{failed}
           && defined $result->{provenance}
           && -e $result->{final_path};
    }
}

# ─── STEP 10: Deduplication phase ────────────────────────────────────────────
#
# Runs only when --dedup is given. Groups files by size first (free stat),
# then SHA256-checksums only size-matched groups. On a typical photo library
# where < 10% of files share a size, this avoids ~90% of checksum I/O.
#
# Keeper selection within each duplicate group:
#   Priority 1 — provenance rank (lower = richer metadata source):
#     EXIF-only / QuickTime-only = 1  (embedded capture date found)
#     Mixed-sources              = 2  (both EXIF and QT found)
#     Fallback-only              = 3  (filesystem dates only)
#     Unknown                   = 4
#   Priority 2 — shortest filename (no .001/.002 suffix = arrived first)
#   Priority 3 — alphabetical path (stable tiebreak)
#
# In dry-run mode: prints groups and what WOULD be deleted; no files removed.
# ─────────────────────────────────────────────────────────────────────────────
if ($opt_dedup && @processed_files) {
    print _cyan("\n" . ('─' x 50) . "\n");
    print _cyan("🔍 Deduplication phase — ${\scalar @processed_files} files to check...\n");

    my %PROV_RANK = (
        'EXIF-only'      => 1,
        'QuickTime-only' => 1,
        'Mixed-sources'  => 2,
        'Fallback-only'  => 3,
        'Unknown'        => 4,
    );

    # Phase 1: group by file size — O(n) stat calls, no content I/O.
    # Only files that share an identical byte-count can possibly be duplicates.
    my %by_size;
    for my $f (@processed_files) {
        next unless -e $f->{path};
        my $size = -s $f->{path};
        next unless defined $size;
        push @{$by_size{$size}}, $f;
    }

    # Phase 2: checksum only size-matched groups.
    my $files_to_checksum = 0;
    my $size_groups        = 0;
    for my $size (keys %by_size) {
        if (@{$by_size{$size}} >= 2) {
            $files_to_checksum += scalar @{$by_size{$size}};
            $size_groups++;
        }
    }

    if ($files_to_checksum > 0) {
        print _cyan("  Size-bucketed: checksumming $files_to_checksum/${\scalar @processed_files} "
                  . "files ($size_groups size group(s) with collisions)...\n");
    } else {
        print _green("  ✅ No files share a size — no duplicates possible.\n");
    }

    my %by_hash;
    my $checked = 0;
    for my $size (keys %by_size) {
        my @same_size = @{$by_size{$size}};
        next if @same_size < 2;
        for my $f (@same_size) {
            $checked++;
            print "\r  Checksumming: $checked/$files_to_checksum   "
                if $files_to_checksum > 100
                && ($checked % 100 == 0 || $checked == $files_to_checksum);
            my $digest = _sha256_file($f->{path});
            next unless defined $digest;
            push @{$by_hash{$digest}}, $f;
        }
    }
    print "\n" if $files_to_checksum > 100;

    # Phase 3: process duplicate groups (2+ files with identical SHA256)
    my $groups_found = 0;
    for my $digest (sort keys %by_hash) {
        my @group = @{$by_hash{$digest}};
        next if @group < 2;
        $groups_found++;
        $C{DuplicateGroups}++;

        # Sort: best provenance first, then shortest name, then alpha path
        my @sorted = sort {
            ($PROV_RANK{ $a->{provenance} } // 99) <=> ($PROV_RANK{ $b->{provenance} } // 99)
            || length(basename($a->{path})) <=> length(basename($b->{path}))
            || $a->{path} cmp $b->{path}
        } @group;

        my $keeper       = shift @sorted;
        my $short_digest = substr($digest, 0, 16) . '…';

        print _cyan("\n  [DEDUP] Group (SHA256: $short_digest) — " . scalar(@sorted) . " duplicate(s)\n");
        print _green("    KEEP   → " . basename($keeper->{path}) . "  [$keeper->{provenance}]\n");

        for my $dup (@sorted) {
            my $size = -s $dup->{path} // 0;
            if ($opt_dry_run) {
                print _yellow("    WOULD DELETE → " . basename($dup->{path})
                    . "  [" . $dup->{provenance} . "]"
                    . "  (" . _fmt_bytes($size) . ")\n");
                $C{DuplicatesRemoved}++;
                $C{BytesFreed} += $size;
            } else {
                if (unlink $dup->{path}) {
                    print _red("    DELETED → " . basename($dup->{path})
                        . "  (" . _fmt_bytes($size) . ")\n");
                    $C{DuplicatesRemoved}++;
                    $C{BytesFreed} += $size;
                } else {
                    print _red("    ❌ Delete failed → " . basename($dup->{path}) . ": $!\n");
                    $C{Failed}++;
                }
            }
        }
    }

    if ($groups_found == 0 && $files_to_checksum > 0) {
        print _green("  ✅ No duplicates found.\n");
    }
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
if ($opt_dedup) {
    print  _cyan('─' x 50 . "\n");
    printf "%-32s: %s\n", 'Duplicate groups found',      $C{DuplicateGroups};
    printf "%-32s: %s\n", 'Duplicate files removed',     $C{DuplicatesRemoved};
    printf "%-32s: %s\n", 'Space freed',                 _fmt_bytes($C{BytesFreed});
}
print  _cyan('═' x 50 . "\n");

# ─── Subroutines ─────────────────────────────────────────────────────────────

# _audit_file: process a single media file through all audit steps.
# Called by both the sequential and parallel processing paths.
#
# Parameters:
#   $filepath     — absolute path to the file (may be modified by renames)
#   $et           — Image::ExifTool instance (caller owns lifecycle)
#   $pct          — formatted percentage string for progress display
#   $idx          — this file's index within the current chunk/run
#   $total        — total files in the current chunk/run
#   $report_every — print progress every N files (0 = always print)
#   $dry_run      — boolean: simulate but don't write
#   $job_num      — worker number for parallel mode prefix (0 = sequential)
#
# Returns a hashref:
#   failed     — 1 if any step failed, 0 otherwise
#   provenance — 'EXIF-only', 'QuickTime-only', etc.; undef if skipped early
#   final_path — filepath after all renames
#   counts     — hashref of per-file counter increments to merge into %C
sub _audit_file {
    my ($filepath, $et, $pct, $idx, $total, $report_every, $dry_run, $job_num) = @_;

    my $filename = basename($filepath);
    my $dir      = dirname($filepath);
    my @actions;
    my $failed     = 0;
    my $provenance;
    my %counts = map { $_ => 0 } qw(
        Processed SignatureMismatch SignatureRenamed DateTakenSet DateModifiedSet
        BirthTimeSet Skipped Failed Renamed WithCounter
        EXIF-only QuickTime-only Fallback-only Mixed-sources Unknown
    );
    $counts{Processed} = 1;

    # ── STEP 1: File existence check ─────────────────────────────────────────
    # A file may no longer exist at the collected path if a previous interrupted
    # run already renamed or moved it. Treat as a skip rather than a failure so
    # it doesn't inflate the error count and the run can continue cleanly.
    unless (-e $filepath) {
        push @actions, "⚠️  File no longer exists — skipping";
        $counts{Skipped}++;
        _print_line($pct, $idx, $total, \@actions, $filename, 0, $job_num)
            if $idx <= 10 || $idx % $report_every == 0;
        return { failed => 0, provenance => undef,
                 final_path => $filepath, counts => \%counts };
    }

    # ── STEP 2: Magic number / signature check ────────────────────────────────
    # Read the first 12 bytes and compare against known format signatures.
    # Catches files with wrong extensions regardless of filename.
    my $true_ext = eval { _detect_true_ext($filepath) };
    if ($@) {
        push @actions, "❌ Read error: " . ($@ =~ s/\n/ /gr);
        $counts{Failed}++;
        _print_line($pct, $idx, $total, \@actions, $filename, 1, $job_num);
        return { failed => 1, provenance => undef,
                 final_path => $filepath, counts => \%counts };
    } else {
        my (undef, undef, $cur_ext) = fileparse($filename, qr/\.[^.]*/);
        if (defined $true_ext && lc($cur_ext) ne $true_ext) {
            $counts{SignatureMismatch}++;
            my ($stem) = $filename =~ /^(.+)\.[^.]+$/;
            my $new_name = $stem . $true_ext;
            my $new_path = File::Spec->catfile($dir, $new_name);
            if ($dry_run) {
                push @actions, "🔍 Signature mismatch → Would rename to $new_name";
            } else {
                if (rename $filepath, $new_path) {
                    push @actions, "✅ Extension corrected: $filename → $new_name";
                    $counts{SignatureRenamed}++;
                    # Refresh — subsequent steps must operate on the new path.
                    # (Mirrors the PS script Bug 5 fix: stale $fileInfo after rename.)
                    $filepath = $new_path;
                    $filename = $new_name;
                } else {
                    push @actions, "❌ Extension rename failed: $!";
                    $failed = 1;
                    $counts{Failed}++;
                }
            }
        }
    }

    # Re-derive extension after any rename
    my (undef, undef, $ext) = fileparse($filename, qr/\.[^.]*/);
    my $is_video = exists $VIDEO_EXT{lc $ext};

    # ── STEP 3: Timestamp extraction (tiered) ────────────────────────────────
    #
    # FastScan => 1 (set on the $et instance) stops ExifTool from scanning
    # past the first metadata block — 2-3x faster with no loss of capture-date
    # accuracy (DateTimeOriginal is always in the primary block).
    #
    # Tier 1a — EXIF/XMP DateTimeOriginal (images)
    #   No group prefix so XMP and IPTC dates are also found automatically.
    #   This matches the PS script's removal of the 'EXIF:' group restriction.
    #
    # Tier 1b — QuickTime:CreateDate (videos)
    #   QuickTimeUTC option (set on $et) interprets the raw QT timestamp as
    #   UTC and converts to local time, matching '-api QuickTimeUTC' in the PS
    #   script. The spec mandates UTC but many cameras write local time instead;
    #   the option is the best-effort standard interpretation.
    #
    # Tier 2 — Filesystem mtime (LastWriteTime) — always available as fallback.
    $et->ExtractInfo($filepath);

    my ($date_taken, $media_created);

    if ($is_video) {
        my $raw = $et->GetValue('CreateDate', 'PrintConv');
        $media_created = _parse_exif_date($raw) if defined $raw;
    } else {
        my $raw = $et->GetValue('DateTimeOriginal', 'PrintConv');
        $date_taken = _parse_exif_date($raw) if defined $raw;
    }

    my $fs_mtime = (stat $filepath)[9];   # mtime — always defined for real files

    # ── STEP 4: Date sanity filter + oldest-date selection ───────────────────
    # Reject dates outside [1970-01-01, now + 5 years]. The 5-year upper bound
    # replaces the original 1-day limit which caused false warnings for valid
    # 2024/2025 files on systems whose clock lagged slightly.
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
        $counts{Skipped}++;
        _print_line($pct, $idx, $total, \@actions, $filename, 0, $job_num)
            if $idx <= 10 || $idx % $report_every == 0;
        $et->SetNewValue();   # clear any stale pending writes
        return { failed => 0, provenance => undef,
                 final_path => $filepath, counts => \%counts };
    }

    # ── STEP 5: Provenance classification ────────────────────────────────────
    # Based solely on which embedded metadata sources were found — filesystem
    # dates are always present and are not counted as "rich" metadata.
    # (Mirrors the PS script Bug 6 fix: correct EXIF-only / QT-only detection.)
    $provenance =
          ($date_taken && $media_created) ? 'Mixed-sources'
        : $date_taken                     ? 'EXIF-only'
        : $media_created                  ? 'QuickTime-only'
        : $fs_mtime                       ? 'Fallback-only'
        :                                   'Unknown';
    $counts{$provenance}++;
    push @actions, "[Source] Provenance → $provenance";

    # ── STEP 6: Write DateTimeOriginal for images that lack it ───────────────
    # Only images (not videos), and only when no DateTimeOriginal was found.
    # Image::ExifTool writes to a temp file then renames so no '_original'
    # backup is created — replicating the PS script's -overwrite_original flag.
    if (!$is_video && !$date_taken) {
        my $exif_date = strftime('%Y:%m:%d %H:%M:%S', localtime($oldest));
        if ($dry_run) {
            push @actions, "Would set DateTaken to " . strftime('%Y-%m-%d', localtime($oldest));
        } else {
            $et->SetNewValue('DateTimeOriginal', $exif_date);
            $et->SetNewValue('CreateDate',       $exif_date);

            # Write to a temp file in the same directory (atomic rename on same FS).
            my (undef, $tmp_path) = tempfile(
                'audit_XXXXXX', DIR => $dir, SUFFIX => '.tmp', UNLINK => 0
            );
            # File::Temp creates an empty placeholder to reserve the name.
            # ExifTool's WriteInfo refuses to overwrite an existing file, so
            # we must remove the placeholder before passing the path to WriteInfo.
            unlink $tmp_path;
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
                        $counts{Failed}++;
                    }
                }
                unless ($failed) {
                    push @actions, "Fixed DateTaken to " . strftime('%Y-%m-%d', localtime($oldest));
                    $counts{DateTakenSet}++;
                }
            } else {
                unlink $tmp_path if -e $tmp_path;
                my $err = $et->GetValue('Error') // 'unknown error';
                push @actions, "❌ Failed to set DateTaken: $err";
                $failed = 1;
                $counts{Failed}++;
            }

            # Clear pending write values so they don't bleed into the next file.
            $et->SetNewValue();
        }
    }

    # ── STEP 7: Correct filesystem mtime (LastWriteTime) ─────────────────────
    # utime(atime, mtime, file) — sets both atime and mtime to $oldest.
    # This is the only timestamp utime() can set; CreationTime requires Win32 API.
    if ($fs_mtime != $oldest) {
        if ($dry_run) {
            push @actions, "Would fix LastWriteTime to " . strftime('%Y-%m-%d', localtime($oldest));
        } else {
            if (utime($oldest, $oldest, $filepath)) {
                push @actions, "Fixed LastWriteTime to " . strftime('%Y-%m-%d', localtime($oldest));
                $counts{DateModifiedSet}++;
            } else {
                push @actions, "❌ Failed to set LastWriteTime: $!";
                $failed = 1;
            }
        }
    }

    # ── STEP 8: Correct CreationTime (birthtime) via Win32 API ───────────────
    # Available on Windows native Perl only. Skipped silently on Linux/WSL
    # because the Linux kernel does not expose a birthtime-setting syscall.
    #
    # On Windows Perl, stat()[10] maps to the C runtime's st_ctime which
    # corresponds to the NTFS CreationTime (not inode-change-time as on Linux).
    if ($^O eq 'MSWin32') {
        my $fs_ctime = (stat $filepath)[10];
        if (defined $fs_ctime && $fs_ctime != $oldest) {
            if ($dry_run) {
                push @actions, "Would fix CreationTime to " . strftime('%Y-%m-%d', localtime($oldest));
            } else {
                my ($ok, $err) = _set_win32_birthtime($filepath, $oldest);
                if ($ok) {
                    push @actions, "Fixed CreationTime to " . strftime('%Y-%m-%d', localtime($oldest));
                    $counts{BirthTimeSet}++;
                } else {
                    push @actions, "❌ Failed to set CreationTime: $err";
                    $failed = 1;
                }
            }
        }
    }

    # ── STEP 9: Timestamp-based rename ───────────────────────────────────────
    # Target: yyyyMMdd_HHmmss.ext — same format as the PS script.
    # Collision handling: check existence before attempting rename; retry with
    # .001/.002/... suffix up to .999. Safe for single-threaded mode; in
    # parallel mode rare collisions between workers are handled by the -e check.
    my $new_base = strftime('%Y%m%d_%H%M%S', localtime($oldest));
    my $new_name = $new_base . lc($ext);

    if ($filename ne $new_name) {
        if ($dry_run) {
            push @actions, "Would rename → $filename → $new_name";
        } else {
            my ($moved, $suffix) = (0, 0);
            while (!$moved && $suffix <= 999) {
                my $candidate = $suffix == 0
                    ? $new_name
                    : $new_base . sprintf('.%03d', $suffix) . lc($ext);
                my $dest = File::Spec->catfile($dir, $candidate);

                if (-e $dest) {
                    $suffix++;
                    next;
                }

                if (rename $filepath, $dest) {
                    push @actions, "Renamed → $filename → $candidate";
                    $counts{Renamed}++;
                    $counts{WithCounter}++ if $suffix > 0;
                    $filepath = $dest;
                    $moved = 1;
                } else {
                    push @actions, "❌ Rename failed: $!";
                    $failed = 1;
                    $counts{Failed}++;
                    last;
                }
            }

            if (!$moved && !$failed) {
                # Suffix space exhausted — mirrors PS script's suffix-exhaustion log
                push @actions, "❌ Rename failed: no unique name available after 999 attempts";
                $failed = 1;
                $counts{Failed}++;
            }
        }
    }

    # ── STEP 10: Progress output ──────────────────────────────────────────────
    _print_line($pct, $idx, $total, \@actions, $filename, $failed, $job_num)
        if $idx <= 10 || $idx % $report_every == 0;

    return {
        failed     => $failed,
        provenance => $provenance,
        final_path => $filepath,
        counts     => \%counts,
    };
}

# _split_chunks: divide an array into N roughly-equal parts.
# Distributes any remainder across the first chunks so they differ by at most 1.
# Returns a list of arrayrefs. If N >= number of elements, one ref per element.
sub _split_chunks {
    my ($arr_ref, $n) = @_;
    my @arr   = @$arr_ref;
    my $total = scalar @arr;
    return (\@arr) if $n <= 1 || $total <= $n;

    my @chunks;
    my $base      = int($total / $n);
    my $remainder = $total % $n;
    my $offset    = 0;
    for my $i (0 .. $n - 1) {
        my $size = $base + ($i < $remainder ? 1 : 0);
        last if $size == 0;
        push @chunks, [@arr[$offset .. $offset + $size - 1]];
        $offset += $size;
    }
    return @chunks;
}

# _detect_true_ext: read first 12 bytes and identify the actual file format.
# Returns the correct extension string (e.g. '.jpg') or undef if unknown.
# Same magic-number logic as the PowerShell version, without the switch-on-array
# bug or the decimal-join encoding bug from the original PS v1.0.0.
sub _detect_true_ext {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot open: $!\n";
    my $buf = '';
    read $fh, $buf, 12;
    close $fh;
    return undef if length($buf) < 2;

    # JPEG: FF D8
    return '.jpg'  if substr($buf,0,2) eq "\xFF\xD8";
    # PNG:  89 50 4E 47 — check all 4 distinctive bytes
    return '.png'  if substr($buf,0,4) eq "\x89PNG";
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

# _parse_exif_date: convert ExifTool date string → Unix timestamp (local time).
# ExifTool returns dates as 'YYYY:MM:DD HH:MM:SS' (possibly with timezone suffix).
# Returns undef if the string is missing, malformed, or has an implausible year.
sub _parse_exif_date {
    my ($str) = @_;
    return undef unless defined $str && $str =~ /^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/;
    my ($Y, $M, $D, $h, $m, $s) = ($1,$2,$3,$4,$5,$6);
    return undef if $Y < 1970 || $Y > 9990;  # pre-screen wildly invalid years
    my $ts = eval { timelocal($s, $m, $h, $D, $M-1, $Y-1900) };
    return $@ ? undef : $ts;
}

# _set_win32_birthtime: set Windows NTFS CreationTime (birthtime) via Win32 API.
#
# Why not utime()? utime() maps to the C runtime's _utime() which sets atime and
# mtime only — there is no portable POSIX mechanism to set birthtime. On Windows
# we must call SetFileTime() via the Win32 API with an open file handle.
#
# FILETIME encoding (see header comment for derivation):
#   ft = (unix_time + 11_644_473_600) × 10_000_000  [100-ns intervals since 1601]
# Packed as two 32-bit little-endian unsigned integers (DWORD lo, DWORD hi).
# 'use integer' ensures arithmetic uses native 64-bit integers on a 64-bit Perl
# build, avoiding floating-point precision loss for large FILETIME values.
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
    my $ft_bytes = pack('VV', $lo, $hi);   # little-endian FILETIME struct

    # CreateFileW requires a UTF-16LE wide string with a null terminator.
    # "\x00" appended before encoding — the null char encodes to \x00\x00 in UTF-16LE.
    my $wide_path = encode('UTF-16LE', $path . "\x00");

    my $GENERIC_WRITE         = 0x4000_0000;
    my $FILE_SHARE_READ       = 0x0000_0001;
    my $FILE_SHARE_WRITE      = 0x0000_0002;
    my $OPEN_EXISTING         = 3;
    my $FILE_ATTRIBUTE_NORMAL = 0x0000_0080;
    my $INVALID_HANDLE        = 0xFFFF_FFFF;

    my $handle = $fn_CreateFileW->Call(
        $wide_path,
        $GENERIC_WRITE,
        $FILE_SHARE_READ | $FILE_SHARE_WRITE,
        0,                      # lpSecurityAttributes = NULL
        $OPEN_EXISTING,
        $FILE_ATTRIBUTE_NORMAL,
        0                       # hTemplateFile = NULL
    );

    return (0, "CreateFileW failed: $^E")
        if !defined $handle || $handle == $INVALID_HANDLE;

    # SetFileTime(handle, lpCreationTime, lpLastAccessTime, lpLastWriteTime)
    # Pass ft_bytes for creation time; 0 (NULL pointer) for the others so they
    # are left unchanged — mtime is already corrected above via utime().
    my $ok  = $fn_SetFileTime->Call($handle, $ft_bytes, 0, 0);
    my $err = $^E;
    $fn_CloseHandle->Call($handle);

    return $ok ? (1, '') : (0, "SetFileTime failed: $err");
}

# _sha256_file: compute SHA256 hex digest of a file's full content.
# Used by the dedup phase to identify byte-for-byte identical files.
# Returns undef if the file cannot be read.
sub _sha256_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $sha = Digest::SHA->new(256);
    $sha->addfile($fh);
    close $fh;
    return $sha->hexdigest;
}

# _fmt_bytes: format a byte count as a human-readable string.
sub _fmt_bytes {
    my ($b) = @_;
    return sprintf('%.1f GB', $b / 1_073_741_824) if $b >= 1_073_741_824;
    return sprintf('%.1f MB', $b / 1_048_576)     if $b >= 1_048_576;
    return sprintf('%.1f KB', $b / 1_024)         if $b >= 1_024;
    return "$b bytes";
}

# _print_line: emit a single colour-coded progress line.
# In parallel mode ($job_num > 0), prefixes with "[JN] " to identify the worker.
# Red = failure, Gray = skipped/missing, Green = normal.
sub _print_line {
    my ($pct, $idx, $total, $actions, $fname, $failed, $job_num) = @_;
    my $prefix  = ($job_num // 0) > 0 ? "[J$job_num] " : '';
    my $line    = "${prefix}[$pct%] ($idx/$total) " . join('; ', @$actions) . " - $fname";
    my $skipped = grep { /no longer exists|Skipped/ } @$actions;
    if    ($failed)  { print _red($line)   . "\n" }
    elsif ($skipped) { print _gray($line)  . "\n" }
    else             { print _green($line) . "\n" }
}

__END__

=head1 NAME

inspect-media-audit.pl — Media signature check, timestamp repair, rename, and deduplication

=head1 SYNOPSIS

  perl inspect-media-audit.pl --path /path/to/photos [--dry-run] [--recurse] [--dedup] [--jobs N]

=head1 DESCRIPTION

For each media file in the given folder the script:

  1. Checks whether the file still exists — skips with a warning if not
     (handles interrupted previous runs gracefully).
  2. Reads the first 12 bytes and checks the magic number against known
     signatures to detect extension mismatches (e.g. a JPEG saved as .mov).
  3. Renames the file to the correct extension if the signature doesn't match.
  4. Extracts capture timestamps via Image::ExifTool (FastScan — no subprocess):
       - DateTimeOriginal for images (EXIF, XMP, IPTC — all groups searched)
       - QuickTime:CreateDate for videos (UTC-corrected via QuickTimeUTC option)
       - Filesystem mtime as fallback (always available)
  5. Filters out implausible dates (before 1970 or more than 5 years in the
     future). Falls back to raw oldest with a warning if all candidates fail.
  6. Selects the oldest remaining valid date as the canonical capture timestamp.
  7. Writes DateTimeOriginal back into the file for images that lack it (via
     temp-file + rename, so no _original backup is created).
  8. Sets mtime (LastWriteTime) via utime().
  9. Sets CreationTime (NTFS birthtime) via Win32::API on Windows native Perl.
  10. Renames the file to yyyyMMdd_HHmmss.ext. Collisions get .001/.002/... suffixes.
  11. Classifies provenance: EXIF-only, QuickTime-only, Fallback-only, Mixed, Unknown.
  12. (--dedup) After all files: groups by size, checksums only size-matched groups,
      keeps the file with richest provenance in each duplicate group, deletes the rest.

=head1 OPTIONS

  --path <dir>   Root folder (required)
  --dry-run      Simulate only — no writes, renames, or deletions
  --recurse      Process subdirectories recursively
  --dedup        Remove byte-identical duplicates by SHA256 (after renaming)
  --jobs N       Parallel workers — requires Parallel::ForkManager

=head1 AUTHOR

Clive DSouza

=head1 LICENSE

MIT

=cut
