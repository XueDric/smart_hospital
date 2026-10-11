/* @reading-aid:file 讲解 —— 本文件的导航分组、页面说明与文档依据三张表，全部服务于「讲给读者听」 */

export const menus = {
  patient: [ ['triage', '智能分诊', 'spark', 'P-2', 'MVP'], ['previsit', '智能预问诊', 'chat', 'P-3', 'MVP'], ['booking', '预约挂号', 'calendar', 'P-4', 'MVP'], ['appointments', '我的预约', 'list', 'P-5', 'MVP'], ['profile', '个人中心', 'user', 'P-6', 'MVP'], ['records', '就诊记录', 'doc', 'P-7/8', '扩展'], ['sessions', '设备会话', 'monitor', 'P-9', '扩展'], ['login', '登录页面', 'logout', 'P-1', 'MVP'] ],
  doctor: [ ['queue', '接诊队列', 'list', 'D-1', '扩展'], ['emr', '电子病历', 'doc', 'D-2', '扩展'] ],
  admin: [ ['dashboard', '运营看板', 'chart', 'A-1', '规划'], ['departments', '科室管理', 'building', 'A-2', '规划'], ['doctors', '医生管理', 'user', 'A-3', '规划'], ['schedules', '排班号源', 'calendar', 'A-4', '规划'], ['users', '账号管理', 'shield', 'A-5', '规划'], ['ai', 'AI 能力中心', 'spark', 'A-6', '规划'], ['kb', '医学知识库', 'book', 'A-7', '规划'] ]
};
/* @reading-aid:begin 讲解 —— 每页一句说明文案，渲染在页头标题下方，仅用于向读者交代该页用途，不参与任何业务判断。
   剥离时须同步移除 App.vue 中对 descriptions 的引用；业务闭环本身不依赖本表。 */
export const descriptions = {
 triage: '描述您的不适，让就诊从正确的科室开始。', previsit: '提前整理病情，让与医生的沟通更高效。', booking: '核对医生、就诊日期和时段，在线确认预约。', appointments: '每一次就诊，都有清晰的安排与状态。', profile: '管理您的就诊信息与账号状态。', records: '只读查看您已提交锁定的就诊档案。', sessions: '查看当前账号的设备会话，管理登录安全。', login: '使用院内开通的账号登录，无自助注册入口。', queue: '聚焦当日接诊，状态流转与病历进度同步。', emr: '七段式记录，保存草稿后提交锁定。', dashboard: '以聚合指标了解医院运营，不展示患者明细。', departments: '维护科室名称、编码与就诊位置。', doctors: '管理医生档案，建立明确的科室归属。', schedules: '安排出诊时段，核对真实可预约号源。', users: '院内账号开通与口令重置，不回显口令摘要。', ai: '管理模型配置、Prompt 与工具开关。', kb: '维护医学知识片段，默认使用关键词检索。', framework: '从文档约束到交互实现，每一部分都有依据。'
};
/* @reading-aid:end */
/* @reading-aid:begin 依据 —— 页面到文档章节的引用映射，供「设计依据」面板与画布属性面板展示出处。
   纯阅读辅助：删掉它，页面功能与业务闭环完全不受影响。剥离时须同步移除 App.vue 中对 evidence 的引用。 */
