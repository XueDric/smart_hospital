// AI-2 复现桩：把响应体**分块慢发**，逼出「读不满缓冲区但流没结束」的短读。
//
// 为什么必须分块慢发：localhost 上一次性 write 整个 body 时，客户端往往只需
// 几次「读满 4096」就读完了，框架那条 `if (n < buf.size) break` 永远不触发
// —— 这也正是评审「未能活复现」的原因。分块 + 小延迟后，客户端每次 read
// 只能拿到当前已到达的那一小块（< 4096），短读必然发生。
//
// 用法：node stub.mjs [port]      默认 19001
// 端点：POST /v1/chat/completions?size=<字节数>
//       返回 OpenAI 兼容响应，其中 message.content 是一个**合法 JSON 字符串**，
//       总长度按 size 参数补齐（合法，因此不合法 JSON 不会成为干扰变量）。

import http from 'node:http';

const PORT = Number(process.argv[2] || 19001);
let requestCount = 0;

/** 造一个合法的模型输出 JSON，使整个 content 字符串恰好约 targetBytes 字节（UTF-8）。 */
function makeContent(targetBytes) {
  // {"answer":"<pad>","basis":["permission: p"]}
  const head = '{"answer":"';
  const tail = '","basis":["permission: p"]}';
  const padLen = Math.max(0, targetBytes - Buffer.byteLength(head + tail, 'utf8'));
  return head + 'a'.repeat(padLen) + tail;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    requestCount += 1;
    if (url.pathname !== '/v1/chat/completions') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"error":"not found"}');
      return;
    }
    const size = Number(url.searchParams.get('size') || 3000);
    const content = makeContent(size);
    const body = Buffer.from(JSON.stringify({
      id: 'stub',
      object: 'chat.completion',
      choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      stub: { requestedContentBytes: size, requestIndex: requestCount },
    }), 'utf8');

    console.log(`[stub] #${requestCount} size=${size} -> body=${body.length}B chunks...`);
    // 分块慢发：每块 1000 字节，块间 20ms。客户端每次 read 只能拿到一块。
    res.writeHead(200, { 'content-type': 'application/json', 'transfer-encoding': 'chunked' });
    const CHUNK = 1000;
    let offset = 0;
    const timer = setInterval(() => {
      if (offset >= body.length) {
        clearInterval(timer);
        res.end();
        return;
      }
      const end = Math.min(offset + CHUNK, body.length);
      res.write(body.subarray(offset, end));
      offset = end;
    }, 20);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[stub] listening on http://127.0.0.1:${PORT} (chunked, 1000B/20ms)`);
});
