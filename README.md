# react-native-pdf-sdk

A PDF viewer for React Native that draws the part of the page you are looking
at, at the zoom you are looking at it, using the renderer that ships with the
platform.

Viewers built on a whole-page bitmap fall over on architectural and engineering
drawings, where one sheet can be metres wide: fitted to a phone the sheet is a
line, and zoomed in the bitmap is too large to hold. This one never draws a
whole page. It draws the rectangle in view, in tiles, so a sheet of any size
costs about what a letter page costs.

```tsx
import { PdfView } from 'react-native-pdf-sdk';

<PdfView
  source={{ uri: 'https://example.com/plan.pdf' }}
  onPageChange={({ page, pageCount }) => setLabel(`${page + 1} / ${pageCount}`)}
  style={StyleSheet.absoluteFill}
/>;
```

## What it looks like

Both documents below are drawn by `example/pdfs/make.swift` and ship with this
repository. Nothing pictured belongs to anyone: every line of it came out of
that script.

**One sheet, 26000 × 1500 points.** A drawing that wide is a line when it is
fitted to a phone's width, so it opens fitted to the height and is read by
panning. The second column is the same screen after pinching into the middle of
it: the casting note set at 4 points, a smudge in the first column, is the same
ink in the same document.

|  | Opening | The same place, zoomed in |
| --- | --- | --- |
| iOS | <img src="https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/docs/sheet-fitted-ios.png" width="240" alt="The sheet fitted to the height on iOS" /> | <img src="https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/docs/sheet-detail-ios.png" width="240" alt="The same sheet zoomed into panel PA2 on iOS" /> |
| Android | <img src="https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/docs/sheet-fitted-android.png" width="240" alt="The sheet fitted to the height on Android" /> | <img src="https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/docs/sheet-detail-android.png" width="240" alt="The same sheet zoomed into panel PA2 on Android" /> |

**Ten ordinary pages.** The case every viewer is built for: fitted to the
width, scrolled, with a gap and a page number between one page and the next.

| iOS | Android |
| --- | --- |
| <img src="https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/docs/report-pages-ios.png" width="240" alt="Two pages of the report on iOS" /> | <img src="https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/docs/report-pages-android.png" width="240" alt="Two pages of the report on Android" /> |

### Recordings

The sheet, pinched in and out on iOS:

https://github.com/user-attachments/assets/0eead98f-01e7-4dd4-8d49-aed94b51f8f2

The same on Android:

https://github.com/user-attachments/assets/d4c5a9db-51ec-417b-a550-8c844b5d489b

The report, scrolled:

https://github.com/user-attachments/assets/a93a3de5-4e77-46d2-8a2e-8ab7bc371ace

The counters in the corner are React Native's own performance monitor, left on
deliberately. Read those rather than the fluidity of the video itself: both
screen recorders top out well under sixty frames a second, and what they cost
is charged to the same threads they are measuring.

## Requirements

- React Native 0.78 or newer with the **New Architecture** enabled. There is no
  old architecture fallback.
