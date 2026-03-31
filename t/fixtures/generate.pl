#!/usr/bin/env perl
# generate.pl — regenerate test fixtures from scratch
#
# Only needed if fixtures are lost or need to be rebuilt.
# Fixtures are committed as binary files — do not run this during tests.
#
# Requirements: ffmpeg, exiftool
#
# Usage: perl t/fixtures/generate.pl

use strict;
use warnings;

chdir(dirname(__FILE__)) or die "Cannot chdir to fixtures: $!";
use File::Basename qw(dirname);

# Base: minimal 2x2 JPEG
system('ffmpeg -y -f lavfi -i "color=red:size=2x2:duration=0.04" -vframes 1 base.jpg 2>/dev/null') == 0
    or die "ffmpeg failed";

# valid_jpeg.jpg — real JPEG with valid EXIF DateTimeOriginal
system('cp base.jpg valid_jpeg.jpg');
system('exiftool -overwrite_original -DateTimeOriginal="2023:12:25 14:30:22" valid_jpeg.jpg >/dev/null 2>&1');

# wrong_ext.jpg — real PNG saved with .jpg extension
system('ffmpeg -y -f lavfi -i "color=blue:size=2x2:duration=0.04" -vframes 1 wrong_ext.png 2>/dev/null');
rename 'wrong_ext.png', 'wrong_ext.jpg';

# no_exif.jpg — JPEG with all metadata stripped
system('cp base.jpg no_exif.jpg');
system('exiftool -overwrite_original -all= no_exif.jpg >/dev/null 2>&1');

# future_date.jpg — EXIF date 10 years in the future
system('cp base.jpg future_date.jpg');
system('exiftool -overwrite_original -DateTimeOriginal="2036:01:01 00:00:00" future_date.jpg >/dev/null 2>&1');

# corrupt_date.jpg — EXIF year 0001
system('cp base.jpg corrupt_date.jpg');
system('exiftool -overwrite_original -DateTimeOriginal="0001:01:01 00:00:00" corrupt_date.jpg >/dev/null 2>&1');

# duplicate_a.jpg + duplicate_b.jpg — byte-identical pair
system('cp base.jpg duplicate_a.jpg');
system('exiftool -overwrite_original -DateTimeOriginal="2022:06:15 10:00:00" duplicate_a.jpg >/dev/null 2>&1');
system('cp duplicate_a.jpg duplicate_b.jpg');

# 20231225_143022.jpg — already in canonical format with matching EXIF
system('cp base.jpg 20231225_143022.jpg');
system('exiftool -overwrite_original -DateTimeOriginal="2023:12:25 14:30:22" 20231225_143022.jpg >/dev/null 2>&1');

unlink 'base.jpg';
print "Fixtures generated.\n";
