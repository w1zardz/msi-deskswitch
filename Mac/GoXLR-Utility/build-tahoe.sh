#!/bin/bash
set -euo pipefail

# Build only: does not install, launch, or alter the user's GoXLR profiles.
if [[ $# != 2 ]]; then
    echo "Usage: $0 /path/to/upstream-git-checkout /new/build-directory" >&2
    exit 2
fi
PATCH_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
UPSTREAM_REVISION=0c093b4c9bfb59d3426357c008760ad6620f97ae
UPSTREAM_SOURCE="$(cd -- "$1" && pwd)"
if [[ -e "$2" ]]; then
    echo "Refusing to overwrite build directory: $2" >&2
    exit 2
fi
git -C "$UPSTREAM_SOURCE" cat-file -e "${UPSTREAM_REVISION}^{commit}"
mkdir -p -- "$2/source"
BUILD_ROOT="$(cd -- "$2" && pwd)"
git -C "$UPSTREAM_SOURCE" archive "$UPSTREAM_REVISION" | tar -x -C "$BUILD_ROOT/source"
cd -- "$BUILD_ROOT/source"
patch --batch --forward --fuzz=0 -p1 < "$PATCH_DIR/patches/tahoe-coreaudio.patch"

# An existing Cargo cache may be shared; the sources remain a separate pristine copy.
export CARGO_TARGET_DIR="${GOXLR_CARGO_TARGET_DIR:-$BUILD_ROOT/target}"
cargo build --locked --release --all-features -p goxlr-daemon \
    --target aarch64-apple-darwin > "$BUILD_ROOT/build.log" 2>&1 || {
    tail -60 "$BUILD_ROOT/build.log" >&2
    exit 1
}
cargo test --locked --release --all-features -p goxlr-daemon \
    --target aarch64-apple-darwin tahoe_tests > "$BUILD_ROOT/test.log" 2>&1 || {
    tail -60 "$BUILD_ROOT/test.log" >&2
    exit 1
}
mkdir -- "$BUILD_ROOT/artifact"
cp -- "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/goxlr-daemon" "$BUILD_ROOT/artifact/"
cp -- LICENSE LICENSE-3RD-PARTY "$BUILD_ROOT/artifact/"
echo "Built: $BUILD_ROOT/artifact/goxlr-daemon"
echo "Build log: $BUILD_ROOT/build.log"
echo "Test log: $BUILD_ROOT/test.log"
