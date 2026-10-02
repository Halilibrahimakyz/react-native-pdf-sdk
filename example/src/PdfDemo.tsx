import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { PdfView, type PdfViewSource } from 'react-native-pdf-sdk';

/**
 * The whole viewer, and nothing else.
 *
 * This is what a screen built on this package looks like when it is finished:
 * a document, a counter, and a way back. It is also the screen the screenshots
 * in the README were taken from, so what is pictured there is what this file
 * produces.
 *
 * It keeps out of the status bar and the home indicator by asking
 * `react-native-safe-area-context` for the insets, which is the one thing here
 * the package itself does not provide. The package has no opinion about where
 * the viewer sits; that is the screen's business, and this is one answer.
 */
export interface PdfDemoProps {
  source: string | PdfViewSource;
  onClose?: () => void;
}

export function PdfDemo({ source, onClose }: PdfDemoProps) {
  const insets = useSafeAreaInsets();
  const [pages, setPages] = useState({ page: 0, total: 0 });
  const [failure, setFailure] = useState<string | null>(null);

  return (
    <View
      style={[
        styles.root,
        { paddingTop: insets.top, paddingBottom: insets.bottom },
      ]}
    >
      <View style={styles.body}>
        <PdfView
          source={source}
          backdropColor="#D4D4D7"
          onLoad={({ pageCount }) => {
            setFailure(null);
            setPages({ page: 0, total: pageCount });
          }}
          onPageChange={({ page, pageCount }) =>
            setPages({ page, total: pageCount })
          }
          onError={({ message }) => setFailure(message)}
          style={StyleSheet.absoluteFill}
        />

        {onClose == null ? null : (
          <Pressable onPress={onClose} style={styles.back} hitSlop={12}>
            <Text style={styles.backMark}>‹</Text>
          </Pressable>
        )}

        {pages.total > 1 ? (
          <View style={styles.counter} pointerEvents="none">
            <Text style={styles.counterText}>
              {pages.page + 1} / {pages.total}
            </Text>
          </View>
        ) : null}

        {failure == null ? null : (
          <View style={styles.failure} pointerEvents="none">
            <Text style={styles.failureText}>{failure}</Text>
          </View>
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#D4D4D7' },
  body: { flex: 1 },

  /** Over the document, the way every viewer puts it. */
  back: {
    position: 'absolute',
    top: 12,
    left: 12,
    width: 38,
    height: 38,
    borderRadius: 19,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(17, 17, 20, 0.55)',
  },
  backMark: { color: '#FFFFFF', fontSize: 26, lineHeight: 30, marginTop: -4 },

  /** Where you are in the document. Hidden for a single page, which has nothing to count. */
  counter: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 28,
    alignItems: 'center',
  },
  counterText: {
    color: '#FFFFFF',
    fontSize: 13,
    fontVariant: ['tabular-nums'],
    paddingHorizontal: 12,
    paddingVertical: 5,
    borderRadius: 999,
    overflow: 'hidden',
    backgroundColor: 'rgba(17, 17, 20, 0.7)',
  },

  failure: {
    position: 'absolute',
    left: 24,
    right: 24,
    top: '45%',
    padding: 14,
    borderRadius: 10,
    backgroundColor: 'rgba(17, 17, 20, 0.85)',
  },
  failureText: { color: '#FFFFFF', fontSize: 13, textAlign: 'center' },
});
