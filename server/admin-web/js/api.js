/*
  /admin/ 的接口客户端（2026-10-14）
  ============================================================================
  只做三件事，但三件都必须**只有一处实现**：

  ① **拆信封**：服务端所有接口都是 `{"ok":true,"data":{…}}` /
     `{"ok":false,"error":{"code","message","fields"?}}`（见 http_common.cj:255-283）。
     失败时把 `code` 与 `message` 原样带出来 —— 界面要显示的是**服务端那句话**
     （它是中文且面向运维），而不是"请求失败 (400)"。
  ② **带令牌**：`Authorization: Bearer <token>`（不用 Cookie：服务端本来就没有
     会话 Cookie，令牌是唯一凭据，见 auth_repo.cj）。
  ③ **401 就地下线**：令牌被吊销/过期时（`AUTH_TOKEN_EXPIRED`），
     把本地会话清掉并让 app.js 回到登录页 —— 否则每个页面都会各自报一次错，
     而使用者不知道"是全部都要重新登录"。

  ⚠ 刻意**不做**自动重试：管理台的每个写操作都是"人点的"，自动重试会让
    "提交了两次"变成偶发问题（比如连点两次新增，第二次 409 —— 看起来像重名）。
    失败就如实报出来，让人自己决定要不要再来一次。
*/

