/*
  管理台页面（2026-10-14）
  ============================================================================
  每个页面就是一条 `page({id, title, group, icon, render(el)})` 注册。
  侧栏、面包屑、路由都由 js/app.js 按这份注册表生成 —— **加页面只改这个文件**
  （不用碰 index.html，也不会出现"侧栏有入口、点进去 404"）。

  ⚠ 三条贯穿全文件的纪律（与后端接口的约定一一对应）：

  ① **不猜字段名**：每个页面的字段名都来自服务端实现（见 docs/ADMIN-WEB.md 的
     接口对照表）。写错字段名在 JS 里不会报错，只会静默显示 `undefined` ——
     这是最难查的一类前端 bug，所以宁可多写一行注释标明来源。

  ② **失败要说清"哪一类"**：`API.ApiError` 带了 `code`。是"没登录"、"没权限"、
     "重名"还是"连不上服务端"，处置完全不同 ⇒ 页面一律把 `code` 一起显示，
     不做"统一改成'操作失败'"这种把所有信息都抹平的处理。

  ③ **不可逆操作先问一句**：删除/停诊这类动作都要 `confirmBox`。
     而"可逆"的（比如失效缓存、跑连通性测试）不打断使用者。
*/

window.HOSPITAL_PAGES = [];

/* ============================== 通用小助手 ============================== */

function page(def) { window.HOSPITAL_PAGES.push(def); }

function loading(el, text) { clear(el); el.appendChild(h('div', { class: 'empty' }, text || '加载中…')); }

function fail(el, err) {
  clear(el);
  el.appendChild(h('div', { class: 'card' },
    h('div', { class: 'empty' }, '加载失败：' + (err && err.toString ? err.toString() : String(err)))));
}

/* 统一的"先显示加载中、出错就地显示"包装 */
async function guarded(el, fn) {
  loading(el);
  try { await fn(); } catch (e) { fail(el, e); }
}

function stat(k, v, note) {
  return h('div', { class: 'stat' }, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v),
    note ? h('div', { class: 'n' }, note) : null);
}

function toolbar(...children) {
  return h('div', { class: 'toolbar' }, children);
}

/* 角色中文名（服务端 role 取值固定三种：admin/doctor/patient） */
function roleLabel(role) {
  return { admin: '管理员', doctor: '医生', patient: '患者' }[role] || role;
}

/* ============================== 1. 运营看板 ============================== */

page({
  id: 'dashboard', title: '运营看板', group: '运营看板', icon: '▤',
  render: (el) => guarded(el, async () => {
    /* 看板刻意**不含** today/timezone（那是 /health 的字段）—— 所以这里取两个接口。
       ⚠ `/health` 用 `API.health()` 而不是 `API.get('/health')`：它是**唯一**一个
       平铺返回（没有 data 信封）的接口，用 get() 会拿到 undefined
       （2026-10-14 就是这么在浏览器里炸出 "Cannot read properties of undefined
       (reading 'today')" 的 —— 而 curl 看接口本身是 200 且字段齐全）。 */
    const [d, health] = await Promise.all([API.get('/admin/dashboard'), API.health()]);
    const a = d.appointments || {};
    const s = d.scale || {};
    const slots = d.slots || {};
    const tri = d.triage || {};
    const pre = d.previsit || {};
    const rec = d.medical_records || {};
    const ai = d.ai || {};
    const kb = d.knowledge_base || {};
    const trend = d.trend || [];
    const maxTrend = Math.max(1, ...trend.map((t) => t.count));

    clear(el);
    el.appendChild(h('div', { class: 'note' },
      h('b', null, '口径提示：'), '所有带 `_permille` 的指标是**千分比整数**（除以 10 才是百分比）；',
      '看板里的 AI 计数只统计**分诊**（不含预问诊）。今日（服务端口径，Asia/Shanghai）：',
      h('code', null, health.today || '—'), '，时区 ', h('code', null, health.timezone || '—'),
      ' —— 与 ', h('code', null, health.service + ' ' + health.version), ' 同源读取。'));

    el.appendChild(h('div', { class: 'stat-row', style: 'margin-top:14px' },
      stat('科室 / 医生', `${fmtNum(s.departments)} / ${fmtNum(s.doctors)}`, '数据来源：' + (s.source || '—')),
      stat('挂号总数', fmtNum(a.total),
        `已约 ${fmtNum(a.booked)} · 就诊中 ${fmtNum(a.visiting)} · 完成 ${fmtNum(a.done)}`),
      stat('取消率', fmtPermille(a.cancel_permille), '爽约率 ' + fmtPermille(a.no_show_permille)),
      stat('号源余量', `${fmtNum(slots.remain_slots)} / ${fmtNum(slots.total_slots)}`,
        `排班 ${fmtNum(slots.schedule_count)} 条（启用 ${fmtNum(slots.enabled_schedule_count)}）`)));

    el.appendChild(h('div', { class: 'card', style: 'margin-top:16px' },
      h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, `挂号趋势（最近 ${d.trend_days || 14} 天）`)),
      h('div', { class: 'bars' }, trend.map((t) => h('div', { class: 'bar', title: `${t.label}：${t.count}` },
        h('i', { style: `height:${Math.round((t.count / maxTrend) * 100)}%` })))),
      h('div', { class: 'bars-x' }, trend.map((t) => h('span', null, (t.label || '').slice(5))))));

    el.appendChild(h('div', { class: 'card' },
      h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, '分诊与预问诊')),
      h('div', { class: 'stat-row' },
        stat('分诊调用', fmtNum(tri.total_calls), `规则路 ${tri.source || 'rules'} · 危急 ${fmtNum(tri.red_flag_calls)}`),
        stat('预问诊完成率', fmtPermille(pre.completion_permille), `会话 ${fmtNum(pre.sessions)} · 完成 ${fmtNum(pre.completed)}`),
        stat('病历', fmtNum(rec.records), `已锁定 ${fmtNum(rec.locked)} · 草稿 ${fmtNum(rec.draft)}`),
        stat('AI 模型', ai.enabled ? '已启用' : '未启用',
          ai.disabled_reason ? String(ai.disabled_reason).slice(0, 40) : `模型 ${ai.model || '—'} · 调用 ${fmtNum(ai.model_calls)}`)),
      h('div', { class: 'note', style: 'margin-top:10px' },
        h('b', null, '知识库：'), `文档 ${fmtNum(kb.docs)}（启用 ${fmtNum(kb.docs_enabled)}）· 切块 ${fmtNum(kb.chunks)} · `,
        `已向量化 ${fmtNum(kb.chunks_embedded)}（覆盖率 ${fmtNum(kb.embedding_coverage_pct)}%）`,
        kb.note ? h('div', { style: 'margin-top:4px' }, kb.note) : null)));

    el.appendChild(h('div', { class: 'card' },
      h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, '按科室（前 20）')),
      table([
        { key: 'label', label: '科室' },
        { key: 'count', label: '挂号数', className: 'right' },
      ], (d.by_department || []).slice(0, 20))));

    el.appendChild(h('div', { class: 'note' },
      h('b', null, '本页数据生成于 '), fmtTime(d.generated_at),
      '（刷新页面即重新拉取；服务端不缓存看板 —— 每个指标各自 catch，单表缺数据不会让整页 500）'));
  }),
});

/* ============================== 2. 用户管理 ============================== */

