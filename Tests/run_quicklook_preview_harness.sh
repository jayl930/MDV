#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${MDV_DERIVED_DATA:-/tmp/mdv-build}"
output_dir="${1:-/tmp/mdv-preview-snapshots}"
product_dir="$build_root/Build/Products/Debug"
binary="/tmp/mdv-quicklook-preview-harness"
packages="$build_root/SourcePackages/checkouts"

xcrun swiftc -O \
  -default-isolation MainActor \
  -module-cache-path /tmp/mdv-preview-module-cache \
  -I "$product_dir" \
  -Xcc -I -Xcc "$packages/swift-markdown/Sources/CAtomic/include" \
  -Xcc -I -Xcc "$packages/swift-cmark/src/include" \
  -Xcc -I -Xcc "$packages/swift-cmark/extensions/include" \
  "$repo_root/MDV/TOC/ToCEntry.swift" \
  "$repo_root/MDV/Editor/MarkdownTable.swift" \
  "$repo_root/MDV/Theme/Theme.swift" \
  "$repo_root/MDV/Theme/Typography.swift" \
  "$repo_root/MDV/Rendering/MarkdownPresentation.swift" \
  "$repo_root/MDV/Rendering/InlineRenderer.swift" \
  "$repo_root/MDV/Rendering/MarkdownPreviewRenderer.swift" \
  "$repo_root/Tests/QuickLookPreviewHarness.swift" \
  "$product_dir/Markdown.o" \
  "$product_dir/CAtomic.o" \
  "$product_dir/cmark-gfm.o" \
  "$product_dir/cmark-gfm-extensions.o" \
  -framework AppKit \
  -o "$binary"

"$binary" "$output_dir"
