// End-to-end check of the built web client in Chrome, under the CSP and
// headers of web/_headers, on both builds Flutter ships: WebAssembly and
// the JavaScript fallback for browsers without WasmGC. Chrome's fake
// microphone (a beeping tone) stands in for a real one.
//
//   flutter build web --wasm --csp --no-web-resources-cdn
//   dart run tool/finalize_web_build.dart
//   (cd tool/web_e2e && npm ci && npm test)
//
// CHROME_PATH selects a Chrome binary; otherwise the installed Chrome is used.
import { chromium } from 'playwright-core';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { serve } from './serve.mjs';

const root = fileURLToPath(new URL('../../build/web/', import.meta.url));
const passphrase = 'correct horse battery staple';
const noteText = 'Persisted under the CSP';
const songTitle = 'Guide take';

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function scenario(browser, origin, mode) {
  const context = await browser.newContext({ locale: 'en-US', permissions: ['microphone'] });
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

  try {
  const settle = () => page.waitForTimeout(500);
  const semantics = async () => {
    await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  };
  // Flutter puts some texts only in the label of their semantics node.
  const labelled = (pattern, timeout) =>
    page.waitForFunction(
      (source) => {
        const wanted = new RegExp(source);
        return [...document.querySelectorAll('[aria-label]')].some((node) =>
          wanted.test(node.getAttribute('aria-label')),
        );
      },
      pattern.source,
      { timeout },
    );
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
  await page.keyboard.press('Enter');
  await page.keyboard.type('With `code` in the Markdown.');
  await page.getByRole('button', { name: 'Save' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 30000 });
  await settle();

  // A song with a guide track recorded from the microphone.
  await page.getByText('New note').first().click();
  await settle();
  await page.getByRole('checkbox', { name: 'Song' }).click();
  await settle();
  await type(0, songTitle);
  await page.getByRole('button', { name: 'Record' }).first().click();
  await page.getByText('Stop and attach').waitFor({ timeout: 30000 });
  await page.waitForTimeout(3000);
  await page.getByRole('button', { name: 'Stop and attach' }).click();
  await labelled(/Recording attached · 0:0[2-4]/, 30000);
  await page.getByRole('button', { name: 'Save' }).click();
  await page.getByText(songTitle).first().waitFor({ timeout: 30000 });
  await settle();

  await page.reload();
  await semantics();
  await page.getByText('Unlock your notes').waitFor({ timeout: 60000 });
  await type(0, 'not the passphrase');
  await page.getByRole('button', { name: 'Unlock' }).click();
  // Argon2id runs on the UI thread and the form is disabled meanwhile:
  // typing before the verdict would be lost on a slow machine.
  await page.getByText('Wrong passphrase.').waitFor({ timeout: 120000 });
  await settle();
  check(await page.getByText('Unlock your notes').count() > 0, 'a wrong passphrase opened the vault');
  check(await page.getByText(noteText).count() === 0, 'a note showed behind a wrong passphrase');
  // The field was emptied by the failed attempt; typing right after the
  // click loses keys while Flutter moves focus, so go through type().
  await type(0, passphrase);
  await settle();
  await page.getByRole('button', { name: 'Unlock' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 120000 });

  // A saved note opens on its Markdown preview.
  await page.getByText(noteText).first().click();
  await page.getByRole('button', { name: 'Preview' }).waitFor({ timeout: 30000 });
  await labelled(/With code in the Markdown/, 10000);
  await page.getByRole('button', { name: 'Back' }).click();
  await settle();

  // The take decrypts, decodes and plays after the reload.
  await page.getByText(songTitle).first().click();
  const play = page.getByRole('button', { name: 'Play recording' });
  await play.waitFor({ timeout: 30000 });
  // Let the page transition finish, or the tap lands on the moving route.
  await page.waitForTimeout(1500);
  await play.click();
  await page.getByRole('button', { name: 'Pause' }).waitFor({ timeout: 30000 });
  await labelled(/0:01 \/ 0:0[2-4]/, 10000);
  await page.getByRole('button', { name: 'Play recording' }).waitFor({ timeout: 10000 });
  await page.getByRole('button', { name: 'Back' }).click();
  await settle();

  // What the browser keeps must be ciphertext only.
  const leaks = await page.evaluate(async (needles) => {
    let found = 0;
    let bytes = 0;
    for (const database of ['modusnote', 'modusnote-blobs']) {
    const db = await new Promise((resolve, reject) => {
      const open = indexedDB.open(database);
      open.onsuccess = () => resolve(open.result);
      open.onerror = reject;
    });
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
    db.close();
    }
    const blobs = await new Promise((resolve) => {
      const open = indexedDB.open('modusnote-blobs');
      open.onsuccess = () => {
        const all = open.result.transaction('blobs').objectStore('blobs').getAll();
        all.onsuccess = () => { resolve(all.result); open.result.close(); };
      };
    });
    return { found, bytes, blobs };
  }, [noteText, passphrase, songTitle, 'OggS', 'OpusHead', 'RIFF']);
  check(leaks.bytes > 0, 'nothing was stored in IndexedDB');
  check(leaks.found === 0, 'a note, the passphrase or audio is stored in clear');
  check(
    leaks.blobs.length === 1 && leaks.blobs[0] > 0,
    `expected one committed recording, found ${JSON.stringify(leaks.blobs)}`,
  );

  const violations = await page.evaluate(() => window.__violations);
  check(violations.length === 0, `CSP violations: ${violations.join(', ')}`);
  check(problems.length === 0, problems.join('\n'));
  check(outside.length === 0, `requests outside the origin: ${outside.join(', ')}`);
  const main = mode === 'js' ? '/main.dart.js' : '/main.dart.wasm';
  check(loaded.includes(main), `the ${mode} build did not load ${main}`);
  return leaks.bytes;
  } catch (error) {
    // CI uploads failures/ as an artifact: what the page showed, and what
    // it logged, beat a bare timeout.
    await mkdir('failures', { recursive: true });
    await page.screenshot({ path: `failures/${mode}.png` }).catch(() => {});
    const labels = await page
      .evaluate(() => [...document.querySelectorAll('[aria-label]')].map((n) => n.getAttribute('aria-label')))
      .catch(() => []);
    error.message += `\non screen: ${JSON.stringify(labels)}`;
    if (problems.length > 0) error.message += `\n${problems.join('\n')}`;
    throw error;
  } finally {
    await context.close();
  }
}

const fakeMicrophone = ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'];
const { server, origin } = await serve(root);
const browser = await chromium.launch(
  process.env.CHROME_PATH
    ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox', ...fakeMicrophone] }
    : { channel: 'chrome', args: fakeMicrophone },
);
let failed = false;
for (const mode of ['wasm', 'js']) {
  try {
    const bytes = await scenario(browser, origin, mode);
    console.log(`ok ${mode}: vault created, note and recording saved, reloaded, unlocked, played; ${bytes} bytes stored, all ciphertext`);
  } catch (error) {
    failed = true;
    console.error(`FAIL ${mode}: ${error.message}`);
  }
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
