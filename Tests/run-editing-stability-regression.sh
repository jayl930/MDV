#!/bin/sh
set -eu
DERIVED_DATA=${MDV_DERIVED_DATA:-/tmp/mdv-build}
PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
PACKAGES="$DERIVED_DATA/SourcePackages/checkouts"
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache
swiftc -parse-as-library -module-cache-path /tmp/mdv-swift-module-cache \
  -I "$PRODUCTS" -F "$PRODUCTS/PackageFrameworks" \
  -Xcc -I -Xcc "$PACKAGES/swift-markdown/Sources/CAtomic/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/src/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/extensions/include" \
  Tests/EditingStabilityRegression.swift \
  "$PRODUCTS/MDV.app/Contents/MacOS/MDV.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/MDV.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/MDV.app/Contents/Frameworks" \
  -o /tmp/mdv-editing-stability-regression
/tmp/mdv-editing-stability-regression