- [`react-native-nitro-modules`](https://nitro.margelo.com), which carries the
  bridge this is built on.
- iOS 15, Android 7 (API 24).

```sh
npm install react-native-pdf-sdk react-native-nitro-modules
cd ios && pod install
```

Nothing to register and nothing to wrap: both platforms autolink.

## The document

`source` takes a string or an object.

| Field | What it does |
| --- | --- |
| `uri` | A local path, a `file://` url, an `http(s)` url the view fetches and keeps, or on Android a `content://` url |
| `headers` | Sent with the request when the document is fetched over http |
| `password` | For a document that needs one to open |
| `cache` | Keep a fetched document on disk for next time. Defaults to true |

A string is shorthand for `{ uri }`. A fetched document is kept under a name
made from its url, so opening it again reads it from disk.

Encrypted documents open on iOS with the right password. On Android a password
can only be handed to the platform from Android 15; before that the platform
refuses an encrypted document outright, and `onError` says so with the code
`password`.

## Props

| Prop | Type | Default | What it does |
| --- | --- | --- | --- |
| `source` | `string \| PdfViewSource` | | The document |
| `page` | `number` | `0` | Which page to show, zero based. Changing it scrolls there |
| `fit` | `'auto' \| 'width' \| 'height' \| 'page'` | `'auto'` | How the document is sized when it opens |
| `minZoom` | `number` | until the widest page fits | How far out it goes, as a multiple of the opening zoom |
| `maxZoom` | `number` | until a PDF point is 13 screen points | How far in it goes, likewise |
| `doubleTapZoom` | `number` | three times, at least 4 | Where a double tap lands |
| `pageGap` | `number` | `14` | The gap between pages, in PDF points |
| `backdropColor` | `ColorValue` | transparent | The ground behind and between the pages |
| `scrollIndicators` | `boolean` | `true` | iOS only, since Android draws none |
| `style` | `StyleProp<ViewStyle>` | `flex: 1` | |

`fit` is worth a sentence. `auto` fits the width, unless the first page is a
strip rather than a page, in which case it fills the height instead: a
building's formwork plan is one sheet thirteen metres wide and sixty
centimetres tall, and fitted to the width that is a line across the middle of
the screen.

Every zoom number in this API is a multiple of the zoom the document opened at,
whatever that turned out to be, so `maxZoom={3}` means the same thing to a
letter page and to a plan.

## Events

| Event | Gives you |
| --- | --- |
| `onLoad` | `{ pageCount, width, height }`, the first page's size in PDF points |
| `onPageChange` | `{ page, pageCount }`, the page under the middle of the view, zero based |
| `onZoom` | `{ zoom, scale }`, a multiple of the opening zoom and what it works out to in screen points per PDF point |
| `onError` | `{ code, message }`, where code is `notFound`, `password`, `unsupported`, `network` or `unknown` |
| `onTap` | `{ x, y, page }`, for a tap that was not part of a double tap |

`onError` is where a viewer earns its keep. Nothing is thrown, nothing is
logged for you: a document that will not open says so once, with a code you can
branch on, and the view stays empty until it is given another one.

## Controlling it

```tsx
const viewer = useRef<PdfViewHandle>(null);

viewer.current?.goToPage(4);        // zero based
viewer.current?.setZoom(2, false);  // twice the opening zoom, without animating
```

## Pictures of pages

Sometimes you want an image rather than a viewer: a thumbnail beside a
filename, a preview in a list, a page to share.

```ts
import { openPdfDocument } from 'react-native-pdf-sdk';

const document = openPdfDocument(path);
const size = document.getPageSize(0);
const png = await document.renderToFile({
  page: 0,
  outWidth: 200,
  outHeight: Math.round((200 * size.height) / size.width),
});
document.close();
```

`renderToFile` answers the path it wrote. Give it `x`, `y`, `width` and
`height` in the page's own points to draw a region of a page rather than the
whole of it, and `path` to say where the PNG goes.

## What is native and why

Everything that happens while a finger is on the screen: the zoom, the
movement, the tile grid and the drawing are read from the same numbers in the
same pass. Drawn from JavaScript, the transform and the layout of what it moves
cannot be changed together, and every change of zoom shows a frame or two of the
document in the wrong place.

The two platforms draw the same way and open a document at the same size, and
the numbers that decide both are written twice, once in Kotlin and once in
Swift, with the same tests on each side. They differ where the platform does:

- **Android** counts the pinch, the double tap and the flick by hand, because
  the platform's own detectors stop reporting halfway through a pinch and claim
  the second tap of a double tap for themselves. `PdfRenderer` draws.
- **iOS** hands all of that to a `UIScrollView`, which is the scroll view every
  iOS app is read through, and reads the zoom and the offset back out of it on
  every frame. `CGPDFDocument` draws.

The drawing is where the two differ most, and all of it follows from one
measurement: `CGPDFDocument` keeps nothing between draws, so a page's content is
read again for every tile, and on a structural drawing that is a tenth of a
second whether the tile is a postage stamp or a screenful. Everything below is
there to make that number matter less, and each was measured before and after:

- Tiles are 1280 pixels rather than Android's 512, so a screenful is four to six
  drawings rather than fifteen.
- They are drawn through three open copies of the file at once. The copies cost
  almost nothing: the system maps the file once, and what is not shared is the
  parsing, which is the part being done in parallel.
- A page small enough to be drawn in one go is drawn in one go, so an ordinary
  page read at the zoom it opens at is one drawing instead of six.
- Tiles are drawn at zooms from a fixed ladder rather than at wherever the
  fingers stopped, so a zoom that comes back finds what it drew last time
  instead of asking for the same picture under another name.
- Every level held is drawn, coarsest first, so moving at a deep zoom lands on
  something drawn on the way in rather than on the page's own small drawing.
- A double tap asks for the tiles of where it is going when it starts, since the
  movement and a tile take about as long as each other.
- What is held is held least recently used, because every tile on the screen is
  read every frame and so can never be the one thrown out.

## Trying it

`example/pdfs` holds two documents drawn by `example/pdfs/make.swift`, so that a
screenshot of this package is this package's own work and carries nobody's
data. `sheet.pdf` is one drawing nine metres wide with dimensions written small
enough to need the zoom; `report.pdf` is ten ordinary A4 pages. Run `npm run
pdfs` to draw them again.

The quickest way to open them on a device is to serve the folder and hand the
url to the view, which also exercises the fetching it does itself:

```sh
cd example/pdfs && python3 -m http.server 8000
```

An iOS simulator reaches that at `http://localhost:8000/sheet.pdf` and an
Android emulator at `http://10.0.2.2:8000/sheet.pdf`.

## Tests

The arithmetic that decides what the reader sees is free of Android and of UIKit
on purpose, so all of it runs on the machine you are writing on, in seconds,
with no emulator and no simulator.

```sh
npm run test:ios       # swiftc, straight on the Mac
npm run test:android   # the same questions, on the JVM
npm run verify         # both, and the types
```

Both sides ask the same questions, which is how a difference between the two
platforms turns up as a failing test rather than as a complaint about one phone.

## Changing the spec

`src/specs/*.nitro.ts` are the source of truth for the bridge. After editing
them run `npm run specs`, then `pod install` and a gradle sync in the app.

## Releasing

```sh
npm install     # inside this package, for the build tools
npm publish     # verifies, builds, then publishes
```

## Contributing

Patches welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the commit format, what
`npm run verify` covers and the two rules that are easy to break without
noticing: the numbers behind the behaviour live twice, once per platform, and
the native view takes no optional props.

## Licence

MIT
