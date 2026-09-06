#!/bin/sh
set -eu
DERIVED_DATA=${MDV_DERIVED_DATA:-/tmp/mdv-build}
PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
PACKAGES="$DERIVED_DATA/SourcePackages/checkouts"
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache

if [ "${MDV_OPTIMIZED_HARNESS:-0}" = "1" ]; then
  swiftc -O -parse-as-library -D MDV_STANDALONE \
    -default-isolation MainActor \
    -module-cache-path /tmp/mdv-swift-module-cache \
    -I "$PRODUCTS" \
    -Xcc -I -Xcc "$PACKAGES/swift-markdown/Sources/CAtomic/include" \
    -Xcc -I -Xcc "$PACKAGES/swift-cmark/src/include" \
    -Xcc -I -Xcc "$PACKAGES/swift-cmark/extensions/include" \
    MDV/MarkdownDocument.swift \
    MDV/TOC/ToCEntry.swift MDV/TOC/ToCModel.swift \
    MDV/Theme/Theme.swift MDV/Theme/Typography.swift \
    MDV/Rendering/MarkdownPresentation.swift \
    MDV/Rendering/InlineRenderer.swift MDV/Rendering/SyntaxHider.swift \
    MDV/Editor/EditorProjection.swift MDV/Editor/MarkdownTable.swift \
    MDV/Editor/GlyphManager.swift \
    MDV/Editor/TableAttachment.swift MDV/Editor/TableAttachmentView.swift \
    MDV/Editor/TableOperations.swift MDV/Editor/MarkdownTextView.swift \
    MDV/Editor/MarkdownEditorView.swift \
    Tests/EditorCoordinatorRegression.swift \
    "$PRODUCTS/Markdown.o" "$PRODUCTS/CAtomic.o" \
    "$PRODUCTS/cmark-gfm.o" "$PRODUCTS/cmark-gfm-extensions.o" \
    -framework AppKit -o /tmp/mdv-editor-coordinator-regression
  /tmp/mdv-editor-coordinator-regression
  exit 0
fi

swiftc -parse-as-library -module-cache-path /tmp/mdv-swift-module-cache \
  -I "$PRODUCTS" -F "$PRODUCTS/PackageFrameworks" \
  -Xcc -I -Xcc "$PACKAGES/swift-markdown/Sources/CAtomic/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/src/include" \
  -Xcc -I -Xcc "$PACKAGES/swift-cmark/extensions/include" \
  Tests/EditorCoordinatorRegression.swift \
  "$PRODUCTS/MDV.app/Contents/MacOS/MDV.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/MDV.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/MDV.app/Contents/Frameworks" \
  -o /tmp/mdv-editor-coordinator-regression
/tmp/mdv-editor-coordinator-regression
