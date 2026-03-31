#!/usr/bin/env perl
# t/02_date_extraction.t — timestamp extraction and sanity filtering tests
#
# Verifies that media-audit.pl correctly extracts dates from EXIF, rejects
# implausible values, and falls back to filesystem mtime when needed.

use strict;
use warnings;
use Test::More tests => 8;
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

# ── TC-04: valid EXIF date — used as canonical date ──────────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/EXIF.only/i,
        'TC-04: valid JPEG — provenance is EXIF-only';

    like $out, qr/20231225/,
        'TC-04: valid JPEG — canonical date 20231225 used';
}

# ── TC-05: future date — rejected, fallback used, warning printed ─────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/future_date.jpg", "$dir/future_date.jpg");

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/outside sane range|sane range/i,
        'TC-05: future date — "outside sane range" warning printed';

    unlike $out, qr/20360101/,
        'TC-05: future date — year 2036 not used as canonical date';
}

# ── TC-06: corrupt date (year 0001) — rejected, fallback used ────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/corrupt_date.jpg", "$dir/corrupt_date.jpg");

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/outside sane range|sane range/i,
        'TC-06: corrupt date — "outside sane range" warning printed';

    unlike $out, qr/00010101/,
        'TC-06: corrupt date — year 0001 not used as canonical date';
}

# ── TC-07: no EXIF — fallback to filesystem mtime, Fallback-only provenance ───

{
    my $dir = tmpdir();
    copy("$FIXTURES/no_exif.jpg", "$dir/no_exif.jpg");

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/Fallback.only/i,
        'TC-07: no EXIF — provenance is Fallback-only';

    unlike $out, qr/EXIF-only sources\s*:\s*[1-9]/i,
        'TC-07: no EXIF — EXIF-only sources counter is 0';
}
