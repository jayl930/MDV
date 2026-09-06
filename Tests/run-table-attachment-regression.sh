#!/bin/sh
set -eu
export CLANG_MODULE_CACHE_PATH=/tmp/mdv-clang-module-cache
export SWIFT_MODULECACHE_PATH=/tmp/mdv-swift-module-cache
swiftc -module-cache-path /tmp/mdv-swift-module-cache \
  MDV/Theme/Typography.swift \
  MDV/Editor/MarkdownTable.swift MDV/Editor/TableOperations.swift \
  MDV/Editor/TableAttachmentView.swift MDV/Editor/TableAttachment.swift \
  Tests/TableAttachmentRegression.swift -o /tmp/mdv-table-attachment-regression
/tmp/mdv-table-attachment-regression
