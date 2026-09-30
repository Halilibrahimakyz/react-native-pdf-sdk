import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules';

/** Where a document comes from. */
export interface PdfViewSource {
  /**
   * A local file path, a `file://` url, an `http(s)` url the view fetches and
   * keeps, or on Android a `content://` url.
   */
  uri: string;
  /** Sent with the request when the document is fetched over http. */
  headers?: Record<string, string>;
  /** For a document that needs one to open. */
  password?: string;
  /** Keep a fetched document on disk for next time. Defaults to true. */
  cache?: boolean;
}

/**
 * How a document is sized when it opens, which is also what a zoom of 1 means.
 *
 * `auto` fits the width, unless the first page is a strip rather than a page,
 * in which case it fills the height instead: a building's formwork plan is one
 * sheet thirteen metres wide, and fitted to the width that is a line across the
 * middle of the screen.
 */
export type PdfFit = 'auto' | 'width' | 'height' | 'page';

export type PdfErrorCode =
  /** There is nothing at that path or url. */
  | 'notFound'
  /** The document is encrypted and the password was wrong or missing. */
  | 'password'
  /** The file is not a PDF, or is one this platform will not open. */
  | 'unsupported'
  /** The document could not be fetched. */
  | 'network'
  | 'unknown';

export interface PdfLoadEvent {
  pageCount: number;
  /** The first page's size in PDF points, a point being a 72nd of an inch. */
  width: number;
  height: number;
}

export interface PdfPageEvent {
  /** Zero based. */
  page: number;
  pageCount: number;
}

export interface PdfZoomEvent {
  /** A multiple of the zoom the document opened at. */
  zoom: number;
  /** Screen points to the PDF point, which is what the zoom works out to. */
  scale: number;
}

export interface PdfErrorEvent {
  code: PdfErrorCode;
  message: string;
}

export interface PdfTapEvent {
  /** Where the tap landed in the view, in screen points. */
  x: number;
  y: number;
  /** The page under it, zero based. */
  page: number;
}

/**
 * What the view is told, with nothing left out.
 *
 * Every property here is required, and the wrapper in `PdfView.tsx` fills in
 * whatever the caller left off. That is not how a nitro spec would normally be
 * written, and the reason is worth knowing: nitro reads an optional property as
 * empty only when JavaScript passes `undefined`
 * (`JSIConverter+Optional.hpp`), while React hands native a `null` whenever a
 * property is taken away. So `maxZoom={maybeUndefined}` would throw inside the
 * bridge rather than mean what it says. Required properties with a value that
 * stands for "left to the viewer" cannot be taken away, so they cannot throw.
 */
export interface NativePdfViewProps extends HybridViewProps {
  source: PdfViewSource;
  /** Which page the document opens at, and scrolls to when it changes. Zero based. */
  page: number;
  fit: PdfFit;
  /**
   * How far the document may be zoomed, as multiples of the zoom it opened at.
   * Zero means the viewer decides: out until the widest page fits the screen,
   * and in until a PDF point is about thirteen screen points, which on a
   * drawing at 1:50 is where a dimension written along a beam becomes
   * comfortable to read.
   */
  minZoom: number;
  maxZoom: number;
  /** Where a double tap zooms to, as a multiple of the opening zoom. Zero to decide. */
  doubleTapZoom: number;
  /** The gap between pages in PDF points. */
  pageGap: number;
  /** The ground behind and between the pages, as a processed colour. */
  backdropColor: number;
  /** iOS only, since Android draws none. */
  scrollIndicators: boolean;

  onLoad?: (event: PdfLoadEvent) => void;
  /**
   * The page the reader is on: the one under the middle of the view. Sent when
   * it changes, not on every scrolled pixel.
   */
  onPageChange?: (event: PdfPageEvent) => void;
  /**
   * Sent a few times a second while the zoom is moving, and once more when it
   * stops. A pinch changes the zoom on every frame, and a listener that renders
   * on every frame would keep JavaScript busy for the whole gesture.
   */
  onZoom?: (event: PdfZoomEvent) => void;
  onError?: (event: PdfErrorEvent) => void;
  /** A tap that was not part of a double tap. */
  onTap?: (event: PdfTapEvent) => void;
}

export interface NativePdfViewMethods extends HybridViewMethods {
  goToPage(page: number, animated: boolean): void;
  /** Zooms about the middle of the view. `zoom` is a multiple of the opening zoom. */
  setZoom(zoom: number, animated: boolean): void;

  /**
   * The share of the view that has been drawn for the zoom it is shown at,
   * between zero and one. What is left is covered by something coarser. Meant
   * for measuring the viewer rather than for building on.
   */
  coverage(): number;
}

/**
 * The same viewer on both platforms: the arithmetic that decides what is drawn
 * is written twice, once in Kotlin and once in Swift, from the same numbers.
 */
export type NativePdfView = HybridView<
  NativePdfViewProps,
  NativePdfViewMethods,
  { android: 'kotlin'; ios: 'swift' }
>;
