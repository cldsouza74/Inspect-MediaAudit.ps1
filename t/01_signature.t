#!/usr/bin/env perl
# t/01_signature.t — magic-number signature detection tests
#
# Verifies that media-audit.pl correctly identifies file formats by content
# rather than extension, and renames files with wrong extensions.

use strict;
use warnings;
use Test::More tests => 6;
use File::Temp  qw(tempdir);
use File::Copy  qw(copy);
use File::Spec;
use FindBin     qw($Bin);

my $SCRIPT   = File::Spec->catfile($Bin, '..', 'media-audit.pl');
my $FIXTURES = File::Spec->catfile($Bin, 'fixtures');

# ── helpers ──────────────────────────────────────────────────────────────────

sub run_audit {
    my ($dir, @flags) = @_;
    my $out = qx(perl "$SCRIPT" --path "$dir" @flags 2>&1);
    return $out;
}

sub tmpdir { tempdir(CLEANUP => 1) }

# ── TC-01: valid JPEG with correct extension — no rename ─────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/Signature mismatches\s*:\s*0/i,
        'TC-01: valid JPEG — signature mismatches counter is 0';

    unlike $out, qr/Would rename.*\.png/i,
        'TC-01: valid JPEG — not renamed to .png';
}

# ── TC-02: PNG disguised as .jpg — detected and would be renamed ─────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/wrong_ext.jpg", "$dir/wrong_ext.jpg");

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/wrong_ext\.png/i,
        'TC-02: wrong_ext.jpg — would rename to .png';

    like $out, qr/Signature mismatches\s*:\s*[1-9]/i,
        'TC-02: wrong_ext.jpg — signature mismatches counter > 0';
}

# ── TC-03: live rename — PNG saved as .jpg is renamed on disk ─────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/wrong_ext.jpg", "$dir/wrong_ext.jpg");

    run_audit($dir);    # live run — no --dry-run

    # After a live run the file is renamed twice:
    # 1. wrong_ext.jpg → wrong_ext.png  (signature fix)
    # 2. wrong_ext.png → YYYYMMDD_HHmmss.png  (timestamp rename)
    # Check that a .png file now exists and the original .jpg is gone.
    my @pngs = glob("$dir/*.png");
    ok scalar(@pngs) == 1,
        'TC-03: wrong_ext.jpg — exactly one .png file exists after live run';

    ok !-e "$dir/wrong_ext.jpg",
        'TC-03: wrong_ext.jpg — original .jpg file no longer exists';
}