page({
  id: 'users', title: '用户管理', group: '基础数据', icon: '☰',
  render: (el) => {
    const state = { limit: 50, offset: 0, role: '', status: '' };
    const listBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        /* GET /api/v1/admin/users：给了 login_name 是"精确查一条"（本例不用），
           不给就是**列表模式**（limit/offset/role/status）—— 见 http_app.cj 的实现。 */
        const data = await API.get('/admin/users' + API.qs({
          limit: state.limit, offset: state.offset, role: state.role, status: state.status,
        }));
        clear(listBox);
        listBox.appendChild(table([
          { key: 'user_id', label: 'ID', className: 'nowrap' },
          { key: 'login_name', label: '登录名' },
          { key: 'display_name', label: '显示名' },
          { key: 'role', label: '角色', render: (r) => badge(roleLabel(r.role), r.role === 'admin' ? 'chat' : '') },
          { key: 'ref_id', label: '关联 ID', className: 'nowrap' },
          { key: 'status', label: '状态', render: (r) => badge(r.status, r.status === 'active' ? 'on' : 'off') },
          {
            label: '操作', className: 'actions', render: (r) => h('button', {
              class: 'btn btn-sm', onclick: () => resetPassword(r),
            }, '重置口令'),
          },
        ], data.items));
        listBox.appendChild(h('div', { class: 'muted', style: 'margin-top:10px' },
          `共 ${data.total} 个账号，本页 ${data.count} 条（offset=${data.offset}，limit=${data.limit}）`,
          h('button', {
            class: 'btn btn-sm', style: 'margin-left:10px', disabled: state.offset <= 0,
            onclick: () => { state.offset = Math.max(0, state.offset - state.limit); reload(); },
          }, '上一页'),
          h('button', {
            class: 'btn btn-sm', style: 'margin-left:6px', disabled: state.offset + state.limit >= data.total,
            onclick: () => { state.offset = state.offset + state.limit; reload(); },
          }, '下一页')));
      } catch (e) { fail(listBox, e); }
    }

    function createUser() {
      openModal({
        title: '新增账号', sub: '口令强度：至少 8 位，且必须同时含字母与数字（服务端校验，见 auth_repo.cj）',
        submitText: '创建',
        fields: [
          { name: 'login_name', label: '登录名', required: true, placeholder: '例如 doctor_li' },
          { name: 'password', label: '初始口令', type: 'password', required: true },
          { name: 'role', label: '角色', type: 'select', value: 'patient', options: [
            { value: 'patient', label: '患者（须给 patient.id）' },
            { value: 'doctor', label: '医生（须给 doctor.id）' },
            { value: 'admin', label: '管理员（关联 ID 填 0）' },
          ] },
          { name: 'ref_id', label: '关联 ID', type: 'number', value: '0',
            hint: '患者账号填 patient.id，医生账号填 doctor.id；管理员填 0' },
          { name: 'display_name', label: '显示名', hint: '留空则与登录名相同' },
        ],
        onSubmit: async (v) => {
          const res = await API.post('/admin/users', {
            login_name: v.login_name, password: v.password, role: v.role,
            ref_id: Number(v.ref_id || 0), display_name: v.display_name || '',
          });
          toast(`账号已创建：${v.login_name}（user_id=${res.user_id}）`, 'ok');
          reload();
        },
      });
    }

    function resetPassword(row) {
      openModal({
        title: `重置口令：${row.login_name}`,
        sub: `⚠ 该账号的**全部**令牌会立即失效（所有设备需要重新登录）。user_id=${row.user_id}`,
        submitText: '重置',
        fields: [{ name: 'password', label: '新口令', type: 'password', required: true }],
        onSubmit: async (v) => {
          await API.post(`/admin/users/${row.user_id}/password`, { password: v.password });
          toast(`口令已重置，令牌已全部吊销：${row.login_name}`, 'ok');
        },
      });
    }

    clear(el);
    el.appendChild(card('用户管理', '管理员 / 医生 / 患者三类账号都在这张表（auth_user）',
      toolbar(
        h('button', { class: 'btn btn-primary', onclick: createUser }, '新增账号'),
        h('span', { class: 'grow' }),
        h('select', { onchange: (e) => { state.role = e.target.value; state.offset = 0; reload(); } },
          h('option', { value: '' }, '全部角色'),
          h('option', { value: 'admin' }, '管理员'),
          h('option', { value: 'doctor' }, '医生'),
          h('option', { value: 'patient' }, '患者')),
        h('select', { onchange: (e) => { state.status = e.target.value; state.offset = 0; reload(); } },
          h('option', { value: '' }, '全部状态'),
          h('option', { value: 'active' }, '正常'),
          h('option', { value: 'disabled' }, '停用')),
      ), listBox));
    reload();
  },
});

/* ============================== 3. 科室管理 ============================== */

page({
  id: 'departments', title: '科室管理', group: '基础数据', icon: '▦',
  render: (el) => {
    const listBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/departments' + API.qs({ include_disabled: 'true' }));
        clear(listBox);
        listBox.appendChild(table([
          { key: 'id', label: 'ID' },
          { key: 'name', label: '科室名' },
          { key: 'code', label: '编码' },
          { key: 'location', label: '位置' },
          { key: 'sort', label: '排序' },
          { key: 'enabled', label: '状态', render: (r) => badge(r.enabled ? '启用' : '停用', r.enabled ? 'on' : 'off') },
          {
            label: '操作', className: 'actions', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm', onclick: () => edit(r) }, '编辑'),
              h('button', {
                class: 'btn btn-sm', style: 'margin-left:6px',
                onclick: () => remove(r),
              }, '删除')),
          },
        ], data.items));
      } catch (e) { fail(listBox, e); }
    }

    function form(row) {
      return openModal({
        title: row ? `编辑科室：${row.name}` : '新增科室',
        submitText: row ? '保存' : '创建',
        fields: [
          { name: 'name', label: '科室名', required: true, value: row ? row.name : '', hint: '同名会 409（BASE_NAME_TAKEN）' },
          { name: 'code', label: '编码', required: true, value: row ? row.code : '', hint: '该编码被占用会 409' },
          { name: 'location', label: '位置', value: row ? row.location : '' },
          { name: 'sort', label: '排序', type: 'number', value: row ? row.sort : 0 },
          { name: 'enabled', label: '启用', type: 'checkbox', value: row ? row.enabled : true },
        ],
        onSubmit: async (v) => {
          const body = { name: v.name, code: v.code, location: v.location, sort: Number(v.sort || 0), enabled: v.enabled };
          if (row) { await API.put(`/admin/departments/${row.id}`, body); toast('科室已保存', 'ok'); }
          else { await API.post('/admin/departments', body); toast('科室已创建', 'ok'); }
          reload();
        },
      });
    }

    async function remove(row) {
      if (!confirmBox(`删除科室「${row.name}」？\n\n若它已被医生/排班引用，服务端会拒绝（BASE_IN_USE）—— 那时可以改为"停用"。`)) { return; }
      try {
        const res = await API.del(`/admin/departments/${row.id}`);
        toast(res.soft_deleted ? '已停用（软删）' : '已删除', 'ok');
        reload();
      } catch (e) {
        /*
         * ★ 409 BASE_IN_USE 是**预期内**的分支（不是异常）：服务端在消息里
         *   已经写明了"可改用 force=true 停用"，这里把它变成一次明确的追问，
         *   而不是把 409 原样丢给使用者。
         */
        if (e.code === 'BASE_IN_USE') {
          if (confirmBox(`${e.message}\n\n要改为**停用**（软删）吗？停用后不再出现在患者端可选科室里。`)) {
            try {
              await API.del(`/admin/departments/${row.id}?force=true`);
              toast('已停用（软删）', 'ok');
              reload();
            } catch (e2) { toast(e2.toString(), 'err'); }
          }
          return;
        }
        toast(e.toString(), 'err');
      }
    }

    function edit(row) { form(row); }

    clear(el);
    el.appendChild(card('科室管理', '分诊推荐科室这条链路的数据源（triage.cj 按科室名查表）',
      toolbar(h('button', { class: 'btn btn-primary', onclick: () => form(null) }, '新增科室')),
      listBox));
    reload();
  },
});

