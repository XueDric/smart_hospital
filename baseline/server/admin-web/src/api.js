// 统一 API 封装：自动带 token，统一处理 {code, message, data} 响应壳
//
// ⚠ 401 有两种完全不同的含义，**不能一律当成"会话失效"去整页跳登录**：
//   ① 没登录 / 令牌过期  → 该回登录页；
//   ② 已登录、但这条接口不归你（例如运维账号去读后台管理接口 /api/perms）→ 只是没权限。
//
// 原先两者不分，于是有两个真实故障（2026-09-17 实测）：
//   · **登录后闪一下就退回登录页**：Dashboard 里 `api.perms()` 外面明明写了
//     try/catch 想"拿不到权限就忽略"，但整页跳转发生在 catch 之前（这里直接
//     window.location.href），所以那个 catch 永远轮不到 —— 用运维账号登录时，
//     仪表盘先渲染出来（/api/dashboard 是 200），紧接着 /api/perms 拿到 401
//     就把整页跳走了。
//   · **错了口令，提示一闪即逝、输入被清空**：/api/login 的 401 也走了这条路，
//     整页重载把输入框和错误提示一起冲掉了。
//
// 所以：只有"任何登录身份都该能用"的接口上的 401 才算会话失效；登录接口自己的 401
// 是"口令错"，后台管理接口上的 401 是"没这个权限"，两者都只抛不跳，交给调用方展示。
const ADMIN_ONLY = ['/api/users', '/api/roles', '/api/perms']

async function request(path, options = {}) {
  const token = localStorage.getItem('qz_token')
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) }
  if (token) headers['Authorization'] = 'Bearer ' + token
  const res = await fetch(path, { ...options, headers })
  const json = await res.json()
  if (json.code !== 0) {
    const e = new Error(json.message || 'request failed')
    e.code = json.code
    const isLoginCall = path.startsWith('/api/login')
    const adminOnly = ADMIN_ONLY.some((p) => path.startsWith(p))
    // adminOnly 上若**连 token 都没有**，那确实是没登录，仍然回登录页。
    const sessionGone = json.code === 401 && !isLoginCall && (!adminOnly || !token)
    if (sessionGone) {
      localStorage.removeItem('qz_token')
      localStorage.removeItem('qz_me')
      window.location.href = '/login'
    }
    throw e
  }
  return json.data
}

export const api = {
  login: (username, password) =>
    request('/api/login', { method: 'POST', body: JSON.stringify({ username, password }) }),
  me: () => request('/api/me'),
  dashboard: () => request('/api/dashboard'),
  users: () => request('/api/users'),
  createUser: (username, password, roleId) =>
    request('/api/users', { method: 'POST', body: JSON.stringify({ username, password, roleId }) }),
  deleteUser: (id) => request('/api/users/' + id, { method: 'DELETE' }),
  roles: () => request('/api/roles'),
  perms: () => request('/api/perms'),

  // ---- 社团管理运维页（/club）----
  // 读：走运维台自己的后端（它只读社团库 MySQL，因此不需要 club-server 在跑）
  // 写：不走这里 —— 直接 fetch club-server 的真实 API，见 views/Club.vue
  clubConfig: () => request('/api/club/config'),
  // 运维会话：后台用 admin.env 的专用运维账号（club-server 的 role = ops）换令牌，
  // 页面拿着它直连 club-server 做写操作 —— 运维人员不需要任何社团账号的口令。
  clubSession: (force = false) => request('/api/club/session' + (force ? '?force=1' : '')),
  clubOverview: () => request('/api/club/overview'),
  clubMembers: (qs = '') => request('/api/club/members' + qs),
  clubDepts: () => request('/api/club/depts'),
  clubTasks: (qs = '') => request('/api/club/tasks' + qs),
  clubPlans: () => request('/api/club/plans'),
  clubLinks: () => request('/api/club/links'),
  clubAudit: (limit = 200) => request('/api/club/audit?limit=' + limit),
  clubServerHealth: () => request('/api/club/server-health'),
  clubBackup: () => request('/api/club/backup', { method: 'POST', body: '{}' })
}