export const evidence = {
 triage: ['docs/前端开发梳理与页面清单.md §8.1 P-2', 'docs/FRONTEND-INTEGRATION.md §5.8', '分诊为校验后的一次性 JSON；red_flag 时 options 必空；结果不是诊断。'],
 previsit: ['docs/FRONTEND-INTEGRATION.md §7', 'docs/前端开发梳理与页面清单.md §8.1 P-3', '整段 UTF-8 解码、双换行分帧、复用 session_id、收到 done 才完成。此页演示流式效果，不发送健康信息。'],
 booking: ['docs/FRONTEND-INTEGRATION.md §8', 'docs/前端开发梳理与页面清单.md §9', '真实接口只有科室/医生 id；姓名从分诊 options 带入，未选推荐时展示 id。client_token 重试复用，换号源换新意图。'],
 appointments: ['docs/FRONTEND-INTEGRATION.md §5.14–§5.16', 'docs/前端开发梳理与页面清单.md §8.1 P-5', '取消需看 status=cancelled，不以 HTTP 200 判成功；slot_restored=false 提示人工。就诊日期使用挂号单快照。'],
 profile: ['docs/FRONTEND-INTEGRATION.md §4', 'docs/前端开发梳理与页面清单.md §8.1 P-6', '只用 role 判断角色；令牌不解析；无自助注册、改密、refresh 接口。'],
 login: ['docs/FRONTEND-INTEGRATION.md §4.2', 'docs/前端开发梳理与页面清单.md §8.1 P-1', 'login_name/password 字段；429 读 retry-after；口令不持久化；当前为演示登录非真实鉴权。'],
 records: ['docs/FRONTEND-INTEGRATION.md §5.17–§5.18', 'docs/P4-HANDOFF.md', '列表无正文；只读已锁定病历，草稿暂不可查看；仅限本人。'],
 sessions: ['docs/FRONTEND-INTEGRATION.md §4.3', 'docs/前端开发梳理与页面清单.md §8.1 P-9', '设备信息不可信；不返回 token 明文；无 device_id 不能按设备踢除。'],
 queue: ['docs/P4-HANDOFF.md', 'server/src/domain_emr.cj', 'doctor_id 从令牌派生；booked→visiting→done；完成前必须锁定病历。'],
 emr: ['docs/前端开发梳理与页面清单.md §8.2 D-2', 'server/src/domain_emr.cj', '七段式病历，diagnosis/treatment 为锁定必填；锁定后只读，管理员才能 reopen。'],
 dashboard: ['docs/P4-HANDOFF.md', 'server/src/dashboard.cj', '运营看板只展示聚合数据；无患者明细下钻。以下所有数值为演示生成。'],
 departments: ['docs/前端开发梳理与页面清单.md §8.3 A-2', 'server/src/http_base.cj', '科室 name/code 唯一；已被引用不可删，停用替代删除。'],
 doctors: ['docs/前端开发梳理与页面清单.md §8.3 A-3', 'server/src/domain_base.cj', '医生必须归属已有科室；有引用时不可直接删除。'],
 schedules: ['docs/前端开发梳理与页面清单.md §8.3 A-4', 'server/src/domain_booking.cj', '总号不能为负；扣号以服务端原子事务为权威，前端显示不是抢号承诺。'],
 users: ['docs/前端开发梳理与页面清单.md §8.3 A-5', 'server/src/auth_repo.cj', 'patient/doctor 需 ref_id>0；重置口令吊销该账号全部令牌。'],
 ai: ['docs/P3-HANDOFF.md', 'server/src/ai_settings.cj', 'ai.key_ref 只接受 env:/file: 引用；绝不存裸密钥；模型默认关闭。工具键由服务端为准，此处为演示。'],
 kb: ['docs/P5-HANDOFF.md', 'server/src/http_kb.cj', '关键词检索默认，MySQL JSON 存向量；标题唯一，患者无检索权限。'],
 framework: ['docs/分工.md §3–§4', 'README.md', '鸿蒙原生客户端仍待建；本新工程是独立 Vue3 Web 演示，不修改或替代服务端。']
};
/* @reading-aid:end */

// 三端角色名，供面包屑与移动端导航的无障碍标签使用
export const ROLE_LABEL = { patient: '患者端', doctor: '医生端', admin: '管理端' };

// 移动端底部导航：三端各取核心入口；入口少于该端全部页面时，末尾补一个「更多」用于打开侧栏抽屉
const SHORT_LABEL = { triage: '分诊', previsit: '预问诊', booking: '挂号', appointments: '我的预约', profile: '我的', queue: '接诊队列', emr: '电子病历', dashboard: '看板', departments: '科室', doctors: '医生', schedules: '排班', users: '账号', ai: 'AI 配置', kb: '知识库' };
const MOBILE_ORDER = { patient: ['triage', 'previsit', 'booking', 'appointments', 'profile'], doctor: ['queue', 'emr'], admin: ['dashboard', 'departments', 'schedules', 'users'] };
export function mobileItems(role, page) {
  const list = MOBILE_ORDER[role].map(id => {
    const i = menus[role].find(x => x[0] === id);
    return i ? { id, route: `${role}/${id}`, icon: i[2], label: SHORT_LABEL[id] || i[1], active: page === id, more: false } : null;
  }).filter(Boolean);
  if (list.length < menus[role].length) list.push({ id: '__more__', route: '', icon: 'menu', label: '更多', active: false, more: true });
  return list;
}
