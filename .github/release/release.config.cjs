module.exports = {
  repositoryUrl: 'https://github.com/T-vK/Pryon-AFE-Runtime.git',
  branches: ['main'],
  tagFormat: 'v${version}',
  plugins: [
    ['@semantic-release/commit-analyzer', { preset: 'conventionalcommits' }],
    ['@semantic-release/release-notes-generator', {
      preset: 'conventionalcommits',
      writerOpts: {
        footerPartial: (context) => {
          const version = String(context.version).replace(/^v/, '');
          const base = `https://github.com/T-vK/Pryon-AFE-Runtime/releases/download/v${version}`;
          return `\n### Downloads\n\n- [afe (Android ARMv7, for Echo)](${base}/afe)\n- [pryon (Android ARMv7, for Echo)](${base}/pryon)\n`;
        },
      },
    }],
    ['@semantic-release/exec', {
      prepareCmd: 'make package RELEASE_VERSION=${nextRelease.version}',
    }],
    ['@semantic-release/github', {
      assets: [
        { path: 'dist/afe', label: 'afe (Android ARMv7, for Echo)' },
        { path: 'dist/pryon', label: 'pryon (Android ARMv7, for Echo)' },
        { path: 'dist/afe-testing', label: 'afe-testing (x86_64, for testing)' },
        { path: 'dist/pryon-testing', label: 'pryon-testing (x86_64, for testing)' },
        { path: 'dist/libasp-mock-testing.so' },
        { path: 'dist/libpryon-mock-testing.so' },
        { path: 'dist/afe.sha256' },
        { path: 'dist/pryon.sha256' },
        { path: 'dist/afe-testing.sha256' },
        { path: 'dist/pryon-testing.sha256' },
        { path: 'dist/libasp-mock-testing.so.sha256' },
        { path: 'dist/libpryon-mock-testing.so.sha256' },
        { path: 'release-assets/architecture-stock.png' },
        { path: 'release-assets/architecture-runtime.png' },
      ],
    }],
  ],
};
