# media-audit — Full Project Plan

**Document version:** 2.0
**Date:** 2026-03-31
**Author:** Clive DSouza
**Status:** Active
**Contact:** clive@clivedsouza.com · linkedin.com/in/clive-dsouza-b8734212

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Target Users and Personas](#3-target-users-and-personas)
4. [Use Cases](#4-use-cases)
5. [Current State Assessment](#5-current-state-assessment)
6. [Goals and Success Metrics](#6-goals-and-success-metrics)
7. [Dependencies](#7-dependencies)
8. [Scope](#8-scope)
9. [Architecture Overview](#9-architecture-overview)
10. [Phase 1 — Infrastructure (Detailed)](#10-phase-1--infrastructure-detailed)
11. [Phase 2 — Web UI MVP](#11-phase-2--web-ui-mvp)
12. [Phase 3 — Polish and UX](#12-phase-3--polish-and-ux)
13. [Phase 4 — Release and Portfolio](#13-phase-4--release-and-portfolio)
14. [Risk Register](#14-risk-register)
15. [Definition of Done](#15-definition-of-done)
16. [Open Questions](#16-open-questions)

---

## 1. Executive Summary

media-audit is a bulk media repair tool that fixes the three core problems that make large photo and video libraries unmanageable: wrong file extensions, incorrect or missing timestamps, and meaningless filenames. It has been battle-tested on real-world libraries of 40,000+ files and handles production edge cases including corrupt EXIF, USB I/O errors, and cross-device moves.

The current release is a polished command-line tool available in both Perl (cross-platform, fast) and PowerShell (Windows-native). This plan covers the work needed to take the project from a working CLI tool to a professional-grade open source project with a browser-based UI, automated tests, CI/CD, and a one-command installer — suitable for public release and use as a senior engineering and PM portfolio highlight.

**Immediate priority (2 days):** Phase 1 infrastructure — CI badge, version management, dependency manifest, and installer. This closes the gap between "working scripts on GitHub" and "professional open source project" without requiring the web UI to be complete.

---

## 2. Problem Statement

### Background

Digital photo libraries accumulate over years from multiple sources: phone backups, camera imports, downloaded images, cloud exports, and old CDs. Each source applies its own naming conventions, timestamp formats, and metadata standards. Over time the result is chaos:

- Files named `IMG_4892.jpg`, `image (47).jpg`, `photo_copy_final2.jpg` — unsortable, unsearchable
- Photos dated 1970-01-01 because the camera had no battery or no clock set
- Videos with `.jpg` extensions because a transfer tool renamed them incorrectly
- The same photo appearing three or four times with different names from repeated imports
- EXIF metadata that disagrees with filesystem dates that disagree with filenames
- No reliable way to find "all photos from Christmas 2019" without scrolling through thousands of files

### The gap existing tools leave

Most photo management tools (Lightroom, digiKam, Google Photos, Apple Photos) assume the metadata is already trustworthy. They organise and display what is there. They do not repair what is broken. A photo dated 1970 in Lightroom is still dated 1970 after import — it just appears at the top of every sort. media-audit repairs the metadata before organisation, making every downstream tool work correctly.

### What media-audit does

In a single pass, media-audit:

1. **Validates file signatures** — reads the first bytes of every file to verify the extension matches the actual content. A JPEG saved as `.mov` is renamed to `.jpg` before any other processing.

2. **Repairs timestamps** — reads every available date source (EXIF `DateTimeOriginal`, QuickTime `CreateDate`, filesystem `mtime`), filters out implausible values (before 1970, more than 5 years in the future), selects the oldest valid date as the canonical capture time, and writes it back to every date field.

3. **Renames files canonically** — every file becomes `YYYYMMDD_HHmmss.ext`. The library sorts chronologically. Duplicates become immediately visible.

4. **Removes exact duplicates** (optional) — size-bucketed SHA256 comparison finds byte-identical files. The copy with the richest metadata provenance is kept; the rest are deleted.

5. **Sorts into year folders** (companion script) — after auditing, `sort-by-year.pl` moves files into `YYYY/` subfolders within the same directory.

---

## 3. Target Users and Personas

### Persona 1 — The Technical Home User

**Name:** Alex
**Background:** Software developer or sysadmin. Has a NAS or external drives with 10–50k photos accumulated over 15 years from multiple phones, cameras, and cloud exports.
**Pain:** Library is a mess. Has tried Lightroom but the underlying file chaos makes it worse not better.
**Comfort level:** Runs scripts from a terminal. Has Perl or Python installed. Comfortable with flags and dry-run modes.
**Goal:** One-time cleanup of the full library, then ongoing maintenance as new photos arrive.
**How they find the tool:** GitHub, Hacker News, Reddit r/DataHoarder or r/selfhosted.

### Persona 2 — The Non-Technical Photographer

**Name:** Sam
**Background:** Hobbyist or semi-professional photographer. Has 20–100k photos on an external drive. Not a developer.
**Pain:** Same as Alex but has no idea how to run a Perl script. Has heard of ExifTool but never used it.
**Comfort level:** Can open a browser. Cannot use a terminal confidently.
**Goal:** Fix the library without learning the command line.
**How they find the tool:** A blog post or YouTube video about photo organisation. Word of mouth.
**Blocker today:** No web UI. This persona cannot use the current version.

### Persona 3 — The IT Administrator

**Name:** Morgan
**Background:** IT or systems administrator at a small company or school. Responsible for a shared photo drive of 100k+ files from multiple contributors.
**Pain:** Shared drives accumulate duplicate files and inconsistent naming from many users over years.
**Comfort level:** Comfortable with scripts, scheduled tasks, and command-line tools.
**Goal:** Automate regular cleanup runs. Wants `--dry-run` reports emailed to them, or a web dashboard showing last run status.
**How they find the tool:** Web search for "bulk photo rename exif repair script".

---

## 4. Use Cases

### UC-01 — Dry-run audit before committing changes

**Actor:** Technical user (Alex, Morgan)
**Preconditions:** Script installed. Target folder exists and contains media files.
**Trigger:** User wants to understand what the script would change before touching any files.

**Basic flow:**
1. User runs `perl media-audit.pl --path /mnt/e/Photos --dry-run --recurse`
2. Script scans all files and prints what it would do per file — extension fix, timestamp correction, rename
3. Script prints a summary: files that would be renamed, metadata that would be written, duplicates that would be removed
4. No files are modified

**Postconditions:** User has a complete picture of what will change. No files touched.
**Alternative flow:** User runs with `--dedup` to also preview duplicate removal.

---

### UC-02 — Full library audit and repair

**Actor:** Technical user (Alex, Morgan)
**Preconditions:** Dry-run reviewed and accepted. Backup exists or user accepts the risk.
**Trigger:** User is ready to apply changes.

**Basic flow:**
1. User runs `perl media-audit.pl --path /mnt/e/Photos --recurse --jobs 4 --dedup`
2. Script processes all files in parallel — fixes extensions, repairs timestamps, renames, removes duplicates
3. Progress printed per file with percentage complete
4. Summary printed on completion: files processed, renamed, metadata written, duplicates removed, space freed, failures

**Postconditions:** Library has canonical filenames, consistent timestamps, no byte-identical duplicates.
**Alternative flow A:** A file cannot be read (USB error) — script logs a warning and continues.
**Alternative flow B:** All suffix slots exhausted (.001–.999) — script logs failure, increments error counter, continues.
**Alternative flow C:** File disappears between scan and processing — counted as Skip, not Failure.

---

### UC-03 — Sort audited files into year folders

**Actor:** Technical user
**Preconditions:** media-audit has run. Files are named in `YYYYMMDD_HHmmss.ext` format.
**Trigger:** User wants to organise the library into year subfolders.

**Basic flow:**
1. User runs `perl sort-by-year.pl --path /mnt/e/Photos --dry-run`
2. Script previews all moves with SRC/DST per file
3. User runs without `--dry-run` to apply
4. Files moved into `PATH/YYYY/` subfolders. Year folders created on demand.

**Postconditions:** Files organised by year. Already-sorted year folders untouched on re-run.
**Alternative flow:** File already exists in target year folder — appended with `.001` suffix rather than overwriting.

---

### UC-04 — Re-run on same folder safely

**Actor:** Any user
**Preconditions:** Script has been run before on this folder.
**Trigger:** New files added to the folder, or user wants to verify the folder is clean.

**Basic flow:**
1. User runs the same command again
2. Files already in canonical format are processed but not renamed (no-op rename)
3. Already-sorted year folders skipped by sort-by-year.pl in `--recurse` mode
4. Only new or unprocessed files are changed

**Postconditions:** No double-processing. Script is safe to schedule as a recurring task.

---

### UC-05 — Browser-based audit (web UI — Phase 2)

**Actor:** Non-technical user (Sam)
**Preconditions:** Web server started (`perl web/app.pl`). Browser open to `http://localhost:7070`.
**Trigger:** User wants to fix their photo library without using a terminal.

**Basic flow:**
1. User opens browser
2. Navigates to the folder using the directory picker
3. Selects options: Dry Run, Recurse, Dedup
4. Clicks Run
5. Progress streams live to the browser — per-file lines, running counters, elapsed time
6. Summary displayed on completion with all counters
7. User downloads log as `.txt` if needed

**Postconditions:** Library repaired. User never opened a terminal.
**Alternative flow:** User clicks Stop — job is cancelled cleanly, partial progress shown.

---

### UC-06 — Review previous runs (web UI — Phase 3)

**Actor:** Any user
**Preconditions:** Web UI. At least one previous job run.
**Trigger:** User wants to review what happened in a past run.

**Basic flow:**
1. User opens History tab
2. List of past jobs shown: date, path, duration, file count, error count
3. User clicks a job to view full log and summary

**Postconditions:** User can audit any past run without keeping manual log files.

---

### UC-07 — Install on a new machine

**Actor:** Any user
**Preconditions:** Linux/macOS/WSL or Windows machine. Internet connection.
**Trigger:** User wants to install media-audit for the first time.

**Basic flow (Linux/macOS/WSL):**
1. User runs `./install.sh`
2. Script checks Perl version, installs cpanm if needed, installs all dependencies, copies scripts to `~/bin`
3. User runs `media-audit --help` to verify

**Basic flow (Windows):**
1. User runs `.\Install.ps1` in PowerShell 7
2. Script checks PowerShell version, checks exiftool on PATH, installs Strawberry Perl if needed, installs CPAN dependencies
3. User runs `media-audit --help` to verify

**Postconditions:** Tool installed and working. User did not need to manually manage any dependencies.

---

## 5. Current State Assessment

### What works and is production-tested

| Feature | Status | Notes |
|---|---|---|
| Magic-number signature validation | ✅ Solid | Tested on 40k+ files |
| EXIF/QuickTime timestamp extraction | ✅ Solid | FastScan mode, all edge cases handled |
| Date sanity filtering (1970–now+5yr) | ✅ Solid | MAX_SANE bug fixed in v1.2.0 |
| Canonical rename (YYYYMMDD_HHmmss) | ✅ Solid | Collision suffixing .001–.999 |
| Size-bucketed SHA256 dedup | ✅ Solid | ~90% I/O reduction, provenance keeper |
| Parallel processing (Perl) | ✅ Solid | --jobs N via Parallel::ForkManager |
| Missing-file skip | ✅ Solid | Counts as Skip not Failure |
| USB I/O error handling in dedup | ✅ Solid | eval wrapper, logs warning, continues |
| Failure always-print | ✅ Solid | Not throttled by report_every |
| Sort into year folders | ✅ Solid | Re-run safe, collision handled |
| Dry-run mode | ✅ Solid | All scripts, all paths |
| Documentation | ✅ Good | README, README-perl, MANUAL, CHANGELOG |

### Gaps

| Gap | Impact | Phase to fix |
|---|---|---|
| No automated tests | Silent regressions possible | Phase 1 |
| No installer | Manual setup required | Phase 1 |
| Version hardcoded in 3 files | Version drift between scripts | Phase 1 |
| No CI/CD | No automated quality gate | Phase 1 |
| No cpanfile | Dependencies not declared formally | Phase 1 |
| No web UI | Non-technical users (Persona 2) cannot use the tool | Phase 2 |
| No job history | Users must keep manual logs | Phase 3 |
| Error messages are technical | "Bad IFD" means nothing to Persona 2 | Phase 3 |
| PS1 script drifting from Perl | Maintenance liability long term | Accepted — PS1 maintenance-only |

---

## 6. Goals and Success Metrics

### Phase 1 Goals

| Goal | Metric | Target |
|---|---|---|
| Tests passing | `prove -lr t/` exit code | 0 on Linux, macOS, Windows |
| CI green | GitHub Actions badge | Green on main branch |
| One-command install | Steps to install from scratch | 1 command on Linux/WSL, 1 on Windows |
| Single version source | Files reading hardcoded version | 0 |

### Phase 2 Goals

| Goal | Metric | Target |
|---|---|---|
| Non-technical usability | Steps to run an audit from browser | Open browser → pick folder → click Run |
| Live progress | Latency from script output to browser | < 2 seconds |
| Long job stability | SSE connection drop rate on 60min job | 0 drops |

### Portfolio Goals

| Goal | Metric |
|---|---|
| Demonstrates engineering depth | Commit history shows real bugs found and fixed in production |
| Demonstrates PM skills | PLAN.md shows planning, use cases, risk management before coding |
| Demonstrates full-stack | Perl core + web server + HTML/CSS/JS + SQL + CI |
| Demonstrates real-world testing | 40,000+ files processed, edge cases documented in CHANGELOG |

---

## 7. Dependencies

### Technical Dependencies — Perl scripts

| Dependency | Version | Required | Purpose | Install |
|---|---|---|---|---|
| Perl | 5.16+ | Yes | Runtime | Pre-installed Linux/macOS; Strawberry Perl on Windows |
| Image::ExifTool | 12.00+ | Yes | Metadata read/write | `cpanm Image::ExifTool` |
| Digest::SHA | 6.00+ | Yes | SHA256 for dedup | Core module — included with Perl 5.10+ |
| File::Path | 2.09+ | Yes | Directory creation | Core module |
| File::Find | Any | Yes | Recursive file scan | Core module |
| File::Spec | Any | Yes | Cross-platform paths | Core module |
| Getopt::Long | Any | Yes | Argument parsing | Core module |
| POSIX | Any | Yes | floor() for time formatting | Core module |
| Parallel::ForkManager | 2.00+ | Optional | `--jobs N` parallel processing | `cpanm Parallel::ForkManager` |
| Win32::API | 0.84+ | Optional | NTFS CreationTime on Windows | `cpanm Win32::API` |

### Technical Dependencies — Web UI (Phase 2)

| Dependency | Version | Required | Purpose | Install |
|---|---|---|---|---|
| Mojolicious | 9.00+ | Yes | Web framework + HTTP server | `cpanm Mojolicious` |
| DBD::SQLite | 1.70+ | Yes | Job history persistence | `cpanm DBD::SQLite` |
| DBI | 1.643+ | Yes | Database interface | `cpanm DBI` |

### Technical Dependencies — PowerShell script

| Dependency | Version | Required | Purpose |
|---|---|---|---|
| PowerShell | 7.0+ | Yes | Runtime |
| exiftool.exe | Any current | Yes | Metadata read/write |
| .NET | Bundled with PS7 | Yes | SHA256, FileInfo, parallel |

### Technical Dependencies — Development and CI

| Dependency | Purpose | Install |
|---|---|---|
| Test::More | Perl unit test framework | Core module |
| Test::Mojo | HTTP route testing | `cpanm Test::Mojo` |
| cpanm | Dependency installer | `cpan App::cpanminus` |
| GitHub Actions | CI runner | Free — github.com |
| prove | Test runner | Bundled with Perl |

### Non-Technical Dependencies

| Dependency | Status | Notes |
|---|---|---|
| GitHub account | ✅ Exists | cldsouza74 |
| Git installed locally | ✅ Assumed | |
| Custom domain email | ❌ Needed | For professional contact info in project |
| LinkedIn profile updated | ❌ Needed | "Open to roles" signal, project linked |
| Test fixture media files | ❌ Needed | Small binary files committed to `t/fixtures/` |

---

## 8. Scope

### In scope — Phase 1

- `VERSION` file — single source of truth for version number
- `cpanfile` — formal dependency declaration
- Minimal test suite — 6 key tests covering critical code paths
- GitHub Actions CI — runs tests on push and pull request
- `install.sh` — Linux/macOS/WSL one-command installer
- `Install.ps1` — Windows one-command installer
- Update README with CI badge and install instructions
- Commit `PLAN.md` to git

### In scope — Phase 2

- Local web application on `127.0.0.1:7070`
- Server-side directory browser
- Job configuration form (all existing CLI flags)
- Live progress streaming via SSE
- Summary panel on completion
- Download log as `.txt`
- SQLite job storage

### In scope — Phase 3

- Job history list and detail view
- Settings persistence
- User-friendly error message mapping
- Job cancellation
- Dark/light mode

### In scope — Phase 4

- Documentation updated for web UI
- v2.0.0 tagged and released
- GitHub release notes

### Out of scope — all phases

- Cloud storage integration (S3, Google Drive, iCloud)
- Mobile app or mobile-responsive UI beyond basic usability
- Remote execution on a different machine
- Multi-user access or authentication
- Photo viewer or thumbnail preview
- Python or Node.js rewrite
- CPAN distribution
- Video transcoding or image editing
- Scheduled/automated runs (cron integration)
- Email notifications

---

## 9. Architecture Overview

```
Browser (localhost:7070)
    │
    │  HTTP + SSE (127.0.0.1 only)
    ▼
Mojolicious Web Server
    ├── GET  /                  Main UI
    ├── GET  /browse?path=      Directory picker
    ├── POST /jobs              Start job → returns job_id
    ├── GET  /jobs/:id/stream   SSE progress feed
    ├── GET  /jobs/:id          Job status + summary
    ├── GET  /jobs              History list
    └── POST /jobs/:id/stop     Cancel job
         │
         │  fork + pipe
         ▼
    Audit Worker Process
    (media-audit.pl core logic)
         │
         ▼
    SQLite (~/.media-audit/jobs.db)
```

Key decisions:
- **Mojolicious** — Perl web framework, same language as audit core, built-in SSE, zero extra server binary
- **SSE not WebSocket** — progress is one-directional, SSE is simpler and auto-reconnects
- **SQLite** — no database server, single file, right scale for a single-user local tool
- **HTMX + vanilla CSS** — no npm, no build pipeline, no node_modules, works everywhere
- **Fork worker** — long jobs (up to 60 min) cannot block the web server thread

Full architecture detail: see Section 9 of this document and inline code comments.

---

## 10. Phase 1 — Infrastructure (Detailed)

**Goal:** Close all professional credibility gaps in the existing CLI tool.
**Duration:** 2 days
**Prerequisite:** None — start immediately.

---

### Task 1.1 — VERSION file

**What:** Single file at the repo root containing the current version number.

**Why:** Version is currently hardcoded as a string inside three separate scripts. When a version bump happens, all three must be edited manually. One will be forgotten. This has already happened (Perl is v1.2.2, PS1 is v1.2.1, sort is v1.3.2).

**Acceptance criteria:**
- `VERSION` file exists at repo root containing `1.4.0`
- `media-audit.pl` reads version from `VERSION` at startup — no hardcoded string
- `media-audit.ps1` reads version from `VERSION` at startup
- `sort-by-year.pl` reads version from `VERSION` at startup
- All three scripts print the same version number in their summary output
- Bumping the version requires editing exactly one file

**Implementation:**

```
VERSION   ← contains: 1.4.0
```

Perl read:
```perl
use FindBin qw($Bin);
my $VERSION = do {
    open my $fh, '<', "$Bin/VERSION" or die "Cannot read VERSION: $!";
    chomp(my $v = <$fh>);
    $v
};
```

PowerShell read:
```powershell
$VERSION = (Get-Content "$PSScriptRoot\VERSION" -Raw).Trim()
```

**Estimated time:** 1 hour
**Risk:** Low

---

### Task 1.2 — cpanfile

**What:** Formal declaration of all Perl module dependencies with minimum versions.

**Why:** Anyone cloning the repo today has no machine-readable way to know what modules are needed. `cpanfile` enables `cpanm --installdeps .` — one command installs everything.

**Acceptance criteria:**
- `cpanfile` exists at repo root
- Lists all required and optional modules with minimum versions
- `cpanm --installdeps .` succeeds on a clean Perl install
- Web UI dependencies listed under a `feature 'web'` block (not required for CLI-only install)

**Content:**
```perl
requires 'Image::ExifTool',        '12.00';
requires 'Digest::SHA',            '6.00';
requires 'File::Path',             '2.09';

recommends 'Parallel::ForkManager','2.00';
recommends 'Win32::API',           '0.84';

feature 'web', 'Web UI' => sub {
    requires 'Mojolicious',        '9.00';
    requires 'DBI',                '1.643';
    requires 'DBD::SQLite',        '1.70';
};

on 'test' => sub {
    requires 'Test::More',         '1.30';
};
```

**Estimated time:** 30 minutes
**Risk:** Low

---

### Task 1.3 — Test fixtures

**What:** Small binary media files committed to `t/fixtures/` that represent known test cases.

**Why:** Tests need real files to process. Synthetic fixtures with known properties let tests assert exact expected outcomes.

**Required fixtures:**

| File | Description | Expected outcome |
|---|---|---|
| `valid_jpeg.jpg` | Real JPEG, correct extension, has EXIF DateTimeOriginal | Extension unchanged, EXIF date used |
| `wrong_ext.png` | Real PNG saved with `.jpg` extension | Extension corrected to `.png` |
| `no_exif.jpg` | JPEG with no embedded metadata | Filesystem mtime used, Fallback-only provenance |
| `future_date.jpg` | JPEG with EXIF date 10 years in future | Future date rejected, fallback used, warning logged |
| `corrupt_date.jpg` | JPEG with EXIF year 0001 | Corrupt date rejected, fallback used, warning logged |
| `duplicate_a.jpg` | Byte-identical pair | One deleted by dedup, one kept |
| `duplicate_b.jpg` | Byte-identical pair (copy of duplicate_a) | Deleted by dedup |
| `canonical.jpg` | Already named `20231225_143022.jpg` with matching EXIF | No rename, no metadata write — no-op |

**How to generate:** `t/fixtures/generate.pl` documents the exact commands used to create each fixture. Fixtures committed as binary files — do not regenerate automatically during tests.

**Estimated time:** 2 hours (creating and verifying the fixtures)
**Risk:** Medium — creating genuinely corrupt EXIF fixtures requires care

---

### Task 1.4 — Test suite

**What:** Six test files in `t/` covering the critical code paths.

**Why:** All production bugs found so far — the `$using:Dedup` silent failure, the throttle-swallowed failures, the SHA256 crash on I/O error, wrong provenance classification — could have been caught by tests. Without tests, every future change risks reintroducing them silently.

**Test files:**

**`t/01_signature.t`** — magic-number detection
- `valid_jpeg.jpg` identified as JPEG ✓
- `wrong_ext.png` identified as PNG despite `.jpg` extension ✓
- Rename applied correctly ✓

**`t/02_date_extraction.t`** — timestamp parsing and sanity filtering
- Valid EXIF date extracted correctly ✓
- Future date (10yr ahead) rejected ✓
- Corrupt date (year 0001) rejected ✓
- Fallback to mtime when no EXIF ✓
- Oldest valid date selected when multiple sources ✓

**`t/03_rename.t`** — canonical rename logic
- File renamed to `YYYYMMDD_HHmmss.ext` format ✓
- Collision produces `.001` suffix ✓
- Second collision produces `.002` suffix ✓
- Already-canonical filename unchanged (no-op) ✓

**`t/04_dedup.t`** — deduplication
- `duplicate_a.jpg` and `duplicate_b.jpg` detected as duplicates ✓
- One file kept, one deleted ✓
- `valid_jpeg.jpg` (unique) not deleted ✓
- Unreadable file during checksum logs warning and continues — does not crash ✓

**`t/05_sort_by_year.t`** — year sorting
- `20231225_143022.jpg` moved to `2023/` subfolder ✓
- File not in canonical format skipped with warning ✓
- Year folder created if it does not exist ✓
- Re-run on same folder does not double-move ✓
- Collision in target folder produces `.001` suffix ✓

**`t/06_failures.t`** — failure handling (critical regression tests)
- Failure at file #42 with `report_every=100` prints immediately ✓
- SHA256 crash on I/O error logs warning and continues — does not crash ✓
- File deleted between scan and processing counted as Skip not Failure ✓

**All tests run in a temp directory. No fixture files are modified. Temp dir cleaned up after each test.**

**Estimated time:** 1 day
**Risk:** Medium — test setup/teardown boilerplate takes time; fixture file creation must be done first (Task 1.3)

---

### Task 1.5 — GitHub Actions CI

**What:** Automated test run on every push and pull request to main.

**Why:** Tests are only useful if they run automatically. A green badge on the README is a visible professional signal.

**File:** `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]

    steps:
      - uses: actions/checkout@v4

      - name: Install cpanm
        run: curl -L https://cpanmin.us | perl - App::cpanminus

      - name: Install dependencies
        run: cpanm --installdeps .

      - name: Run tests
        run: prove -lr t/
```

**README badge:**
```markdown
[![CI](https://github.com/cldsouza74/media-audit/actions/workflows/ci.yml/badge.svg)](https://github.com/cldsouza74/media-audit/actions)
```

**Estimated time:** 2 hours
**Risk:** Low — standard GitHub Actions pattern. Windows cpanm install may need adjustment.

---

### Task 1.6 — install.sh (Linux / macOS / WSL)

**What:** Shell script that installs all dependencies and copies scripts to PATH in one command.

**Acceptance criteria:**
- Checks Perl >= 5.16 — exits with clear message if not found
- Installs `cpanm` if not present
- Runs `cpanm --installdeps .`
- Copies `media-audit.pl` and `sort-by-year.pl` to `~/bin/` as `media-audit` and `sort-by-year` (no `.pl` extension)
- Adds `~/bin` to PATH in `.bashrc`/`.zshrc` if not already there
- Prints a verification command at the end: `media-audit --help`
- `--system` flag installs to `/usr/local/bin` instead (requires sudo)

**Estimated time:** 3 hours
**Risk:** Low — standard shell scripting

---

### Task 1.7 — Install.ps1 (Windows)

**What:** PowerShell installer for Windows users.

**Acceptance criteria:**
- Checks PowerShell >= 7 — exits with download link if not found
- Checks `exiftool.exe` on PATH — prints download instructions if not found
- Checks Strawberry Perl — prints download link if not found
- Runs `cpanm --installdeps .`
- Copies scripts to a directory on PATH or adds the script directory to user PATH
- Prints verification command at the end

**Estimated time:** 3 hours
**Risk:** Low-medium — PATH manipulation in PowerShell needs testing on clean Windows install

---

### Task 1.8 — README and CHANGELOG updates

**What:** Update README with CI badge, install instructions, and contact info. Add v1.4.0 CHANGELOG entry.

**Acceptance criteria:**
- CI badge visible at top of README
- "Install" section with one-liner for Linux/macOS/WSL and Windows
- Contact footer: name, email, LinkedIn
- CHANGELOG v1.4.0 entry covering all Phase 1 changes

**Estimated time:** 1 hour
**Risk:** Low

---

### Phase 1 — Task Summary

| Task | Estimated time | Risk | Dependency |
|---|---|---|---|
| 1.1 VERSION file | 1 hour | Low | None |
| 1.2 cpanfile | 30 min | Low | None |
| 1.3 Test fixtures | 2 hours | Medium | None |
| 1.4 Test suite | 1 day | Medium | 1.3 |
| 1.5 GitHub Actions CI | 2 hours | Low | 1.4 |
| 1.6 install.sh | 3 hours | Low | 1.2 |
| 1.7 Install.ps1 | 3 hours | Low-Medium | 1.2 |
| 1.8 README + CHANGELOG | 1 hour | Low | All above |
| **Total** | **~2 days** | | |

**Order of execution:**
1. Tasks 1.1, 1.2, 1.3 in parallel (no dependencies between them)
2. Task 1.4 after 1.3
3. Tasks 1.5, 1.6, 1.7 after 1.4 (can be parallel)
4. Task 1.8 last

---

## 11. Phase 2 — Web UI MVP

**Goal:** Non-technical users can run a full audit from a browser.
**Duration:** 2 weeks
**Prerequisite:** Phase 1 complete and CI green.

| Task | Estimate |
|---|---|
| Mojolicious app skeleton + routing | 1 day |
| SQLite schema + job model | 1 day |
| Directory browser (`/browse` + HTMX panel) | 1 day |
| Job configuration form | 1 day |
| Job runner (fork worker, capture output) | 2 days |
| SSE progress stream endpoint | 1 day |
| Progress UI (live feed, counters, elapsed timer) | 2 days |
| Summary panel + download log button | 1 day |
| CSS layout and colour coding | 1 day |
| **Total** | **~10 days** |

---

## 12. Phase 3 — Polish and UX

**Goal:** Job history, settings, cancellation, error UX improvements.
**Duration:** 1 week
**Prerequisite:** Phase 2 complete.

| Task | Estimate |
|---|---|
| Job history list + detail view | 1 day |
| Settings persistence (last path, last options) | 1 day |
| User-friendly error message mapping | 1 day |
| Job cancellation (Stop button + SIGTERM) | 1 day |
| Dark/light mode toggle | 0.5 day |
| Disk space pre-flight check | 0.5 day |
| **Total** | **~5 days** |

---

## 13. Phase 4 — Release and Portfolio

**Goal:** v2.0.0 public release. Portfolio documentation complete.
**Duration:** 3–5 days
**Prerequisite:** Phase 3 complete.

| Task | Estimate |
|---|---|
| MANUAL.md web UI section | 1 day |
| README web UI quick start | 0.5 day |
| CHANGELOG v2.0.0 entry | 1 hour |
| Final test pass (Windows, Linux, macOS) | 1 day |
| GitHub Sponsors setup | 30 min |
| v2.0.0 tag + GitHub release notes | 2 hours |
| LinkedIn post about the release | 1 hour |
| **Total** | **~4 days** |

---

## 14. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Windows `fork()` not supported | High | High | Use temp file written by worker + tailed by server instead of pipe. Test on Windows before Phase 2 commit. |
| SSE drops on long jobs | Medium | High | Write progress to SQLite as it arrives. On reconnect, stream from last stored position. |
| Extracting logic breaks CLI scripts | Medium | High | Phase 1 tests must pass before any refactor. Run full regression on fixture files after each change. |
| Test fixture creation is harder than expected | Medium | Medium | Start with 3 fixtures (valid JPEG, wrong extension, duplicate pair) — enough for CI. Add others incrementally. |
| UI complexity creep in Phase 2 | Medium | Medium | No feature starts Phase 2 that belongs in Phase 3. Strict scope gate at Phase 2 start. |
| 5-week timeline too optimistic | Medium | Low | Phase 1 is independently valuable — ship it regardless. Web UI is bonus. |
| HTMX insufficient for progress UI | Low | Medium | Fall back to vanilla JS EventSource API for SSE. HTMX handles forms and navigation; raw JS handles the stream. |
| SQLite corruption on job cancel | Low | Medium | All SQLite writes in transactions. Job status written in `finally` block. |

---

## 15. Definition of Done

### Phase 1 complete when:
- [ ] `prove -lr t/` passes locally on Linux/WSL
- [ ] GitHub Actions CI is green on main
- [ ] `./install.sh` installs successfully on a clean Linux/WSL environment
- [ ] `.\Install.ps1` installs successfully on Windows
- [ ] All three scripts read version from `VERSION` — no hardcoded strings
- [ ] README shows green CI badge
- [ ] CHANGELOG has v1.4.0 entry
- [ ] PLAN.md committed to main

### Phase 2 complete when:
- [ ] User can open browser, pick a folder, run a dry-run audit, see live progress, view summary, download log — without touching a terminal
- [ ] SSE stream runs without drops on a 60-minute job
- [ ] All Phase 1 tests still pass

### Phase 3 complete when:
- [ ] Job history persists across server restarts
- [ ] Running job can be cancelled cleanly
- [ ] All Phase 1 tests still pass

### Phase 4 complete when:
- [ ] v2.0.0 tagged on GitHub
- [ ] MANUAL.md covers web UI
- [ ] GitHub Sponsors page live
- [ ] LinkedIn updated with project link

### Professional grade when all of the above, plus:
- [ ] No known bugs in the critical path
- [ ] Commit history tells a coherent story of development
- [ ] Contact info visible in README, web UI footer, and POD

---

## 16. Open Questions

| Question | Owner | Status |
|---|---|---|
| Custom domain email — which domain? | Clive | Open |
| Web UI port — 7070 or configurable? | Clive | Proposed: default 7070, `--port` flag to override |
| Windows worker process — temp file or named pipe? | Clive | Investigate before Phase 2 starts |
| GitHub Sponsors — set up now or at Phase 4? | Clive | Recommended: Phase 4 |
| LinkedIn "open to roles" — update now? | Clive | Recommended: now, before Phase 1 ships |
| PS1 script — maintenance-only or deprecate? | Clive | Proposed: maintenance-only, no new features |

---

*This document is the authoritative plan for the media-audit project. Update it when decisions change — do not let it drift from reality. Last updated: 2026-03-31.*