/* ============================== 4. 医生管理 ============================== */

page({
  id: 'doctors', title: '医生管理', group: '基础数据', icon: '✚',
  render: (el) => {
    const state = { deptId: 0 };
    const listBox = h('div');
    let depts = [];

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/doctors' + API.qs({
          department_id: state.deptId || '', include_disabled: 'true',
        }));
        clear(listBox);
        listBox.appendChild(table([
          { key: 'id', label: 'ID' },
          { key: 'name', label: '姓名' },
          { key: 'department_name', label: '所属科室', render: (r) => r.department_name || `#${r.department_id}` },
          { key: 'title', label: '职称' },
          { key: 'specialty', label: '专长' },
          { key: 'enabled', label: '状态', render: (r) => badge(r.enabled ? '启用' : '停用', r.enabled ? 'on' : 'off') },
          {
            label: '操作', className: 'actions', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm', onclick: () => form(r) }, '编辑'),
              h('button', { class: 'btn btn-sm', style: 'margin-left:6px', onclick: () => remove(r) }, '删除')),
          },
        ], data.items));
      } catch (e) { fail(listBox, e); }
    }

    function form(row) {
      openModal({
        title: row ? `编辑医生：${row.name}` : '新增医生',
        sub: '医生必须属于某个**已启用**的科室（否则建排班时会被拒绝）',
        submitText: row ? '保存' : '创建',
        fields: [
          { name: 'name', label: '姓名', required: true, value: row ? row.name : '' },
          { name: 'department_id', label: '所属科室', type: 'select', value: row ? row.department_id : (state.deptId || ''),
            options: depts.map((d) => ({ value: d.id, label: `${d.name}${d.enabled ? '' : '（已停用）'}` })) },
          { name: 'title', label: '职称', value: row ? row.title : '', placeholder: '例如 主任医师' },
          { name: 'specialty', label: '专长', value: row ? row.specialty : '' },
          { name: 'enabled', label: '启用', type: 'checkbox', value: row ? row.enabled : true },
        ],
        onSubmit: async (v) => {
          const body = {
            name: v.name, department_id: Number(v.department_id || 0),
            title: v.title, specialty: v.specialty, enabled: v.enabled,
          };
          if (row) { await API.put(`/admin/doctors/${row.id}`, body); toast('医生已保存', 'ok'); }
          else { await API.post('/admin/doctors', body); toast('医生已创建', 'ok'); }
          reload();
        },
      });
    }

    async function remove(row) {
      if (!confirmBox(`删除医生「${row.name}」？\n\n若已被排班引用，服务端会拒绝（BASE_IN_USE），可改为"停用"。`)) { return; }
      try {
        const res = await API.del(`/admin/doctors/${row.id}`);
        toast(res.soft_deleted ? '已停用（软删）' : '已删除', 'ok');
        reload();
      } catch (e) {
        if (e.code === 'BASE_IN_USE') {
          if (confirmBox(`${e.message}\n\n要改为**停用**（软删）吗？`)) {
            try { await API.del(`/admin/doctors/${row.id}?force=true`); toast('已停用（软删）', 'ok'); reload(); }
            catch (e2) { toast(e2.toString(), 'err'); }
          }
          return;
        }
        toast(e.toString(), 'err');
      }
    }

    clear(el);
    el.appendChild(card('医生管理', null,
      toolbar(
        h('button', { class: 'btn btn-primary', onclick: () => form(null) }, '新增医生'),
        h('span', { class: 'grow' }),
        h('select', { onchange: (e) => { state.deptId = Number(e.target.value); reload(); } },
          h('option', { value: '0' }, '全部科室'))),
      listBox));
    /* 科室下拉要在渲染前拿到（新增医生必须选科室）—— 一次拉取，两个用途 */
    API.get('/admin/departments' + API.qs({ include_disabled: 'true' })).then((d) => {
      depts = d.items || [];
      const sel = el.querySelector('.toolbar select');
      depts.forEach((x) => sel.appendChild(h('option', { value: x.id }, x.name)));
    }).catch((e) => toast('科室列表加载失败：' + e.toString(), 'err'));
    reload();
  },
});

/* ============================== 5. 排班号源 ============================== */

/*
 ★ 这一页覆盖了本轮的**两个真实缺口**（详见 docs/ADMIN-WEB.md）：
   ① 以前只有 `POST /admin/schedules`（建），**没有改** —— 放号数写错或临时停诊
      只能再建一条，老的那条连同已约出去的号一起留在那里、患者端照约不误；
   ② 以前没有"列表"（只有 `GET /api/v1/schedules`，够用）。
   现在：新增（POST）、改放号数/停诊（PUT，带 version 乐观锁）。
*/
page({
  id: 'schedules', title: '排班号源', group: '基础数据', icon: '▩',
  render: (el) => {
    const state = { deptId: 0, workDate: '' };
    const listBox = h('div');
    let depts = [];
    let doctors = [];

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/schedules' + API.qs({
          department_id: state.deptId || '', work_date: state.workDate, limit: 100,
        }));
        const rows = (data.schedules || []).map((s) => Object.assign({}, s, {
          /* 已约张数 = 放号数 − 余量；**这是页面上最该看懂的派生值**，
             所以在这里算一次并显示出来（后端 PUT 拒绝时也会回同样的口径） */
          booked: s.total_num - s.remain_num,
        }));
        clear(listBox);
        listBox.appendChild(table([
          { key: 'id', label: 'ID' },
          { key: 'work_date', label: '日期' },
          { key: 'period', label: '时段', render: (r) => badge(r.period, '') },
          { key: 'department_name', label: '科室' },
          { key: 'doctor_name', label: '医生' },
          { key: 'total_num', label: '放号数', className: 'right' },
          { key: 'booked', label: '已约', className: 'right' },
          { key: 'remain_num', label: '余量', className: 'right' },
          { key: 'version', label: '版本', className: 'right' },
          { key: 'enabled', label: '状态', render: (r) => badge(r.enabled ? '可约' : '停诊', r.enabled ? 'on' : 'off') },
          {
            label: '操作', className: 'actions', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm', onclick: () => edit(r) }, '改放号/停诊')),
          },
        ], rows));
        listBox.appendChild(h('div', { class: 'muted', style: 'margin-top:10px' },
          `共 ${data.count} 条（含已约满与已停诊 —— "已约满仍出现在列表里"是刻意的：`,
          `停号要能看见、要能改回来）`));
      } catch (e) { fail(listBox, e); }
    }

    function create() {
      openModal({
        title: '新增排班（号源）',
        sub: '日期不早于今天；时段只能 AM/PM；总号数 > 0（服务端逐条校验）',
        submitText: '创建',
        fields: [
          { name: 'department_id', label: '科室', type: 'select', value: state.deptId || '',
            options: depts.map((d) => ({ value: d.id, label: d.name })) },
          { name: 'doctor_id', label: '医生', type: 'select', value: '',
            options: doctors.map((d) => ({ value: d.id, label: `${d.name}（${d.department_name || ''}）` })),
            hint: '医生必须属于所选科室（服务端校验）' },
          { name: 'work_date', label: '日期', type: 'date', required: true, value: state.workDate || '' },
          { name: 'period', label: '时段', type: 'select', value: 'AM',
            options: [{ value: 'AM', label: '上午 AM' }, { value: 'PM', label: '下午 PM' }] },
          { name: 'total_num', label: '放号数', type: 'number', required: true, value: 10, min: 1 },
        ],
        onSubmit: async (v) => {
          const res = await API.post('/admin/schedules', {
            department_id: Number(v.department_id || 0), doctor_id: Number(v.doctor_id || 0),
            work_date: v.work_date, period: v.period, total_num: Number(v.total_num || 0),
          });
          toast(`排班已创建：id=${res.schedule_id}，放号 ${res.total_num}`, 'ok');
          reload();
        },
      });
    }

    function edit(row) {
      openModal({
        title: `排班 #${row.id}：${row.work_date} ${row.period} ${row.doctor_name || ''}`,
        sub: `当前：放号 ${row.total_num} · 已约 ${row.booked} · 余量 ${row.remain_num} · version ${row.version}`,
        submitText: '保存',
        fields: [
          { name: 'total_num', label: '放号数', type: 'number', value: row.total_num, min: 1,
            hint: `不能小于已约张数（当前已约 ${row.booked} 张）—— 服务端会 400 拒绝并说明` },
          { name: 'enabled', label: '可约（取消勾选 = 停诊，患者端不再出现该排班）', type: 'checkbox', value: row.enabled },
          { name: 'version', label: '版本（乐观锁，不要改）', type: 'number', value: row.version,
            hint: '它来自列表接口。若期间有人改过这条排班，保存会 409 并提示刷新' },
        ],
        onSubmit: async (v) => {
          const res = await API.put(`/admin/schedules/${row.id}`, {
            total_num: Number(v.total_num || 0), enabled: v.enabled, version: Number(v.version || 0),
          });
          toast(`已保存：放号 ${res.total_num} · 已约 ${res.booked} · 余量 ${res.remain_num} · version ${res.version}`, 'ok');
          reload();
        },
      });
    }

    clear(el);
    el.appendChild(card('排班号源', '号源域的写操作只经 BookingRepo 的这一条路由（ADR-0001）',
      toolbar(
        h('button', { class: 'btn btn-primary', onclick: create }, '新增排班'),
        h('span', { class: 'grow' }),
        h('input', { type: 'date', title: '按日期筛选', onchange: (e) => { state.workDate = e.target.value; reload(); } }),
      ),
      listBox));
    /*
     * 科室 + 医生下拉：**各拉一次全量**（管理台的数据量级是几十条，
     * 分页拉取的复杂度不值得）。医生的科室归属用于让使用者少填错。
     */
    Promise.all([
      API.get('/admin/departments' + API.qs({ include_disabled: 'true' })),
      API.get('/admin/doctors' + API.qs({ include_disabled: 'true' })),
    ]).then(([d, doc]) => {
      depts = d.items || [];
      doctors = doc.items || [];
    }).catch((e) => toast('科室/医生列表加载失败：' + e.toString(), 'err'));
    reload();
  },
});

