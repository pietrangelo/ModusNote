// End-to-end check of the built web client in Chrome, under the CSP and
// headers of web/_headers, on both builds Flutter ships: WebAssembly and
// the JavaScript fallback for browsers without WasmGC.
//
//   flutter build web --wasm --csp --no-web-resources-cdn
//   dart run tool/finalize_web_build.dart
//   (cd tool/web_e2e && npm ci && npm test)
//
// CHROME_PATH selects a Chrome binary; otherwise the installed Chrome is used.
import { chromium } from 'playwright-core';
import { fileURLToPath } from 'node:url';
import { serve } from './serve.mjs';

const root = fileURLToPath(new URL('../../build/web/', import.meta.url));
const passphrase = 'correct horse battery staple';
const noteText = 'Persisted under the CSP';

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function scenario(browser, origin, mode) {
  const context = await browser.newContext({ locale: 'en-US' });
  const page = await context.newPage();
  const problems = [];
  const outside = [];
  const loaded = [];
  page.on('pageerror', (error) => problems.push(`page error: ${error.message}`));
  page.on('console', (message) => {
    if (message.type() === 'error') problems.push(`console: ${message.text()}`);
  });
  page.on('request', (request) => {
    const url = request.url();
    if (!url.startsWith(origin) && !url.startsWith(`blob:${origin}/`)) outside.push(url);
  });
  page.on('response', (response) => loaded.push(new URL(response.url()).pathname));
  await page.addInitScript((forceJs) => {
    window.__violations = [];
    document.addEventListener('securitypolicyviolation', (event) =>
      window.__violations.push(`${event.violatedDirective} ${event.blockedURI}`),
    );
    // How Flutter's loader detects WasmGC: make it pick the JS build.
    if (forceJs) WebAssembly.validate = () => false;
  }, mode === 'js');

  const settle = () => page.waitForTimeout(500);
  const semantics = async () => {
    await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  };
  const type = async (index, text) => {
    await page.getByRole('textbox').nth(index).click();
    await settle();
    await page.keyboard.type(text);
  };

  await page.goto(origin);
  await semantics();
  await page.getByText('Create your vault').waitFor({ timeout: 60000 });
  await type(0, passphrase);
  await type(1, passphrase);
  await page.getByRole('button', { name: 'Create vault' }).click();
  await page.getByText('New note').first().waitFor({ timeout: 120000 });

  await page.getByText('New note').first().click();
  await settle();
  await type(0, noteText);
  await page.getByRole('button', { name: 'Save' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 30000 });
  await settle();

  await page.reload();
  await semantics();
  await page.getByText('Unlock your notes').waitFor({ timeout: 60000 });
  await type(0, 'not the passphrase');
  await page.getByRole('button', { name: 'Unlock' }).click();
  await page.waitForTimeout(4000);
  check(await page.getByText('Unlock your notes').count() > 0, 'a wrong passphrase opened the vault');
  check(await page.getByText(noteText).count() === 0, 'a note showed behind a wrong passphrase');
  await page.getByRole('textbox').nth(0).click();
  await page.keyboard.press('Control+A');
  await page.keyboard.type(passphrase);
  await page.getByRole('button', { name: 'Unlock' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 120000 });

  // What the browser keeps must be ciphertext only.
  const leaks = await page.evaluate(async (needles) => {
    const db = await new Promise((resolve, reject) => {
      const open = indexedDB.open('modusnote');
      open.onsuccess = () => resolve(open.result);
      open.onerror = reject;
    });
    let found = 0;
    let bytes = 0;
    for (const name of db.objectStoreNames) {
      const rows = await new Promise((resolve) => {
        const all = db.transaction(name).objectStore(name).getAll();
        all.onsuccess = () => resolve(all.result);
      });
      for (const row of rows) {
        let text;
        if (row instanceof Blob) text = new Uint8Array(await row.arrayBuffer());
        else if (row instanceof ArrayBuffer) text = new Uint8Array(row);
        else if (ArrayBuffer.isView(row)) text = new Uint8Array(row.buffer);
        else text = new TextEncoder().encode(JSON.stringify(row));
        bytes += text.length;
        const latin1 = new TextDecoder('latin1').decode(text);
        for (const needle of needles) if (latin1.includes(needle)) found++;
      }
    }
    return { found, bytes };
  }, [noteText, passphrase]);
  check(leaks.bytes > 0, 'nothing was stored in IndexedDB');
  check(leaks.found === 0, 'the note or the passphrase is stored in clear');

  const violations = await page.evaluate(() => window.__violations);
  check(violations.length === 0, `CSP violations: ${violations.join(', ')}`);
  check(problems.length === 0, problems.join('\n'));
  check(outside.length === 0, `requests outside the origin: ${outside.join(', ')}`);
  const main = mode === 'js' ? '/main.dart.js' : '/main.dart.wasm';
  check(loaded.includes(main), `the ${mode} build did not load ${main}`);
  await context.close();
  return leaks.bytes;
}

const { server, origin } = await serve(root);
const browser = await chromium.launch(
  process.env.CHROME_PATH
    ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] }
    : { channel: 'chrome' },
);
let failed = false;
for (const mode of ['wasm', 'js']) {
  try {
    const bytes = await scenario(browser, origin, mode);
    console.log(`ok ${mode}: vault created, note saved, reloaded, unlocked; ${bytes} bytes stored, all ciphertext`);
  } catch (error) {
    failed = true;
    console.error(`FAIL ${mode}: ${error.message}`);
  }
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
