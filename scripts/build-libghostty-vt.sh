#!/bin/bash
# Build libghostty-vt for iOS arm64 using Zig cross-compilation.
#
# Prerequisites:
#   - Zig installed (brew install zig)
#   - ghostty source cloned
#
# Usage:
#   ./scripts/build-libghostty-vt.sh /path/to/ghostty/source
#
# Output:
#   Vendor/libghostty-vt/libghostty-vt.a
#   Vendor/libghostty-vt/include/ghostty/

set -euo pipefail

GHOSTTY_SRC="${1:?Usage: $0 /path/to/ghostty/source}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/Vendor/libghostty-vt"

echo "Building libghostty-vt for iOS arm64..."
echo "Ghostty source: $GHOSTTY_SRC"
echo "Output: $OUTPUT_DIR"

# Uncomment when libghostty-vt provides a stable C API:
# cd "$GHOSTTY_SRC"
# zig build -Dtarget=aarch64-ios -Doptimize=ReleaseFast lib
# cp zig-out/lib/libghostty-vt.a "$OUTPUT_DIR/"
# cp -r include/ghostty "$OUTPUT_DIR/include/"

echo ""
echo "NOTE: This script is a placeholder. The project uses stub"
echo "implementations in CGhosttyVT until libghostty-vt is linked."
