// web-ext configuration (lint, run, build, sign).
// The add-on lives entirely in extension/ — the PHP server, the mobile app
// and the tooling stay outside the package.
export default {
  sourceDir: 'extension',
  artifactsDir: 'dist',
  build: {
    filename: 'pouch-{version}.xpi',
  },
  run: {
    startUrl: ['about:debugging#/runtime/this-firefox'],
  },
};