/* ========================= 6. AI 模型配置（`ai_model` 表）========================= */

/*
  ★ 这一页对应截图里的「AI 模型配置」，但有**三处刻意的差异**（都在 docs/ADMIN-WEB.md
    里写明了理由）：

  ① 截图示例的两行是"百练 / dashscope 兼容模式"。本项目的默认值是**播种**出来的
     （`aiModelSeedDefaults`：百练 + qwen-plus / text-embedding-v3），但**种子只在
     表为空时写一次** —— 之后管理台改成什么就是什么，不会被"重启回默认"覆盖。
  ② 截图的「失效配置缓存」在这里是**真按钮**，且一次清两张表的缓存
     （`ai_model` 与 `ai_setting`）—— 名字与效果必须一致。
  ③ 截图只有 CHAT 行显示温度/最大 Token。这里 EMBEDDING 行**也保留字段但不显示**
     （显示 `—`）：embedding 请求确实不发这两个参数，显示出来会让人以为它生效。

  ⚠ 密钥**永不回显**：列表只给 `key_ref_set` / `key_ref_kind` / `key_source`
    （自带 / 用全局 / 没有）。这是服务端的既定口径（`aiModelJson`），前端不要试图
    "显示一部分"。
*/
page({
  id: 'ai-models', title: 'AI 模型配置', group: 'AI 能力中心', icon: '◆',
  render: (el) => {
    const listBox = h('div');
    const probeBox = h('div');
    let globalKeyRefSet = false;

    function keySourceLabel(src) {
      return { model: '自带密钥', global: '用全局密钥', '': '无密钥' }[src || ''] || ('未知（' + src + '）');
    }

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/ai/models' + API.qs({ include_disabled: 'true' }));
        globalKeyRefSet = !!data.global_key_ref_set;
        clear(listBox);
        listBox.appendChild(table([
          { key: 'name', label: '配置名称', render: (r) => h('span', null, r.name,
            r.is_default ? h('span', { class: 'badge chat', style: 'margin-left:6px' }, '默认') : null,
            /*
             * ★★ 「生效中」= 运行时**真正**会选中的那一行（后端 in_use）。
             *    它与「默认」会分叉：默认行被停用或删掉后，运行时退到该类型
             *    第一条启用的行。此时若页面只画「默认」，就会出现
             *    「一行标记都没有、但 AI 确实在用某一行」——用户找不到自己在用哪条。
             */
            (r.in_use && !r.is_default)
              ? h('span', { class: 'badge on', style: 'margin-left:6px',
                            title: '该类型的默认行已停用或已删除，运行时正在用这一条' }, '生效中')
              : null) },
          { key: 'kind', label: '类型', render: (r) => badge(r.kind_label || r.kind, r.kind === 'CHAT' ? 'chat' : 'embedding') },
          { key: 'provider', label: '提供方' },
          { key: 'base_url', label: '接口地址(OpenAI 兼容)', className: 'mono',
            render: (r) => h('span', { title: r.request_url || '' }, r.base_url) },
          { key: 'model', label: '模型名称', className: 'mono' },
          /*
           * 温度只对 CHAT 有意义（embedding 请求体里没有 temperature —— 见 ai_call.cj）。
           * 显示 `—` 而不是 0，是为了不让"没发出去的参数"看起来像"发出去了"。
           */
          { key: 'temperature', label: '温度', className: 'right',
            render: (r) => r.kind === 'CHAT' ? Number(r.temperature).toFixed(2) : '—' },
          { key: 'max_tokens', label: '最大Token', className: 'right',
            render: (r) => r.kind === 'CHAT' ? fmtNum(r.max_tokens) : '—' },
          { key: 'enabled', label: '状态', render: (r) => badge(r.enabled ? '启用' : '停用', r.enabled ? 'on' : 'off') },
          { key: 'key_ref_set', label: '密钥', render: (r) => badge(keySourceLabel(r.key_source),
            r.key_source === 'model' ? 'ok' : (r.key_source === 'global' ? 'chat' : 'err')) },
          {
            label: '操作', className: 'actions nowrap', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm btn-success', onclick: () => probe(r) }, '连通性测试'),
              h('button', { class: 'btn btn-sm btn-info', style: 'margin-left:5px', onclick: () => form(r) }, '编辑'),
              h('button', { class: 'btn btn-sm btn-danger', style: 'margin-left:5px', onclick: () => remove(r) }, '删除')),
          },
        ], data.items));
        listBox.appendChild(h('div', { class: 'muted', style: 'margin-top:10px' },
          `共 ${data.count} 条。服务端缓存 ${data.cache_ttl_secs} 秒；写操作会立即失效缓存，`,
          `因此"保存后下一次 AI 请求自动用新配置"（无需重启）。`,
          globalKeyRefSet ? ' 全局密钥引用已设置（可作为本页留空行的兜底）。' : ' ⚠ 全局密钥引用**未**设置：留空密钥的行会不可用。'));
      } catch (e) { fail(listBox, e); }
    }

    function form(row) {
      const isEdit = !!row;
      const fields = [
        { name: 'name', label: '配置名称', required: true, value: row ? row.name : '',
          placeholder: '例如 默认对话模型(CHAT)', hint: '同名会 409（AI_MODEL_NAME_TAKEN）' },
        { name: 'kind', label: '类型', type: 'select', value: row ? row.kind : 'CHAT',
          options: [{ value: 'CHAT', label: 'CHAT（对话）' }, { value: 'EMBEDDING', label: 'EMBEDDING（向量）' }],
          hint: '决定请求地址：CHAT → /chat/completions，EMBEDDING → /embeddings' },
        { name: 'provider', label: '提供方', value: row ? row.provider : '百练', hint: '仅用于展示，不影响调用' },
        { name: 'base_url', label: '接口地址(OpenAI 兼容)', required: true, value: row ? row.base_url : '',
          placeholder: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          hint: '必须 https；写到 /v1 即可（服务端自动补 /chat/completions 或 /embeddings），也可写完整地址' },
        { name: 'model', label: '模型名称', required: true, value: row ? row.model : '',
          placeholder: 'qwen-plus / text-embedding-v3' },
        { name: 'temperature', label: '温度', type: 'number', step: '0.01', min: '0', max: '2',
          value: row ? row.temperature : '0.3', hint: '0 ~ 2（仅 CHAT 会随请求发出；留空 = 新增用 0.3 / 编辑保持原值）' },
        { name: 'max_tokens', label: '最大 Token', type: 'number', value: row ? row.max_tokens : '2048',
          hint: '64 ~ 8192（仅 CHAT 会随请求发出）' },
        {
          name: 'key_ref', label: '密钥引用', value: '',
          placeholder: 'env:DASHSCOPE_API_KEY 或 file:D:\\keys\\ai.key',
          hint: isEdit
            ? '留空 = **保持原值**（密钥不回显，所以这里永远是空的 —— 想清空请勾下面的"清空"）'
            : '留空 = 用全局密钥引用（ai/settings 页的 ai.key_ref）',
        },
      ];
      if (isEdit) {
        fields.push({ name: 'clear_key_ref', label: '清空本行密钥引用', type: 'checkbox', value: false,
          hint: '勾选并保存 ⇒ 本行改用全局密钥引用' });
      }
      fields.push(
        { name: 'enabled', label: '启用', type: 'checkbox', value: row ? row.enabled : true },
        { name: 'is_default', label: '设为该类型的默认（同类型只有一个默认）', type: 'checkbox',
          value: row ? row.is_default : false,
          hint: 'AI 运行时按"默认行 → 该类型第一条启用行"的顺序解析' });

      openModal({
        title: isEdit ? `编辑模型配置：${row.name}` : '新增模型配置',
        sub: '⚠ 这条路会真的打到大模型服务商（密钥从 env/file 解析，服务端不存明文密钥）',
        wide: true,
        submitText: isEdit ? '保存' : '创建',
        fields: fields,
        onSubmit: async (v) => {
          const body = {
            name: v.name, kind: v.kind, provider: v.provider, base_url: v.base_url, model: v.model,
            enabled: v.enabled, is_default: v.is_default,
          };
          /*
           * ⚠ 数值字段"留空"必须**不发这个键**（而不是发 0）：
           *   服务端 PUT 是 PATCH 语义（缺省保持原值），而 0 是非法值 ⇒ 会 400。
           *   把"没填"编码成 0 是这类表单最常见的坑。
           */
          if (v.temperature !== '' && v.temperature !== null) { body.temperature = Number(v.temperature); }
          if (v.max_tokens !== '' && v.max_tokens !== null) { body.max_tokens = Number(v.max_tokens); }
          if (!isEdit || v.clear_key_ref || (v.key_ref || '').length > 0) { body.key_ref = v.key_ref || ''; }
          if (isEdit) { await API.put(`/admin/ai/models/${row.id}`, body); toast(`已保存：${v.name}`, 'ok'); }
          else { const res = await API.post('/admin/ai/models', body); toast(`已创建：id=${res.id}`, 'ok'); }
          reload();
        },
      });
    }

    async function probe(row) {
      clear(probeBox);
      probeBox.appendChild(h('div', { class: 'note' }, `正在真实调用 ${row.model} …（最长 15 秒）`));
      try {
        const res = await API.post(`/admin/ai/models/${row.id}/test`);
        const p = res.probe || {};
        clear(probeBox);
        probeBox.appendChild(h('div', { class: 'note' + (p.ok ? '' : ' warn') },
          h('b', null, p.ok ? '✅ 连通性测试通过' : '❌ 连通性测试失败'),
          ` · ${p.kind} / ${p.model} · HTTP ${p.http_status} · ${p.elapsed_ms} ms · 密钥来源：${keySourceLabel(p.key_source)}`,
          h('div', { class: 'mono', style: 'margin-top:6px' }, p.request_url || ''),
          p.reason ? h('div', { style: 'margin-top:6px' }, p.reason) : null,
          p.sample ? h('div', { class: 'mono', style: 'margin-top:6px' }, p.sample) : null));
        toast(p.ok ? '连通性测试通过' : '连通性测试失败：' + (p.reason || ''), p.ok ? 'ok' : 'err');
      } catch (e) {
        /* 走到这里不是"模型不通"，而是**接口本身**失败（404/权限/网络）—— 必须区别对待 */
        clear(probeBox);
        probeBox.appendChild(h('div', { class: 'note warn' }, '测试请求本身失败：' + e.toString()));
        toast(e.toString(), 'err');
      }
    }

    async function remove(row) {
      if (!confirmBox(`删除模型配置「${row.name}」？\n\n这是**硬删**。若只是想停用它，请改为"编辑 → 取消启用"。`)) { return; }
      try {
        await API.del(`/admin/ai/models/${row.id}`);
        toast(`已删除：${row.name}`, 'ok');
        reload();
      } catch (e) { toast(e.toString(), 'err'); }
    }

    async function invalidate() {
      try {
        const res = await API.post('/admin/ai/models/invalidate');
        toast(`缓存已失效（模型 ${res.model_cache_ttl_secs}s / 全局 ${res.settings_cache_ttl_secs}s TTL 重新计时）`, 'ok');
      } catch (e) { toast(e.toString(), 'err'); }
    }

    clear(el);
    el.appendChild(card('AI 模型配置', '一个模型一行：类型 / 提供方 / 接口地址 / 模型 / 温度 / 上限 / 启停；AI 请求按此动态构建',
      toolbar(
        h('button', { class: 'btn btn-primary', onclick: () => form(null) }, '新增模型配置'),
        h('button', { class: 'btn', onclick: invalidate }, '失效配置缓存'),
        h('span', { class: 'muted' }, '配置全部存数据库；保存后自动失效缓存，下一次 AI 请求动态构建模型实例，无需重启服务'),
      ),
      probeBox, listBox));
    reload();
  },
});

