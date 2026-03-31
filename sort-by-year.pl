#!/usr/bin/env perl
# sort-by-year.pl — v1.0.0
# Copyright © 2025-2026 Clive DSouza
# SPDX-License-Identifier: MIT
# Licensed under the MIT License — see LICENSE file in repo root
#
# Moves media files from a source folder into DEST/YEAR/ subfolders.
# Files must be named in the media-audit canonical format: YYYYMMDD_HHmmss.ext
# The year is extracted directly from the filename — no metadata reads needed.
#
# USAGE:
#   perl sort-by-year.pl --src /path/to/test --dest /path/to/Photos [--dry-run] [--recurse]
#
# EXAMPLE:
#   perl sort-by-year.pl --src /mnt/e/Photos/test --dest /mnt/e/Photos --dry-run
#   perl sort-by-year.pl --src /mnt/e/Photos/test --dest /mnt/e/Photos

use strict;
use warnings;
use 5.016;

use Getopt::Long qw(GetOptions :config no_ignore_case);
use File::Find   qw(find);
use File::Basename qw(basename dirname);
use File::Spec;
use File::Path   qw(make_path);

# ─── ANSI colour helpers ─────────────────────────────────────────────────────
sub _red    { "\e[31m$_[0]\e[0m" }
sub _green  { "\e[32m$_[0]\e[0m" }
sub _yellow { "\e[33m$_[0]\e[0m" }
sub _cyan   { "\e[36m$_[0]\e[0m" }
sub _gray   { "\e[90m$_[0]\e[0m" }

# ─── Argument parsing ─────────────────────────────────────────────────────────
my ($opt_src, $opt_dest, $opt_dry_run, $opt_recurse, $opt_help);

GetOptions(
    'src=s'    => \$opt_src,
    'dest=s'   => \$opt_dest,
    'dry-run'  => \$opt_dry_run,
    'recurse'  => \$opt_recurse,
    'help'     => \$opt_help,
) or die "Usage: $0 --src <dir> --dest <dir> [--dry-run] [--recurse]\n";

if ($opt_help) {
    print <<'USAGE';
sort-by-year.pl — move media files into DEST/YEAR/ subfolders

USAGE:
  perl sort-by-year.pl --src <dir> --dest <dir> [--dry-run] [--recurse]

OPTIONS:
  --src <dir>    Source folder containing media files (required)
  --dest <dir>   Destination root folder — files go into DEST/YEAR/ (required)
  --dry-run      Preview moves without touching any files
  --recurse      Scan subdirectories of --src recursively

NOTES:
  Files must be named in the media-audit canonical format: YYYYMMDD_HHmmss.ext
  Run media-audit.pl first to ensure all files are renamed correctly.
  Files that don't start with a 4-digit year are skipped with a warning.
  Collision handling: if DEST/YEAR/filename already exists, a .001/.002/...
  suffix is appended rather than overwriting the existing file.

EXAMPLE:
  perl sort-by-year.pl --src /mnt/e/Photos/test --dest /mnt/e/Photos --dry-run
  perl sort-by-year.pl --src /mnt/e/Photos/test --dest /mnt/e/Photos
USAGE
    exit 0;
}

die "❌ --src is required\n"                  unless defined $opt_src;
die "❌ --dest is required\n"                 unless defined $opt_dest;
die "❌ Source not found: $opt_src\n"         unless -d $opt_src;
die "❌ Destination not found: $opt_dest\n"   unless -d $opt_dest;

# Resolve to absolute paths
$opt_src  = File::Spec->rel2abs($opt_src);
$opt_dest = File::Spec->rel2abs($opt_dest);

# Guard against moving a folder into itself
die "❌ --src and --dest cannot be the same folder\n"
    if $opt_src eq $opt_dest;
die "❌ --dest cannot be inside --src\n"
    if index($opt_dest, $opt_src . '/') == 0;

# ─── File collection ──────────────────────────────────────────────────────────
my @files;

if ($opt_recurse) {
    find(sub {
        return unless -f $_;
        return if /^\./;    # skip hidden files
        push @files, $File::Find::name;
    }, $opt_src);
} else {
    opendir my $dh, $opt_src or die "Cannot open source directory: $!\n";
    while (my $entry = readdir $dh) {
        next if $entry =~ /^\./;
        my $full = File::Spec->catfile($opt_src, $entry);
        push @files, $full if -f $full;
    }
    closedir $dh;
}

my $total = scalar @files;

if ($total == 0) {
    print _yellow("⚠️  No files found in '$opt_src'. Nothing to do.\n");
    exit 0;
}

print _cyan("\n📂 Source      : $opt_src\n");
print _cyan("📂 Destination : $opt_dest\n");
print _cyan("   Files found : $total\n");
print _yellow("DRY RUN — no files will be moved\n") if $opt_dry_run;
print "\n";

# ─── Move files ───────────────────────────────────────────────────────────────
my ($moved, $skipped, $errors, $collisions) = (0, 0, 0, 0);

for my $filepath (sort @files) {
    my $fname = basename($filepath);

    # Extract year from the first 4 characters of the filename.
    # Valid canonical names: YYYYMMDD_HHmmss.ext or YYYYMMDD_HHmmss.001.ext
    my ($year) = $fname =~ /^(\d{4})\d{4}_\d{6}/;

    unless (defined $year) {
        print _yellow("⚠️  Skipping (name not in YYYYMMDD_HHmmss format): $fname\n");
        $skipped++;
        next;
    }

    # Sanity check: year must be plausible for a consumer photo library
    if ($year < 1970 || $year > 2100) {
        print _yellow("⚠️  Skipping (implausible year $year): $fname\n");
        $skipped++;
        next;
    }

    my $target_dir = File::Spec->catdir($opt_dest, $year);
    my $target     = File::Spec->catfile($target_dir, $fname);

    # Collision handling: append .001/.002/... suffix if target already exists.
    # Extracts stem and extension to insert the suffix before the extension.
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
            print _red("❌ No unique name available after 999 attempts: $fname\n");
            $errors++;
            next;
        }
        $collisions++;
    }

    my $dest_fname = basename($target);

    if ($opt_dry_run) {
        print _green("Would move → $fname → $year/$dest_fname\n");
        $moved++;
    } else {
        # Create the year folder if it doesn't exist yet.
        unless (-d $target_dir) {
            make_path($target_dir) or do {
                print _red("❌ Cannot create directory $target_dir: $!\n");
                $errors++;
                next;
            };
        }

        if (rename $filepath, $target) {
            my $suffix_note = $dest_fname ne $fname ? " (renamed: $dest_fname)" : '';
            print _green("Moved → $fname → $year/$dest_fname$suffix_note\n");
            $moved++;
        } else {
            print _red("❌ Move failed: $fname → $year/ : $!\n");
            $errors++;
        }
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print _cyan("\n" . ('═' x 50) . "\n");
print _yellow("DRY RUN — no files were moved\n") if $opt_dry_run;
printf "%-24s: %s\n", 'Files found',       $total;
printf "%-24s: %s\n", 'Moved',             $moved;
printf "%-24s: %s\n", 'Skipped',           $skipped;
printf "%-24s: %s\n", 'Collision renames', $collisions;
printf "%-24s: %s\n", 'Errors',            $errors;
print _cyan('═' x 50 . "\n");
