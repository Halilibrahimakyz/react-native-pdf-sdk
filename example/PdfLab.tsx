import { useRef, useState, type ReactNode } from 'react';
import {
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  PdfView,
  openPdfDocument,
  type PdfFit,
  type PdfViewHandle,
  type PdfViewSource,
} from '../src';

/**
 * Every prop, event and method of the viewer, on one screen.
 *
 * The app this was written for only ever opens a local file and reads the page
 * number, so everything else went to a device untested. This is where the rest
 * is put in front of a finger: the fits, the zoom limits, the events, the
 * methods, a url fetched by the view itself, and a page drawn into a file.
 *
 * Deliberately free of any design system. It belongs to the package, and the
 * package should not know what an app's theme looks like.
 */
export interface PdfLabProps {
  /** A document already on disk, which is what the host app has to hand. */
  path: string;
  /** The same document as a url, to watch the view fetch it itself. */
  remote?: { uri: string; headers?: Record<string, string> };
}

/** A public document, for when the host app has no url to lend. */
const SAMPLE =
  'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf';

const FITS: PdfFit[] = ['auto', 'width', 'height', 'page'];
const GAPS = [0, 14, 60];
const MAX_ZOOMS: (number | undefined)[] = [undefined, 2, 6];
const BACKDROPS = ['#D4D4D7', '#2A2A2E', '#FFFFFF'];

export function PdfLab({ path, remote }: PdfLabProps) {
  const viewer = useRef<PdfViewHandle>(null);

  const [uri, setUri] = useState(path);
  const [typed, setTyped] = useState(remote?.uri ?? SAMPLE);
  const [password, setPassword] = useState('');
  const [headers, setHeaders] = useState<Record<string, string> | undefined>();

  const [fit, setFit] = useState<PdfFit>('auto');
  const [gap, setGap] = useState(14);
  const [maxZoom, setMaxZoom] = useState<number | undefined>();
  const [doubleTapZoom, setDoubleTapZoom] = useState<number | undefined>();
  const [backdrop, setBackdrop] = useState(BACKDROPS[0]);
  const [indicators, setIndicators] = useState(true);

  const [loaded, setLoaded] = useState('-');
  const [page, setPage] = useState('-');
  const [zoom, setZoom] = useState('-');
  const [tap, setTap] = useState('-');
  const [failure, setFailure] = useState('-');
  const [thumbnail, setThumbnail] = useState<string | null>(null);
  const [controls, setControls] = useState(true);

  const source: PdfViewSource = {
    uri,
    headers,
    password: password.length > 0 ? password : undefined,
  };

  function use(next: string, withHeaders?: Record<string, string>) {
    setFailure('-');
    setLoaded('-');
    setHeaders(withHeaders);
    setUri(next);
  }

  async function drawThumbnail() {
    setThumbnail(null);
    try {
      const document = openPdfDocument(
        uri,
        password.length > 0 ? password : undefined,
      );
      const size = document.getPageSize(0);
      const width = 180;
      const file = await document.renderToFile({
        page: 0,
        outWidth: width,
        outHeight: Math.max(1, Math.round((width * size.height) / size.width)),
      });
      document.close();
      setThumbnail(file);
      setFailure(
        `thumbnail ${Math.round(size.width)}x${Math.round(size.height)} pt`,
      );
    } catch (error) {
      setFailure(`thumbnail failed: ${String(error)}`);
    }
  }

  return (
    <View style={styles.root}>
      <Row>
        <Pill
          label={controls ? 'hide' : 'show'}
          onPress={() => setControls(!controls)}
        />
        <Pill label="local" on={uri === path} onPress={() => use(path)} />
        <Pill
          label="url"
          on={uri === typed}
          onPress={() =>
            use(typed, remote?.uri === typed ? remote?.headers : undefined)
          }
        />
        <Pill
          label="missing"
          on={uri === '/no/such.pdf'}
          onPress={() => use('/no/such.pdf')}
        />
        <Pill label="png" onPress={drawThumbnail} />
      </Row>

      {!controls ? null : (
        <>
          <Row>
            <TextInput
              value={typed}
              onChangeText={setTyped}
              autoCapitalize="none"
              autoCorrect={false}
              placeholder="https://..."
              style={styles.input}
            />
            <TextInput
              value={password}
              onChangeText={setPassword}
              autoCapitalize="none"
              autoCorrect={false}
              placeholder="password"
              style={[styles.input, styles.short]}
            />
          </Row>

          <Row>
            {FITS.map(value => (
              <Pill
                key={value}
                label={value}
                on={fit === value}
                onPress={() => setFit(value)}
              />
            ))}
            {GAPS.map(value => (
              <Pill
                key={value}
                label={`gap ${value}`}
                on={gap === value}
                onPress={() => setGap(value)}
              />
            ))}
          </Row>

          <Row>
            {MAX_ZOOMS.map((value, index) => (
              <Pill
                key={index}
                label={value == null ? 'max auto' : `max ${value}x`}
                on={maxZoom === value}
                onPress={() => setMaxZoom(value)}
              />
            ))}
            <Pill
              label={doubleTapZoom == null ? 'tap auto' : 'tap 2x'}
              on={doubleTapZoom != null}
              onPress={() =>
                setDoubleTapZoom(doubleTapZoom == null ? 2 : undefined)
              }
            />
            <Pill
              label={indicators ? 'bars on' : 'bars off'}
              on={indicators}
              onPress={() => setIndicators(!indicators)}
            />
            {BACKDROPS.map(value => (
              <Pill
                key={value}
                label={value}
                on={backdrop === value}
                onPress={() => setBackdrop(value)}
              />
            ))}
          </Row>

          <Row>
            <Pill label="page 0" onPress={() => viewer.current?.goToPage(0)} />
            <Pill
              label="page +1"
              onPress={() => viewer.current?.goToPage(nextPage(page))}
            />
            <Pill label="zoom 1" onPress={() => viewer.current?.setZoom(1)} />
            <Pill label="zoom 3" onPress={() => viewer.current?.setZoom(3)} />
            <Pill
              label="zoom 3 now"
              onPress={() => viewer.current?.setZoom(3, false)}
            />
            <Pill
              label="coverage"
              onPress={() => setZoom(`coverage ${viewer.current?.coverage()}`)}
            />
          </Row>
        </>
      )}

      <View style={styles.viewer}>
        <PdfView
          ref={viewer}
          source={source}
          fit={fit}
          pageGap={gap}
          maxZoom={maxZoom}
          doubleTapZoom={doubleTapZoom}
          backdropColor={backdrop}
          scrollIndicators={indicators}
          onLoad={info =>
            setLoaded(
              `${info.pageCount} pages, ${Math.round(info.width)}x${Math.round(
                info.height,
              )} pt`,
            )
          }
          onPageChange={info => setPage(`${info.page + 1} / ${info.pageCount}`)}
          onZoom={info =>
            setZoom(`${info.zoom.toFixed(2)}x, ${info.scale.toFixed(2)} pt`)
          }
          onTap={info =>
            setTap(
              `${Math.round(info.x)},${Math.round(info.y)} on page ${
                info.page + 1
              }`,
            )
          }
          onError={error => setFailure(`${error.code}: ${error.message}`)}
          style={styles.pdf}
        />
        {thumbnail == null ? null : (
          <Image
            source={{ uri: `file://${thumbnail}` }}
            style={styles.thumbnail}
          />
        )}
      </View>

      <View style={styles.readout}>
        <Text style={styles.line} numberOfLines={1}>
          load {loaded}
        </Text>
        <Text style={styles.line} numberOfLines={1}>
          page {page} zoom {zoom}
        </Text>
        <Text style={styles.line} numberOfLines={1}>
          tap {tap}
        </Text>
        <Text style={styles.line} numberOfLines={2}>
          last {failure}
        </Text>
      </View>
    </View>
  );
}

