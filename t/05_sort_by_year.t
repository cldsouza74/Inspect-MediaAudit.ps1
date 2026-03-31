#!/usr/bin/env perl
# t/05_sort_by_year.t — sort-by-year.pl tests
#
# Verifies year folder creation, canonical file sorting, non-canonical skip,
# collision suffix handling, and re-run safety.

use strict;
use warnings;
use Test::More tests => 8;
use File::Temp  qw(tempdir);
use File::Copy  qw(copy);
use File::Spec;
use FindBin     qw($Bin);

my $SCRIPT   = File::Spec->catfile($Bin, '..', 'sort-by-year.pl');
my $FIXTURES = File::Spec->catfile($Bin, 'fixtures');

sub run_sort {
    my ($dir, @flags) = @_;
    return qx(perl "$SCRIPT" --path "$dir" @flags 2>&1);
}

sub tmpdir { tempdir(CLEANUP => 1) }

# ── TC-15: canonical file moved into year subfolder ───────────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/20231225_143022.jpg", "$dir/20231225_143022.jpg");

    run_sort($dir);

    ok -e "$dir/2023/20231225_143022.jpg",
        'TC-15: canonical file — moved to 2023/ subfolder';

    ok !-e "$dir/20231225_143022.jpg",
        'TC-15: canonical file — no longer in root after sort';
}

# ── TC-16: year folder created on demand ──────────────────────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/20231225_143022.jpg", "$dir/20231225_143022.jpg");

    run_sort($dir);

    ok -d "$dir/2023",
        'TC-16: year folder 2023/ created automatically';
}

# ── TC-17: non-canonical filename skipped with warning ────────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");    # not canonical

    my $out = run_sort($dir);

    like $out, qr/Skipping.*format|not in.*format/i,
        'TC-17: non-canonical file — skipped with format warning';

    ok !-d "$dir/2023",
        'TC-17: non-canonical file — no year folder created';
}

# ── TC-18: collision — existing file in target gets .001 suffix ───────────────

{
    my $dir = tmpdir();
    mkdir "$dir/2023";
    copy("$FIXTURES/20231225_143022.jpg", "$dir/20231225_143022.jpg");
    copy("$FIXTURES/20231225_143022.jpg", "$dir/2023/20231225_143022.jpg");

    run_sort($dir);

    ok -e "$dir/2023/20231225_143022.001.jpg",
        'TC-18: collision — second file renamed to .001 in year folder';
}

# ── TC-19: re-run safe — already-sorted year folder not re-processed ──────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/20231225_143022.jpg", "$dir/20231225_143022.jpg");

    run_sort($dir);                    # first run — moves to 2023/
    my $out = run_sort($dir, '--recurse');    # second run with --recurse

    # File should still be in 2023/ not moved to 2023/2023/
    ok -e "$dir/2023/20231225_143022.jpg",
        'TC-19: re-run safe — file stays in 2023/, not double-moved';

    ok !-e "$dir/2023/2023/20231225_143022.jpg",
        'TC-19: re-run safe — no 2023/2023/ nested folder created';
}
