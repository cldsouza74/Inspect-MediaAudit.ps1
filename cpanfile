# media-audit — Perl dependency manifest
# Install all dependencies with: cpanm --installdeps .

# ── Required ──────────────────────────────────────────────────────────────────
requires 'Image::ExifTool',         '12.00';
requires 'Digest::SHA',             '6.00';
requires 'File::Path',              '2.09';

# ── Optional ──────────────────────────────────────────────────────────────────
# Parallel::ForkManager — enables --jobs N parallel processing in media-audit.pl
# If not installed the script runs single-threaded with a one-time warning.
recommends 'Parallel::ForkManager', '2.00';

# Win32::API — enables NTFS CreationTime correction on Windows native Perl only.
# Not needed on Linux / macOS / WSL. Silently skipped if absent.
recommends 'Win32::API',            '0.84';

# ── Web UI (Phase 2) ──────────────────────────────────────────────────────────
# Not required for CLI use. Install with: cpanm --installdeps . --with-feature web
feature 'web', 'Web UI' => sub {
    requires 'Mojolicious',         '9.00';
    requires 'DBI',                 '1.643';
    requires 'DBD::SQLite',         '1.70';
};

# ── Development and testing ───────────────────────────────────────────────────
on 'test' => sub {
    requires 'Test::More',          '1.30';
};
