/*
  管理台的 DOM/交互小工具（2026-10-14）
  ============================================================================
  这里刻意**不引入任何 UI 框架**（理由见 index.html 顶部）。为了让"没有框架"
  不等于"到处手写 createElement"，下面给出四个原语，页面脚本只用它们：

    h(...)        建元素（含属性/事件/子节点）
    card(...)     白卡片 + 标题 + 右侧操作区
    table(...)    表格（列定义 + 行数据，空数据给统一空态）
    openModal(...)表单弹窗（**字段由数据描述**，收集 + 校验 + 报错一处解决）

  ⚠ 所有"能给使用者看的话"都在页面脚本里（用中文），这里只提供机制 ——
    机制里混入业务文案，改文案就得动公共代码，是最容易出不一致的写法。
*/

/* ------------------------------ DOM 原语 ------------------------------ */

/*
 * h('div', {class:'x', onclick:fn}, child1, child2…)
 * · 属性值 undefined/null/false 会被跳过（便于 `disabled: cond && true` 这种写法）
 * · 子节点可以是字符串、节点、数组、null
 */
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  Object.keys(attrs || {}).forEach((k) => {
    const v = attrs[k];
    if (v === undefined || v === null || v === false) { return; }
    if (k.startsWith('on') && typeof v === 'function') {
      el.addEventListener(k.slice(2).toLowerCase(), v);
    } else if (k === 'class') {
      el.className = v;
    } else if (k === 'html') {
      el.innerHTML = v;
    } else if (k === 'value') {
      el.value = v;
    } else if (k === 'checked' || k === 'disabled' || k === 'selected') {
      el[k] = !!v;
    } else {
      el.setAttribute(k, v);
    }
  });
  append(el, children);
  return el;
}

function append(parent, children) {
  (children || []).forEach((c) => {
    if (c === null || c === undefined || c === false) { return; }
    if (Array.isArray(c)) { append(parent, c); return; }
    parent.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c)));
  });
}

function clear(node) { while (node.firstChild) { node.removeChild(node.firstChild); } }

function badge(text, cls) { return h('span', { class: 'badge ' + (cls || '') }, text); }

/* --------------------------------- 提示 -------------------------------- */

function toast(message, kind) {
  const root = document.getElementById('toast-root');
  const box = h('div', { class: 'toast ' + (kind || '') }, message);
  root.appendChild(box);
  /* 3.2s 后自动消失；`err` 多留一会儿 —— 报错信息通常要读两遍 */
  setTimeout(() => { if (box.parentNode) { box.parentNode.removeChild(box); } }, kind === 'err' ? 6000 : 3200);
}

/* --------------------------------- 卡片 -------------------------------- */

function card(title, sub, actions, ...children) {
  return h('div', { class: 'card' },
    h('div', { class: 'card-head' },
      h('div', null, h('div', { class: 'card-title' }, title), sub ? h('div', { class: 'card-sub' }, sub) : null),
      h('div', { class: 'spacer' }),
      actions || null),
    children);
}

/* --------------------------------- 表格 -------------------------------- */

/*
 * table(columns, rows)
 *   columns: [{ key, label, className, render(row) -> node|string }]
 *   空数据 ⇒ 一行"暂无数据"（而不是一张空表格：空表格看起来像"还在加载"）
 */
function table(columns, rows) {
  if (!rows || rows.length === 0) {
    return h('div', { class: 'empty' }, '暂无数据');
  }
  const thead = h('thead', null, h('tr', null, columns.map((c) =>
    h('th', { class: c.className || '' }, c.label))));
  const tbody = h('tbody', null, rows.map((row) => h('tr', null, columns.map((c) => {
    const cell = c.render ? c.render(row) : row[c.key];
    return h('td', { class: c.className || '' }, cell === undefined || cell === null ? '—' : cell);
  }))));
  return h('table', { class: 'grid' }, thead, tbody);
}

/* --------------------------------- 格式化 ------------------------------ */

