#!/bin/sh
#
# The iOS viewer's arithmetic, run on the Mac.
#
# Everything that decides what the reader sees is UIKit-free on purpose, so it
# compiles and runs here in a couple of seconds. There is no simulator in this,
# and there should not be: a viewer that has to be opened by hand to be checked
# is a viewer that stops being checked.
#
set -e

cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/pdf-sdk-tests"

swiftc -O -o "$out" \
  PdfDocumentLayout.swift \
  PdfViewport.swift \
  PdfScrollPlan.swift \
  PdfTileGrid.swift \
  PdfFailure.swift \
  PdfSourceLoader.swift \
  PdfPageSource.swift \
  PdfImageCache.swift \
  tests/PdfSdkTests.swift

"$out"
