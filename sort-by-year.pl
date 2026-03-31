#!/usr/bin/env perl
# sort-by-year.pl — v1.3.0
# Copyright © 2025-2026 Clive DSouza
# SPDX-License-Identifier: MIT
# Licensed under the MIT License — see LICENSE file in repo root
#
# Sorts media files in-place into YYYY/ subfolders within the same directory.
# Files must be named in the media-audit canonical format: YYYYMMDD_HHmmss.ext
# The year is extracted directly from the filename — no metadata reads needed.
#
# USAGE:
#   perl sort-by-year.pl --path <dir> [--dry-run] [--recurse]
#
# EXAMPLE:
#   perl sort-by-year.pl --path /mnt/e/Photos/test --dry-run
#   perl sort-by-year.pl --path /mnt/e/Photos/test
#   perl sort-by-year.pl --path /mnt/e/Photos/test --recurse

use strict;
use warnings;
use 5.016;

use Getopt::Long qw(GetOptions :config no_ignore_case);
use File::Find   qw(find);
use File::Basename qw(basename);
use File::Spec;
use File::Path   qw(make_path);
use POSIX        qw(floor);

# ─── ANSI colour helpers ─────────────────────────────────────────────────────
sub _red    { "\e[31m$_[0]\e[0m" }
sub _green  { "\e[32m$_[0]\e[0m" }
sub _yellow { "\e[33m$_[0]\e[0m" }
sub _cyan   { "\e[36m$_[0]\e[0m" }

# ─── Argument parsing ────────────────────────────────────────────────────────
my ($opt_path, $opt_dry_run, $opt_recurse, $opt_help);

GetOptions(
    'path=s'  => \$opt_path,
    'dry-run' => \$opt_dry_run,
    'recurse' => \$opt_recurse,
    'help'    => \$opt_help,
) or die "Usage: $0 --path <dir> [--dry-run] [--recurse]\n";

if ($opt_help) {
    print <<'USAGE';
sort-by-year.pl — sort media files in-place into YYYY/ subfolders

USAGE:
  perl sort-by-year.pl --path <dir> [--dry-run] [--recurse]

OPTIONS:
  --path <dir>   Folder to sort — files move into PATH/YYYY/ subfolders (required)
  --dry-run      Preview moves without touching any files
  --recurse      Also sort files found in subdirectories of --path.
                 Already-named year folders (e.g. 2023/) are skipped automatically
                 so re-running is always safe.

NOTES:
  Files must be named in the media-audit canonical format: YYYYMMDD_HHmmss.ext
  Run media-audit.pl first to ensure all files are renamed correctly.
  Files that don't match the YYYYMMDD_HHmmss format are skipped with a warning.
  Collision handling: if PATH/YYYY/filename already exists a .001/.002/...
  suffix is appended rather than overwriting the existing file.

EXAMPLE:
  # Always preview first:
  perl sort-by-year.pl --path /mnt/e/Photos/test --dry-run

  # Apply (top-level files only):
  perl sort-by-year.pl --path /mnt/e/Photos/test

  # Apply recursively (includes subdirectories):
  perl sort-by-year.pl --path /mnt/e/Photos/test --recurse
USAGE
    exit 0;
}

die "❌ --path is required\n"         unless defined $opt_path;
die "❌ Path not found: $opt_path\n"  unless -d $opt_path;

my $start_time = time();

$opt_path = File::Spec->rel2abs($opt_path);

# ─── File collection ─────────────────────────────────────────────────────────
# Without --recurse: collect only files directly in $opt_path (not subdirs).
# This ensures already-sorted year folders (2023/, 2024/, etc.) are never
# re-processed, making the script safe to re-run without double-moving files.
#
# With --recurse: walk all subdirectories but skip any folder whose name is a
# 4-digit year (1970–2100) — these are already-sorted destination folders and
# should not be re-sorted into themselves.
my @files;

if ($opt_recurse) {
    find(sub {
        # Skip hidden files and directories
        if (/^\./) { $File::Find::prune = 1; return; }

        # Skip already-sorted year folders to prevent re-processing sorted files.
        # A folder named with exactly 4 digits in the range 1970–2100 is treated
        # as a year destination — pruning it means its contents are left alone.
        if (-d $_ && /^(\d{4})$/ && $1 >= 1970 && $1 <= 2100) {
            $File::Find::prune = 1;
            return;
        }

        push @files, $File::Find::name if -f $_;
    }, $opt_path);
} else {
    # Top-level only — files directly in $opt_path
    opendir my $dh, $opt_path or die "Cannot open directory: $!\n";
    while (my $entry = readdir $dh) {
        next if $entry =~ /^\./;
        my $full = File::Spec->catfile($opt_path, $entry);
        push @files, $full if -f $full;
    }
    closedir $dh;
}

@files = sort @files;
my $total = scalar @files;

if ($total == 0) {
    print _yellow("⚠️  No files found in '$opt_path'. Nothing to do.\n");
    exit 0;
}

my $mode_str = $opt_recurse ? ' (recursive)' : ' (top-level only)';
print _cyan("\n📂 Path        : $opt_path$mode_str\n");
print _cyan("   Files found : $total\n");
print _yellow("DRY RUN — no files will be moved\n") if $opt_dry_run;
print "\n";

