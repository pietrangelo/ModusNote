// End-to-end check of the built web client in Chrome, under the CSP and
// headers of web/_headers, on both builds Flutter ships: WebAssembly and
// the JavaScript fallback for browsers without WasmGC. Chrome's fake
// microphone (a beeping tone) stands in for a real one, and its virtual
// WebAuthn authenticator (with PRF, user verification always granted) for
// a passkey.
//
//   flutter build web --wasm --csp --no-web-resources-cdn
//   dart run tool/finalize_web_build.dart
//   (cd tool/web_e2e && npm ci && npm test)
//
// CHROME_PATH selects a Chrome binary; otherwise the installed Chrome is used.
import { chromium } from 'playwright-core';
import { mkdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { serve } from './serve.mjs';

const root = fileURLToPath(new URL('../../build/web/', import.meta.url));
const passphrase = 'correct horse battery staple';
const noteText = 'Persisted under the CSP';
const songTitle = 'Guide take';
const livePath = `/api/w/${'0'.repeat(32)}/live`;
// Shaped like the device's credential, mn1.<key>.<ms>.<nonce>.<signature>;
// nothing here checks the signature.
const liveToken = `mn1.${'A'.repeat(43)}.${Date.now()}.${'A'.repeat(22)}.${'A'.repeat(86)}`;

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function scenario(browser, origin, handshakes, mode) {
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
  // The live channel is a WebSocket to the page's own origin (ws: or wss:);
  // one anywhere else counts as a request outside it.
  const sockets = [];
  page.on('websocket', (socket) => {
    sockets.push(socket.url());
    const url = new URL(socket.url());
    const own = new URL(origin);
    const scheme = own.protocol === 'https:' ? 'wss:' : 'ws:';
    if (url.protocol !== scheme || url.host !== own.host) outside.push(socket.url());
  });
  page.on('response', (response) => loaded.push(new URL(response.url()).pathname));
  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable', { enableUI: false });
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      ctap2Version: 'ctap2_1',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      hasPrf: true,
      automaticPresenceSimulation: true,
    },
  });
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
  const typeInto = async (name, text) => {
    await page.getByRole('textbox', { name }).click();
    await settle();
    await page.keyboard.type(text);
  };

  await page.goto(origin);
  await semantics();
  await page.getByText('Create your vault').waitFor({ timeout: 60000 });
  await type(0, passphrase);
  await type(1, passphrase);
  await page.getByRole('checkbox', { name: /nobody can recover my notes/ }).click();
  await settle();
  await page.getByRole('button', { name: 'Create vault' }).click();
  await page.getByText('New note').first().waitFor({ timeout: 120000 });

  await page.getByText('New note').first().click();
  await settle();
  // The window is wide enough for three columns: the note opens beside the
  // list. A quick note's Markdown body is styled as it is typed, and
  // closing the note saves it.
  await typeInto(/^Content/, noteText);
  await page.keyboard.press('Enter');
  await page.keyboard.type('With `code` in the Markdown.');
  await page.getByText('Saved').waitFor({ timeout: 30000 });
  await page.getByRole('button', { name: 'Close' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 30000 });
  await settle();

  // A song with a guide track recorded from the microphone.
  await page.getByText('New note').first().click();
  await settle();
  await page.getByRole('button', { name: /^Note type(?!s)/ }).click();
  await page.getByLabel('Song', { exact: true }).click();
  await settle();
  await typeInto(/^Title/, songTitle);
  await page.getByRole('button', { name: 'Record' }).first().click();
  // The sheet shows its stop button before the microphone has started, and
  // its counter only once it has: count three seconds of the take itself,
  // not of a microphone that may take seconds to open on a busy runner.
  await page.getByText(/^0:0[3-9]$/).first().waitFor({ timeout: 30000 });
  await page.getByRole('button', { name: 'Stop and attach' }).click();
  await labelled(/Recording attached · 0:0[3-9]/, 30000);
  await page.getByText('Saved').waitFor({ timeout: 30000 });
  await page.getByRole('button', { name: 'Close' }).click();
  await page.getByText(songTitle).first().waitFor({ timeout: 30000 });
  await settle();

  await page.reload();
  await semantics();
  await page.getByText('Unlock your notes').waitFor({ timeout: 60000 });
  await type(0, 'not the passphrase');
  await page.getByRole('button', { name: 'Unlock' }).click();
  // Argon2id runs on the UI thread and the form is disabled meanwhile:
  // typing before the verdict would be lost on a slow machine.
  await page.getByText('Wrong passphrase.').first().waitFor({ timeout: 120000 });
  await settle();
  check(await page.getByText('Unlock your notes').count() > 0, 'a wrong passphrase opened the vault');
  check(await page.getByText(noteText).count() === 0, 'a note showed behind a wrong passphrase');
  // The field was emptied by the failed attempt; typing right after the
  // click loses keys while Flutter moves focus, so go through type().
  await type(0, passphrase);
  await settle();
  await page.getByRole('button', { name: 'Unlock' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 120000 });

  // The command palette finds a saved note from the keyboard; it opens
  // beside the list, with the formatting toolbar.
  await page.keyboard.press('Control+KeyP');
  await page.getByRole('textbox', { name: /Search notes or commands/ }).waitFor({ timeout: 10000 });
  await settle();
  await page.keyboard.type(noteText);
  await settle();
  await page.keyboard.press('Enter');
  await page.getByRole('button', { name: /^Bold/ }).waitFor({ timeout: 30000 });
  await page.getByText('Saved').waitFor({ timeout: 10000 });
  await page.getByRole('button', { name: 'Close' }).click();
  await settle();

  // The take decrypts, decodes and plays after the reload.
  await page.getByText(songTitle).first().click();
  const play = page.getByRole('button', { name: 'Play recording' });
  await play.waitFor({ timeout: 30000 });
  await settle();
  await play.click();
  await page.getByRole('button', { name: 'Pause' }).waitFor({ timeout: 30000 });
  await labelled(/0:01 \/ 0:0[3-9]/, 10000);
  await page.getByRole('button', { name: 'Play recording' }).waitFor({ timeout: 10000 });
  await page.getByRole('button', { name: 'Close' }).click();
  await settle();

  // Ctrl+click picks a note instead of opening it; Escape lets it go.
  await page.getByText(noteText).first().click({ modifiers: ['Control'] });
  await page.getByText('1 note selected').waitFor({ timeout: 10000 });
  await settle();
  await page.keyboard.press('Escape');
  await page.getByText(/notes? selected/).waitFor({ state: 'detached', timeout: 10000 });
  await settle();

  // The encrypted backup downloads as ciphertext and restores into the
  // same vault, adding nothing; the Markdown export is in clear, after a
  // warning.
  // Actions that give lasting access ask for the passphrase again, unless
  // an earlier confirmation still lasts.
  const confirmIfAsked = async () => {
    const asked = await page
      .getByText("Confirm it's you")
      .first()
      .waitFor({ timeout: 3000 })
      .then(() => true, () => false);
    if (!asked) return;
    await typeInto('Passphrase', passphrase);
    await page.getByRole('button', { name: 'Confirm', exact: true }).click();
    await page.getByText("Confirm it's you").first().waitFor({ state: 'detached', timeout: 60000 });
    await settle();
  };
  const backupSheet = async (item) => {
    await page.getByRole('button', { name: 'Backup and export' }).click();
    await confirmIfAsked();
    await settle();
    await page.getByText(item).click();
    await settle();
  };
  await backupSheet('Download an encrypted backup');
  await typeInto('Backup phrase', 'una frase per il backup');
  await typeInto('Repeat the phrase', 'una frase per il backup');
  const backupDownload = page.waitForEvent('download', { timeout: 60000 });
  await page.getByRole('button', { name: 'Continue' }).click();
  const backupPath = await (await backupDownload).path();
  const backup = await readFile(backupPath);
  if (backup.subarray(0, 4).toString('latin1') !== 'MNBK' ||
      backup.includes(Buffer.from(noteText))) {
    throw new Error(`${mode}: the backup is not sealed`);
  }
  await page.getByText('Backup downloaded.').first().waitFor({ timeout: 10000 });
  await settle();

  // The restore asks for the file first.
  const chooser = page.waitForEvent('filechooser', { timeout: 30000 });
  await backupSheet('Restore a backup');
  await (await chooser).setFiles(backupPath);
  await settle();
  await typeInto('Backup phrase', 'una frase per il backup');
  await page.keyboard.press('Enter');
  await page.getByText(/Restore done: 0 added, [1-9][0-9]* already here\./).first().waitFor({ timeout: 60000 });
  await settle();

  await backupSheet('Export as Markdown');
  await page.getByText('Export in clear?').waitFor({ timeout: 10000 });
  const markdownDownload = page.waitForEvent('download', { timeout: 30000 });
  await page.getByRole('button', { name: 'Export', exact: true }).click();
  const zip = await readFile(await (await markdownDownload).path());
  if (zip.subarray(0, 4).toString('latin1') !== 'PK\x03\x04' ||
      !zip.includes(Buffer.from(noteText))) {
    throw new Error(`${mode}: the Markdown export lacks the note`);
  }
  await page.getByText('Notes exported.').first().waitFor({ timeout: 10000 });
  await settle();

  // A passkey replaces the passphrase after the next reload.
  await page.getByRole('button', { name: 'Passkey unlock' }).click();
  await page.getByRole('button', { name: 'Set up passkey' }).click();
  await confirmIfAsked();
  // The snackbar's text, not Flutter's aria-live announcement of it, which
  // may or may not still be in the page.
  await page
    .locator('span', { hasText: 'Passkey ready. Next time you can unlock with it.' })
    .waitFor({ timeout: 30000 });
  const { credentials } = await cdp.send('WebAuthn.getCredentials', { authenticatorId });
  check(credentials.length === 1, `expected one passkey, found ${credentials.length}`);
  await settle();
  await page.reload();
  await semantics();
  await page.getByRole('button', { name: 'Unlock with passkey' }).click();
  await page.getByText(noteText).first().waitFor({ timeout: 60000 });
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

  // The live channel, opened from the page as LiveLink does, under the
  // served CSP and Trusted Types: the sync is off here, so the app opens
  // none itself. The local server checks the handshake as the Worker does,
  // apart from the signature, and answers with the live subprotocol.
  const before = handshakes.length;
  const live = await page.evaluate(async ({ path, token }) => {
    let socket;
    try {
      socket = new WebSocket(`${location.origin.replace(/^http/, 'ws')}${path}`, [
        'modusnote.live.v1',
        token,
      ]);
    } catch (error) {
      return { outcome: `refused: ${error.message}` };
    }
    const outcome = await new Promise((resolve) => {
      socket.onopen = () => resolve('open');
      socket.onerror = () => resolve('error');
      socket.onclose = (event) => resolve(`closed ${event.code}`);
    });
    const protocol = socket.protocol;
    socket.close();
    return { outcome, protocol };
  }, { path: livePath, token: liveToken });
  check(
    live.outcome === 'open' && live.protocol === 'modusnote.live.v1',
    `the live channel did not open: ${JSON.stringify(live)}`,
  );
  check(
    sockets.length === 1 && new URL(sockets[0]).host === new URL(origin).host,
    `expected one WebSocket to the page's origin, saw ${JSON.stringify(sockets)}`,
  );
  const seen = handshakes.slice(before);
  check(
    seen.length === 1 && seen[0].path === livePath && seen[0].origin === origin,
    `expected one live handshake from the page, the server saw ${JSON.stringify(seen)}`,
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
const { server, origin, handshakes } = await serve(root);
const browser = await chromium.launch(
  process.env.CHROME_PATH
    ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox', ...fakeMicrophone] }
    : { channel: 'chrome', args: fakeMicrophone },
);
let failed = false;
for (const mode of ['wasm', 'js']) {
  try {
    const bytes = await scenario(browser, origin, handshakes, mode);
    console.log(`ok ${mode}: vault created, note and recording saved, reloaded, unlocked, played, passkey set up and used, live channel opened; ${bytes} bytes stored, all ciphertext`);
  } catch (error) {
    failed = true;
    console.error(`FAIL ${mode}: ${error.message}`);
  }
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
