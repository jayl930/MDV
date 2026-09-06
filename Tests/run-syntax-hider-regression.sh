#!/bin/sh
set -eu
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache
swiftc -module-cache-path /tmp/mdv-swift-module-cache \
  MDV/Editor/GlyphManager.swift MDV/Rendering/SyntaxHider.swift \
  Tests/SyntaxHiderRegression.swift -o /tmp/mdv-syntax-hider-regression
/tmp/mdv-syntax-hider-regression