/* ===================== 7. AI 全局设置（`ai_setting` 表 / 总开关与兜底）===================== */

/*
  与「AI 模型配置」的分工（服务端在 http_app.cj:1473 起有同样一段注释）：
    · 本页 = **全局**事实：总开关、超时、并发、全局密钥引用兜底、CA 包；
    · 模型页 = **每行**事实：用哪个模型、温度、上限、单独密钥。
  模型行里留空的密钥会回落到本页的 `ai.key_ref` —— 这就是两页必须同时存在的原因。
*/
page({
  id: 'ai-settings', title: 'AI 全局设置', group: 'AI 能力中心', icon: '⚙',
  render: (el) => {
    const listBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/ai/settings');
        clear(listBox);
        listBox.appendChild(h('div', { class: 'note' + (data.enabled ? '' : ' warn') },
          h('b', null, data.enabled ? 'AI 总开关：已启用' : 'AI 总开关：未启用'),
          data.disabled_reason ? ' —— ' + data.disabled_reason : '',
          data.endpoint_host ? h('div', { class: 'mono', style: 'margin-top:4px' }, '生效地址：' + data.endpoint_host) : null));
        listBox.appendChild(table([
          { key: 'key', label: '配置项', className: 'mono' },
          { key: 'label', label: '说明' },
          {
            key: 'value', label: '当前值', render: (r) => {
              if (r.secret) {
                return h('span', null, badge(r.set ? '已设置' : '未设置', r.set ? 'ok' : 'err'),
                  r.ref_kind ? h('span', { class: 'muted', style: 'margin-left:6px' }, '来源：' + r.ref_kind) : null);
              }
              return h('span', { class: 'mono' }, r.value === '' ? '（空）' : r.value,
                r.redacted ? h('span', { class: 'badge warn', style: 'margin-left:6px' }, '已脱敏') : null);
            },
          },
          { key: 'default', label: '默认', render: (r) => r.secret ? '—' : h('span', { class: 'mono muted' }, r.default === '' ? '（空）' : r.default) },
          {
            label: '状态', render: (r) => r.secret ? '' : (r.is_default ? badge('使用默认', 'off') : badge('已自定义', 'ok')),
          },
          {
            label: '操作', className: 'actions nowrap', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm btn-info', onclick: () => edit(r) }, '编辑'),
              (!r.secret && !r.is_default) ? h('button', {
                class: 'btn btn-sm', style: 'margin-left:5px', onclick: () => reset(r),
              }, '恢复默认') : null),
          },
        ], data.items));
        listBox.appendChild(h('div', { class: 'muted', style: 'margin-top:10px' },
          '⚠ `ai.ca_bundle_path` 在本版本**不支持**（仓颉 stdx 1.1.3.1 的 TlsClientConfig 只能配 mTLS，没有信任锚入口）——',
          '服务端会拒绝写入并说明理由。这一项留在这里是为了"看得见它为什么用不了"。'));
      } catch (e) { fail(listBox, e); }
    }

    function edit(row) {
      /* 总开关用下拉（"1"/"0"），其余按类型给输入框：数值项服务端有范围校验 */
      const numeric = ['ai.timeout_secs', 'ai.max_concurrent', 'ai.max_tokens'].indexOf(row.key) >= 0;
      openModal({
        title: `编辑：${row.label}`,
        sub: `键名 ${row.key}` + (row.secret ? '（密钥类：只接受 env:名 或 file:路径 —— 不接受明文）' : ''),
        submitText: '保存',
        fields: [{
          name: 'value',
          label: '值',
          type: row.key === 'ai.enabled' ? 'select' : (numeric ? 'number' : 'text'),
          options: row.key === 'ai.enabled' ? [{ value: '1', label: '启用' }, { value: '0', label: '停用' }] : undefined,
          value: row.secret ? '' : (row.key === 'ai.enabled' ? row.value : (row.is_default ? '' : row.value)),
          placeholder: row.secret ? 'env:DASHSCOPE_API_KEY' : (row.is_default ? '（当前为默认值 ' + row.default + '）' : ''),
          hint: row.secret
            ? '留空保存 = 回到默认（未设置）；密钥本身请放在环境变量或文件里'
            : '留空保存 = 恢复默认值（不是"设为空"，服务端对空值一律回默认）',
        }],
        onSubmit: async (v) => {
          await API.put(`/admin/ai/settings/${row.key}`, { value: v.value });
          toast(`已保存：${row.label}`, 'ok');
          reload();
        },
      });
    }

    async function reset(row) {
      if (!confirmBox(`把「${row.label}」恢复为默认值（默认 ${row.default === '' ? '空' : row.default}）？`)) { return; }
      try { await API.del(`/admin/ai/settings/${row.key}`); toast('已恢复默认', 'ok'); reload(); }
      catch (e) { toast(e.toString(), 'err'); }
    }

    clear(el);
    el.appendChild(card('AI 全局设置', '总开关 / 超时 / 并发 / 全局密钥引用 —— 模型行留空的项在这里兜底',
      toolbar(h('button', { class: 'btn', onclick: () => reload() }, '刷新')), listBox));
    reload();
  },
});

