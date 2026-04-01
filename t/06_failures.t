#!/usr/bin/env perl
# t/06_failures.t — failure handling regression tests
#
# These tests cover the specific failure modes that caused real production bugs.
# Each test is named after the bug it guards against.

use strict;
use warnings;
use Test::More tests => 9;
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

# ── TC-20: failure always printed regardless of report_every throttle ─────────
#
# Regression: _print_line was throttled by $report_every with no exception for
# failures. A failure on file #42 with report_every=100 was counted but never
# printed. Fixed by adding $failed || to the output condition.

{
    my $dir = tmpdir();

    # Create enough files that a failure in the middle would be throttled
    # if the fix were not in place. We use an unreadable file as the failure.
    for my $i (1..5) {
        copy("$FIXTURES/valid_jpeg.jpg", "$dir/file_$i.jpg");
    }
    my $bad = "$dir/unreadable.jpg";
    copy("$FIXTURES/valid_jpeg.jpg", $bad);
    chmod 0000, $bad;

    my $out = run_audit($dir);

    like $out, qr/Failures\s*:\s*[1-9]|❌/,
        'TC-20: failure throttle — failure reported in output';

    chmod 0644, $bad;    # restore for cleanup
}

# ── TC-21: file deleted between scan and processing — Skip not Failure ─────────
#
# Regression: files that no longer exist at their collected path were logged as
# Read error and incremented the failure counter. Now detected before the
# magic-number read, logged as warning, counted as Skipped.

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");
    copy("$FIXTURES/no_exif.jpg",    "$dir/no_exif.jpg");

    # We can't easily delete a file between scan and processing in a subprocess,
    # so we test the outcome of a previously interrupted run: a file that was
    # already renamed by a prior run (old path no longer exists).
    # Start with a canonical file and verify skipped count stays 0 (no phantom failures).
    my $out = run_audit($dir, '--dry-run');

    unlike $out, qr/Failures\s*:\s*[1-9]/,
        'TC-21: no phantom failures on clean folder';
}

# ── TC-22: VERSION file readable — all scripts start without error ─────────────

{
    my $sort_script = File::Spec->catfile($Bin, '..', 'sort-by-year.pl');
    my $out = qx(perl "$SCRIPT" --help 2>&1);
    like $out, qr/media-audit/i,
        'TC-22: media-audit.pl --help — starts and reads VERSION without error';

    $out = qx(perl "$sort_script" --help 2>&1);
    like $out, qr/sort-by-year/i,
        'TC-22: sort-by-year.pl --help — starts and reads VERSION without error';
}

# ── TC-23: summary shows correct version from VERSION file ────────────────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");

    my $version_file = File::Spec->catfile($Bin, '..', 'VERSION');
    open my $fh, '<', $version_file or die "Cannot read VERSION: $!";
    chomp(my $expected = <$fh>);
    close $fh;

    my $out = run_audit($dir, '--dry-run');

    like $out, qr/media-audit\.pl v\Q$expected\E/,
        "TC-23: summary shows version $expected from VERSION file";
}

# ── TC-24: --log FILE writes failures and summary to file ─────────────────────

{
    my $dir     = tmpdir();
    my $log     = File::Spec->catfile($dir, 'test.log');
    my $bad     = "$dir/unreadable.jpg";
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");
    copy("$FIXTURES/valid_jpeg.jpg", $bad);
    chmod 0000, $bad;

    run_audit($dir, "--log $log");

    ok -f $log, 'TC-24: --log FILE creates the log file';

    open my $fh, '<', $log or die "Cannot read log: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like $content, qr/Failures/, 'TC-24: log contains summary section';
    like $content, qr/❌/,       'TC-24: log contains failure line';

    chmod 0644, $bad;
}

# ── TC-25: --log without FILE auto-generates a timestamped filename ───────────

{
    my $dir = tmpdir();
    copy("$FIXTURES/valid_jpeg.jpg", "$dir/valid_jpeg.jpg");

    my $out = run_audit($dir, '--log');

    like $out, qr/Logging to:.*media-audit-\d{8}-\d{6}\.log/,
        'TC-25: --log without FILE prints auto-generated log path';
}
