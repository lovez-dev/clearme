#!/bin/sh
# Install clearme from GitHub Releases to /usr/local/bin.
# Usage:
#   Install only:
#     curl -fsSL https://raw.githubusercontent.com/lovez-dev/clearme/main/install.sh | sh
#   Install and run clearme with the remaining arguments:
#     curl -fsSL .../install.sh | sudo bash -s -- --yes --user admin --password '...'
set -eu

REPO=lovez-dev/clearme
PREFIX=/usr/local/bin

command -v curl >/dev/null 2>&1 || { echo "curl is required; install it first" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum (coreutils) is required" >&2; exit 1; }

case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *)
        echo "Unsupported architecture: $(uname -m) (only amd64/arm64 are available)" >&2
        exit 1
        ;;
esac

if [ "$(uname -s)" = "Linux" ]; then
    :
else
    echo "clearme supports Linux only" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ] && [ ! -w "$PREFIX" ]; then
    echo "Root privileges or write access to $PREFIX are required" >&2
    exit 1
fi

BASE="https://github.com/$REPO/releases/latest/download"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

echo "Downloading $BASE/clearme-$ARCH ..."
curl -fL --retry 3 --connect-timeout 15 -o "$TMPDIR/clearme-$ARCH" "$BASE/clearme-$ARCH"
curl -fL --retry 3 --connect-timeout 15 -o "$TMPDIR/sha256sums.txt" "$BASE/sha256sums.txt"

line="$(grep -E " [*]?clearme-$ARCH\$" "$TMPDIR/sha256sums.txt" || true)"
if [ -z "$line" ]; then
    echo "clearme-$ARCH is missing from sha256sums.txt" >&2
    exit 1
fi
(
    cd "$TMPDIR"
    printf '%s\n' "$line" | sha256sum -c -
)

install -m 0755 "$TMPDIR/clearme-$ARCH" "$PREFIX/clearme"
echo "Installed: $PREFIX/clearme"

# Run clearme immediately when arguments are provided.
if [ "$#" -gt 0 ]; then
    "$PREFIX/clearme" "$@"
    exit 0
fi

"$PREFIX/clearme" -V