/* ============================== 8. Prompt 模板 ============================== */

/*
  Prompt 的正文**原样回显**（服务端刻意不脱敏 —— 它不是机密，是"让模型干什么"的
  指令文本，管理员必须能核对）。改写时服务端会校验**必需占位符**与长度上限
  （`{主诉}` 这类占位符少一个，模型就会在缺信息的情况下作答）。
  「恢复默认」= 删掉库里的自定义行 ⇒ 回到代码里的内置模板。
*/
page({
  id: 'ai-prompts', title: 'Prompt 模板', group: 'AI 能力中心', icon: '✎',
  render: (el) => {
    const listBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/ai/prompts');
        clear(listBox);
        listBox.appendChild(table([
          { key: 'label', label: '模板' },
          { key: 'name', label: '键名', className: 'mono nowrap' },
          { key: 'required', label: '必需占位符', render: (r) => h('span', { class: 'mono' }, (r.required || []).join(' ')) },
          { key: 'max_len', label: '长度上限', className: 'right', render: (r) => r.max_len + ' 字' },
          { key: 'customized', label: '状态', render: (r) => r.customized ? badge('已自定义', 'ok') : badge('内置默认', 'off') },
          { key: 'body', label: '正文预览', className: 'muted',
            render: (r) => (r.body || '').slice(0, 40) + ((r.body || '').length > 40 ? '…' : '') },
          {
            label: '操作', className: 'actions nowrap', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm btn-info', onclick: () => edit(r) }, '编辑'),
              r.customized ? h('button', {
                class: 'btn btn-sm', style: 'margin-left:5px', onclick: () => reset(r),
              }, '恢复默认') : null),
          },
        ], data.prompts));
      } catch (e) { fail(listBox, e); }
    }

    function edit(row) {
      openModal({
        title: `编辑模板：${row.label}`,
        sub: `必需占位符（少一个就会被服务端拒绝）：${(row.required || []).join('  ')}　·　上限 ${row.max_len} 字`,
        wide: true,
        submitText: '保存',
        fields: [{ name: 'body', label: '模板正文', type: 'textarea', rows: 14, required: true, value: row.body }],
        onSubmit: async (v) => {
          await API.put(`/admin/ai/prompts/${row.name}`, { body: v.body });
          toast(`已保存模板：${row.label}`, 'ok');
          reload();
        },
      });
    }

    async function reset(row) {
      if (!confirmBox(`把「${row.label}」恢复为内置默认模板？（当前自定义内容会被删除）`)) { return; }
      try { await API.del(`/admin/ai/prompts/${row.name}`); toast('已恢复默认', 'ok'); reload(); }
      catch (e) { toast(e.toString(), 'err'); }
    }

    clear(el);
    el.appendChild(card('Prompt 模板', '分诊 / 预问诊 / 危急检测三条路的系统提示词',
      toolbar(h('button', { class: 'btn', onclick: reload }, '刷新')), listBox));
    reload();
  },
});

