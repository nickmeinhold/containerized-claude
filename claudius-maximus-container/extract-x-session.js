#!/usr/bin/env node
// Extract X/Twitter session cookies from a running Chrome via CDP.
//
// Filters cookies to X/Twitter domains and verifies key auth indicators.
// Saves X-only cookies + origins to a temporary file for merging.
//
// Usage: node extract-x-session.js [cdp-port]

const { chromium } = require('playwright');
const fs = require('fs');

const CDP_PORT = process.argv[2] || '9222';
const OUTPUT = 'x-session.json';

// Domains that belong to X/Twitter
const X_DOMAINS = ['.x.com', '.twitter.com', '.twimg.com', 'x.com', 'twitter.com', 'twimg.com'];

function isXDomain(domain) {
  return X_DOMAINS.some(d => domain === d || domain.endsWith(d));
}

function isXOrigin(origin) {
  try {
    const host = new URL(origin).hostname;
    return host === 'x.com' || host === 'twitter.com' ||
           host.endsWith('.x.com') || host.endsWith('.twitter.com');
  } catch {
    return false;
  }
}

(async () => {
  try {
    const browser = await chromium.connectOverCDP(`http://localhost:${CDP_PORT}`);
    const contexts = browser.contexts();
    if (contexts.length === 0) {
      console.error('No browser contexts found. Is Chrome running with the right profile?');
      process.exit(1);
    }

    const context = contexts[0];
    const fullState = await context.storageState();

    // Filter to X/Twitter cookies and origins only
    const xState = {
      cookies: (fullState.cookies || []).filter(c => isXDomain(c.domain)),
      origins: (fullState.origins || []).filter(o => isXOrigin(o.origin)),
    };

    fs.writeFileSync(OUTPUT, JSON.stringify(xState, null, 2) + '\n');

    // Check auth indicators
    const authToken = xState.cookies.find(c => c.name === 'auth_token');
    const ct0 = xState.cookies.find(c => c.name === 'ct0');
    const twid = xState.cookies.find(c => c.name === 'twid');

    const indicators = [];
    if (authToken) indicators.push('auth_token');
    if (ct0) indicators.push('ct0');
    if (twid) indicators.push(`twid=${decodeURIComponent(twid.value)}`);

    if (indicators.length >= 2) {
      console.log(`X session saved to ${OUTPUT} (${indicators.join(', ')} — authenticated)`);
    } else {
      console.log(`X session saved to ${OUTPUT}`);
      console.log(`WARNING: only found [${indicators.join(', ')}] — you may not be logged in.`);
      console.log('Expected: auth_token, ct0, twid');
    }

    console.log(`Cookies: ${xState.cookies.length}, Origins: ${xState.origins.length}`);

    await browser.close();
  } catch (err) {
    console.error('Failed to connect to Chrome CDP:', err.message);
    console.error(`Make sure Chrome is running with --remote-debugging-port=${CDP_PORT}`);
    process.exit(1);
  }
})();
