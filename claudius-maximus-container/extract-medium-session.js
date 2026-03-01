#!/usr/bin/env node
// Extract Medium session cookies from a running Chrome via CDP.
// Usage: node extract-medium-session.js [cdp-port]
const { chromium } = require('playwright');

const CDP_PORT = process.argv[2] || '9222';

(async () => {
  try {
    const browser = await chromium.connectOverCDP(`http://localhost:${CDP_PORT}`);
    const contexts = browser.contexts();
    if (contexts.length === 0) {
      console.error('No browser contexts found. Is Chrome running with the right profile?');
      process.exit(1);
    }
    const context = contexts[0];
    const state = await context.storageState({ path: 'playwright-storage.json' });

    // Check if we actually got an authenticated session
    const mediumOrigin = state.origins?.find(o => o.origin === 'https://medium.com');
    const isLoggedIn = mediumOrigin?.localStorage?.find(
      e => e.name === 'viewer-status|is-logged-in'
    );

    // Check for sid cookie as primary auth indicator
    const hasSid = state.cookies?.some(
      c => c.name === 'sid' && c.domain?.includes('medium.com')
    );

    if (hasSid) {
      console.log('Session saved to playwright-storage.json (sid cookie found — authenticated)');
    } else if (isLoggedIn?.value === 'true') {
      console.log('Session saved to playwright-storage.json (logged in!)');
    } else {
      console.log('Session saved to playwright-storage.json');
      console.log('WARNING: no auth indicators found — you may not be logged in.');
    }

    // Disconnect without closing the browser
    await browser.close();
  } catch (err) {
    console.error('Failed to connect to Chrome CDP:', err.message);
    console.error(`Make sure Chrome is running with --remote-debugging-port=${CDP_PORT}`);
    process.exit(1);
  }
})();
