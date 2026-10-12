/* ==========================================================================
   【预览专用】Mock 数据 —— 仅用于开发预览，实际软件中数据来自服务端 REST API。
   字段命名对齐 docs/FRONTEND-INTEGRATION.md 与 docs/frontend-preview.html（走查稿）：
   - 患者手机号一律脱敏回显（138****6021）
   - 号源含 remain_num/total_num/序号；医生端队列只见「序号 + 患者 #id」，不见姓名
   - 病历七段含字符上限，required_to_lock 仅 diagnosis / treatment
   ========================================================================== */

window.MOCK = {

  /* 当前登录身份（GET /api/v1/auth/me；判角色只看 role） */
  session: {
    patient: { role: 'patient', displayName: '张三', phoneMasked: '138****6021', refId: 7 },
    doctor:  { role: 'doctor',  displayName: '李医生', title: '副主任医师', refId: 3 },
    admin:   { role: 'admin',   displayName: '管理员' }
  },

  /* 科室（A-2 科室管理：name/code 均唯一） */
  departments: [
    { id: 3, name: '呼吸内科', code: 'RESP', location: '门诊楼 3F', enabled: true },
    { id: 4, name: '骨科',     code: 'ORTH', location: '门诊楼 2F', enabled: true },
    { id: 5, name: '皮肤科',   code: 'DERM', location: '门诊楼 4F', enabled: false },
    { id: 6, name: '消化内科', code: 'DIGE', location: '门诊楼 3F', enabled: true }
  ],

  /* 可约号源（GET /api/v1/schedules；remain_num=0 的行也会返回，客户端置灰「已约满」） */
  schedules: [
    { id: 501, deptId: 3, dept: '呼吸内科', doctor: '李医生', title: '副主任医师', date: '2026-11-20', period: 'AM', seq: 6,  total: 20, remain: 5 },
    { id: 502, deptId: 3, dept: '呼吸内科', doctor: '王医生', title: '主治医师',   date: '2026-11-20', period: 'PM', seq: null, total: 16, remain: 0 },
    { id: 503, deptId: 3, dept: '呼吸内科', doctor: '李医生', title: '副主任医师', date: '2026-11-21', period: 'AM', seq: 3,  total: 20, remain: 11 },
    { id: 504, deptId: 4, dept: '骨科',     doctor: '张医生', title: '主治医师',   date: '2026-11-20', period: 'AM', seq: 9,  total: 18, remain: 4 },
    { id: 505, deptId: 6, dept: '消化内科', doctor: '韩医生', title: '主治医师',   date: '2026-11-21', period: 'PM', seq: 2,  total: 18, remain: 8 }
  ],

  /* 分诊结论（POST /api/v1/triage 的 options[]；患者端唯一能拿到科室名/医生姓名的来源）
     【预览专用】实际由服务端验证层给出，保证 remain_num > 0 */
  triageOptions: [
    { scheduleId: 501, dept: '呼吸内科', doctor: '李医生', title: '副主任医师', date: '2026-11-20', period: 'AM', remain: 5, total: 1, kind: '备选' },
    { scheduleId: 502, dept: '呼吸内科', doctor: '王医生', title: '主治医师',   date: '2026-11-20', period: 'PM', remain: 0, kind: 'full' }
  ],

  /* 我的预约（GET /api/v1/appointments；按 created_at DESC，但响应不含 created_at） */
  appointments: [
    { id: 9001, dept: '呼吸内科', doctor: '李医生', date: '2026-11-20', period: 'AM', seq: 6, status: 'booked' },
    { id: 9002, dept: '骨科',     doctor: '张医生', date: '2026-11-12', period: 'AM', seq: 3, status: 'done' },
    { id: 9003, dept: '皮肤科',   doctor: '陈医生', date: '2026-11-05', period: 'PM', seq: 9, status: 'cancelled' }
  ],

  /* 就诊记录列表（GET /api/v1/medical-records —— 不含正文，只有进度/时间） */
  recordList: [
    { appointmentId: 9002, date: '2026-11-12', dept: '骨科',   filled: 7, total: 7, locked: true,  updated: '2026-11-12' },
    { appointmentId: 9004, date: '2026-11-05', dept: '皮肤科', filled: 2, total: 7, locked: false, updated: '2026-11-05' }
  ],

  /* 就诊记录详情（GET /api/v1/medical-records/:appointmentId；草稿未锁定一律 404 EMR_NOT_FOUND） */
  recordDetail: {
    appointmentId: 9002, date: '2026-11-12', dept: '骨科', locked: true,
    sections: [
      ['chief',     '主诉',     '咳嗽三天，有黄痰', false],
      ['hpi',       '现病史',   '三天前受凉后出现咳嗽，夜间加重，伴少量黄痰，无胸痛气促。', false],
      ['past',      '既往史',   '否认高血压、糖尿病史。', false],
      ['allergy',   '过敏史',   '否认药物食物过敏史。', false],
      ['exam',      '体格检查', '咽充血，双肺呼吸音粗，未闻及干湿啰音。', false],
      ['diagnosis', '诊断',     '急性支气管炎', true],
      ['treatment', '处理意见', '止咳化痰，三天后复诊；不适随诊。', true]
    ]
  },

  /* 设备会话（GET /api/v1/auth/sessions；绝不返回 token 明文） */
  sessions: [
    { deviceId: 'mate60-x1', name: 'Mate 60', self: true,  lastActive: '2 分钟前', expires: '2026-11-20' },
    { deviceId: '',          name: '未知设备', self: false, lastActive: '3 天前',   expires: '2026-11-18' }
  ],

  /* 预问诊 6 槽位（chief / duration / severity / associated / history / allergy）
     【预览专用】固定脚本模拟 SSE 流式；实际 GET /previsit/stream + POST /previsit/answer */
  previsitSlots: [
    { key: 'chief',      q: '请问您最主要的不舒服是什么？' },
    { key: 'duration',   q: '第 2/6 项：这种情况持续多长时间了？' },
    { key: 'severity',   q: '第 3/6 项：对日常生活影响大吗？' },
    { key: 'associated', q: '第 4/6 项：有没有其他伴随症状（如发热、乏力）？' },
    { key: 'history',    q: '第 5/6 项：有无慢性病史？' },
    { key: 'allergy',    q: '第 6/6 项：有无药物或食物过敏史？' }
  ],

  /* 医生端 · 接诊队列（GET /api/v1/doctor/visits；doctor_id 只从令牌派生，队列只见序号+患者#id）
     record_status: none / draft / locked */
  doctorVisits: [
    { id: 7001, seq: 6, patientRef: '#7',  date: '2026-11-20', period: 'AM', status: 'booked',   recordStatus: 'locked', recordFilled: 7 },
    { id: 7002, seq: 7, patientRef: '#12', date: '2026-11-20', period: 'AM', status: 'visiting', recordStatus: 'draft',  recordFilled: 3 },
    { id: 7003, seq: 8, patientRef: '#15', date: '2026-11-20', period: 'AM', status: 'done',     recordStatus: 'locked', recordFilled: 7 }
  ],

  /* 医生端 · 病历编辑（七段上限 2000/4000/2000/2000/2000/2000/4000；required_to_lock 仅诊断/处理意见） */
  emrSections: [
    { key: 'chief',     label: '主诉',     limit: 2000, required: false },
    { key: 'hpi',       label: '现病史',   limit: 4000, required: false },
    { key: 'past',      label: '既往史',   limit: 2000, required: false },
    { key: 'allergy',   label: '过敏史',   limit: 2000, required: false },
    { key: 'exam',      label: '体格检查', limit: 2000, required: false },
    { key: 'diagnosis', label: '诊断',     limit: 2000, required: true },
    { key: 'treatment', label: '处理意见', limit: 4000, required: true }
  ],
  editingRecord: { visitId: 7002, seq: 7, locked: false, values: { chief: '', hpi: '', past: '', allergy: '', exam: '', diagnosis: '', treatment: '' } },

  /* 管理端 · 运营看板（GET /api/v1/admin/dashboard —— 只出聚合，响应无任何患者标识字段） */
  dashboard: {
    stats: [
      { v: '1,284', l: '累计挂号' }, { v: '86%', l: '号源使用率' },
      { v: '73%', l: '分诊命中率' }, { v: '91%', l: '预问诊完成率' }
    ],
    week: [
      { label: '周一', pct: 46 }, { label: '周二', pct: 62 }, { label: '周三', pct: 38 },
      { label: '周四', pct: 78 }, { label: '周五', pct: 88 }, { label: '周六', pct: 34 }, { label: '周日', pct: 22 }
    ]
  },

  /* 管理端 · AI 能力中心（settings / prompts / tools 三块；密钥绝不回显，只回「是否已设置 + 引用类型」） */
  aiSettings: [
    { key: 'ai.endpoint', value: 'https://api.example.com/v1', secret: false },
    { key: 'ai.model',    value: 'deepseek-chat',              secret: false },
    { key: 'ai.api_key',  value: '已设置（引用类型：env）',     secret: true }
  ],
  aiPrompts: [
    { key: 'prompt.triage',   value: '含 {complaint} {options} 占位符', ok: true },
    { key: 'prompt.previsit', value: '含 {slot} {history} 占位符',      ok: true }
  ],
  aiTools: [
    { key: 'tool.triage',   enabled: true },
    { key: 'tool.previsit', enabled: true },
    { key: 'tool.rag',      enabled: false }
  ],

  /* 管理端 · 知识库（A-7，与 A-2 同「列表 + 表单 + 确认」范式） */
  kbDocs: [
    { id: 1, title: '呼吸内科就诊指引',     chunks: 18, updated: '2026-10-09' },
    { id: 2, title: '常见危急征象识别手册', chunks: 25, updated: '2026-10-06' },
    { id: 3, title: '门诊退费流程说明',     chunks: 7,  updated: '2026-09-30' }
  ]
};
