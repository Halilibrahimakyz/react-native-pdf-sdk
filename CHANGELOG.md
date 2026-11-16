# Changelog

## 0.2.0

The bridge is regenerated with Nitro 0.37.2. Nothing hand-written changed.

- Fixed: on React Native 0.88, Debug builds crashed the moment `PdfView`
  mounted, on an assertion that the view's props were never set. Release
  builds were not affected.
- Breaking: the app now needs `react-native-nitro-modules` 0.37.2 or newer.
  The generated code includes headers that earlier versions do not have, and
  the peer range says so.

## 0.1.1

The readme only. Nothing in the package's code changed.

- Screenshots of both documents on both platforms, three recordings, and a
  loop of the sheet being zoomed into at the top of the page. The loop is an
  image rather than a video so that it plays on npm as well as on GitHub.

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
