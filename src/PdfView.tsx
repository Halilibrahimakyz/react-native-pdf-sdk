import { forwardRef, useCallback, useImperativeHandle, useMemo, useRef } from 'react';
import {
  Platform,
  StyleSheet,
  View,
  processColor,
  type ColorValue,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { callback, getHostComponent } from 'react-native-nitro-modules';

import ViewConfig from '../nitrogen/generated/shared/json/NativePdfViewConfig.json';
import type {
  NativePdfViewMethods,
  NativePdfViewProps,
  PdfErrorEvent,
  PdfFit,
  PdfLoadEvent,
  PdfPageEvent,
  PdfTapEvent,
  PdfViewSource,
  PdfZoomEvent,
} from './specs/PdfView.nitro';

/**
 * What the view is handed when the caller says nothing.
 *
 * Every property the native view takes is required, and this is where the gaps
 * are filled. The reason is not style: nitro reads a property as empty only
 * when JavaScript passes `undefined`, while React hands native a `null`
 * whenever a property is taken away, and the bridge throws on that. Required
 * properties cannot be taken away, so `maxZoom={maybeUndefined}` is safe.
 */
const DECIDE = 0;

/** The gap between pages in PDF points, about a fifth of an inch. */
const DEFAULT_PAGE_GAP = 14;

const NativePdfView = getHostComponent<
  NativePdfViewProps,
  NativePdfViewMethods
>('NativePdfView', () => ViewConfig);

/**
 * Whether this platform has the viewer, which both of the ones React Native
 * ships for do: Android draws it with `PdfRenderer`, iOS with `CGPDFDocument`.
 *
 * Worth asking before reaching for it all the same, so that a platform without
 * it falls back rather than showing an empty box.
 */
export function isPdfViewAvailable(): boolean {
  return Platform.OS === 'android' || Platform.OS === 'ios';
}

export interface PdfViewProps {
  /** A url or a local path, or the same with headers and a password. */
  source: string | PdfViewSource;
  /** Which page to show, zero based. Changing it scrolls there. */
  page?: number;
  /** How the document is sized when it opens. Defaults to `auto`. */
  fit?: PdfFit;
  /** How far it may be zoomed, as multiples of the zoom it opened at. */
  minZoom?: number;
  maxZoom?: number;
  /** Where a double tap zooms to, as a multiple of the opening zoom. */
  doubleTapZoom?: number;
  /** The gap between pages, in PDF points. Defaults to 14. */
  pageGap?: number;
  /** The ground behind and between the pages. */
  backdropColor?: ColorValue;
  /** iOS only, since Android draws none. Defaults to true. */
  scrollIndicators?: boolean;
  style?: StyleProp<ViewStyle>;

  onLoad?: (event: PdfLoadEvent) => void;
  onPageChange?: (event: PdfPageEvent) => void;
  onZoom?: (event: PdfZoomEvent) => void;
  onError?: (event: PdfErrorEvent) => void;
  /** A tap that was not part of a double tap. */
  onTap?: (event: PdfTapEvent) => void;
}

export interface PdfViewHandle {
  /** Zero based. */
  goToPage: (page: number, animated?: boolean) => void;
  /** A multiple of the zoom the document opened at. */
  setZoom: (zoom: number, animated?: boolean) => void;
  /**
   * The share of the view drawn for the zoom it is shown at, between zero and
   * one. For measuring the viewer rather than for building on.
   */
  coverage: () => number;
}

/**
 * A PDF, drawn by the platform, in tiles.
 *
 * Everything that happens while a finger is on the screen happens in the native
 * view: the zoom, the movement, the tile grid and the drawing are read from the
 * same numbers in the same pass. JavaScript says which document and which page,
 * and hears back what was found in it.
 *
 * ```tsx
 * <PdfView
 *   source={{ uri: 'https://example.com/plan.pdf' }}
 *   onPageChange={({ page, pageCount }) => setLabel(`${page + 1} / ${pageCount}`)}
 *   style={StyleSheet.absoluteFill}
 * />
 * ```
 */
export const PdfView = forwardRef<PdfViewHandle, PdfViewProps>(
  function PdfView(
    {
      source,
      page = 0,
      fit,
      minZoom,
      maxZoom,
      doubleTapZoom,
      pageGap,
      backdropColor,
      scrollIndicators,
      style,
      onLoad,
      onPageChange,
      onZoom,
      onError,
      onTap,
    },
    ref,
  ) {
    const native = useRef<NativePdfViewMethods | null>(null);

    /** Native hands the view over once; it is the same object from then on. */
    const handleRef = useCallback((view: NativePdfViewMethods) => {
      native.current = view;
    }, []);

    const plain = typeof source === 'string';
    const uri = plain ? source : source.uri;
    const password = plain ? undefined : source.password;
    const cache = plain ? undefined : source.cache;
    const headers = plain ? undefined : source.headers;
    const headerNames = JSON.stringify(headers ?? null);

    /**
     * Held steady across renders on purpose: the native view opens the document
     * again whenever this changes, and an object literal in the caller's render
     * body is a different object every time. The headers are compared by what
     * is in them for the same reason.
     */
    const resolved = useMemo<PdfViewSource>(
      () => ({ uri, headers, password, cache }),
      // eslint-disable-next-line react-hooks/exhaustive-deps
      [uri, password, cache, headerNames],
    );

    /**
     * Transparent when nothing was asked for, which is what the view drew
     * before this property existed.
     */
    const backdrop = useMemo(() => {
      if (backdropColor == null) return 0;
      const processed = processColor(backdropColor);
      return typeof processed === 'number' ? processed : 0;
    }, [backdropColor]);

    useImperativeHandle(
      ref,
      () => ({
        goToPage: (to: number, animated = true) => native.current?.goToPage(to, animated),
        setZoom: (zoom: number, animated = true) => native.current?.setZoom(zoom, animated),
        coverage: () => native.current?.coverage() ?? 0,
      }),
      [],
    );

    const handleLoad = useCallback((event: PdfLoadEvent) => onLoad?.(event), [onLoad]);
    const handlePageChange = useCallback(
      (event: PdfPageEvent) => onPageChange?.(event),
      [onPageChange],
    );
    const handleZoom = useCallback((event: PdfZoomEvent) => onZoom?.(event), [onZoom]);
    const handleError = useCallback((event: PdfErrorEvent) => onError?.(event), [onError]);
    const handleTap = useCallback((event: PdfTapEvent) => onTap?.(event), [onTap]);

    const flattened = useMemo(() => StyleSheet.flatten([styles.fill, style]), [style]);

    if (!isPdfViewAvailable()) {
      return <View style={flattened} />;
    }

    return (
      <NativePdfView
        hybridRef={callback(handleRef)}
        source={resolved}
        page={page}
        fit={fit ?? 'auto'}
        minZoom={minZoom ?? DECIDE}
        maxZoom={maxZoom ?? DECIDE}
        doubleTapZoom={doubleTapZoom ?? DECIDE}
        pageGap={pageGap ?? DEFAULT_PAGE_GAP}
        backdropColor={backdrop}
        scrollIndicators={scrollIndicators ?? true}
        onLoad={callback(handleLoad)}
        onPageChange={callback(handlePageChange)}
        onZoom={callback(handleZoom)}
        onError={callback(handleError)}
        onTap={callback(handleTap)}
        style={flattened}
      />
    );
  },
);

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
});
