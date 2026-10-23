import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { browserConfig } from './config.mjs';

export function allowedPath(input) {
  let decoded;
  try { decoded = decodeURIComponent(input.split('?')[0]); } catch { return null; }
  if (decoded.includes('\\') || decoded.includes('\0') || decoded.split('/').some(segment => segment === '..' || segment.startsWith('.'))) return null;
  if (decoded === '/' || decoded === '/index.html') return 'index.html';
  if (decoded === '/config.js') return 'config.js';
  if (/^\/src\/[a-zA-Z0-9_-]+\.(?:js|mjs|css)$/.test(decoded)) return decoded.slice(1);
  return null;
}

export async function startServer({ port = 4173, useDist = false } = {}) {
  const projectRoot = fileURLToPath(new URL('../', import.meta.url));
  const root = useDist ? path.join(projectRoot, 'dist') : projectRoot;
  const config = useDist ? null : await browserConfig(projectRoot);
  const server = createServer(async (request, response) => {
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Referrer-Policy', 'no-referrer');
    if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405); response.end(); return; }
    const file = allowedPath(request.url);
    if (!file) { response.writeHead(404); response.end('Not found'); return; }
    try {
      const bytes = file === 'config.js' && config
        ? Buffer.from(`globalThis.PAYSME_VOUCHERS_CONFIG = ${JSON.stringify(config)};`)
        : await readFile(path.join(root, file));
      response.setHeader('Content-Type', file.endsWith('.html') ? 'text/html; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/javascript; charset=utf-8');
      response.writeHead(200); response.end(request.method === 'HEAD' ? undefined : bytes);
    } catch (error) {
      response.writeHead(error.code === 'ENOENT' ? 404 : 500); response.end('Unable to serve this file.');
    }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return server;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = await startServer({ useDist: process.argv.includes('--dist') });
  console.log(`PaySME Vouchers is running at http://127.0.0.1:${server.address().port}`);
}
