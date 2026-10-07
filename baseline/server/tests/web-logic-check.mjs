/*
 * web-logic-check.mjs —— 运维台前端的「401 不该整页跳转」回归闸门
 *
 * 为什么需要它：下边这两条都是**纯前端逻辑**缺陷，后端无论怎么测都抓不到，
 * 而它们的现象又特别容易被误判成"登录失效"（2026-09-17 用户实测报告）：
 *   ① 用运维账号登录后台 → 仪表盘渲染出来（/api/dashboard 是 200）→ 紧接着
 *      Dashboard 里那句"拿不到权限就忽略"的 api.perms() 拿到 401 →
 *      旧版 api.js 直接 window.location.href = '/login' → **页面闪一下就退回登录页**；
 *   ② 口令打错时 /api/login 也是 401 → 同样整页跳转 → **错误提示一闪即逝、
 *      输入框被清空**（整页重载）。
 * 根因是 api.js 把「没登录」和「登录了但这条接口不归你」两类 401 混成了一件事故。
 *
 * 这个脚本用一个假的 fetch / localStorage / window 把 admin-web 的 api.js 真的跑起来，
 * 断言"哪一类 401 该跳、哪一类不该跳"。不需要浏览器，Node 即可：
 *
 *   node server/tests/web-logic-check.mjs
 *
 * 它不启动任何服务、不联网、不写文件。
 */

const failures = []
let passed = 0

function check(name, cond, extra = '') {
  if (cond) {
    console.log('  ok    ' + name)
    passed++
  } else {
    console.log('  FAIL  ' + name + (extra ? '  ' + extra : ''))
    failures.push(name)
  }
}

/* ---------------- 运行环境替身 ---------------- */

const store = new Map()
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k)
}

/* 只关心"有没有被整页跳走"以及跳去了哪 —— 普通对象即可 */
globalThis.window = { location: { href: '' } }

let lastRequest = null
let responder = () => ({ code: 0, message: 'ok', data: {} })

globalThis.fetch = async (path, options = {}) => {
  lastRequest = { path, options }
  const json = responder(path, options)
  return { json: async () => json }
}

const { api } = await import('../admin-web/src/api.js')

function reset() {
  store.clear()
  globalThis.window.location.href = ''
  lastRequest = null
}

/* ---------------- 1) 登录接口的 401：口令错，只抛不跳 ---------------- */
console.log('=== 1) 口令错（/api/login 401）不该整页跳转 —— 问题 3 ===')
reset()
responder = () => ({ code: 401, message: '登录失败：手机号或口令不对', data: null })

let threw = false
let msg = ''
try {
  await api.login('13800000009', 'WrongPass')
} catch (e) {
  threw = true
  msg = e.message
}
check('口令错时抛出异常（调用方才能显示错误）', threw)
check('异常里带上服务端的诊断信息', msg.includes('口令'), 'msg=' + msg)
check('**没有**整页跳转（否则输入框与提示会被重载冲掉）', globalThis.window.location.href === '', 'href=' + globalThis.window.location.href)
check('没有把已填内容相关的状态清掉（token 未被误删）', !store.has('qz_token'), 'token=' + store.get('qz_token'))

/* ---------------- 2) 后台管理接口的 401：已登录但没权限，只抛不跳 ---------------- */
console.log('')
console.log('=== 2) 运维账号读后台专属接口（401）不该整页跳转 —— 问题 2 的根因 ===')
reset()
store.set('qz_token', 'ops-token-xxxxx')          /* 已登录（运维身份） */
store.set('qz_me', JSON.stringify({ role: 'ops', is_ops_account: true }))
responder = () => ({ code: 401, message: 'unauthorized', data: null })

threw = false
try {
  await api.perms()
} catch (e) {
  threw = true
}
check('api.perms() 抛出异常（Dashboard 的 try/catch 能接住）', threw)
check('**没有**整页跳转（页面能留在仪表盘上）', globalThis.window.location.href === '', 'href=' + globalThis.window.location.href)
check('令牌**没有**被清掉（用户并没有登出）', store.get('qz_token') === 'ops-token-xxxxx', 'token=' + store.get('qz_token'))

/* 同一身份下，运维接口要正常可用 */
responder = () => ({ code: 0, message: 'ok', data: { total: 2 } })
const ov = await api.clubOverview()
check('同一身份下 /api/club/overview 正常返回', ov && ov.total === 2)
check('仍然没有发生跳转', globalThis.window.location.href === '')

/* ---------------- 3) 真正的会话失效：该跳 ---------------- */
console.log('')
console.log('=== 3) 真的没登录 / 令牌过期（该跳登录页）—— 不能修过头 ===')
reset()
responder = () => ({ code: 401, message: 'missing authorization', data: null })
threw = false
try {
  await api.me()
} catch (e) {
  threw = true
}
check('无令牌访问 /api/me -> 抛出', threw)
check('跳转到 /login', globalThis.window.location.href === '/login', 'href=' + globalThis.window.location.href)

reset()
responder = () => ({ code: 401, message: 'unauthorized', data: null })
try { await api.users() } catch (e) { /* 期望抛 */ }
check('无令牌访问后台接口 /api/users 也要跳 /login', globalThis.window.location.href === '/login', 'href=' + globalThis.window.location.href)

/* ---------------- 4) 成功路径不受影响 ---------------- */
console.log('')
console.log('=== 4) 成功路径不受影响 ===')
reset()
responder = () => ({ code: 0, message: 'ok', data: { token: 'bootstrap-token-1234567890' } })
const data = await api.login('admin', 'whatever')
check('登录成功返回 data.token', data && data.token === 'bootstrap-token-1234567890')
check('成功时不跳转', globalThis.window.location.href === '')
check('请求带了 Content-Type', lastRequest.options.headers['Content-Type'] === 'application/json')

responder = () => ({ code: 0, message: 'ok', data: { id: 0, role: 'ops' } })
store.set('qz_token', 'ops-token-xxxxx')
const me = await api.me()
check('带令牌时请求头里有 Authorization', lastRequest.options.headers['Authorization'] === 'Bearer ops-token-xxxxx')
check('返回 /api/me 的数据', me && me.role === 'ops')

/* ---------------- 汇总 ---------------- */
console.log('')
console.log('======================================')
console.log(`前端逻辑回归： PASS ${passed} / FAIL ${failures.length}`)
console.log('======================================')
if (failures.length > 0) {
  for (const f of failures) console.log('  FAIL ' + f)
  process.exit(1)
}
