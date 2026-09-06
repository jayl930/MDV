#!/bin/bash
set -euo pipefail
DERIVED_DATA=${MDV_DERIVED_DATA:-/tmp/mdv-build}
PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
PACKAGES="$DERIVED_DATA/SourcePackages/checkouts"
LOG=$(mktemp /tmp/mdv-glyph-layout-warning-regression-log.XXXXXX)
BIN=$(mktemp /tmp/mdv-glyph-layout-warning-regression-bin.XXXXXX)
trap 'rm -f "$LOG" "$BIN"' EXIT
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache
swiftc -parse-as-library -module-cache-path /tmp/mdv-swift-module-cache \
  -I "$PRODUCTS" -F "$PRODUCTS/PackageFrameworks" \
  -Xcc -I -Xcc "$PACKAGES/swift-markdown/Sources/CAtomic/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/src/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/extensions/include" \
  Tests/GlyphLayoutWarningRegression.swift \
  "$PRODUCTS/MDV.app/Contents/MacOS/MDV.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/MDV.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/MDV.app/Contents/Frameworks" \
  -o "$BIN"
: >"$LOG"
for variant in minimal original; do
  if ! MDV_GLYPH_VARIANT="$variant" "$BIN" >>"$LOG" 2>&1; then
    cat "$LOG"
    exit 1
  fi
done
cat "$LOG"
if grep -Fq 'invalid glyph index' "$LOG"; then
  echo 'FAIL: GlyphLayoutWarningRegression observed invalid glyph index diagnostic' >&2
  exit 1
fi