/* ============================== 9. 工具中心 mcp_tool ============================== */

/*
  这里的"工具"是**本项目内置的只读查询能力**（科室/号源/医生专长/危急扫描/问项/既往史），
  不是外部 MCP 服务 —— 名字沿用截图（`mcp_tool`），但实现是本地函数白名单。
  开关只接受布尔（服务端明确拒绝 "1"/"yes" 这类写法）。
*/
page({
  id: 'ai-tools', title: '工具中心 mcp_tool', group: 'AI 能力中心', icon: '⚒',
  render: (el) => {
    const listBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/ai/tools');
        clear(listBox);
        listBox.appendChild(h('div', { class: 'note' },
          h('b', null, `已开启 ${data.count_enabled} / ${(data.tools || []).length} 个工具`),
          ' —— 工具让模型能"查事实"（科室、号源、医生专长、既往史…），而不是凭记忆作答。全部关闭时模型仍可作答，但准确率会下降。'));
        listBox.appendChild(table([
          { key: 'label', label: '工具' },
          { key: 'name', label: '键名', className: 'mono nowrap' },
          { key: 'default_on', label: '默认', render: (r) => r.default_on ? badge('默认开', 'off') : '—' },
          { key: 'enabled', label: '当前', render: (r) => badge(r.enabled ? '已开启' : '已关闭', r.enabled ? 'on' : 'off') },
          {
            label: '操作', className: 'actions nowrap', render: (r) => h('button', {
              class: 'btn btn-sm ' + (r.enabled ? '' : 'btn-primary'), onclick: () => toggle(r),
            }, r.enabled ? '关闭' : '开启'),
          },
        ], data.tools));
      } catch (e) { fail(listBox, e); }
    }

    async function toggle(row) {
      try {
        await API.put(`/admin/ai/tools/${row.name}`, { enabled: !row.enabled });
        toast(`${row.label}：已${row.enabled ? '关闭' : '开启'}`, 'ok');
        reload();
      } catch (e) { toast(e.toString(), 'err'); }
    }

    clear(el);
    el.appendChild(card('工具中心', '模型的"手"：只读查询白名单（开关即时生效，无需重启）',
      toolbar(h('button', { class: 'btn', onclick: reload }, '刷新')), listBox));
    reload();
  },
});

/* ============================== 10. 医学知识库 ============================== */

/*
  两件事同页：**文档 CRUD** 与 **检索自测**。
  检索自测是刻意放在这里的：改完文档后"搜一下"是最直接的自检手段，
  而服务端在返回里明确给了 `source`（keyword/vector）与 `missing_vectors` ——
  这解释了"为什么没召回"（当前生产检索走关键词路，见 kb_repo.cj 的 embedding_note）。

  ⚠ 文档是**硬删**（连带切块），停用请用"编辑 → 取消启用"。
*/
page({
  id: 'kb', title: '医学知识库', group: 'AI 能力中心', icon: '❖',
  render: (el) => {
    const listBox = h('div');
    const statsBox = h('div');
    const searchBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/kb/docs' + API.qs({ include_disabled: 'true' }));
        clear(listBox);
        listBox.appendChild(table([
          { key: 'id', label: 'ID' },
          { key: 'title', label: '标题' },
          { key: 'category', label: '分类', render: (r) => r.category || '—' },
          { key: 'chunk_count', label: '切块', className: 'right' },
          { key: 'enabled', label: '状态', render: (r) => badge(r.enabled ? '启用' : '停用', r.enabled ? 'on' : 'off') },
          { key: 'updated_at', label: '更新于', render: (r) => fmtTime(r.updated_at) },
          {
            label: '操作', className: 'actions nowrap', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm btn-info', onclick: () => edit(r) }, '编辑'),
              h('button', { class: 'btn btn-sm btn-danger', style: 'margin-left:5px', onclick: () => remove(r) }, '删除')),
          },
        ], data.items));
      } catch (e) { fail(listBox, e); }
    }

    async function loadStats() {
      loading(statsBox);
      try {
        const s = await API.get('/admin/kb/stats');
        clear(statsBox);
        statsBox.appendChild(h('div', { class: 'stat-row' },
          stat('文档', `${fmtNum(s.docs_enabled)} / ${fmtNum(s.docs)}`, '启用 / 总数'),
          stat('切块', fmtNum(s.chunks), s.scan_limit_reached ? `⚠ 统计达到扫描上限 ${s.scan_limit}` : `扫描口径 ${s.scan_limit} 以内`),
          stat('已向量化', fmtNum(s.chunks_embedded), `覆盖率 ${fmtNum(s.embedding_coverage_pct)}%`)));
        statsBox.appendChild(h('div', { class: 'note', style: 'margin-top:12px' },
          h('b', null, '口径：'), s.embedding_note || '—',
          s.scan_limit_note ? h('div', { style: 'margin-top:4px' }, s.scan_limit_note) : null));
      } catch (e) { fail(statsBox, e); }
    }

    function create() {
      openModal({
        title: '新增知识库文档',
        sub: '保存时会**立即切块**（chunk_count 即切块数）；正文上限 20000 字',
        wide: true,
        submitText: '保存',
        fields: [
          { name: 'title', label: '标题', required: true, hint: '同名会 409（KB_TITLE_TAKEN）' },
          { name: 'category', label: '分类', placeholder: '例如 内科 / 用药安全' },
          { name: 'body', label: '正文', type: 'textarea', rows: 16, required: true,
            hint: '疑似含个人信息（手机号/身份证等）会被服务端拒绝' },
        ],
        onSubmit: async (v) => {
          const res = await API.post('/admin/kb/docs', { title: v.title, category: v.category, body: v.body });
          toast(`已保存：id=${res.id}，切块 ${res.chunk_count} 段`, 'ok');
          reload(); loadStats();
        },
      });
    }

    async function edit(row) {
      /* 列表接口**不含正文**（列表轻、详情重）⇒ 编辑前必须先取详情 */
      let full;
      try { full = await API.get(`/admin/kb/docs/${row.id}`); }
      catch (e) { toast('读取文档失败：' + e.toString(), 'err'); return; }
      openModal({
        title: `编辑文档：${full.title}`,
        sub: `id=${full.id} · 更新于 ${fmtTime(full.updated_at)} · 保存后**无条件重新切块**`,
        wide: true,
        submitText: '保存',
        fields: [
          { name: 'title', label: '标题', required: true, value: full.title },
          { name: 'category', label: '分类', value: full.category },
          { name: 'body', label: '正文', type: 'textarea', rows: 16, required: true, value: full.body,
            hint: '⚠ 表单会带上完整正文（保存后**无条件重新切块**）。服务端是 PATCH 语义：**没传**的字段保留旧值，但**传了空正文**会被拒（400），不会静默清空' },
          { name: 'enabled', label: '启用', type: 'checkbox', value: full.enabled },
        ],
        onSubmit: async (v) => {
          const res = await API.put(`/admin/kb/docs/${row.id}`, {
            title: v.title, category: v.category, body: v.body, enabled: v.enabled,
          });
          toast(`已保存：切块 ${res.chunk_count} 段${res.enabled ? '' : '（已停用）'}`, 'ok');
          reload(); loadStats();
        },
      });
    }

    async function remove(row) {
      if (!confirmBox(`删除文档「${row.title}」？\n\n这是**硬删**：文档与它的 ${row.chunk_count} 个切块会一起删除，不可恢复。\n只想下架请改为"编辑 → 取消启用"。`)) { return; }
      try { await API.del(`/admin/kb/docs/${row.id}`); toast('已删除（含切块）', 'ok'); reload(); loadStats(); }
      catch (e) { toast(e.toString(), 'err'); }
    }

    function search() {
      const input = searchBox.querySelector('input');
      const q = (input.value || '').trim();
      const out = searchBox.querySelector('.search-out');
      if (!q) { toast('请输入查询词', 'err'); return; }
      loading(out, '检索中…');
      API.get('/kb/search' + API.qs({ q: q, top: 5 })).then((res) => {
        clear(out);
        if (!res.items || res.items.length === 0) {
          out.appendChild(h('div', { class: 'empty' }, '没有命中'));
        } else {
          out.appendChild(table([
            { key: 'score', label: '得分', className: 'right', render: (r) => Number(r.score).toFixed(4) },
            { key: 'title', label: '文档' },
            { key: 'seq', label: '块', className: 'right' },
            { key: 'content', label: '内容', render: (r) => (r.content || '').slice(0, 120) + ((r.content || '').length > 120 ? '…' : '') },
          ], res.items));
        }
        out.appendChild(h('div', { class: 'muted', style: 'margin-top:8px' },
          `检索路：${res.source} · 扫描 ${res.scanned} 块 · 缺向量 ${res.missing_vectors} 块`,
          res.source !== 'vector' ? '（当前走关键词路：向量路需要 EMBEDDING 模型 + 已向量化的切块）' : ''));
      }).catch((e) => { clear(out); out.appendChild(h('div', { class: 'note warn' }, '检索失败：' + e.toString())); });
    }

    clear(el);
    el.appendChild(card('知识库概览', '统计口径与"为什么没召回"的答案都在这里', null, statsBox));
    el.appendChild(card('检索自测', '改完文档立刻验证召回（返回里带 source 与 missing_vectors）',
      toolbar(
        h('input', { type: 'text', placeholder: '例如 高血压 用药', style: 'min-width:260px' }),
        h('button', { class: 'btn btn-info', onclick: search }, '检索'),
      ),
      h('div', { class: 'search-out' })));
    el.appendChild(card('文档管理', '保存即切块；停用用编辑、删除是硬删',
      toolbar(h('button', { class: 'btn btn-primary', onclick: create }, '新增文档')),
      listBox));
    reload(); loadStats();
  },
});

