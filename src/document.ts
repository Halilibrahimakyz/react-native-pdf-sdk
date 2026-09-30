import { NitroModules } from 'react-native-nitro-modules';
import type { PdfSdk, PdfDocument } from './specs/PdfSdk.nitro';

let canvas: PdfSdk | null = null;

function getCanvas(): PdfSdk {
  if (canvas == null) {
    canvas = NitroModules.createHybridObject<PdfSdk>('PdfSdk');
  }
  return canvas;
}

/**
 * Opens a document to take pictures of pages: a thumbnail beside a filename, a
 * preview in a list, a page to share.
 *
 * The viewer is `PdfView`, which draws its own pages and needs none of
 * this. Takes a local path or a `file://` url, and throws for a file that is
 * missing, malformed, or encrypted without the right password.
 *
 * ```ts
 * const document = openPdfDocument(path);
 * const size = document.getPageSize(0);
 * const png = await document.renderToFile({
 *   page: 0,
 *   outWidth: 200,
 *   outHeight: Math.round((200 * size.height) / size.width),
 * });
 * document.close();
 * ```
 */
export function openPdfDocument(path: string, password?: string): PdfDocument {
  return getCanvas().open(path, password);
}
