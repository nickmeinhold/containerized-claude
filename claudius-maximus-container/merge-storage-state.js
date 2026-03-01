#!/usr/bin/env node
// Merge two Playwright storage state files.
//
// Cookies are keyed by (name, domain, path) — values from the "new" file win.
// Origins are keyed by URL; within each origin, localStorage entries are merged
// by key (new wins). This lets capture scripts for different sites (Medium, X)
// coexist in a single playwright-storage.json without overwriting each other.
//
// Usage:
//   node merge-storage-state.js <base.json> <new.json> [output.json]
//
// If output.json is omitted, the result is written back to base.json.

const fs = require('fs');
const path = require('path');

function loadState(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  } catch (err) {
    if (err.code === 'ENOENT') {
      // File doesn't exist yet — start with empty state
      return { cookies: [], origins: [] };
    }
    throw err;
  }
}

function cookieKey(cookie) {
  return `${cookie.name}\0${cookie.domain}\0${cookie.path}`;
}

function mergeStorageStates(base, overlay) {
  // Merge cookies: keyed by (name, domain, path), overlay wins
  const cookieMap = new Map();
  for (const c of (base.cookies || [])) {
    cookieMap.set(cookieKey(c), c);
  }
  for (const c of (overlay.cookies || [])) {
    cookieMap.set(cookieKey(c), c);
  }

  // Merge origins: keyed by origin URL, localStorage merged by key
  const originMap = new Map();
  for (const o of (base.origins || [])) {
    originMap.set(o.origin, { origin: o.origin, localStorage: [...(o.localStorage || [])] });
  }
  for (const o of (overlay.origins || [])) {
    const existing = originMap.get(o.origin);
    if (existing) {
      // Merge localStorage entries by key
      const lsMap = new Map();
      for (const item of existing.localStorage) {
        lsMap.set(item.name, item);
      }
      for (const item of (o.localStorage || [])) {
        lsMap.set(item.name, item);
      }
      existing.localStorage = Array.from(lsMap.values());
    } else {
      originMap.set(o.origin, { origin: o.origin, localStorage: [...(o.localStorage || [])] });
    }
  }

  return {
    cookies: Array.from(cookieMap.values()),
    origins: Array.from(originMap.values()),
  };
}

// --- CLI ---
if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length < 2 || args.length > 3) {
    console.error('Usage: node merge-storage-state.js <base.json> <new.json> [output.json]');
    process.exit(1);
  }

  const [basePath, newPath, outputPath] = args;
  const dest = outputPath || basePath;

  const base = loadState(basePath);
  const overlay = loadState(newPath);
  const merged = mergeStorageStates(base, overlay);

  fs.writeFileSync(dest, JSON.stringify(merged, null, 2) + '\n');

  const stats = {
    baseCookies: (base.cookies || []).length,
    overlayCookies: (overlay.cookies || []).length,
    mergedCookies: merged.cookies.length,
    mergedOrigins: merged.origins.length,
  };
  console.log(`Merged: ${stats.baseCookies} base + ${stats.overlayCookies} new → ${stats.mergedCookies} cookies, ${stats.mergedOrigins} origins`);
  console.log(`Written to ${dest}`);
}

module.exports = { mergeStorageStates, loadState };
