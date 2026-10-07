// 仓颉出站 HTTP/HTTPS 能力 spike —— 本地桩服务（模拟大模型 API 的各种返回形态）
//
// 用法：node stub.mjs [port]     默认 18080
//
// 端点（全部同时支持 GET / POST）：
//   /ok        200  {"ok":true,"data":{"title":"例会","owner_id":7}}
//   /badjson   200  {"ok": true, "data": {          <- 截断的非法 JSON
//   /fenced    200  ```json\n{"ok":true}\n```       <- 常见"模型包了代码块"形态
//   /prose     200  好的，建议如下：{"ok":true} 以上。 <- 前后带自然语言
//   /slow      200  延迟 ?ms= 毫秒后返回（默认 5000）<- 验证超时是否被真正执行
//   /e500      500  {"error":"boom"}
//   /e401      401  {"error":"unauthorized"}         <- 模拟无 API Key
//   /echo      200  回显 method / 关键 header / body  <- 验证鉴权头与请求体
//   /big       200  约 2 MB 文本                      <- 验证大响应体读取

import http from 'node:http';

const PORT = Number(process.argv[2] || 18080);
const started = Date.now();

function send(res, status, body, extraHeaders = {}) {
  const buf = Buffer.from(body, 'utf8');
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': buf.length,
    ...extraHeaders,
  });
  res.end(buf);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const path = url.pathname;
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    console.log(`[stub] ${req.method} ${path} body=${body.length}B`);

    switch (path) {
      case '/ok':
        return send(res, 200, JSON.stringify({ ok: true, data: { title: '例会', owner_id: 7 } }));

      case '/badjson':
        return send(res, 200, '{"ok": true, "data": {');

      case '/fenced':
        return send(res, 200, '```json\n{"ok":true,"data":{"title":"例会"}}\n```');

      case '/prose':
        return send(res, 200, '好的，建议如下：{"ok":true,"data":{"title":"例会"}} 以上。');

      case '/slow': {
        const ms = Number(url.searchParams.get('ms') || 5000);
        return setTimeout(
          () => send(res, 200, JSON.stringify({ ok: true, slow: true, ms })),
          ms,
        );
      }

      case '/e500':
        return send(res, 500, JSON.stringify({ error: 'boom' }));

      case '/e401':
        return send(res, 401, JSON.stringify({ error: 'unauthorized' }));

      case '/echo':
        return send(res, 200, JSON.stringify({
          ok: true,
          method: req.method,
          auth: req.headers['authorization'] || null,
          contentType: req.headers['content-type'] || null,
          custom: req.headers['x-spike'] || null,
          bodyLen: body.length,
          bodyEcho: body.slice(0, 200),
        }));

      case '/big':
        return send(res, 200, JSON.stringify({ ok: true, text: 'x'.repeat(2 * 1024 * 1024) }));

      default:
        return send(res, 404, JSON.stringify({ error: 'not found', path }));
    }
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[stub] listening on http://127.0.0.1:${PORT} (pid=${process.pid})`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[stub] ${sig} -> shutdown after ${Date.now() - started}ms`);
    server.close(() => process.exit(0));
  });
}
