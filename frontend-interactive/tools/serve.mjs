import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../dist');
const port = Number(process.env.PORT || 5178);
if (!fs.existsSync(path.join(root, 'index.html'))) { console.error('Please run npm run build first.'); process.exit(1); }
http.createServer((req, res) => {
  const requested = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
  const file = path.resolve(root, '.' + (requested === '/' ? '/index.html' : requested));
  if (file !== root && !file.startsWith(root + path.sep)) { res.writeHead(403); res.end(); return; }
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end('Not found'); return; }
  res.setHeader('Content-Type', file.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream');
  res.setHeader('Cache-Control', 'no-store'); fs.createReadStream(file).pipe(res);
}).listen(port, '127.0.0.1', () => console.log('Preview: http://127.0.0.1:' + port));
