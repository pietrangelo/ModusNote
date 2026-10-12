// Serves a Flutter web build with the headers of its _headers file, the way
// Cloudflare Pages does (only the "/*" block is used).
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
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}
