const path = require('path');

const { getConfig } = require('react-native-builder-bob/babel-config');

const pkg = require('../package.json');

/**
 * `react-native-pdf-sdk` resolves to the library's `src` here rather than to a
 * build, so an edit in the library shows up on the next reload.
 */
module.exports = getConfig(
  { presets: ['module:@react-native/babel-preset'] },
  { root: path.resolve(__dirname, '..'), pkg }
);
