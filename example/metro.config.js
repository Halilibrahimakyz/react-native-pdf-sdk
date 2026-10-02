const path = require('path');

const { getDefaultConfig } = require('@react-native/metro-config');
const { withMetroConfig } = require('react-native-monorepo-config');

/**
 * The library is the directory above this one, so Metro is told to watch it
 * and to resolve react, react-native and nitro from here rather than from
 * there. Without that it finds two copies of each and the bridge refuses to
 * start.
 *
 * `workspaces` is passed by hand because this repository is a library with an
 * example inside it rather than a workspace monorepo, and the helper reads
 * that field from the root `package.json` otherwise.
 */
module.exports = withMetroConfig(getDefaultConfig(__dirname), {
  root: path.resolve(__dirname, '..'),
  dirname: __dirname,
  workspaces: ['example'],
});
