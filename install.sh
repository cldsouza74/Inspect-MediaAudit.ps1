#!/usr/bin/env bash
# install.sh — media-audit installer for Linux, macOS, and WSL
#
# Usage:
#   ./install.sh           # installs to ~/bin (user install, no sudo)
#   ./install.sh --system  # installs to /usr/local/bin (requires sudo)
#   ./install.sh --help

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()    { echo -e "${CYAN}$*${RESET}"; }
success() { echo -e "${GREEN}✅ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠️  $*${RESET}"; }
error()   { echo -e "${RED}❌ $*${RESET}" >&2; }
die()     { error "$*"; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────
SYSTEM_INSTALL=0

for arg in "$@"; do
    case "$arg" in
        --system) SYSTEM_INSTALL=1 ;;
        --help|-h)
            echo "Usage: ./install.sh [--system]"
            echo ""
            echo "  (no flag)   Install to ~/bin — no sudo required"
            echo "  --system    Install to /usr/local/bin — requires sudo"
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ── Banner ───────────────────────────────────────────────────────────────────
VERSION=$(cat "$(dirname "$0")/VERSION" 2>/dev/null || echo "unknown")
echo ""
info "══════════════════════════════════════════════"
info "  media-audit v${VERSION} — installer"
info "══════════════════════════════════════════════"
echo ""

# ── Step 1: Check Perl ───────────────────────────────────────────────────────
info "Checking Perl..."

if ! command -v perl &>/dev/null; then
    error "Perl not found."
    echo ""
    echo "  Linux (Debian/Ubuntu):  sudo apt install perl"
    echo "  macOS:                  brew install perl"
    echo "  Windows/WSL:            https://strawberryperl.com"
    echo ""
    die "Install Perl 5.16+ and re-run this script."
fi

PERL_VERSION=$(perl -e 'printf "%vd", $^V')
PERL_MAJOR=$(perl -e 'print $]')

if perl -e 'exit($] < 5.016 ? 1 : 0)'; then
    success "Perl $PERL_VERSION found"
else
    die "Perl $PERL_VERSION is too old. Perl 5.16 or higher is required."
fi

# ── Step 2: Check / install cpanm ────────────────────────────────────────────
info "Checking cpanm..."

if ! command -v cpanm &>/dev/null; then
    # Also check common local Perl paths
    for candidate in "$HOME/perl5/bin/cpanm" "$HOME/bin/cpanm" "/usr/local/bin/cpanm"; do
        if [ -x "$candidate" ]; then
            export PATH="$(dirname "$candidate"):$PATH"
            break
        fi
    done
fi

if ! command -v cpanm &>/dev/null; then
    warn "cpanm not found — attempting to install..."

    # Try package manager first (no network CPAN build required)
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y cpanminus 2>/dev/null && success "cpanm installed via apt" \
            || true
    elif command -v brew &>/dev/null; then
        brew install cpanminus 2>/dev/null && success "cpanm installed via brew" \
            || true
    fi

    # Fallback: bootstrap from cpanmin.us into ~/bin
    if ! command -v cpanm &>/dev/null; then
        if command -v curl &>/dev/null; then
            curl -sL https://cpanmin.us -o "$HOME/bin/cpanm" \
                && chmod +x "$HOME/bin/cpanm" \
                && export PATH="$HOME/bin:$PATH" \
                || die "Failed to install cpanm. Try: sudo apt install cpanminus"
        elif command -v wget &>/dev/null; then
            wget -qO "$HOME/bin/cpanm" https://cpanmin.us \
                && chmod +x "$HOME/bin/cpanm" \
                && export PATH="$HOME/bin:$PATH" \
                || die "Failed to install cpanm."
        else
            die "Cannot install cpanm. Install manually: sudo apt install cpanminus"
        fi
    fi
fi

success "cpanm found: $(cpanm --version 2>&1 | head -1)"

# ── Step 3: Install Perl dependencies ────────────────────────────────────────
info "Installing Perl dependencies from cpanfile..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SCRIPT_DIR/cpanfile" ]; then
    die "cpanfile not found in $SCRIPT_DIR — is this the media-audit repo?"
fi

cpanm --installdeps "$SCRIPT_DIR" \
    || die "Dependency install failed. Check the errors above."

success "Perl dependencies installed"

# ── Step 4: Check exiftool (informational — only needed for media-audit.ps1) ─
info "Checking exiftool..."

if command -v exiftool &>/dev/null; then
    success "exiftool $(exiftool -ver) found"
else
    warn "exiftool not found — not required for Perl scripts (Image::ExifTool is used directly)"
    warn "Only needed if you also use media-audit.ps1"
fi

# ── Step 5: Install scripts ──────────────────────────────────────────────────
if [ "$SYSTEM_INSTALL" -eq 1 ]; then
    INSTALL_DIR="/usr/local/bin"
    info "Installing to $INSTALL_DIR (system install — may prompt for password)..."
    SUDO="sudo"
else
    INSTALL_DIR="$HOME/bin"
    info "Installing to $INSTALL_DIR (user install)..."
    mkdir -p "$INSTALL_DIR"
    SUDO=""
fi

# Copy scripts without .pl extension so they run as plain commands
# VERSION file must travel with the scripts — FindBin locates it relative to script
$SUDO cp "$SCRIPT_DIR/media-audit.pl"  "$INSTALL_DIR/media-audit"
$SUDO cp "$SCRIPT_DIR/sort-by-year.pl" "$INSTALL_DIR/sort-by-year"
$SUDO cp "$SCRIPT_DIR/VERSION"         "$INSTALL_DIR/VERSION"
$SUDO chmod +x "$INSTALL_DIR/media-audit" "$INSTALL_DIR/sort-by-year"

success "Scripts installed to $INSTALL_DIR"

# ── Step 6: PATH check (user install only) ───────────────────────────────────
if [ "$SYSTEM_INSTALL" -eq 0 ]; then
    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        warn "$HOME/bin is not on your PATH"

        # Detect shell and update the right profile file
        PROFILE=""
        if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
            PROFILE="$HOME/.zshrc"
        else
            PROFILE="$HOME/.bashrc"
        fi

        echo ""
        info "Adding $HOME/bin to PATH in $PROFILE..."
        echo '' >> "$PROFILE"
        echo '# media-audit' >> "$PROFILE"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$PROFILE"
        success "PATH updated in $PROFILE"
        warn "Run: source $PROFILE  (or open a new terminal) to apply"
    fi
fi

# ── Step 7: Verify ───────────────────────────────────────────────────────────
echo ""
info "──────────────────────────────────────────────"
info "  Verifying installation..."
info "──────────────────────────────────────────────"

# Run from INSTALL_DIR directly to avoid PATH issues in same session
if "$INSTALL_DIR/media-audit" --help &>/dev/null; then
    success "media-audit — OK"
else
    die "media-audit failed to run. Check errors above."
fi

if "$INSTALL_DIR/sort-by-year" --help &>/dev/null; then
    success "sort-by-year — OK"
else
    die "sort-by-year failed to run. Check errors above."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
info "══════════════════════════════════════════════"
success "media-audit v${VERSION} installed successfully"
info "══════════════════════════════════════════════"
echo ""
echo "  Quick start:"
echo "    media-audit --path /path/to/photos --dry-run --recurse"
echo "    sort-by-year --path /path/to/photos --dry-run"
echo ""
echo "  Full docs: $(dirname "$0")/MANUAL.md"
echo ""
