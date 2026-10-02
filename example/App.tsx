import { useState } from 'react';
import {
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';

import { PdfDemo } from './src/PdfDemo';
import { PdfLab } from './src/PdfLab';

/**
 * Two documents, both drawn by `example/pdfs/make.swift` and kept in this
 * repository. They are opened over https rather than from the app bundle
 * because that is what a document in a real app is: something fetched. The
 * view keeps what it fetches, so the second launch does not need the network.
 */
const RAW =
  'https://raw.githubusercontent.com/Halilibrahimakyz/react-native-pdf-sdk/main/example/pdfs';

const DOCUMENTS = [
  {
    key: 'sheet',
    title: 'A sheet',
    note: 'One page, 26000 × 1500 points. Nine metres of drawing, with notes set at four points.',
    uri: `${RAW}/sheet.pdf`,
  },
  {
    key: 'report',
    title: 'A report',
    note: 'Ten A4 pages of text and tables. The case every viewer is built for.',
    uri: `${RAW}/report.pdf`,
  },
] as const;

type Mode = 'viewer' | 'lab';

export default function App() {
  return (
    <SafeAreaProvider>
      {/* Every screen here is light, and Android draws white icons on a dark
          theme, which on a white page is an empty strip where the clock
          should be. */}
      <StatusBar barStyle="dark-content" backgroundColor="transparent" />
      <Home />
    </SafeAreaProvider>
  );
}

function Home() {
  const insets = useSafeAreaInsets();
  const [mode, setMode] = useState<Mode>('viewer');
  const [open, setOpen] = useState<string | null>(null);

  if (open != null) {
    if (mode === 'viewer') {
      return <PdfDemo source={open} onClose={() => setOpen(null)} />;
    }
    return (
      <View style={[styles.lab, { paddingTop: insets.top }]}>
        <Pressable onPress={() => setOpen(null)} style={styles.back}>
          <Text style={styles.backText}>‹ Documents</Text>
        </Pressable>
        <PdfLab path={open} remote={{ uri: open }} />
      </View>
    );
  }

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + 28, paddingBottom: insets.bottom + 28 },
      ]}
    >
      <Text style={styles.title}>PDF SDK</Text>
      <Text style={styles.lead}>
        A viewer that draws the part of the page you are looking at, at the zoom
        you are looking at it, with the renderer the platform ships.
      </Text>

      <Text style={styles.section}>Open with</Text>
      <View style={styles.modes}>
        {(['viewer', 'lab'] as const).map(value => (
          <Pressable
            key={value}
            onPress={() => setMode(value)}
            style={[styles.mode, mode === value && styles.modeOn]}
          >
            <Text style={[styles.modeText, mode === value && styles.modeTextOn]}>
              {value === 'viewer' ? 'The viewer' : 'The lab'}
            </Text>
          </Pressable>
        ))}
      </View>
      <Text style={styles.hint}>
        {mode === 'viewer'
          ? 'The document, a page counter and a way back. About forty lines of screen.'
          : 'Every property, every event and both methods, with a live readout.'}
      </Text>

      <Text style={styles.section}>Documents</Text>
      {DOCUMENTS.map(document => (
        <Pressable
          key={document.key}
          onPress={() => setOpen(document.uri)}
          style={styles.card}
        >
          <Text style={styles.cardTitle}>{document.title}</Text>
          <Text style={styles.cardNote}>{document.note}</Text>
        </Pressable>
      ))}

      <Text style={styles.footer}>
        Both are fetched the first time and kept on disk afterwards. Nothing
        pictured belongs to anyone: every line of both documents is drawn by a
        script in this repository.
      </Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#FFFFFF' },
  content: { paddingHorizontal: 20 },

  title: { fontSize: 30, fontWeight: '700', color: '#111114' },
  lead: { marginTop: 8, fontSize: 15, lineHeight: 21, color: '#51515A' },

  section: {
    marginTop: 28,
    marginBottom: 10,
    fontSize: 12,
    letterSpacing: 1,
    color: '#8A8A93',
  },

  modes: { flexDirection: 'row', gap: 8 },
  mode: {
    flex: 1,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#DEDEE3',
    alignItems: 'center',
  },
  modeOn: { backgroundColor: '#111114', borderColor: '#111114' },
  modeText: { fontSize: 14, color: '#51515A' },
  modeTextOn: { color: '#FFFFFF' },
  hint: { marginTop: 8, fontSize: 13, lineHeight: 18, color: '#8A8A93' },

  card: {
    marginBottom: 10,
    padding: 16,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#DEDEE3',
  },
  cardTitle: { fontSize: 17, fontWeight: '600', color: '#111114' },
  cardNote: {
    marginTop: 4,
    fontSize: 13,
    lineHeight: 19,
    color: '#6B6B74',
  },

  footer: {
    marginTop: 24,
    fontSize: 12,
    lineHeight: 18,
    color: '#A0A0A8',
  },

  lab: { flex: 1, backgroundColor: '#FFFFFF' },
  back: { paddingHorizontal: 16, paddingVertical: 12 },
  backText: { fontSize: 15, color: '#111114' },
});
