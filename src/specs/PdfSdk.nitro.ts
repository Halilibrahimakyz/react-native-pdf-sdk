import type { HybridObject } from 'react-native-nitro-modules';

/** A page's size in PDF points, a point being a 72nd of an inch. */
export interface PdfPageSize {
  width: number;
  height: number;
}

/**
 * One drawing job: which part of which page to draw, and how large the
 * resulting image should be.
 *
 * The region is given in the page's own points with the origin at its top left
 * corner, and the output size in pixels. Nothing outside the region is drawn,
 * so the cost of a job follows the size of the image asked for, not the size of
 * the page.
 */
export interface PdfRenderRequest {
  /** Zero based. */
  page: number;
  /** The region of the page. The whole page when left out. */
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  /** The image's size in pixels. */
  outWidth: number;
  outHeight: number;
  /** Where to write the PNG. A file in the cache directory when left out. */
  path?: string;
}

/**
 * An open PDF file, for taking pictures of pages: a thumbnail beside a filename,
 * a preview in a list, a page to share.
 *
 * The file stays open until `close` is called, so a document that has left the
 * screen should be closed.
 */
export interface PdfDocument extends HybridObject<{ android: 'kotlin'; ios: 'swift' }> {
  readonly pageCount: number;

  getPageSize(page: number): PdfPageSize;

  /** Draws the request into a PNG file and answers where it was written. */
  renderToFile(request: PdfRenderRequest): Promise<string>;

  close(): void;
}

export interface PdfSdk extends HybridObject<{ android: 'kotlin'; ios: 'swift' }> {
  /**
   * Opens a PDF from a local file path or a `file://` url.
   *
   * Throws when the file is missing or malformed. A document that needs a
   * password to open needs one here: Android can only take it from API 35, and
   * throws for encrypted documents before that.
   */
  open(path: string, password?: string): PdfDocument;
}
