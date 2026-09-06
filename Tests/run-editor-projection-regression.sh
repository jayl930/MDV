#!/bin/sh
set -eu
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache
swiftc -module-cache-path /tmp/mdv-swift-module-cache \
  MDV/Editor/EditorProjection.swift Tests/EditorProjectionRegression.swift \
  -o /tmp/mdv-editor-projection-regression
/tmp/mdv-editor-projection-regression
