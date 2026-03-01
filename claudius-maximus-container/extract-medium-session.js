#!/usr/bin/env node
// Extract Medium session cookies from a running Chrome via CDP.
//
// Filters cookies to Medium domains and verifies auth indicators.
// Saves Medium-only cookies + origins to a temporary file for merging.
//
// Usage: node extract-medium-session.js [cdp-port]

const { chromium } = require('playwright');
const fs = require('fs');

const CDP_PORT = process.argv[2] || '9222';
const OUTPUT = 'medium-session.json';

// Domains that belong to Medium
const MEDIUM_DOMAINS = ['.medium.com', 'medium.com'];

function isMediumDomain(domain) {
  return MEDIUM_DOMAINS.some(d => domain === d || domain.endsWith(d));
}

function isMediumOrigin(origin) {
  try {
    const host = new URL(origin).hostname;
    return host === 'medium.com' || host.endsWith('.medium.com');
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

    // Filter to Medium cookies and origins only
    const mediumState = {
      cookies: (fullState.cookies || []).filter(c => isMediumDomain(c.domain)),
      origins: (fullState.origins || []).filter(o => isMediumOrigin(o.origin)),
    };

    // CDP storageState() doesn't capture localStorage from pre-existing tabs.
    // Explicitly extract it from the Medium page.
    const pages = context.pages();
    const mediumPage = pages.find(p => {
      try { return new URL(p.url()).hostname.includes('medium.com'); } catch { return false; }
    });

    if (mediumPage) {
      const lsEntries = await mediumPage.evaluate(() => {
        const entries = [];
        for (let i = 0; i < localStorage.length; i++) {
          const key = localStorage.key(i);
          entries.push({ name: key, value: localStorage.getItem(key) });
        }
        return entries;
      });

      if (lsEntries.length > 0) {
        // Merge with any origins already captured (unlikely via CDP, but be safe)
        const existing = mediumState.origins.find(o => o.origin === 'https://medium.com');
        if (existing) {
          const lsMap = new Map(existing.localStorage.map(e => [e.name, e]));
          for (const e of lsEntries) lsMap.set(e.name, e);
          existing.localStorage = Array.from(lsMap.values());
        } else {
          mediumState.origins.push({
            origin: 'https://medium.com',
            localStorage: lsEntries,
          });
        }
        console.log(`Extracted ${lsEntries.length} localStorage entries from Medium tab`);
      }
    } else {
      console.log('NOTE: No Medium tab found — localStorage not captured.');
      console.log('Make sure medium.com is open in Chrome before running this script.');
    }

    fs.writeFileSync(OUTPUT, JSON.stringify(mediumState, null, 2) + '\n');

    // Check auth indicators
    const mediumOrigin = mediumState.origins.find(o => o.origin === 'https://medium.com');
    const isLoggedIn = mediumOrigin?.localStorage?.find(
      e => e.name === 'viewer-status|is-logged-in'
    );
    const hasSid = mediumState.cookies.some(
      c => c.name === 'sid' && c.domain?.includes('medium.com')
    );

    if (hasSid && isLoggedIn?.value === 'true') {
      console.log(`Medium session saved to ${OUTPUT} (sid + localStorage — fully authenticated)`);
    } else if (hasSid) {
      console.log(`Medium session saved to ${OUTPUT} (sid cookie found — authenticated)`);
    } else if (isLoggedIn?.value === 'true') {
      console.log(`Medium session saved to ${OUTPUT} (localStorage logged in)`);
    } else {
      console.log(`Medium session saved to ${OUTPUT}`);
      console.log('WARNING: no auth indicators found — you may not be logged in.');
    }

    console.log(`Cookies: ${mediumState.cookies.length}, Origins: ${mediumState.origins.length}`);

    // Disconnect without closing the browser
    await browser.close();
  } catch (err) {
    console.error('Failed to connect to Chrome CDP:', err.message);
    console.error(`Make sure Chrome is running with --remote-debugging-port=${CDP_PORT}`);
    process.exit(1);
  }
})();
