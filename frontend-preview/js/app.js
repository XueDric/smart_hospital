/* ==========================================================================
   智慧医院 · 前端预览 — 交互逻辑
   布局 / 页面清单 / 关键交互全量对齐 docs/frontend-preview.html（走查稿）：
   - 患者端 5 Tab：分诊 / 预问诊 / 约号 / 我的预约 / 我的（规范无首页、无公告页）
   - 三条红线：① 分诊 red_flag 只引导急诊、不复述关键词、绝不展示号源
               ② 挂号 client_token：一次意图一个、换号源换新
               ③ 在线直连；退号成功必须看 data.status === 'cancelled'
   - 病历：required_to_lock 仅 diagnosis / treatment；锁定后只读，reopen 是管理员动作
   【预览专用】全部数据为 js/data.js 中的 Mock，实际应替换为服务端 REST 调用。
   ========================================================================== */

(function () {
  'use strict';

  var D = window.MOCK;

  /* ---------------- 全局状态（【预览专用】内存态，无持久化） ---------------- */
  var state = {
    role: 'patient',
    patient: {
      loggedIn: false,
      tab: 'triage',            // triage | previsit | booking | appointments | profile
      page: null, pageArg: null, // records | recordDetail | sessions
      apptIncludeCancelled: false
    },
    triage: { complaint: '', loading: false, result: null },
    previsit: { step: 0, answers: [], done: false },
    booking: { deptId: null, date: null, clientToken: null, scheduleId: null },
    doctor: {
      loggedIn: false, page: 'queue', // queue | record
      periodFilter: 'ALL'             // ALL | AM | PM
    },
    admin: { page: 'dashboard', aiTab: 'settings', editDeptId: null }
  };

  /* ---------------- 通用工具 ---------------- */
  function $(sel) { return document.querySelector(sel); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  /** 【预览专用】标注徽标：仅在开发预览中展示，实际软件中不会出现 */
  function PV(text) {
    return '<span class="preview-badge" title="此元素仅开发预览展示，实际软件中不存在">' + esc(text || '预览专用') + '</span>';
  }
  function toast(msg) {
    var old = $('.toast'); if (old) old.remove();
    var t = document.createElement('div');
    t.className = 'toast'; t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, 2400);
  }
  function newToken() {
    return 'ct-' + Date.now().toString(16) + '-' + Math.floor(Math.random() * 0xffffff).toString(16);
  }
  function periodText(p) { return p === 'AM' ? '上午（AM）' : p === 'PM' ? '下午（PM）' : (p || '时段未知'); }

  /* 预约 / 就诊状态标签（对齐走查稿 m-tag 语义） */
  var APPT_TAG = {
    booked:    ['已挂号', ''],
    visiting:  ['接诊中', 'warn'],
    done:      ['已完成', 'ok'],
    cancelled: ['已取消', 'danger'],
    no_show:   ['爽约',   'danger']
  };
  function apptTag(s) {
    var t = APPT_TAG[s] || ['未知', 'gray'];
    return '<span class="m-tag ' + t[1] + '">' + t[0] + '</span>';
  }

  /* ==========================================================================
     渲染入口
     ========================================================================== */
  function render() {
    var stage = $('#stage');
    if (state.role === 'admin') stage.innerHTML = renderAdmin();
    else if (state.role === 'doctor') stage.innerHTML = renderDoctorPhone();
    else stage.innerHTML = renderPatientPhone();
    var ov = $('#pending-overlay');
    if (ov) ov.remove();
  }

  /* ---- 手机壳（对齐走查稿骨架：状态栏 + 标题栏 + 滚动内容 + 底部 Tab） ---- */
  function phone(navTitle, backFn, bodyHtml, tabbarHtml, overlayHtml) {
    return '<div class="phone"><div class="screen">' +
      // 【预览专用】状态栏为预览模拟，实际由系统提供
      '<div class="sbar"><span>9:41</span><span class="dots">●●●' + PV('预览·手机壳') + '</span><span>100%</span></div>' +
      '<div class="navbar">' + (backFn ? '<span class="back" onclick="App.' + backFn + '()">‹</span>' : '') + esc(navTitle) + '</div>' +
      '<div class="mbody">' + bodyHtml + '</div>' +
      (tabbarHtml || '') +
      (overlayHtml || '') +
      '</div></div>';
  }

  /* 患者端 5 Tab（对齐走查稿：✦分诊 💬预问诊 ＋约号 📋我的预约 👤我的） */
  var P_TABS = [
    ['triage', '✦', '分诊'], ['previsit', '💬', '预问诊'], ['booking', '＋', '约号'],
    ['appointments', '📋', '我的预约'], ['profile', '👤', '我的']
  ];
  function patientTabbar() {
    return '<div class="tabbar">' + P_TABS.map(function (t) {
      var on = state.patient.tab === t[0] && !state.patient.page ? ' on' : '';
      return '<div class="tab' + on + '" onclick="App.pTab(\'' + t[0] + '\')"><span class="ic">' + t[1] + '</span>' + t[2] + '</div>';
    }).join('') + '</div>';
  }

  function renderPatientPhone() {
    var p = state.patient;
    if (!p.loggedIn) return phone('登录', null, renderLogin(), null, null);
    if (p.page === 'records') return phone('就诊记录', 'pBack', renderRecords(), null, null);
    if (p.page === 'recordDetail') return phone('就诊记录', 'pBack', renderRecordDetail(p.pageArg), null, null);
    if (p.page === 'sessions') return phone('设备管理', 'pBack', renderSessions(), null, null);
    switch (p.tab) {
      case 'previsit': return phone('智能预问诊', null, renderPrevisit(), patientTabbar(), null);
      case 'booking': return phone('预约挂号', null, renderBooking(), patientTabbar(), state.booking.scheduleId ? renderBookDialog() : null);
      case 'appointments': return phone('我的预约', null, renderAppointments(), patientTabbar(), null);
      case 'profile': return phone('我的', null, renderProfile(), patientTabbar(), null);
      default: return phone('智能分诊', null, renderTriage(), patientTabbar(), state.triage.result === 'redflag' ? renderRedflagDialog() : null);
    }
  }

  /* ==========================================================================
     P-1 登录（字段必须 login_name / password；dev_auth 红色告警）
     ========================================================================== */
  function renderLogin() {
    return '<div class="login-wrap">' +
      '<div class="login-logo"><div class="avatar">医</div>' +
      '<div class="nm">智慧医院</div><div class="sb">智能导诊就诊系统 · 患者端</div></div>' +
      '<div class="field" id="f-lname"><div class="m-label">登录名（手机号）</div>' +
      '<input class="m-input" id="login-name" maxlength="11" placeholder="请输入 11 位手机号" value="13800006021">' +
      '<div class="err">请输入正确的 11 位手机号（字段名 login_name）</div></div>' +
      '<div class="field" id="f-lpwd"><div class="m-label">密码</div>' +
      '<input class="m-input" id="login-pwd" type="password" placeholder="至少 6 位" value="123456">' +
      '<div class="err">密码至少 6 位（字段名 password）</div></div>' +
      '<button class="m-btn" onclick="App.pLogin()">登 录</button>' +
      '<div class="banner warn">开发鉴权模式已开启（dev_auth=true），请勿用于正式环境 ' + PV('Mock 提示') + '</div>' +
      '</div>';
  }

  /* ==========================================================================
     P-2 智能分诊（一次性 JSON 无流式；options 是唯一科室/医生名来源）
     ========================================================================== */
  function renderTriage() {
    var t = state.triage;
    var html = '<div class="m-label">请描述您的不适</div>' +
      '<div class="field" id="f-complaint">' +
      '<textarea class="m-input area" id="triage-input" placeholder="例如：咳嗽三天，有黄痰，晚上有点发热">' + esc(t.complaint) + '</textarea>' +
      '<div class="err">请输入至少 4 个字的主诉（服务端超长按字符截断到 500 字）</div></div>' +
      '<button class="m-btn" onclick="App.triageSubmit()"' + (t.loading ? ' disabled' : '') + '>' + (t.loading ? '分诊中…' : '开始分诊') + '</button>';

    if (t.loading) {
      html += '<div class="loading-block">AI 分诊中（一次性 JSON，无流式）</div>';
    } else if (t.result === 'ok') {
      html += '<div class="m-sec" style="margin-top:4px">推荐号源 <span style="font-weight:400;color:#8b97a5">· 每一个都已校验真实有号</span></div>';
      html += D.triageOptions.map(function (o) {
        if (o.remain === 0) {
          return '<div class="m-item dim"><div class="top"><span class="tt">' + esc(o.dept) + '</span><span class="m-tag gray">已约满</span></div>' +
            '<div class="mt">' + esc(o.doctor) + ' · ' + esc(o.title) + '</div>' +
            '<div class="mt">' + o.date + ' ' + periodText(o.period) + '</div></div>';
        }
        return '<div class="m-item"><div class="top"><span class="tt">' + esc(o.dept) + '</span><span class="m-tag">剩 ' + o.remain + ' 号</span></div>' +
          '<div class="mt">' + esc(o.doctor) + ' · ' + esc(o.title) + '</div>' +
          '<div class="mt">' + o.date + ' ' + periodText(o.period) + '</div>' +
          '<div class="bt" style="margin-top:2px"><span class="mt">' + esc(o.kind || '推荐') + ' · 共 ' + o.total + ' 个号源</span>' +
          '<button class="m-btn sm" onclick="App.triageBook(' + o.scheduleId + ')">去挂号</button></div></div>';
      }).join('');
    } else if (t.result === 'empty') {
      html += '<div class="banner warn">主诉信息不足，请补充症状、部位、持续时间等（reason_code: NO_COMPLAINT / NEED_CLARIFY）。</div>';
    }
    return html;
  }

  /* 红线①：危急征象强提醒弹层 —— options 必空、只引导急诊/人工、不复述命中关键词 */
  function renderRedflagDialog() {
    return '<div class="overlay in-phone"><div class="dialog">' +
      '<div class="ic">🚨</div><h5>危急征象提醒</h5>' +
      '<p>系统检测到您的症状可能存在危急情况，<b>请立即前往急诊或拨打 120</b>。<br>本系统不提供普通门诊推荐，如有疑问请联系人工服务。</p>' +
      '<div class="acts"><button class="m-btn" onclick="App.redflagAck()">我知道了</button></div>' +
      '</div></div>';
  }

  /* ==========================================================================
     P-3 智能预问诊（6 槽位；进度 filled/total_slots；「无」是有效阴性答案）
     ========================================================================== */
  function renderPrevisit() {
    var pv = state.previsit;
    var total = D.previsitSlots.length;
    var filled = Math.min(pv.step, total);

    var html = '<div class="m-card"><div style="display:flex;justify-content:space-between;font-size:11.5px;color:#55616f;margin-bottom:7px">' +
      '<span>采集进度</span><span><b>' + filled + ' / ' + total + '</b> 项</span></div>' +
      '<div class="progress"><i style="width:' + Math.round(filled / total * 100) + '%"></i></div>' +
      '<div class="slotdots" style="margin-top:8px">' +
      D.previsitSlots.map(function (s, i) { return '<span class="sd' + (i < filled ? ' done' : '') + '"></span>'; }).join('') +
      '</div></div>';

    if (pv.step === 0 && !pv.done) {
      html += '<div class="bubble ai">您好，我是预问诊助手。为了帮医生更快了解情况，我会问您几个问题，一共 ' + total + ' 项。</div>';
    }
    for (var i = 0; i < filled && i < total; i++) {
      html += '<div class="bubble ai">' + esc(D.previsitSlots[i].q) + '</div>';
      if (pv.answers[i] != null) html += '<div class="bubble me">' + esc(pv.answers[i]) + '</div>';
    }

    if (pv.done) {
      html += '<div class="bubble ai">采集完成，已生成预问诊单，就诊时可预填医生端病历（use_intake_session，仅首次）。</div>' +
        '<div class="m-card"><div class="m-sec" style="margin-bottom:6px">预问诊摘要</div>' +
        D.previsitSlots.map(function (s, i) {
          return '<div style="font-size:12px;padding:4px 0;border-bottom:1px dashed var(--line-2)"><span style="color:#8b97a5">' + esc(s.key) + '：</span>' + esc(pv.answers[i] || '（跳过）') + '</div>';
        }).join('') + '</div>' +
        '<button class="m-btn" onclick="App.previsitFinish()">完成</button>';
      return html;
    }

    if (filled < total) {
      html += '<div class="bubble ai">' + esc(D.previsitSlots[filled].q) + '<span class="cursor">▍</span></div>' +
        '<div style="flex:1"></div>' +
        '<div class="form-row"><input class="m-input" id="previsit-input" placeholder="请输入…（空串 = 跳过，不提交）" ' +
        'onkeydown="if(event.key===\'Enter\')App.previsitSend()">' +
        '<button class="m-btn sm" style="align-self:center" onclick="App.previsitSend()">发送</button></div>' +
        '<div class="m-row" style="margin-top:8px">' +
        '<button class="m-tag gray" onclick="App.previsitQuick(\'无\')">「无」</button>' +
        '<button class="m-tag gray" onclick="App.previsitQuick(\'（跳过此项）\')">跳过此项</button></div>';
    }
    return html;
  }

  /* ==========================================================================
     P-4 预约挂号（筛选栏 + 号源列表；确认弹窗带 client_token 幂等说明）
     ========================================================================== */
  function bookingDates() {
    var set = {};
    D.schedules.forEach(function (s) { set[s.date] = 1; });
    return Object.keys(set).sort();
  }

  function renderBooking() {
    var b = state.booking;
    var dates = bookingDates();
    var deptOpts = '<option value="">科室：全部</option>' + D.departments.filter(function (d) { return d.enabled; }).map(function (d) {
      return '<option value="' + d.id + '"' + (b.deptId === d.id ? ' selected' : '') + '>科室：' + esc(d.name) + '</option>';
    }).join('');
    var dateOpts = dates.map(function (dt, i) {
      var val = b.date || dates[0];
      return '<option value="' + dt + '"' + (val === dt ? ' selected' : '') + '>' + dt.slice(5) + '</option>';
    }).join('');

    var html = '<div class="form-row">' +
      '<select class="m-input" style="flex:1.3" onchange="App.bookFilterDept(this.value)">' + deptOpts + '</select>' +
      '<select class="m-input" style="flex:1" onchange="App.bookFilterDate(this.value)">' + dateOpts + '</select></div>' +
      '<div class="m-sec">可约号源</div>';

    var curDate = b.date || dates[0];
    var list = D.schedules.filter(function (s) {
      return s.date === curDate && (!b.deptId || s.deptId === b.deptId);
    });

    if (!list.length) {
      html += '<div class="empty-state">当前筛选条件下暂无号源</div>';
    } else {
      html += list.map(function (s) {
        if (s.remain === 0) {
          return '<div class="m-item dim"><div class="top"><span class="tt">' + esc(s.doctor) + ' · ' + esc(s.title) + '</span><span class="m-tag gray">已约满</span></div>' +
            '<div class="mt">' + s.date + ' ' + periodText(s.period) + '</div></div>';
        }
        return '<div class="m-item"><div class="top"><span class="tt">' + esc(s.doctor) + ' · ' + esc(s.title) + '</span><span class="m-tag">剩 ' + s.remain + ' 号</span></div>' +
          '<div class="mt">' + esc(s.dept) + ' · ' + s.date + ' ' + periodText(s.period) + ' · 共 ' + s.total + ' 号</div>' +
          '<div class="bt" style="margin-top:2px"><span class="mt">序号 ' + s.seq + '</span>' +
          '<button class="m-btn sm" onclick="App.bookOpen(' + s.id + ')">预约</button></div></div>';
      }).join('');
      // 走查稿缺口演示：号源列表只回 id、无医生/科室名时的兜底行
      html += '<div class="m-item dim"><div class="top"><span class="tt">科室 #3 / 医生 #9</span><span class="m-tag gray">无名称</span></div>' +
        '<div class="mt">⚠ 号源列表只回 id，无医生/科室名 —— 建议从分诊结果进入 ' + PV('缺口演示') + '</div></div>';
    }
    return html;
  }

  function renderBookDialog() {
    var s = D.schedules.find(function (x) { return x.id === state.booking.scheduleId; });
    if (!s) return '';
    return '<div class="overlay in-phone"><div class="dialog">' +
      '<div class="ic">📅</div><h5>确认挂号</h5>' +
      '<p>' + esc(s.dept) + ' · ' + esc(s.doctor) + '<br>' + s.date + ' ' + periodText(s.period) + ' · 序号 ' + s.seq + '</p>' +
      '<p style="margin-top:6px;font-size:11px;color:#8b97a5">client_token 已生成（本次意图唯一）<br><span class="mono" style="font-size:10.5px">' + esc(state.booking.clientToken) + '</span></p>' +
      '<div class="acts"><button class="m-btn gray" onclick="App.bookCancel()">取消</button>' +
      '<button class="m-btn" onclick="App.bookConfirm()">确认挂号</button></div></div></div>';
  }

  /* ==========================================================================
     P-5 我的预约（seg 筛选；退号成功与否看 data.status === 'cancelled'）
     ========================================================================== */
  function renderAppointments() {
    var inc = state.patient.apptIncludeCancelled;
    var list = D.appointments.filter(function (a) { return inc || (a.status !== 'cancelled' && a.status !== 'no_show'); });
    var html = '<div class="seg">' +
      '<button class="s' + (!inc ? ' on' : '') + '" onclick="App.apptSeg(false)">进行中</button>' +
      '<button class="s' + (inc ? ' on' : '') + '" onclick="App.apptSeg(true)">含已取消</button></div>';
    if (!list.length) return html + '<div class="empty-state">暂无预约，可先完成智能分诊再约号</div>';
    return html + list.map(function (a) {
      var right = a.status === 'booked'
        ? '<button class="m-btn sm ghost" onclick="App.cancelAppt(' + a.id + ')">退号</button>'
        : a.status === 'done' ? '<button class="m-btn sm gray" disabled>已就诊</button>' : '';
      return '<div class="m-item"><div class="top"><span class="tt">' + esc(a.dept) + ' · ' + esc(a.doctor) + '</span>' + apptTag(a.status) + '</div>' +
        '<div class="mt">' + a.date + ' ' + periodText(a.period) + ' · 序号 ' + a.seq + '</div>' +
        '<div class="bt" style="margin-top:2px"><span class="mt mono" style="font-size:11px">status: ' + a.status + '</span>' + right + '</div></div>';
    }).join('');
  }

  /* ==========================================================================
     P-6 我的 / P-7/8 就诊记录 / P-9 设备会话
     ========================================================================== */
  function renderProfile() {
    var s = D.session.patient;
    return '<div class="m-card" style="display:flex;gap:12px;align-items:center">' +
      '<div class="avatar">' + esc(s.displayName[0]) + '</div>' +
      '<div><div style="font-weight:800;font-size:15px">' + esc(s.displayName) + '</div>' +
      '<div style="font-size:11.5px;color:#7b8694">' + esc(s.phoneMasked) + ' · <span class="m-tag" style="font-size:10px">' + s.role + '</span></div></div></div>' +
      '<button class="entry" onclick="App.pTab(\'appointments\')"><span class="l"><span>📋</span>我的预约</span><span class="chev">›</span></button>' +
      '<button class="entry" onclick="App.pGo(\'records\')"><span class="l"><span>📄</span>就诊记录</span><span class="chev">›</span></button>' +
      '<button class="entry" onclick="App.pGo(\'sessions\')"><span class="l"><span>💻</span>设备管理</span><span class="chev">›</span></button>' +
      '<button class="entry" onclick="toast(\'智慧医院患者端 · 预览版 ' + '【预览专用】\')"><span class="l"><span>ℹ️</span>关于</span><span class="chev">›</span></button>' +
      '<div style="flex:1"></div>' +
      '<button class="m-btn ghost" onclick="App.pLogout()">退出登录</button>';
  }

  /* 列表不含正文，只有进度/时间；草稿未锁定一律 404 EMR_NOT_FOUND */
  function renderRecords() {
    var html = '<div class="m-sec">列表（不含正文，只有进度/时间）</div>';
    html += D.recordList.map(function (r) {
      var tag = r.locked ? '<span class="m-tag ok">已锁定</span>' : '<span class="m-tag gray">草稿</span>';
      var sub = r.locked ? '已填 ' + r.filled + '/' + r.total + ' 段 · ' + r.updated + ' 更新' : '已填 ' + r.filled + '/' + r.total + ' 段 · 尚未提交';
      return '<button class="m-item" style="text-align:left;width:100%" onclick="App.recordOpen(' + r.appointmentId + ',' + r.locked + ')">' +
        '<div class="top"><span class="tt">' + r.date + ' · ' + esc(r.dept) + '</span>' + tag + '</div>' +
        '<div class="mt">' + sub + '</div></button>';
    }).join('');
    return html;
  }

  function renderRecordDetail(appointmentId) {
    var r = D.recordDetail;
    var html = '<div class="m-sec">详情（七段正文） · ' + esc(r.date) + ' ' + esc(r.dept) + ' <span class="m-tag ok">已锁定</span></div>';
    return html + r.sections.map(function (s) {
      return '<div class="m-item"><div class="mt" style="font-weight:700;color:#16202e">' + esc(s[1]) +
        (s[3] ? ' <span class="m-tag danger" style="font-size:9.5px">必填</span>' : '') + '</div>' +
        '<div class="mt" style="color:#2c3846;line-height:1.6">' + esc(s[2]) + '</div></div>';
    }).join('');
  }

  function renderSessions() {
    var html = D.sessions.map(function (s, i) {
      var title = esc(s.name) + (s.self ? ' <span class="m-tag" style="font-size:10px">本机</span>' : '');
      var sub = s.deviceId ? ('最近活跃 ' + esc(s.lastActive) + ' · ' + esc(s.expires) + ' 到期') : 'device_id 为空，无法按设备踢';
      return '<div class="m-item"><div class="top"><span class="tt">' + title + '</span>' +
        '<button class="m-btn sm ghost" onclick="App.kickSession(' + i + ')">踢出</button></div>' +
        '<div class="mt">' + sub + '</div></div>';
    }).join('');
    return html + '<div style="flex:1"></div><button class="m-btn ghost" onclick="App.logoutAll()">退出全部设备</button>';
  }

  /* ==========================================================================
     医生端（D-1 接诊队列 / D-2 电子病历）
     ========================================================================== */
  function renderDoctorPhone() {
    var d = state.doctor;
    if (!d.loggedIn) {
      return phone('登录', null,
        '<div class="login-wrap"><div class="login-logo"><div class="avatar">医</div>' +
        '<div class="nm">智慧医院 · 医生端</div><div class="sb">接诊与电子病历 ' + PV('Mock 登录') + '</div></div>' +
        '<div class="field" id="f-did"><div class="m-label">工号（登录名）</div>' +
        '<input class="m-input" id="doc-id" value="D1001">' +
        '<div class="err">请输入工号（字母+数字，至少 4 位）</div></div>' +
        '<div class="field" id="f-dpwd"><div class="m-label">密码</div>' +
        '<input class="m-input" id="doc-pwd" type="password" value="123456">' +
        '<div class="err">密码至少 6 位</div></div>' +
        '<button class="m-btn" onclick="App.dLogin()">登 录</button></div>', null, null);
    }
    if (d.page === 'record') return phone('电子病历 · 序号 ' + D.editingRecord.seq, 'dBack', renderEmr(), null, null);
    return phone('接诊队列（' + D.session.doctor.displayName + '）', null, renderQueue(), null, null);
  }

  function renderQueue() {
    var f = state.doctor.periodFilter;
    var list = D.doctorVisits.filter(function (v) { return f === 'ALL' || v.period === f; });
    var html = '<div class="seg">' +
      '<button class="s' + (f === 'ALL' ? ' on' : '') + '" onclick="App.dSeg(\'ALL\')">今日</button>' +
      '<button class="s' + (f === 'AM' ? ' on' : '') + '" onclick="App.dSeg(\'AM\')">上午</button>' +
      '<button class="s' + (f === 'PM' ? ' on' : '') + '" onclick="App.dSeg(\'PM\')">下午</button></div>';
    if (!list.length) return html + '<div class="empty-state">该时段暂无就诊安排</div>';
    return html + list.map(function (v) {
      var recText = v.recordStatus === 'locked' ? '已填 ' + v.recordFilled + '/7 · 已锁定'
        : v.recordStatus === 'draft' ? '已填 ' + v.recordFilled + '/7 · 草稿' : '无病历（record_status: none）';
      var btn;
      if (v.status === 'booked') btn = '<span><button class="m-btn sm gray" onclick="App.dNoShow(' + v.id + ')">爽约</button> <button class="m-btn sm" onclick="App.dStart(' + v.id + ')">开始接诊</button></span>';
      else if (v.status === 'visiting') btn = '<span><button class="m-btn sm ghost" onclick="App.dOpenRecord(' + v.id + ')">写病历</button> <button class="m-btn sm ghost" onclick="App.dFinish(' + v.id + ')">完成就诊</button></span>';
      else btn = '';
      return '<div class="m-item"' + (v.status === 'done' ? ' style="opacity:.6"' : '') + '>' +
        '<div class="top"><span class="tt">序号 ' + v.seq + ' · 患者 ' + esc(v.patientRef) + '</span>' + apptTag(v.status) + '</div>' +
        '<div class="mt">病历进度：' + recText + '</div>' +
        '<div class="bt" style="margin-top:2px"><span class="mt">' + v.date + ' ' + v.period + '</span>' + btn + '</div></div>';
    }).join('');
  }

  /* D-2 七段式病历：每段带字符上限与计数；required_to_lock 仅诊断/处理意见 */
  function renderEmr() {
    var r = D.editingRecord;
    var html = '';
    if (!r.locked) html += '<div class="banner info">可由预问诊单预填（use_intake_session，仅首次）<button class="m-tag" style="margin-left:8px;border:none" onclick="App.emrPrefill()">一键预填 ' + PV('模拟') + '</button></div>';
    html += D.emrSections.map(function (s) {
      var val = r.values[s.key] || '';
      return '<div class="field" id="f-emr-' + s.key + '">' +
        '<div class="m-label">' + esc(s.label) +
        (s.required ? ' <span class="m-tag danger" style="font-size:9.5px">必填锁定</span>' : '') +
        '<span style="float:right;color:#b0b8c4" id="cnt-' + s.key + '">' + val.length + '/' + s.limit + '</span></div>' +
        '<textarea class="m-input area" id="emr-' + s.key + '" maxlength="' + s.limit + '"' + (r.locked ? ' disabled' : '') +
        ' oninput="document.getElementById(\'cnt-' + s.key + '\').textContent=this.value.length+\'/' + s.limit + '\'"' +
        ' placeholder="请输入' + esc(s.label) + '">' + esc(val) + '</textarea>' +
        '<div class="err">「' + esc(s.label) + '」为锁定必填段（missing_required 非空不可锁定）</div></div>';
    }).join('');
    html += '<div style="flex:1"></div>';
    if (r.locked) {
      html += '<div class="banner warn">已提交锁定（409 EMR_LOCKED），仅管理员可 reopen；医生也 403。</div>' +
        '<button class="m-btn" onclick="App.dFinish(' + r.visitId + ')">完成就诊</button>';
    } else {
      html += '<div class="m-row"><button class="m-btn ghost" style="flex:1" onclick="App.emrSave()">保存草稿</button>' +
        '<button class="m-btn" style="flex:1" onclick="App.emrLock()">提交锁定</button></div>' +
        '<div class="banner warn">锁定后不可修改（409 EMR_LOCKED），仅管理员可 reopen</div>';
    }
    return html;
  }

  /* ==========================================================================
     管理端（browser 框 + 深色侧栏；硬红线：只出聚合、绝不出明细）
     ========================================================================== */
  var A_NAV = [
    ['dashboard', '运营看板'], ['departments', '科室管理'], ['doctors', '医生管理'],
    ['schedules', '排班/号源'], ['users', '账号管理'], ['ai', 'AI 能力中心'], ['kb', '知识库']
  ];
  function renderAdmin() {
    var p = state.admin.page;
    var nav = A_NAV.map(function (n) {
      return '<button class="' + (p === n[0] ? 'on' : '') + '" onclick="App.aGo(\'' + n[0] + '\')">' + n[1] + '</button>';
    }).join('');
    var url = 'https://admin.smart-hospital.local/' + (p === 'dashboard' ? 'dashboard' : p);
    var content;
    switch (p) {
      case 'departments': content = renderAdminDepts(); break;
      case 'ai': content = renderAdminAI(); break;
      case 'kb': content = renderAdminKB(); break;
      case 'doctors': case 'schedules': case 'users':
        content = '<div class="ptitle">' + A_NAV.find(function (n) { return n[0] === p; })[1] + '</div>' +
          '<div class="panel"><div class="ph">与「科室管理」同一「列表 + 表单 + 确认」范式</div>' +
          '<p style="font-size:12.5px;color:var(--ink-2)">A-3 医生管理 / A-4 排班号源 / A-5 账号管理在走查稿中按 A-2 同族范式实现，本预览从略 ' + PV('范式从略') + '</p></div>';
        break;
      default: content = renderAdminDash();
    }
    return '<div class="browser"><div class="bar"><i></i><i></i><i></i><span class="url">' + url + '</span>' + PV('预览·浏览器框') + '</div>' +
      '<div class="adm"><div class="side"><div class="bd">智慧医院 · 管理端</div>' + nav + '</div>' +
      '<div class="content">' + content + '</div></div></div>';
  }

  function renderAdminDash() {
    var db = D.dashboard;
    return '<div class="ptitle">运营看板</div>' +
      '<div class="statgrid">' + db.stats.map(function (s) {
        return '<div class="statcard"><div class="v">' + esc(s.v) + '</div><div class="l">' + esc(s.l) + '</div></div>';
      }).join('') + '</div>' +
      '<div class="panel"><div class="ph">近 7 日挂号趋势</div><div class="barchart">' +
      db.week.map(function (w) {
        return '<div class="b" style="height:' + w.pct + '%"><span>' + w.label + '</span></div>';
      }).join('') + '</div><div style="height:18px"></div></div>' +
      '<div class="banner info">响应不含任何 patient_id / doctor_id / phone / name —— 只出聚合计数</div>';
  }

  function renderAdminDepts() {
    var edit = state.admin.editDeptId != null ? D.departments.find(function (d) { return d.id === state.admin.editDeptId; }) : null;
    var html = '<div class="ptitle">科室管理</div>' +
      '<div class="panel"><div class="ph">' + (edit ? '编辑科室 #' + edit.id : '新增科室') + '</div>' +
      '<div style="display:flex;gap:9px;flex-wrap:wrap">' +
      '<input class="m-input" id="dept-name" style="flex:1;min-width:120px" placeholder="名称（唯一）" value="' + esc(edit ? edit.name : '') + '">' +
      '<input class="m-input" id="dept-code" style="flex:1;min-width:120px" placeholder="编码（唯一）" value="' + esc(edit ? edit.code : '') + '">' +
      '<input class="m-input" id="dept-loc" style="flex:1;min-width:120px" placeholder="位置" value="' + esc(edit ? edit.location : '') + '">' +
      '<button class="abtn" style="align-self:center" onclick="App.deptSave()">' + (edit ? '保存' : '新增科室') + '</button>' +
      (edit ? '<button class="abtn ghost" style="align-self:center" onclick="App.deptEdit(null)">取消</button>' : '') +
      '</div><div class="err" id="dept-err" style="display:none;font-size:11.5px;color:var(--danger);margin-top:8px"></div></div>' +
      '<table class="atable"><tr><th>ID</th><th>名称</th><th>编码</th><th>位置</th><th>状态</th><th>操作</th></tr>' +
      D.departments.map(function (d) {
        return '<tr><td>' + d.id + '</td><td>' + esc(d.name) + '</td><td class="mono">' + esc(d.code) + '</td><td>' + esc(d.location) + '</td>' +
          '<td>' + (d.enabled ? '<span class="pill o">启用</span>' : '<span class="pill n">停用</span>') + '</td>' +
          '<td><button class="abtn ghost" onclick="App.deptEdit(' + d.id + ')">编辑</button> ' +
          '<button class="abtn danger" onclick="App.deptDel(' + d.id + ')">删除</button></td></tr>';
      }).join('') + '</table>' +
      '<div class="banner err" id="dept-inuse" style="margin-top:12px;display:none">该记录正被引用，不能删除（409 BASE_IN_USE）</div>';
    return html;
  }

  function renderAdminAI() {
    var t = state.admin.aiTab;
    var html = '<div class="ptitle">AI 能力中心</div>' +
      '<div class="tabs">' +
      '<button class="t' + (t === 'settings' ? ' on' : '') + '" onclick="App.aiTab(\'settings\')">模型配置</button>' +
      '<button class="t' + (t === 'prompts' ? ' on' : '') + '" onclick="App.aiTab(\'prompts\')">Prompt 模板</button>' +
      '<button class="t' + (t === 'tools' ? ' on' : '') + '" onclick="App.aiTab(\'tools\')">工具开关</button></div>';
    if (t === 'settings') {
      html += '<table class="atable"><tr><th>配置键</th><th>值</th><th>操作</th></tr>' +
        D.aiSettings.map(function (s, i) {
          return '<tr><td class="mono">' + esc(s.key) + '</td><td>' +
            (s.secret ? '<span class="pill i">' + esc(s.value) + '</span>' : '<span class="mono">' + esc(s.value) + '</span>') +
            '</td><td><button class="abtn ghost" onclick="App.aiEdit(' + i + ')">编辑</button></td></tr>';
        }).join('') + '</table>' +
        '<div class="banner info" style="margin-top:12px">改配置零重启：写库 → 失效缓存；密钥<b>只存引用</b>（env: / file:），裸密钥被机制性拒绝，回显一律脱敏</div>';
    } else if (t === 'prompts') {
      html += '<table class="atable"><tr><th>模板键</th><th>占位符校验</th><th>状态</th></tr>' +
        D.aiPrompts.map(function (s) {
          return '<tr><td class="mono">' + esc(s.key) + '</td><td class="mono">' + esc(s.value) + '</td>' +
            '<td>' + (s.ok ? '<span class="pill o">有效</span>' : '<span class="pill n">缺占位符即拒</span>') + '</td></tr>';
        }).join('') + '</table>';
    } else {
      html += '<table class="atable"><tr><th>工具</th><th>开关（enabled 只接受 JSON 布尔）</th></tr>' +
        D.aiTools.map(function (s, i) {
          return '<tr><td class="mono">' + esc(s.key) + '</td><td>' +
            '<button class="abtn ' + (s.enabled ? '' : 'ghost') + '" onclick="App.aiToolToggle(' + i + ')">' + (s.enabled ? '已开启' : '已关闭') + '</button></td></tr>';
        }).join('') + '</table>';
    }
    return html;
  }

  function renderAdminKB() {
    return '<div class="ptitle">知识库管理</div>' +
      '<div class="panel"><div style="display:flex;gap:9px;flex-wrap:wrap">' +
      '<input class="m-input" id="kb-q" style="flex:1;min-width:160px" placeholder="输入关键词过滤文档（关键词检索为默认路）" oninput="App.kbFilter(this.value)">' +
      '<button class="abtn ghost" style="align-self:center" onclick="toast(\'上传入口预览从略 ' + '【预览专用】\')">上传文档 ' + '</button></div></div>' +
      '<table class="atable"><thead><tr><th>ID</th><th>文档</th><th>切块数</th><th>更新时间</th></tr></thead><tbody id="kb-tbody">' +
      kbRows(D.kbDocs) + '</tbody></table>';
  }
  function kbRows(docs) {
    if (!docs.length) return '<tr><td colspan="4" style="text-align:center;color:var(--ink-3)">无匹配文档</td></tr>';
    return docs.map(function (d) {
      return '<tr><td>' + d.id + '</td><td>' + esc(d.title) + '</td><td>' + d.chunks + '</td><td>' + d.updated + '</td></tr>';
    }).join('');
  }

  /* ==========================================================================
     动作层
     ========================================================================== */
  var App = {

    /* ---- 角色切换（【预览专用】实际软件中三端是独立入口） ---- */
    setRole: function (r) {
      state.role = r;
      document.querySelectorAll('.role-switch button').forEach(function (b) {
        b.classList.toggle('active', b.getAttribute('data-role') === r);
      });
      render();
    },

    /* ---- P-1 登录 ---- */
    pLogin: function () {
      var name = $('#login-name').value.trim();
      var pwd = $('#login-pwd').value;
      var okName = /^1\d{10}$/.test(name);
      var okPwd = pwd.length >= 6;
      $('#f-lname').classList.toggle('invalid', !okName);
      $('#f-lpwd').classList.toggle('invalid', !okPwd);
      if (!okName || !okPwd) return;
      state.patient.loggedIn = true;
      toast('登录成功（令牌已持久化：token/expires_at/role/ref_id，绝不存口令）');
      render();
    },
    pLogout: function () {
      state.patient.loggedIn = false;
      state.patient.page = null;
      toast('已登出（POST /auth/logout，吊销当前令牌）');
      render();
    },
    pTab: function (t) { state.patient.tab = t; state.patient.page = null; render(); },
    pGo: function (page, arg) { state.patient.page = page; state.patient.pageArg = arg || null; render(); },
    pBack: function () { state.patient.page = null; render(); },

    /* ---- P-2 分诊 ---- */
    triageSubmit: function () {
      var v = $('#triage-input').value.trim();
      if (v.length < 4) {
        $('#f-complaint').classList.add('invalid');
        state.triage.complaint = v; state.triage.result = 'empty';
        render(); return;
      }
      $('#f-complaint').classList.remove('invalid');
      state.triage.complaint = v;
      state.triage.loading = true; state.triage.result = null;
      render();
      // 【预览专用】模拟一次性 JSON 延迟；实际 POST /api/v1/triage
      setTimeout(function () {
        var redFlags = ['胸痛', '昏迷', '大出血', '呼吸困难', '意识不清', '抽搐'];
        var hit = redFlags.some(function (w) { return v.indexOf(w) >= 0; });
        state.triage.loading = false;
        // 红线①：red_flag 时 options 必空，且不复述命中关键词
        state.triage.result = hit ? 'redflag' : 'ok';
        render();
      }, 700);
    },
    redflagAck: function () { state.triage.result = null; render(); },
    triageBook: function (scheduleId) {
      var s = D.schedules.find(function (x) { return x.id === scheduleId; });
      state.booking = { deptId: s ? s.deptId : null, date: s ? s.date : null, clientToken: null, scheduleId: null };
      App.pTab('booking');
    },

    /* ---- P-3 预问诊 ---- */
    previsitSend: function () {
      var input = $('#previsit-input');
      var v = input.value.trim();
      // 空串 = 跳过，不提交（不落库、不推进 turn）
      if (!v) { toast('空串视为跳过，不提交'); return; }
      state.previsit.answers[state.previsit.step] = v;
      state.previsit.step++;
      if (state.previsit.step >= D.previsitSlots.length) state.previsit.done = true;
      render();
    },
    previsitQuick: function (text) {
      // 「无」是有效阴性答案，与「没答」语义不同
      if (text === '（跳过此项）') {
        state.previsit.answers[state.previsit.step] = null;
      } else {
        state.previsit.answers[state.previsit.step] = text;
      }
      state.previsit.step++;
      if (state.previsit.step >= D.previsitSlots.length) state.previsit.done = true;
      render();
    },
    previsitFinish: function () {
      state.previsit = { step: 0, answers: [], done: false };
      App.pTab('booking');
      toast('预问诊单已生成，可直接去约号');
    },

    /* ---- P-4 挂号（红线②：client_token 一次意图一个、换号源换新） ---- */
    bookFilterDept: function (val) { state.booking.deptId = val ? Number(val) : null; render(); },
    bookFilterDate: function (val) { state.booking.date = val; render(); },
    bookOpen: function (scheduleId) {
      // 换号源必须换新 token（复用只会回放原单）
      state.booking.scheduleId = scheduleId;
      state.booking.clientToken = newToken();
      render();
    },
    bookCancel: function () { state.booking.scheduleId = null; render(); },
    bookConfirm: function () {
      var s = D.schedules.find(function (x) { return x.id === state.booking.scheduleId; });
      if (!s) return;
      if (s.remain === 0) {
        // 409 SLOT_GONE → 刷新列表，不要自己重试
        state.booking.scheduleId = null;
        render(); toast('409 SLOT_GONE：号源已被抢完，列表已刷新');
        return;
      }
      s.remain--;
      D.appointments.unshift({
        id: 9000 + Math.floor(Math.random() * 900), dept: s.dept, doctor: s.doctor,
        date: s.date, period: s.period, seq: s.seq, status: 'booked'
      });
      state.booking.scheduleId = null;
      state.booking.clientToken = null; // 首次成功 201；意图终结
      App.pTab('appointments');
      toast('挂号成功（201 Created；在线直连，不进离线队列）');
    },

    /* ---- P-5 退号（红线③：成功与否看 data.status === 'cancelled'） ---- */
    apptSeg: function (inc) { state.patient.apptIncludeCancelled = inc; render(); },
    cancelAppt: function (id) {
      var a = D.appointments.find(function (x) { return x.id === id; });
      if (!a) return;
      // 【预览专用】模拟服务端返回 200 + data.status
      a.status = 'cancelled';
      if (a.status === 'cancelled') {
        render(); toast('已退号，号源已释放（重复退同一单仍 200，幂等）');
      } else {
        render(); toast('退号未生效，请重试');
      }
    },

    /* ---- P-7/8 就诊记录 ---- */
    recordOpen: function (appointmentId, locked) {
      if (!locked) {
        // 草稿未锁定一律 404 EMR_NOT_FOUND ——「尚未提交」与「不存在」不可区分
        toast('病历尚未提交，暂不可查看（404 EMR_NOT_FOUND）');
        return;
      }
      App.pGo('recordDetail', appointmentId);
    },

    /* ---- P-9 设备会话 ---- */
    kickSession: function (i) {
      var s = D.sessions[i];
      if (!s.deviceId) { toast('device_id 为空，无法按设备踢（400）'); return; }
      if (s.self) { toast('本机会话请走「退出登录」'); return; }
      D.sessions.splice(i, 1);
      render(); toast('已踢出该设备会话（POST /auth/sessions/revoke）');
    },
    logoutAll: function () {
      D.sessions = D.sessions.filter(function (s) { return s.self; });
      render(); toast('已吊销本人全部令牌（logout-all，含本机）');
    },

    /* ---- D-1 接诊队列 ---- */
    dLogin: function () {
      var id = $('#doc-id').value.trim();
      var pwd = $('#doc-pwd').value;
      var okId = /^[A-Za-z0-9]{4,}$/.test(id);
      var okPwd = pwd.length >= 6;
      $('#f-did').classList.toggle('invalid', !okId);
      $('#f-dpwd').classList.toggle('invalid', !okPwd);
      if (!okId || !okPwd) return;
      state.doctor.loggedIn = true;
      toast('登录成功（doctor_id 只从令牌派生，前端不可传）');
      render();
    },
    dSeg: function (f) { state.doctor.periodFilter = f; render(); },
    dBack: function () { state.doctor.page = 'queue'; render(); },
    dStart: function (id) {
      var v = D.doctorVisits.find(function (x) { return x.id === id; });
      if (!v) return;
      v.status = 'visiting';
      if (v.recordStatus === 'none') { v.recordStatus = 'draft'; v.recordFilled = 0; }
      render(); toast('已开始接诊（booked → visiting）');
    },
    dNoShow: function (id) {
      var v = D.doctorVisits.find(function (x) { return x.id === id; });
      if (v) { v.status = 'no_show'; render(); toast('已标记爽约（no_show）'); }
    },
    dOpenRecord: function (id) {
      var v = D.doctorVisits.find(function (x) { return x.id === id; });
      D.editingRecord.visitId = id;
      D.editingRecord.seq = v ? v.seq : 0;
      D.editingRecord.locked = v ? v.recordStatus === 'locked' : false;
      state.doctor.page = 'record';
      render();
    },
    dFinish: function (id) {
      var v = D.doctorVisits.find(function (x) { return x.id === id; });
      // 核心不变式：完成就诊前必须已提交锁定病历
      if (!v || v.recordStatus !== 'locked') {
        toast('409 EMR_NOT_LOCKED：完成就诊前必须已提交锁定病历');
        return;
      }
      v.status = 'done';
      state.doctor.page = 'queue';
      render(); toast('就诊已完成（visiting → done）');
    },

    /* ---- D-2 电子病历 ---- */
    emrCollect: function () {
      D.emrSections.forEach(function (s) {
        var el = $('#emr-' + s.key);
        if (el) D.editingRecord.values[s.key] = el.value.trim();
      });
    },
    emrPrefill: function () {
      // 【预览专用】模拟 use_intake_session 预填（仅首次）
      var r = D.editingRecord;
      if (r.values.chief) { toast('预填仅首次有效'); return; }
      r.values.chief = '咳嗽三天，有黄痰';
      r.values.hpi = '三天前受凉后出现咳嗽，夜间加重。';
      r.values.allergy = '无';
      render(); toast('已用预问诊单预填（use_intake_session）');
    },
    emrSave: function () {
      App.emrCollect();
      var v = D.doctorVisits.find(function (x) { return x.id === D.editingRecord.visitId; });
      var filled = D.emrSections.filter(function (s) { return (D.editingRecord.values[s.key] || '').length > 0; }).length;
      if (v) { v.recordStatus = 'draft'; v.recordFilled = filled; }
      toast('草稿已保存（PUT …/record，已填 ' + filled + '/7 段）');
      render();
    },
    emrLock: function () {
      App.emrCollect();
      var missing = [];
      D.emrSections.forEach(function (s) {
        var bad = s.required && !(D.editingRecord.values[s.key] || '').length;
        $('#f-emr-' + s.key).classList.toggle('invalid', bad);
        if (bad) missing.push(s.label);
      });
      // required_to_lock 仅 diagnosis / treatment；missing_required 非空 → 不可锁定
      if (missing.length) { toast('missing_required：' + missing.join('、') + ' 未填，不可锁定'); return; }
      var v = D.doctorVisits.find(function (x) { return x.id === D.editingRecord.visitId; });
      D.editingRecord.locked = true;
      if (v) { v.recordStatus = 'locked'; v.recordFilled = 7; }
      render(); toast('病历已提交锁定（POST …/record/lock）');
    },

    /* ---- 管理端 ---- */
    aGo: function (p) { state.admin.page = p; render(); },
    deptEdit: function (id) { state.admin.editDeptId = id; render(); },
    deptSave: function () {
      var name = $('#dept-name').value.trim();
      var code = $('#dept-code').value.trim();
      var loc = $('#dept-loc').value.trim();
      var err = $('#dept-err');
      var dupName = D.departments.some(function (d) { return d.name === name && d.id !== state.admin.editDeptId; });
      var dupCode = D.departments.some(function (d) { return d.code === code && d.id !== state.admin.editDeptId; });
      if (!name || !code) { err.style.display = 'block'; err.textContent = '名称与编码均必填'; return; }
      if (dupName) { err.style.display = 'block'; err.textContent = '409 BASE_NAME_TAKEN：同名科室已存在'; return; }
      if (dupCode) { err.style.display = 'block'; err.textContent = '409 BASE_CODE_TAKEN：同编码科室已存在'; return; }
      err.style.display = 'none';
      if (state.admin.editDeptId != null) {
        var d = D.departments.find(function (x) { return x.id === state.admin.editDeptId; });
        d.name = name; d.code = code; d.location = loc;
        toast('科室已更新');
      } else {
        var nid = Math.max.apply(null, D.departments.map(function (d) { return d.id; })) + 1;
        D.departments.push({ id: nid, name: name, code: code, location: loc, enabled: true });
        toast('科室已新增（name/code 唯一性已校验）');
      }
      state.admin.editDeptId = null;
      render();
    },
    deptDel: function (id) {
      // 有引用不可删（409 BASE_IN_USE）：预览模拟——被号源/预约引用的科室拒绝删除
      var inUse = D.schedules.some(function (s) { return s.deptId === id; }) ||
                  D.appointments.some(function (a) { return a.dept === (D.departments.find(function (d) { return d.id === id; }) || {}).name; });
      if (inUse) {
        var el = $('#dept-inuse');
        if (el) { el.style.display = 'block'; setTimeout(function () { el.style.display = 'none'; }, 2600); }
        return;
      }
      D.departments = D.departments.filter(function (d) { return d.id !== id; });
      render(); toast('科室已删除');
    },
    aiTab: function (t) { state.admin.aiTab = t; render(); },
    aiEdit: function (i) {
      var s = D.aiSettings[i];
      var v = prompt('修改 ' + s.key + (s.secret ? '（密钥只接受 env: / file: 引用）' : ''), s.secret ? 'env:HOSPITAL_AI_KEY' : s.value);
      if (v == null) return;
      v = v.trim();
      if (s.secret) {
        if (!/^(env:|file:).+/.test(v)) { toast('裸密钥已被机制性拒绝：请使用 env: 或 file: 引用'); return; }
        s.value = '已设置（引用类型：' + (v.indexOf('env:') === 0 ? 'env' : 'file') + '）';
      } else {
        s.value = v;
      }
      render(); toast('配置已保存并即时生效（写库→失效缓存，零重启）');
    },
    aiToolToggle: function (i) {
      D.aiTools[i].enabled = !D.aiTools[i].enabled;
      render(); toast('工具开关已更新（enabled 只接受 JSON 布尔）');
    },
    kbFilter: function (q) {
      var docs = D.kbDocs.filter(function (d) { return d.title.indexOf(q.trim()) >= 0; });
      $('#kb-tbody').innerHTML = kbRows(docs);
    }
  };

  window.App = App;

  /* ---------------- 启动 ---------------- */
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.role-switch button').forEach(function (b) {
      b.addEventListener('click', function () { App.setRole(b.getAttribute('data-role')); });
    });
    render();
  });
})();
