// AI 端到端联调用的桩服务（OpenAI 兼容）。
//
// 为什么要有它：真模型不可控（不稳定、要钱、断网就没了），而端到端要验的是
// 「服务端在**各种模型返回**下的行为」—— 三态降级、重试、永不 5xx。
//
// 用法：node ai-stub.mjs [port]      默认 19100
//   POST /v1/chat/completions   按 mode 返回
//   POST /__mode?m=<mode>       切换模式（联调脚本用它验不同分支，无需重启）
//   GET  /__stats               看收到几次请求（验节流/重试次数用）
//
// mode：
//   ok        按提示词判断是哪个功能，返回**合法**的结构化 JSON
//   garbage   返回非 JSON 的话术（验「归一化失败 → 重试 → 降级」）
//   fenced    返回 ```json 围栏包裹（验 extractJson 剥围栏）
//   e500      返回 500（验服务端错误 → 可重试 → 降级）
//   e401      返回 401（验不可重试 → 立刻降级）
//   slow      睡 5 秒（验超时）

import http from 'node:http';

const PORT = Number(process.argv[2] || 19100);
let mode = 'ok';
let requests = 0;
// P2 写操作 e2e 用：从 /__mode?task=N 带过来，喂给 agentwrite 剧本
let stubTask = 0;
// R-17（2026-10-05 晚修）：记录 Authorization，供 e2e 断言 Bearer 拼装正确。
// 原先桩接受任意（或缺失）的 Authorization -> ai_client.cj 里
// headers["authorization"] = "Bearer " + apiKey 这一句**没有任何测试证明**，
// 密钥完全缺失时 mode=ok 也照样通过。
const authSeen = new Set();
// F-4：记录"重定向目标被请求过几次"。fail-closed 的判据就是它必须恒为 0。
let stolen = 0;

/** /ai/agent 的三种剧本。第二轮靠 prompt 里有没有"你已经查到的数据"来区分。 */
function pickAgentPayload(prompt, mode) {
  const round2 = prompt.includes('你已经查到的数据');
  if (mode === 'agent') {
    // 先查一次工具，再给最终回答 —— 正好两轮
    return round2 ? { final: '桩：部门统计已查到，共 2 人。（第 2 轮）' } : { tool: 'dept_stats', args: {} };
  }
  if (mode === 'agentloop') {
    // 永远要工具、从不 final —— 撞轮数上限
    return { tool: 'dept_stats', args: {} };
  }
  if (mode === 'agentwrite') {
    // P2：提议一个**写操作** —— 服务端应当只产出 proposal，**不执行**
    return { tool: 'set_my_task_status', args: { task_id: stubTask, status: 'done' } };
  }
  if (mode === 'agentbad') {
    // 白名单外的工具名 —— 应被 dispatchAiTool 拒（allowed=false）
    return { tool: 'drop_database', args: {} };
  }
  return { final: '桩：默认' };
}

function pickPayload(prompt, mode) {
  // agent 的提示词里有"可用工具"，且它的提问也在同一段里 —— 先判它，别被 ask 抢走
  if (prompt.includes('可用工具')) {
    return pickAgentPayload(prompt, mode);
  }
  if (prompt.includes('可选负责人')) {
    // task-suggest：从候选名单里挑第一个 id，保证"模型不得凭空造人"能过校验
    const m = prompt.match(/id=(\d+)/);
    const id = m ? Number(m[1]) : 1;
    return { owner_id: id, due_at: '2026-10-20T18:00:00+08:00',
             granularity: '建议拆成 2—3 个子任务', reasons: ['桩：按候选名单第一名'] };
  }
  if (prompt.includes('起草一则通知')) {
    return { title: '关于招新的通知', body: '各位成员：请于 10 月 20 日前完成筹备。',
             audience: 'members', suggest_send_at: '2026-10-16T09:00:00+08:00' };
  }
  if (prompt.includes('客观事实')) {
    return { summary: '桩：该任务整体完成情况良好。',
             causes: ['dependency: 等待物料交付'], suggestions: ['下次提前备料'] };
  }
  if (prompt.includes('提问：')) {
    return { answer: '桩：按系统判定，你可以创建本部门任务。',
             basis: ['permission: can() 判定', 'data: 当前角色'] };
  }
  return { answer: '桩：未识别的提示词' };
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    if (url.pathname === '/__mode') {
      mode = url.searchParams.get('m') || 'ok';
      stubTask = Number(url.searchParams.get('task') || 0);
      console.log(`[ai-stub] mode -> ${mode}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, mode }));
      return;
    }
    if (url.pathname === '/__stats') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, requests, mode, authSeen: [...authSeen], stolen }));
      return;
    }

    requests += 1;
    authSeen.add(req.headers['authorization'] || '(missing)');
    const body = Buffer.concat(chunks).toString('utf8');
    let prompt = body;
    try {
      const j = JSON.parse(body);
      prompt = (j.messages || []).map((m) => m.content || '').join('\n');
    } catch (_) { /* 原样用 body */ }

    const reply = (status, text) => {
      const buf = Buffer.from(text, 'utf8');
      res.writeHead(status, { 'content-type': 'application/json', 'content-length': buf.length });
      res.end(buf);
    };

    console.log(`[ai-stub] #${requests} mode=${mode}`);

    // F-4：重定向目标。**它被请求到就说明客户端跟随了 3xx**（fail-closed 失败）。
    if (url.pathname === '/steal') {
      stolen += 1;
      console.log(`[ai-stub] !! /steal 被请求了（第 ${stolen} 次）—— 客户端跟随了重定向`);
      return reply(200, JSON.stringify({
        choices: [{ message: { content: '{"answer":"REDIRECTED-TO-THIRD-PARTY"}' } }],
      }));
    }
    if (mode === 'redirect') {
      res.writeHead(302, { location: `http://127.0.0.1:${PORT}/steal` });
      res.end();
      return;
    }
    if (mode === 'e500') return reply(500, JSON.stringify({ error: 'boom' }));
    if (mode === 'e401') return reply(401, JSON.stringify({ error: 'unauthorized' }));
    if (mode === 'slow') {
      return setTimeout(() => reply(200, JSON.stringify({
        choices: [{ message: { content: JSON.stringify(pickPayload(prompt)) } }],
      })), 5000);
    }

    const payload = pickPayload(prompt, mode);
    let content = JSON.stringify(payload);
    if (mode === 'garbage') content = '好的，我建议如下：这个任务应该找张三。';
    if (mode === 'fenced') content = '```json\n' + content + '\n```';

    reply(200, JSON.stringify({
      id: 'stub', object: 'chat.completion',
      choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    }));
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[ai-stub] listening on http://127.0.0.1:${PORT} (mode=${mode})`);
});
