#!/usr/bin/env bash
# Installs sochi: curl -fsSL https://raw.githubusercontent.com/Chandram-Dutta/sochi/main/install.sh | bash
#
#   SOCHI_VERSION=v0.1.0   install a specific release (default: latest)
#   SOCHI_INSTALL=~/.sochi install location (binary goes in $SOCHI_INSTALL/bin)
#   SOCHI_NO_MODIFY_PATH=1 don't touch shell startup files
set -euo pipefail

repo="Chandram-Dutta/sochi"
asset="sochi-macos-universal.tar.gz"
install_dir="${SOCHI_INSTALL:-$HOME/.sochi}"
version="${SOCHI_VERSION:-latest}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "sochi runs on macOS only."
xcode-select -p >/dev/null 2>&1 || info "warning: no Xcode selected. sochi needs Xcode 16 or later (xcode-select -s /Applications/Xcode.app)."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -n "${SOCHI_ARCHIVE:-}" ]; then
    # Local archive (used to test this script before a release exists).
    cp "$SOCHI_ARCHIVE" "$tmp/$asset"
    [ -f "$SOCHI_ARCHIVE.sha256" ] && cp "$SOCHI_ARCHIVE.sha256" "$tmp/$asset.sha256"
else
    if [ "$version" = "latest" ]; then
        url="https://github.com/$repo/releases/latest/download/$asset"
    else
        url="https://github.com/$repo/releases/download/$version/$asset"
    fi
    bold "Downloading sochi ($version)"
    curl --fail --location --progress-bar --output "$tmp/$asset" "$url" \
        || fail "couldn't download $url. Is there a release yet? See https://github.com/$repo/releases"
    curl --fail --silent --location --output "$tmp/$asset.sha256" "$url.sha256" \
        || fail "couldn't download the checksum for $asset"
fi

if [ -f "$tmp/$asset.sha256" ]; then
    expected="$(awk '{print $1}' "$tmp/$asset.sha256")"
    actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || fail "checksum mismatch for $asset (expected $expected, got $actual)"
fi

tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/sochi" ] || fail "the archive doesn't contain a sochi binary"
mkdir -p "$install_dir/bin"
install -m 0755 "$tmp/sochi" "$install_dir/bin/sochi"
bold "Installed $("$install_dir/bin/sochi" --version) to $install_dir/bin/sochi"

# Startup files refer to $HOME rather than an absolute path, so they survive a renamed home folder.
path_dir="$install_dir/bin"
case "$path_dir" in "$HOME"/*) path_dir="\$HOME${path_dir#"$HOME"}" ;; esac

case ":$PATH:" in
    *":$install_dir/bin:"*) ;;
    *)
        if [ -n "${SOCHI_NO_MODIFY_PATH:-}" ]; then
            info "Add it to your PATH: export PATH=\"$install_dir/bin:\$PATH\""
        else
            case "$(basename "${SHELL:-zsh}")" in
                fish) rc="$HOME/.config/fish/config.fish"; line="fish_add_path \"$path_dir\"" ;;
                bash) rc="$HOME/.bash_profile"; line="export PATH=\"$path_dir:\$PATH\"" ;;
                *) rc="$HOME/.zshrc"; line="export PATH=\"$path_dir:\$PATH\"" ;;
            esac
            mkdir -p "$(dirname "$rc")"
            if ! grep -qsF "$line" "$rc"; then
                printf '\n# sochi\n%s\n' "$line" >> "$rc"
                info "Added $install_dir/bin to your PATH in $rc"
            fi
            info "Open a new terminal (or run: $line), then try: sochi --help"
        fi
        ;;
esac
