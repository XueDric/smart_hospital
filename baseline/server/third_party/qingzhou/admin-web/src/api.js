// 统一 API 封装：自动带 token，统一处理 {code, message, data} 响应壳
async function request(path, options = {}) {
  const token = localStorage.getItem('qz_token')
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) }
  if (token) headers['Authorization'] = 'Bearer ' + token
  const res = await fetch(path, { ...options, headers })
  const json = await res.json()
  if (json.code !== 0) {
    if (json.code === 401) {
      // 登录失效，清 token 回登录页
      localStorage.removeItem('qz_token')
      window.location.href = '/login'
    }
    throw new Error(json.message || 'request failed')
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
  perms: () => request('/api/perms')
}