const API = (() => {
  const PREFIX = '/api/v1';
  const TOKEN_KEY = 'hospital_admin_token';
  const WHO_KEY = 'hospital_admin_who';

  class ApiError extends Error {
    constructor(code, message, status, fields) {
      super(message || code || '请求失败');
      this.code = code || '';
      this.message = message || '';
      this.status = status || 0;
      this.fields = fields || null;
    }
    /* 给界面用的一行文字：带上 code（排查时这一串最有信息量） */
    toString() {
      return this.code ? `${this.message}（${this.code}）` : this.message || '请求失败';
    }
  }

  let token = null;
  let who = null;
  /*
   * 由 app.js 注入：令牌失效时调用（回登录页）。
   * ⚠ 用回调而不是在这里直接操作 DOM/位置：api.js 要能在**没有界面**的情况下
   *   被单测/控制台复用（例如在浏览器控制台里 `API.get('/health')`）。
   */
  let onUnauthorized = null;

  function load() {
    try {
      token = localStorage.getItem(TOKEN_KEY) || null;
      const raw = localStorage.getItem(WHO_KEY);
      who = raw ? JSON.parse(raw) : null;
    } catch (e) {
      /* localStorage 被禁用（隐私模式）时降级为"只在内存里保存" */
      token = null; who = null;
    }
  }

  function save(newToken, newWho) {
    token = newToken || null;
    who = newWho || null;
    try {
      if (token) { localStorage.setItem(TOKEN_KEY, token); } else { localStorage.removeItem(TOKEN_KEY); }
      if (who) { localStorage.setItem(WHO_KEY, JSON.stringify(who)); } else { localStorage.removeItem(WHO_KEY); }
    } catch (e) { /* 同上：存不下也不影响本次会话 */ }
  }

  async function request(method, path, body, opts) {
    const options = opts || {};
    const headers = { 'Accept': 'application/json' };
    if (body !== undefined && body !== null) { headers['Content-Type'] = 'application/json'; }
    if (token && !options.anonymous) { headers['Authorization'] = 'Bearer ' + token; }

    let resp;
    try {
      resp = await fetch(PREFIX + path, {
        method: method,
        headers: headers,
        body: (body === undefined || body === null) ? undefined : JSON.stringify(body),
        /* 管理台与 API 同源 ⇒ 不带 credentials 也不会丢凭据（凭据在头里） */
        credentials: 'omit',
        cache: 'no-store',
      });
    } catch (e) {
      /*
       * fetch 抛错 = **连不上**（服务端没起来 / 网络断开 / 证书问题）。
       * ⚠ 这与"服务端回了一个错误"是两类问题，文案必须分开：
       *   否则使用者会去查业务日志，而真因是进程没起来。
       */
      throw new ApiError('NETWORK', '连不上服务端（检查服务端是否在运行、地址是否正确）', 0, null);
    }

    const text = await resp.text();
    let json = null;
    if (text) {
      try { json = JSON.parse(text); } catch (e) { json = null; }
    }

    if (json && json.ok === false && json.error) {
      const err = new ApiError(json.error.code, json.error.message, resp.status, json.error.fields);
      if (resp.status === 401 && !options.anonymous) {
        save(null, null);
        if (onUnauthorized) { onUnauthorized(err); }
      }
      throw err;
    }
    if (!resp.ok) {
      /*
       * 走到这里说明"HTTP 层失败，但 body 不是统一信封" —— 例如 `408 Request Timeout`
       * （纯文本，`timeout.cj:46-48`）这类不由应用接管的出口。
       * ⚠ 历史：**未匹配路由**曾经也是这样（框架 `router.cj` 直写 `{"error":"Not Found"}`）；
       *   2026-10-17 起框架层 400/404/405/413/416 已全部改走统一信封
       *   （见 `contract/CHANGELOG.md` 与 `docs/FRONTEND-INTEGRATION.md` §3.2）。
       * 把原始 body 截断带上：这类问题基本都是**路径写错**，原文最能说明问题。
       */
      const brief = (text || '').slice(0, 200);
      throw new ApiError('HTTP_' + resp.status, `HTTP ${resp.status} ${resp.statusText}${brief ? '：' + brief : ''}`, resp.status, null);
    }
    if (!json || json.ok !== true) {
      throw new ApiError('BAD_ENVELOPE', '服务端响应不是预期的统一信封（ok/data）', resp.status, null);
    }
    /*
     * ⚠ `raw`：**唯一**一个不走 `data` 信封的接口是 `/health`（它比统一信封更早
     *   就存在，且被部署探针/压测脚本按平铺字段消费，见 http_app.cj 的 healthJson）。
     *   所以"整份 JSON 就是数据"这件事必须由调用方**显式**声明（`API.health()`），
     *   不能在这里做成"没有 data 就返回整份"的隐式兜底 —— 那会让"某个接口漏了
     *   data 字段"从"报错"退化成"页面上某个字段静默变成 undefined"。
     */
    return options.raw ? json : json.data;
  }

  const api = {
    ApiError: ApiError,
    load: load,
    get who() { return who; },
    get token() { return token; },
    setUnauthorizedHandler(fn) { onUnauthorized = fn; },
    login(name, password) { return request('POST', '/auth/login', { login_name: name, password: password }, { anonymous: true }); },
    logout() { return request('POST', '/auth/logout', {}); },
    me() { return request('GET', '/auth/me'); },
    /*
     * `/health`：**免鉴权、且不走 data 信封**（见 request() 里那段注释）。
     * 管理台只用它的两个字段：`today`（医院今天，Asia/Shanghai）与 `timezone`。
     * 为什么要向服务端要日期而不是用浏览器本地时间：服务端与客户端可能不在同一
     * 时区/同一台机器，而"今天"决定号源是否可约 —— 猜错一天就是"能约的显示不可约"。
     */
    health() { return request('GET', '/health', undefined, { anonymous: true, raw: true }); },
    session(newToken, newWho) { save(newToken, newWho); },
    clear() { save(null, null); },
    get(path) { return request('GET', path); },
    post(path, body) { return request('POST', path, body === undefined ? {} : body); },
    put(path, body) { return request('PUT', path, body === undefined ? {} : body); },
    del(path) { return request('DELETE', path); },
    /*
     * 查询串拼装：**只拼有值的项**（`undefined`/`null`/空串都不发给服务端）。
     * ⚠ 不这样做的话 `?role=` 这种空参数会走进"按空串过滤"的分支，
     *   而服务端对空串的处理是"不过滤" —— 现在能跑，但一旦某天改成
     *   "空串 = 不过滤 vs 空串 = 报错"就会变成隐藏的坑。少发无用参数最稳。
     */
    qs(params) {
      const parts = [];
      Object.keys(params || {}).forEach((k) => {
        const v = params[k];
        if (v === undefined || v === null || v === '') { return; }
        parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
      });
      return parts.length ? ('?' + parts.join('&')) : '';
    },
  };
  return api;
})();
