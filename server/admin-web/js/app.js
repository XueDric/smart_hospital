/*
  管理台外壳（2026-10-14）
  ============================================================================
  职责只有四件，且都只在这里做一次：

    ① **登录态**：令牌存在 localStorage（键名在 api.js 里）。启动时先用
       `GET /auth/me` **验证**它 —— 只看"localStorage 里有没有值"是不够的：
       令牌可能已被吊销/过期，那样界面会先进去再到处报 401。
    ② **侧栏**：由 `window.HOSPITAL_PAGES`（js/pages.js）**自动生成**。
       加一个页面 = 在 pages.js 里注册一条，这里不用改一行。
    ③ **路由**：`#/页面id` 哈希路由（不用 History API：服务端已有 SPA 回退，
       但哈希路由让"刷新/分享链接"天然可用，且不依赖服务端把未知路径回退到 index）。
    ④ **面包屑 + 侧栏高亮**：都由当前路由推导，不允许页面自己改。

  ⚠ 侧栏里有三个**灰掉的**入口（患者档案 / 症状标签库 / Agent 执行观测）：
    它们出现在截图的侧栏里，但**服务端没有对应接口**（详见 docs/dev/ADMIN-WEB.md 的
    "缺口清单"）。灰掉并写明原因，好过做一个点了就 404 的假入口 ——
    "看起来有、点进去报错"会让人以为是故障。
*/

