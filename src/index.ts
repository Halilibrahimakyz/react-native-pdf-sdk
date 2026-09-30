export { PdfView, isPdfViewAvailable } from './PdfView';
export type { PdfViewProps, PdfViewHandle } from './PdfView';

export { openPdfDocument } from './document';
export type { PdfSdk, PdfDocument, PdfPageSize, PdfRenderRequest } from './specs/PdfSdk.nitro';

export type {
  PdfErrorCode,
  PdfErrorEvent,
  PdfFit,
  PdfLoadEvent,
  PdfPageEvent,
  PdfTapEvent,
  PdfViewSource,
  PdfZoomEvent,
} from './specs/PdfView.nitro';
