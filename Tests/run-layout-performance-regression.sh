#!/bin/sh
set -eu
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache
DERIVED_DATA=${MDV_DERIVED_DATA:-/tmp/mdv-build}
PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
PACKAGES="$DERIVED_DATA/SourcePackages/checkouts"
swiftc -default-isolation MainActor -module-cache-path /tmp/mdv-swift-module-cache \
  -I "$PRODUCTS" \
  -Xcc -I -Xcc "$PACKAGES/swift-markdown/Sources/CAtomic/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/src/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/extensions/include" \
  MDV/TOC/ToCEntry.swift MDV/Editor/MarkdownTable.swift \
  MDV/Theme/Theme.swift MDV/Theme/Typography.swift MDV/Rendering/MarkdownPresentation.swift MDV/Rendering/InlineRenderer.swift \
  MDV/Editor/GlyphManager.swift MDV/Editor/MarkdownTextView.swift \
  Tests/LayoutPerformanceRegression.swift \
  "$PRODUCTS/Markdown.o" "$PRODUCTS/CAtomic.o" "$PRODUCTS/cmark-gfm.o" \
  "$PRODUCTS/cmark-gfm-extensions.o" -framework AppKit \
  -o /tmp/mdv-layout-performance-regression
/tmp/mdv-layout-performance-regression