(function () {
  const LOGIN_VIEW = document.getElementById('login-view');
  const APP_VIEW = document.getElementById('app-view');
  const NAV = document.getElementById('nav');
  const CONTENT = document.getElementById('content');
  const CRUMB = document.getElementById('breadcrumb');
  const WHOAMI = document.getElementById('whoami');
  const FOOT_NOTE = document.getElementById('nav-foot-note');

  /* 截图里有、但服务端没有接口的入口 —— 灰显 + 说明原因（不是 TODO 占位） */
  const NOT_IMPLEMENTED = [
    { title: '患者档案', group: '基础数据', reason: '服务端没有"按患者查询档案"的管理接口（患者侧只有自己的病历接口）' },
    { title: '症状标签库', group: '基础数据', reason: '服务端没有症状标签表；分诊按规则匹配，不查标签库' },
    { title: 'Agent 执行观测', group: '观测面板', reason: '服务端只聚合了分诊计数（看板），没有逐次 Agent 轨迹的落库与查询接口' },
  ];

  /* ------------------------------- 侧栏 ------------------------------- */

  function groupPages() {
    const groups = [];
    window.HOSPITAL_PAGES.forEach((p) => {
      let g = groups.filter((x) => x.title === p.group)[0];
      if (!g) { g = { title: p.group, items: [] }; groups.push(g); }
      g.items.push({ id: p.id, title: p.title, icon: p.icon || '·' });
    });
    NOT_IMPLEMENTED.forEach((p) => {
      let g = groups.filter((x) => x.title === p.group)[0];
      if (!g) { g = { title: p.group, items: [] }; groups.push(g); }
      g.items.push({ id: null, title: p.title, icon: '×', reason: p.reason });
    });
    return groups;
  }

  function buildNav() {
    clear(NAV);
    groupPages().forEach((g) => {
      NAV.appendChild(h('div', { class: 'nav-group' }, h('div', { class: 'nav-group-title' }, g.title)));
      g.items.forEach((it) => {
        if (it.id === null) {
          NAV.appendChild(h('div', { class: 'nav-item disabled', title: it.reason },
            h('span', { class: 'ic' }, it.icon), it.title));
          return;
        }
        NAV.appendChild(h('a', {
          class: 'nav-item', href: '#/' + it.id, 'data-page': it.id,
        }, h('span', { class: 'ic' }, it.icon), it.title));
      });
    });
  }

  function markActive(id) {
    Array.prototype.forEach.call(NAV.querySelectorAll('.nav-item'), (el) => {
      el.classList.toggle('active', el.getAttribute('data-page') === id);
    });
  }

  /* ------------------------------- 路由 ------------------------------- */

  function currentId() {
    const raw = (location.hash || '').replace(/^#\/?/, '');
    return raw || (window.HOSPITAL_PAGES[0] && window.HOSPITAL_PAGES[0].id) || '';
  }

  function route() {
    const id = currentId();
    const page = window.HOSPITAL_PAGES.filter((p) => p.id === id)[0];
    if (!page) {
      /* 未知页面（手改哈希/旧书签）⇒ 指回第一页，并说清楚发生了什么 */
      toast(`没有这个页面：${id}（已回到第一个页面）`, 'err');
      location.hash = '#/' + currentIdFallback();
      return;
    }
    markActive(id);
    clear(CRUMB);
    CRUMB.appendChild(h('span', null, page.group + ' / ', h('b', null, page.title)));
    clear(CONTENT);
    try {
      page.render(CONTENT);
    } catch (e) {
      fail(CONTENT, e);
    }
  }

  function currentIdFallback() {
    return (window.HOSPITAL_PAGES[0] && window.HOSPITAL_PAGES[0].id) || '';
  }

  /* ----------------------------- 登录 / 登出 ----------------------------- */

  function showLogin(message) {
    API.clear();
    APP_VIEW.classList.add('hidden');
    LOGIN_VIEW.classList.remove('hidden');
    const box = document.getElementById('login-error');
    if (message) { box.textContent = message; box.classList.remove('hidden'); }
    else { box.classList.add('hidden'); }
    const name = document.getElementById('login-name');
    if (name) { name.focus(); }
  }

  async function showApp() {
    LOGIN_VIEW.classList.add('hidden');
    APP_VIEW.classList.remove('hidden');
    const who = API.who || {};
    WHOAMI.textContent = `${who.display_name || who.login_name || '（未知）'}（${who.role || '?'}）`;
    buildNav();
    if (!location.hash) { location.hash = '#/' + currentIdFallback(); } else { route(); }
    loadFootNote();
  }

  /*
   * 侧栏底部只放"服务端事实"，不放导航：版本、数据后端、服务端认定的今天。
   * ★ 今天的日期**必须**从 /health 读（而不是浏览器本地时间）—— 服务端与客户端的
   *   时区可能不同，管理台显示的日期必须与"排班能不能建"用的是同一个今天。
   */
  function loadFootNote() {
    /* ⚠ `API.health()` 而不是 `API.get('/health')`：/health 是**唯一**一个平铺返回
       （没有 data 信封）的接口，用 get() 会拿到 undefined —— 页脚就会永远显示
       "服务端信息读取失败"（2026-10-14 实测踩到，浏览器截图里一眼能看到）。 */
    API.health().then((h) => {
      FOOT_NOTE.textContent = `服务端 ${h.service || ''} ${h.version || ''} · 数据后端 ${h.data_backend || '—'} · 今天 ${h.today || '—'}（${h.timezone || '—'}）`;
    }).catch(() => { FOOT_NOTE.textContent = '（服务端信息读取失败）'; });
  }

  document.getElementById('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const box = document.getElementById('login-error');
    const btn = document.getElementById('login-submit');
    box.classList.add('hidden');
    btn.disabled = true; btn.textContent = '登录中…';
    try {
      /*
       * ⚠ 登录响应是**扁平**的（不是 `{user:{…}}`）：`token` / `expires_at` /
       *   `user_id` / `role` / `ref_id` / `display_name` / `patient_id`
       *   —— 见 http_app.cj:990-1010。写成 `data.user.role` 会静默得到 undefined。
       */
      const data = await API.login(
        document.getElementById('login-name').value,
        document.getElementById('login-password').value);
      /*
       * ⚠ 这里**必须**再判一次角色：服务端的登录接口对三种角色都签发令牌
       *   （患者/医生也能登录），但管理台的每个接口都要求 admin。
       *   不在入口拦住，使用者会看到"登录成功但每个页面都 403"。
       */
      if (data.role !== 'admin') {
        showLogin(`该账号角色是「${data.role}」，后台只允许管理员登录。`);
        return;
      }
      API.session(data.token, {
        user_id: data.user_id, role: data.role, ref_id: data.ref_id,
        display_name: data.display_name, expires_at: data.expires_at,
      });
      document.getElementById('login-password').value = '';
      await showApp();
    } catch (err) {
      showLogin(err.toString());
    } finally {
      btn.disabled = false; btn.textContent = '登录';
    }
  });

  document.getElementById('logout-btn').addEventListener('click', async () => {
    if (!confirmBox('退出登录？（服务端会吊销当前令牌）')) { return; }
    try { await API.logout(); } catch (e) { /* 令牌可能已失效：照样本地登出 */ }
    showLogin('已退出登录。');
  });

  API.setUnauthorizedHandler((err) => {
    /* 令牌失效是**全局**事件（所有页面同时失效）⇒ 统一回登录页，而不是各页各自报错 */
    showLogin('登录已失效，请重新登录。' + (err && err.message ? '（' + err.message + '）' : ''));
  });

  window.addEventListener('hashchange', route);

  /* ------------------------------- 启动 ------------------------------- */

  (async function boot() {
    const base = document.getElementById('login-base');
    if (base) { base.textContent = location.origin + '/api/v1'; }
    API.load();
    if (!API.token) { showLogin(); return; }
    try {
      /* 用 /auth/me 验证既有令牌，并顺手拿到最新的用户信息（响应同样是扁平的） */
      const me = await API.me();
      if (me.role !== 'admin') { showLogin(`该账号角色是「${me.role}」，后台只允许管理员登录。`); return; }
      API.session(API.token, me);
      await showApp();
    } catch (e) {
      showLogin('登录已失效，请重新登录。');
    }
  })();
})();