# ─── Move files ──────────────────────────────────────────────────────────────
my ($moved, $skipped, $errors, $collisions) = (0, 0, 0, 0);
my $processed = 0;

for my $filepath (@files) {
    $processed++;

    # Percentage complete — shown as a prefix on every line so progress is
    # always visible even when output is piped to a file via tee.
    my $pct = sprintf('[%5.1f%%] (%d/%d)', $processed / $total * 100, $processed, $total);

    my $fname = basename($filepath);

    # Extract year from canonical filename: YYYYMMDD_HHmmss[.NNN].ext
    # The regex anchors on the full timestamp pattern so partial matches
    # (e.g. a file starting with just 4 digits) are not accepted.
    my ($year) = $fname =~ /^(\d{4})\d{4}_\d{6}/;

    unless (defined $year) {
        print _yellow("$pct ⚠️  Skipping (not in YYYYMMDD_HHmmss format): $fname\n");
        $skipped++;
        next;
    }

    if ($year < 1970 || $year > 2100) {
        print _yellow("$pct ⚠️  Skipping (implausible year $year): $fname\n");
        $skipped++;
        next;
    }

    # Build the destination directory and full target path.
    # Year folder is created on demand — only when the first file for that
    # year is actually moved (not in dry-run mode).
    my $target_dir = File::Spec->catdir($opt_path, $year);
    my $target     = File::Spec->catfile($target_dir, $fname);

    # Collision handling: if a file with the same name already exists in the
    # target year folder, append a .001/.002/... suffix rather than overwriting.
    # This mirrors the media-audit.pl rename collision logic.
    if (-e $target && !$opt_dry_run) {
        my ($stem, $ext) = $fname =~ /^(.+?)(\.[^.]+)$/;
        $stem //= $fname; $ext //= '';
        my $suffix = 1;
        while (-e $target && $suffix <= 999) {
            $target = File::Spec->catfile(
                $target_dir, sprintf('%s.%03d%s', $stem, $suffix, $ext)
            );
            $suffix++;
        }
        if ($suffix > 999) {
            print _red("$pct ❌ No unique name after 999 attempts: $fname\n");
            $errors++;
            next;
        }
        $collisions++;
    }

    my $dest_fname = basename($target);

    # Print source → destination for every file so the move is fully auditable.
    # In dry-run mode the prefix is "Would move"; in live mode it is "Moved".
    # Collision renames show the adjusted destination filename as a warning line.
    if ($opt_dry_run) {
        print _green("$pct Would move\n");
        print _green("            SRC: $filepath\n");
        print _green("            DST: $target_dir/$dest_fname\n");
        $moved++;
    } else {
        # Create the year subfolder if it does not yet exist.
        unless (-d $target_dir) {
            make_path($target_dir) or do {
                print _red("$pct ❌ Cannot create $target_dir: $!\n");
                $errors++;
                next;
            };
        }

        if (rename $filepath, $target) {
            print _green("$pct Moved\n");
            print _green("            SRC: $filepath\n");
            print _green("            DST: $target\n");
            print _yellow("            ⚠️  Collision — renamed to: $dest_fname\n")
                if $dest_fname ne $fname;
            $moved++;
        } else {
            print _red("$pct ❌ Move failed\n");
            print _red("            SRC: $filepath\n");
            print _red("            DST: $target\n");
            print _red("            ERR: $!\n");
            $errors++;
        }
    }
}

# ─── Summary ─────────────────────────────────────────────────────────────────
my $elapsed   = time() - $start_time;
my $hrs       = floor($elapsed / 3600);
my $mins      = floor(($elapsed % 3600) / 60);
my $secs      = $elapsed % 60;
my $runtime   = $hrs  ? sprintf('%dh %02dm %02ds', $hrs, $mins, $secs)
              : $mins ? sprintf('%dm %02ds', $mins, $secs)
              :          sprintf('%ds', $secs);
my $rate      = ($elapsed > 0 && $moved > 0)
                ? sprintf('%.0f files/sec', $moved / $elapsed)
                : 'N/A';

print _cyan("\n" . ('═' x 50) . "\n");
printf "%-24s: %s\n", 'Script',            'sort-by-year.pl v1.3.1';
printf "%-24s: %s\n", 'Runtime',           $runtime;
print _yellow("DRY RUN — no files were moved\n") if $opt_dry_run;
print _cyan('─' x 50 . "\n");
printf "%-24s: %s\n", 'Files found',       $total;
printf "%-24s: %s\n", 'Moved',             $moved;
printf "%-24s: %s\n", 'Skipped',           $skipped;
printf "%-24s: %s\n", 'Collision renames', $collisions;
if ($errors > 0) {
    printf "%-24s: %s\n", _red('Errors'), _red($errors);
} else {
    printf "%-24s: %s\n", 'Errors', $errors;
}
printf "%-24s: %s\n", 'Throughput',        $rate;
print _red("⚠️  $errors file(s) could not be moved — check output above for details\n")
    if $errors > 0;
print _cyan('═' x 50 . "\n");
