// Serves a Flutter web build with the headers of its _headers file, the way
// Workers Static Assets does (only the "/*" block is used), and answers the
// handshake of the live channel as the Worker does, without its signature.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
  '.png': 'image/png',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
};

export async function headersOf(root) {
  const headers = {};
  let inBlock = false;
  for (const line of (await readFile(join(root, '_headers'), 'utf8')).split('\n')) {
    if (line.startsWith('#') || !line.trim()) continue;
    if (!line.startsWith(' ')) {
      inBlock = line.trim() === '/*';
    } else if (inBlock) {
      const colon = line.indexOf(':');
      headers[line.slice(0, colon).trim()] = line.slice(colon + 1).trim();
    }
  }
  return headers;
}

export async function serve(root) {
  const headers = await headersOf(root);
  const server = createServer(async (request, response) => {
    let path = decodeURIComponent(new URL(request.url, 'http://x').pathname);
    if (path.endsWith('/')) path += 'index.html';
    const file = normalize(join(root, path));
    if (!file.startsWith(normalize(root)) || path.endsWith('/_headers')) {
      response.writeHead(404, headers).end();
      return;
    }
    try {
      const body = await readFile(file);
      response
        .writeHead(200, {
          ...headers,
          'Content-Type': types[extname(file)] ?? 'application/octet-stream',
        })
        .end(body);
    } catch {
      response.writeHead(404, headers).end();
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  // localhost, not the bare IP: WebAuthn refuses IP addresses as relying
  // party, and localhost is a secure context like the HTTPS deployment.
  const origin = `http://localhost:${server.address().port}`;
  const handshakes = [];
  const open = new Set();
  server.on('upgrade', (request, socket) => {
    const answer = liveHandshake(request, origin);
    handshakes.push({ path: request.url, origin: request.headers.origin, status: answer.status });
    if (answer.status !== 101) {
      socket.end(`HTTP/1.1 ${answer.status} ${answer.reason}\r\nConnection: close\r\n\r\n`);
      return;
    }
    socket.write(
      [
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Accept: ${answer.accept}`,
        `Sec-WebSocket-Protocol: ${liveProtocol}`,
        '',
        '',
      ].join('\r\n'),
    );
    open.add(socket);
    socket.on('close', () => open.delete(socket));
    socket.on('error', () => socket.destroy());
    // Nothing is sent; a close frame from the page (opcode 8) is answered
    // with an empty one, and the connection ends.
    socket.on('data', (frame) => {
      if ((frame[0] & 0x0f) === 0x08) socket.end(Buffer.from([0x88, 0x00]));
    });
  });
  server.on('close', () => open.forEach((socket) => socket.destroy()));
  return { server, origin, handshakes };
}

const liveProtocol = 'modusnote.live.v1';
const livePath = /^\/api\/w\/[0-9a-f]{32}\/live$/;

// What the Worker checks before a live channel reaches the workspace, apart
// from the signature: a GET to a workspace's /live from the app's own
// origin, offering the live subprotocol and exactly one mn1. credential.
// The answer picks the live subprotocol, as the Worker's does.
export function liveHandshake(request, origin) {
  const headers = request.headers;
  const offered = (headers['sec-websocket-protocol'] ?? '').split(',').map((name) => name.trim());
  if (request.method !== 'GET' || !livePath.test(request.url)) return { status: 404, reason: 'Not Found' };
  if (headers.origin !== undefined && headers.origin !== origin) return { status: 403, reason: 'Forbidden' };
  if (
    headers.upgrade?.toLowerCase() !== 'websocket' ||
    !headers['sec-websocket-key'] ||
    !offered.includes(liveProtocol)
  ) {
    return { status: 426, reason: 'Upgrade Required' };
  }
  if (offered.filter((name) => name.startsWith('mn1.')).length !== 1) {
    return { status: 401, reason: 'Unauthorized' };
  }
  const accept = createHash('sha1')
    .update(`${headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
  return { status: 101, accept };
}