/** The page number shown in the readout, plus one. */
function nextPage(shown: string): number {
  const current = Number.parseInt(shown.split('/')[0]?.trim() ?? '', 10);
  return Number.isFinite(current) ? current : 1;
}

function Row({ children }: { children: ReactNode }) {
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      style={styles.rowScroll}
      contentContainerStyle={styles.row}
      keyboardShouldPersistTaps="handled"
    >
      {children}
    </ScrollView>
  );
}

function Pill({
  label,
  on,
  onPress,
}: {
  label: string;
  on?: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      style={[styles.pill, on === true && styles.pillOn]}
    >
      <Text style={[styles.pillText, on === true && styles.pillTextOn]}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#111114' },
  rowScroll: { flexGrow: 0, flexShrink: 0 },
  row: {
    paddingHorizontal: 8,
    paddingVertical: 3,
    gap: 6,
    alignItems: 'center',
  },
  pill: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 14,
    backgroundColor: '#26262C',
  },
  pillOn: { backgroundColor: '#3B82F6' },
  pillText: { color: '#C9C9D1', fontSize: 12 },
  pillTextOn: { color: '#FFFFFF' },
  input: {
    flexGrow: 1,
    minWidth: 220,
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
    backgroundColor: '#26262C',
    color: '#FFFFFF',
    fontSize: 12,
  },
  short: { minWidth: 110, flexGrow: 0 },
  viewer: { flex: 1, margin: 8, borderRadius: 8, overflow: 'hidden' },
  pdf: { flex: 1 },
  thumbnail: {
    position: 'absolute',
    right: 8,
    bottom: 8,
    width: 90,
    height: 120,
    borderRadius: 4,
    borderWidth: 1,
    borderColor: '#FFFFFF',
    backgroundColor: '#FFFFFF',
    resizeMode: 'contain',
  },
  readout: { paddingHorizontal: 12, paddingBottom: 10, gap: 2 },
  line: { color: '#9AA0AA', fontSize: 11 },
});