function fmtTime(secs) {
  if (!secs) { return '—'; }
  const d = new Date(secs * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/* 服务端给的 `*_permille` 是**千分比整数**（÷10 = 百分比）—— 见 dashboard.cj 的 permille_note */
function fmtPermille(v) {
  if (v === undefined || v === null) { return '—'; }
  return (Number(v) / 10).toFixed(1) + '%';
}

function fmtNum(v) { return (v === undefined || v === null) ? '—' : String(v); }

/* --------------------------------- 弹窗 -------------------------------- */

/*
 * openModal({title, sub, fields, submitText, wide, onSubmit})
 *
 * `fields` 是**数据描述**（而不是外面自己拼 DOM）：新增与编辑用的是同一份字段表，
 * 差别只在 `value` 初值 —— 这是"两处表单长得不一样"这类 bug 的根源。
 *   { name, label, type: 'text'|'password'|'number'|'textarea'|'select'|'checkbox'|'date',
 *     value, required, hint, placeholder, options: [{value,label}], min, max, step, rows }
 *
 * `onSubmit(values, box)`：
 *   · 返回 undefined / true ⇒ 关闭；
 *   · 返回字符串 ⇒ 当作错误显示在弹窗里（**不关闭**，让使用者改完再来）；
 *   · 抛异常 ⇒ 同上（ApiError.toString() 会带 code）。
 * ⚠ 失败时**不关闭弹窗**：关掉再让使用者重填一遍是最气人的交互。
 */
function openModal(spec) {
  const root = document.getElementById('modal-root');
  const errBox = h('div', { class: 'modal-error hidden' });
  const okBox = h('div', { class: 'modal-ok hidden' });
  const inputs = {};

  const body = (spec.fields || []).map((f) => {
    if (f.type === 'checkbox') {
      const input = h('input', { type: 'checkbox', checked: !!f.value, id: 'f-' + f.name });
      inputs[f.name] = () => input.checked;
      return h('label', { class: 'field', style: 'display:flex;align-items:center;gap:8px' },
        input, h('span', { style: 'margin:0' }, f.label),
        f.hint ? h('span', { class: 'hint', style: 'margin:0' }, f.hint) : null);
    }
    let input;
    if (f.type === 'textarea') {
      input = h('textarea', { rows: f.rows || 6, placeholder: f.placeholder || '' }, f.value === undefined ? '' : f.value);
    } else if (f.type === 'select') {
      input = h('select', null, (f.options || []).map((o) =>
        h('option', { value: o.value, selected: String(o.value) === String(f.value) }, o.label)));
    } else {
      input = h('input', {
        type: f.type || 'text',
        value: f.value === undefined || f.value === null ? '' : f.value,
        placeholder: f.placeholder || '',
        min: f.min, max: f.max, step: f.step,
        autocomplete: f.type === 'password' ? 'new-password' : 'off',
      });
    }
    inputs[f.name] = () => input.value;
    return h('label', { class: 'field' },
      h('span', null, f.label, f.required ? h('span', { class: 'req' }, '*') : null),
      input,
      f.hint ? h('div', { class: 'hint' }, f.hint) : null);
  });

  const submitBtn = h('button', { class: 'btn btn-primary', type: 'submit' }, spec.submitText || '保存');
  const form = h('form', { class: 'modal-form' }, errBox, okBox, body,
    h('div', { class: 'modal-foot' },
      h('button', { class: 'btn', type: 'button', onclick: () => close() }, '取消'),
      submitBtn));

  const modal = h('div', { class: 'modal' + (spec.wide ? ' wide' : '') },
    h('div', { class: 'modal-title' }, spec.title),
    spec.sub ? h('div', { class: 'modal-sub' }, spec.sub) : null,
    form);
  const mask = h('div', { class: 'modal-mask', onclick: (e) => { if (e.target === mask) { close(); } } }, modal);

  function close() { if (mask.parentNode) { mask.parentNode.removeChild(mask); } }

  const box = {
    close: close,
    showError(msg) { errBox.textContent = msg; errBox.classList.remove('hidden'); okBox.classList.add('hidden'); },
    showOk(msg) { okBox.textContent = msg; okBox.classList.remove('hidden'); errBox.classList.add('hidden'); },
    hideMessages() { errBox.classList.add('hidden'); okBox.classList.add('hidden'); },
    setBusy(busy, label) {
      submitBtn.disabled = !!busy;
      submitBtn.textContent = busy ? (label || '处理中…') : (spec.submitText || '保存');
    },
  };

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    box.hideMessages();
    const values = {};
    Object.keys(inputs).forEach((k) => { values[k] = inputs[k](); });
    box.setBusy(true);
    try {
      const res = await spec.onSubmit(values, box);
      if (typeof res === 'string' && res.length > 0) {
        box.showError(res);
        box.setBusy(false);
        return;
      }
      close();
    } catch (err) {
      box.showError(err && err.toString ? err.toString() : String(err));
      box.setBusy(false);
    }
  });

  root.appendChild(mask);
  const first = modal.querySelector('input, select, textarea');
  if (first) { first.focus(); }
  return box;
}

/* 二次确认（删除这类不可逆操作前必须问一句） */
function confirmBox(message) {
  return window.confirm(message);
}
