#!/usr/bin/env perl
# t/03_rename.t — canonical rename logic tests
#
# Verifies that media-audit.pl renames files to YYYYMMDD_HHmmss.ext format,
# handles collisions with .001 suffixes, and does not rename already-canonical files.

use strict;
use warnings;
use Test::More tests => 7;
use File::Temp  qw(tempdir);
use File::Copy  qw(copy);
use File::Spec;
use FindBin     qw($Bin);

my $SCRIPT   = File::Spec->catfile($Bin, '..', 'media-audit.pl');
my $FIXTURES = File::Spec->catfile($Bin, 'fixtures');

sub run_audit {
    my ($dir, @flags) = @_;
    return qx(perl "$SCRIPT" --path "$dir" @flags 2>&1);
}

sub tmpdir { tempdir(CLEANUP => 1) }

# ── TC-08: file with valid EXIF is renamed to canonical format ────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");

    run_audit($dir);    # live run

    ok -e "$dir/20231225_143022.jpg",
        'TC-08: valid_jpeg.jpg — renamed to 20231225_143022.jpg';

    ok !-e "$dir/valid_jpeg.jpg",
        'TC-08: valid_jpeg.jpg — original filename no longer exists';
}

# ── TC-09: already canonical filename — no rename (no-op) ────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/20231225_143022.jpg", "$dir/20231225_143022.jpg");

    my $out = run_audit($dir);

    ok -e "$dir/20231225_143022.jpg",
        'TC-09: canonical file — still exists after run';

    like $out, qr/Files renamed by timestamp\s*:\s*0/i,
        'TC-09: canonical file — renamed counter is 0';
}

# ── TC-10: collision — second file with same timestamp gets .001 suffix ───────

{
    my $dir = tmpdir();
    # Two files that both have EXIF date 2023:12:25 14:30:22
    copy("$FIXTURES/valid_jpeg.jpg",      "$dir/file_a.jpg");
    copy("$FIXTURES/20231225_143022.jpg", "$dir/file_b.jpg");

    my $out = run_audit($dir);    # live run

    ok -e "$dir/20231225_143022.jpg",
        'TC-10: collision — first file renamed to 20231225_143022.jpg';

    ok -e "$dir/20231225_143022.001.jpg",
        'TC-10: collision — second file renamed to 20231225_143022.001.jpg';

    # Re-run audit on the already-renamed files and check summary counter.
    # Files are already canonical so no second rename, but the first live run
    # above produced a .001 suffix — verify it was counted.
    like $out, qr/Timestamp rename w\/ suffix\s*:\s*[1-9]/i,
        'TC-10: collision — WithCounter reported in live run summary';
}