/* ============================== 11. 系统公告 ============================== */

/*
  公告有**两个时间概念**，这一页必须让它们都看得见：
    · `published_at` —— 生效时间（服务端只对患者端回 `published_at <= now` 的公告）
    · `enabled` —— 启停（下架留痕用这个，而不是删除）
  PUT 时 `published_at` **缺省保持原值**（服务端防"预排期被提前发布"）—— 所以这里
  编辑表单里它是**预填**的：留空 = 不改。
*/
page({
  id: 'notices', title: '系统公告', group: '系统管理', icon: '☂',
  render: (el) => {
    const listBox = h('div');

    async function reload() {
      loading(listBox);
      try {
        const data = await API.get('/admin/notices' + API.qs({ include_disabled: 'true', limit: 200 }));
        clear(listBox);
        listBox.appendChild(table([
          { key: 'id', label: 'ID' },
          { key: 'title', label: '标题' },
          { key: 'category', label: '分类', render: (r) => r.category || '—' },
          { key: 'date', label: '生效日期' },
          { key: 'sort', label: '排序', className: 'right' },
          { key: 'enabled', label: '状态', render: (r) => badge(r.enabled ? '已发布' : '已下架', r.enabled ? 'on' : 'off') },
          { key: 'updated_at', label: '更新于', render: (r) => fmtTime(r.updated_at) },
          {
            label: '操作', className: 'actions nowrap', render: (r) => h('span', null,
              h('button', { class: 'btn btn-sm btn-info', onclick: () => edit(r) }, '编辑'),
              h('button', { class: 'btn btn-sm', style: 'margin-left:5px', onclick: () => toggle(r) }, r.enabled ? '下架' : '重新发布'),
              h('button', { class: 'btn btn-sm btn-danger', style: 'margin-left:5px', onclick: () => remove(r) }, '删除')),
          },
        ], data.items));
        listBox.appendChild(h('div', { class: 'muted', style: 'margin-top:10px' },
          `共 ${data.count} 条。患者端只看得到"已发布且生效时间已到"的公告（服务端过滤，见 domain_notice.cj）。`));
      } catch (e) { fail(listBox, e); }
    }

    /* epoch 秒 ↔ <input type="datetime-local"> 的本地时间串（两者都按浏览器本地时区理解） */
    function toLocalInput(secs) {
      if (!secs) { return ''; }
      const d = new Date(secs * 1000);
      const p = (n) => String(n).padStart(2, '0');
      return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
    }
    function fromLocalInput(v) {
      if (!v) { return null; }
      const t = new Date(v).getTime();
      return isNaN(t) ? null : Math.floor(t / 1000);
    }

    function form(row) {
      openModal({
        title: row ? `编辑公告：${row.title}` : '新增公告',
        sub: row ? `id=${row.id} · 生效时间留空 = 保持原值（${fmtTime(row.published_at)}）`
          : '生效时间留空 = 立即生效；标题不许换行，正文可以',
        wide: true,
        submitText: row ? '保存' : '发布',
        fields: [
          { name: 'title', label: '标题', required: true, value: row ? row.title : '',
            hint: '≤128 字、不能含换行/制表符；同名会 409（NOTICE_TITLE_TAKEN）' },
          { name: 'category', label: '分类', value: row ? row.category : '通知', hint: '≤32 字，自由文本（服务端不校验枚举）' },
          { name: 'body', label: '正文', type: 'textarea', rows: 8, value: row ? row.body : '', hint: '≤2000 字' },
          { name: 'sort', label: '排序', type: 'number', value: row ? row.sort : 0, hint: '小的在前' },
          { name: 'published_at', label: '生效时间', type: 'datetime-local', value: row ? toLocalInput(row.published_at) : '',
            hint: '留空：新增=立即生效；编辑=保持原值' },
          { name: 'enabled', label: '发布（取消勾选 = 下架，患者端立即看不到）', type: 'checkbox', value: row ? row.enabled : true },
        ],
        onSubmit: async (v) => {
          const body = {
            title: v.title, body: v.body, category: v.category,
            sort: Number(v.sort || 0), enabled: v.enabled,
          };
          const t = fromLocalInput(v.published_at);
          if (t !== null) { body.published_at = t; }
          if (row) { await API.put(`/admin/notices/${row.id}`, body); toast('公告已保存', 'ok'); }
          else { const res = await API.post('/admin/notices', body); toast(`公告已发布：id=${res.id}`, 'ok'); }
          reload();
        },
      });
    }

    async function toggle(row) {
      try {
        await API.put(`/admin/notices/${row.id}`, { enabled: !row.enabled });
        toast(row.enabled ? '已下架' : '已重新发布', 'ok');
        reload();
      } catch (e) { toast(e.toString(), 'err'); }
    }

    async function remove(row) {
      if (!confirmBox(`删除公告「${row.title}」？\n\n这是**硬删**。想留痕请用"下架"。`)) { return; }
      try { await API.del(`/admin/notices/${row.id}`); toast('已删除', 'ok'); reload(); }
      catch (e) { toast(e.toString(), 'err'); }
    }

    function edit(row) { form(row); }

    clear(el);
    el.appendChild(card('系统公告', '发布 / 下架 / 预排期（生效时间到点后患者端可见）',
      toolbar(h('button', { class: 'btn btn-primary', onclick: () => form(null) }, '新增公告')), listBox));
    reload();
  },
});

