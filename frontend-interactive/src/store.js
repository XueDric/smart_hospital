import { reactive, computed, ref } from 'vue';

export function day(offset = 0) {
  const d = new Date(); d.setDate(d.getDate() + offset);
  return [d.getFullYear(), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')].join('-');
}
function seed() { return {
  departments: [
    { id: 3, name: '呼吸内科', code: 'RESP', location: '门诊楼 3F · A区', enabled: true },
    { id: 4, name: '骨科', code: 'ORTH', location: '门诊楼 2F · B区', enabled: true },
    { id: 5, name: '皮肤科', code: 'DERM', location: '门诊楼 4F · A区', enabled: true },
    { id: 6, name: '全科医学科', code: 'GEN', location: '门诊楼 1F · C区', enabled: true }
  ],
  doctors: [
    { id: 9, name: '李医生', department_id: 3, title: '副主任医师', specialty: '呼吸系统常见病', enabled: true },
    { id: 10, name: '王医生', department_id: 3, title: '主治医师', specialty: '慢性咳嗽与气道疾病', enabled: true },
    { id: 11, name: '张医生', department_id: 4, title: '主任医师', specialty: '关节及运动损伤', enabled: true },
    { id: 12, name: '陈医生', department_id: 5, title: '主治医师', specialty: '常见皮肤疾病', enabled: true },
    { id: 13, name: '赵医生', department_id: 6, title: '主治医师', specialty: '全科健康管理', enabled: true }
  ],
  schedules: [
    { id: 101, doctor_id: 9, department_id: 3, work_date: day(1), period: 'AM', total_num: 20, remain_num: 5, enabled: true },
    { id: 102, doctor_id: 10, department_id: 3, work_date: day(1), period: 'PM', total_num: 20, remain_num: 0, enabled: true },
    { id: 103, doctor_id: 9, department_id: 3, work_date: day(2), period: 'AM', total_num: 20, remain_num: 8, enabled: true },
    { id: 104, doctor_id: 11, department_id: 4, work_date: day(1), period: 'AM', total_num: 18, remain_num: 6, enabled: true },
    { id: 105, doctor_id: 12, department_id: 5, work_date: day(1), period: 'PM', total_num: 24, remain_num: 12, enabled: true },
    { id: 106, doctor_id: 13, department_id: 6, work_date: day(1), period: 'AM', total_num: 30, remain_num: 9, enabled: true }
  ],
  appointments: [
    { id: 2001, schedule_id: 101, patient_id: 7, doctor_id: 9, department_id: 3, visit_date: day(1), period: 'AM', seq_no: 15, status: 'booked', client_token: 'seed-intent', slot_restored: false },
    { id: 2002, schedule_id: 104, patient_id: 7, doctor_id: 11, department_id: 4, visit_date: day(-5), period: 'AM', seq_no: 3, status: 'done', client_token: null, slot_restored: false },
    { id: 2003, schedule_id: 101, patient_id: 12, doctor_id: 9, department_id: 3, visit_date: day(1), period: 'AM', seq_no: 16, status: 'booked', client_token: 'seed-other', slot_restored: false }
  ],
  records: { 2002: { status: 'locked', sections: { chief_complaint: '膝关节不适（虚构演示）', present_illness: '活动后出现不适，仅用于界面展示。', past_history: '无', allergy_history: '无', physical_exam: '演示体格检查', diagnosis: '示例诊断 · 非医疗意见', treatment: '示例处理意见 · 非医疗建议' } } },  // @reading-aid:演示 —— 病历正文里的「虚构演示 / 非医疗意见」免责后缀；剥离须人工改写字符串，不可删整行
  intake: { id: '', answers: [], complete: false },
  users: [ { id: 1, login_name: 'demo.patient', role: 'patient', ref_id: 7, display_name: '演示患者' }, { id: 2, login_name: 'demo.doctor', role: 'doctor', ref_id: 9, display_name: '李医生' } ],
  kb: [ { id: 1, title: '呼吸内科就诊指引', category: '就诊指南', body: '呼吸内科位于门诊楼三层。就诊时请携带既往检查资料。本条为虚构知识库演示，不构成医疗建议。', enabled: true }, { id: 2, title: '门诊预约与退号说明', category: '门诊服务', body: '挂号以在线确认结果为准。取消预约后需核对号源归还状态。此处为界面演示。', enabled: true } ],  // @reading-aid:演示 —— 知识库正文里的「虚构演示 / 不构成医疗建议」免责后缀
  ai: { endpoint: 'https://api.example.com/v1', model: 'example-chat', key_ref: '', enabled: false, timeout: 10, prompt: '根据 {complaint}，仅参考 {options} 中可预约的号源。', tools: { get_departments: true, get_schedules: true, search_kb: true } },
  sessions: [ { id: 'demo-desktop', name: '当前浏览器', current: true, last: '刚刚' }, { id: 'demo-phone', name: '演示手机', current: false, last: '30 分钟前' }, { id: '', name: '未标识设备', current: false, last: '1 小时前' } ]  // @reading-aid:演示 —— 设备名带「演示」字样，用于声明这是虚构会话而非真实设备
}; }
export const data = reactive(seed());
export const ui = reactive({ toast: null, modal: null, busy: false, sourceOpen: false, mobileNav: false });
export const session = reactive({ active: true, role: 'patient', name: '演示患者', ref_id: 7 });
let toastTimer;
export function notify(message, type = 'success') { clearTimeout(toastTimer); ui.toast = { message, type }; toastTimer = setTimeout(() => ui.toast = null, 5000); }
export function confirmAction(title, message, onConfirm, danger = false) { ui.modal = { title, message, onConfirm, danger }; }
export async function acceptModal() { const m = ui.modal; if (!m) return; ui.modal = null; await m.onConfirm(); }
export function resetDemo() {
  confirmAction('重置演示数据？', '预约、病历、配置与知识库将恢复为初始虚构数据。不会影响服务端或真实文件。', () => { Object.assign(data, seed()); notify('演示数据已重置'); });  // @reading-aid:演示 —— 弹窗正文的「不会影响服务端或真实文件」免责说明
}
export const patientAppointments = computed(() => data.appointments.filter(a => a.patient_id === 7));
export function dept(id) { return data.departments.find(d => d.id === id)?.name || `科室 #${id}`; }
export function doctor(id) { return data.doctors.find(d => d.id === id)?.name || `医生 #${id}`; }
export const labels = { booked: '已挂号', visiting: '接诊中', done: '已完成', cancelled: '已取消', no_show: '爽约', draft: '草稿', locked: '已锁定' };
export const emrFields = [
  { key: 'chief_complaint', label: '主诉', max: 2000 }, { key: 'present_illness', label: '现病史', max: 4000 },
  { key: 'past_history', label: '既往史', max: 2000 }, { key: 'allergy_history', label: '过敏史', max: 2000 },
  { key: 'physical_exam', label: '体格检查', max: 2000 }, { key: 'diagnosis', label: '诊断', max: 2000, required: true },
  { key: 'treatment', label: '处理意见', max: 4000, required: true }
];
export function delay(ms = 550) { return new Promise(r => setTimeout(r, ms)); }
export function newIntent() { return globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}`; }
export function book(scheduleId, token) {
  if (session.role !== 'patient') return notify('FORBIDDEN_ROLE：该功能只面向患者', 'error');
  const replay = data.appointments.find(a => a.patient_id === 7 && a.client_token === token);
  if (replay) { notify('幂等回放：已返回同一笔预约，不重复扣号'); return replay; }  // @reading-aid:演示 —— 「幂等回放」为演示用的教学式反馈，功能反馈本身须保留
  const s = data.schedules.find(s => s.id === scheduleId);
  if (!s || s.remain_num <= 0) { notify('SLOT_GONE：号源已约满，请选择其他排班', 'error'); return; }
  s.remain_num--;
  const a = { id: Math.max(2003, ...data.appointments.map(a => a.id)) + 1, schedule_id: s.id, patient_id: 7, doctor_id: s.doctor_id, department_id: s.department_id, visit_date: s.work_date, period: s.period, seq_no: s.total_num - s.remain_num, status: 'booked', client_token: token, slot_restored: false };
  data.appointments.unshift(a); notify('演示挂号成功 · 已扣减 1 个号源'); return a;  // @reading-aid:演示 —— 「演示」前缀用于声明本次挂号未落真实库
}
export function cancelAppointment(a) {
  confirmAction('确认取消预约？', `${a.visit_date} ${a.period === 'AM' ? '上午' : '下午'} · ${dept(a.department_id)}。这将结束本次预约意图。`, () => {
    if (a.status !== 'booked') return notify('当前预约状态不允许取消', 'error');
    a.status = 'cancelled'; a.client_token = null;
    const s = data.schedules.find(s => s.id === a.schedule_id);
    if (s && s.enabled) { s.remain_num = Math.min(s.total_num, s.remain_num + 1); a.slot_restored = true; notify('预约已取消 · 号源已归还'); }
    else { a.slot_restored = false; notify('预约已取消，但号源归还异常，请联系人工', 'warning'); }
  }, true);
}

// 应用级导航状态。刻意放在 store 而不是 App.vue 的局部 ref：
// App.vue 模板中 <main> 之后的区域不会随导航重新 patch（编译后的块跟踪边界），
// 独立组件订阅 store 才能稳定重渲染。底部导航即依赖这一点。
export const role = ref('patient');
export const page = ref('triage');
export const search = ref('');
const ROLE_NAME = { patient: '演示患者', doctor: '李医生', admin: '运营管理员' };
const ROLE_REF = { patient: 7, doctor: 9, admin: 0 };
export function go(p, r = role.value) {
  role.value = r; page.value = p; ui.mobileNav = false; search.value = '';
  session.role = r; session.name = ROLE_NAME[r]; session.ref_id = ROLE_REF[r];
  const h = `#/${r}/${p}`;
  if (location.hash !== h) location.hash = h;
  window.scrollTo({ top: 0, behavior: 'instant' });
}
