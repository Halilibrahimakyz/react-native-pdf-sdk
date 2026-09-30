# Changelog

## 0.1.0

First release.

- `PdfView`, a viewer that draws the part of the page in view, in tiles,
  at the zoom it is being viewed at, on both platforms.
- Documents from a local path, a `file://` url, an `http(s)` url the view
  fetches and keeps, or an Android `content://` url, with request headers and a
  password.
- `fit`, `minZoom`, `maxZoom`, `doubleTapZoom`, `pageGap`, `backdropColor` and
  `scrollIndicators` for how it opens and how far it goes.
- `onLoad`, `onPageChange`, `onZoom`, `onError` and `onTap`, and `goToPage` and
  `setZoom` through a ref.
- `openPdfDocument`, for drawing a page into a PNG file without a viewer.
