<script setup>
import { ref, computed, onMounted } from 'vue'
import { api } from '../api'

/*
 * 社团管理（运维页）
 *
 * 两条链路，别混淆：
 *   读 —— 走运维台自己的后端 /api/club/*（后台进程**只读**社团库；
 *         2026-09-20 起 club-server 的持久化是 **MySQL**，
 *         所以后端是现连现载那份库，club-server 没起也能看）
 *   写 —— 浏览器**直连** club-server 的真实 API /api/v1/*，用会长手机号+口令现场登录拿令牌。
 *         为什么不由运维台代写：两个进程同时写同一份数据 = last-writer-wins，
 *         会静默丢数据，还会绕过 club-server 的权限判定与两阶段赋值。
 */

// ---------- 读：运维台后端 ----------
const cfg = ref({})
const overview = ref(null)
const members = ref([])
const memberTotal = ref(0)
const depts = ref([])
const tasks = ref([])
const taskTotal = ref(0)
const plans = ref([])
const links = ref([])
const audit = ref([])
const tab = ref('members')
const err = ref('')
const note = ref('')
const forbidden = ref(false)
const q = ref('')
const statusFilter = ref('')
const taskStatus = ref('')

// ---------- 写：直连 club-server，身份是**后台代持的专用运维账号** ----------
// 运维人员只登录后台一次（admin/admin123）；后台用 admin.env 里的 club_user/club_pass
// 去 club-server 换一个运维令牌交给本页面，所以这里既不需要会长口令，也不显示任何凭据。
const base = ref(localStorage.getItem('club_base') || '')
const clubToken = ref('')
const clubMe = ref(null)
const clubUp = ref(null)
const healthAt = ref('')
const sessionErr = ref('')
const opsConfigured = ref(null)   // null=未知 true/false
const opsAccount = ref('')

const loggedIn = computed(() => !!clubToken.value)
const me = computed(() => clubMe.value || {})

const ROLE_OPTIONS = [
  { code: 'vice_president', label: '副会长' },
  { code: 'lead', label: '部长' },
  { code: 'vice_lead', label: '副部长' },
  { code: 'member', label: '成员' }
]
const STATUS_OPTIONS = [
  { code: '', label: '全部状态' },
  { code: 'pending', label: '待分配' },
  { code: 'active', label: '在册' },
  { code: 'disabled', label: '已停用' }
]
const TASK_STATUS_OPTIONS = [
  { code: '', label: '全部' },
  { code: 'todo', label: '待办' },
  { code: 'doing', label: '进行中' },
  { code: 'blocked', label: '受阻' },
  { code: 'done', label: '已完成' }
]

function saveBase() {
  localStorage.setItem('club_base', base.value)
}

// ---------- 直连 club-server ----------
async function clubFetch(path, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) }
  if (clubToken.value) headers['Authorization'] = 'Bearer ' + clubToken.value
  let res
  try {
    res = await fetch(base.value + path, { ...options, headers })
  } catch (e) {
    throw new Error('连不上 club-server（' + base.value + '）：' + e.message)
  }
  const json = await res.json()
  if (!json.ok) {
    const e = json.error || {}
    const extra = e.fields ? '（' + Object.keys(e.fields).map(k => k + ': ' + e.fields[k]).join('；') + '）' : ''
    throw new Error((e.code || 'ERROR') + ' ' + (e.message || '') + extra)
  }
  return json.data
}

async function clubLogin() {
  return ensureSession(true)
}

/*
 * 取运维会话：后台用 admin.env 里的专用运维账号（club-server 的 role = ops）登录 club-server，
 * 把令牌交给本页面。页面上不出现任何社团账号的口令，运维人员只登录后台。
 * 令牌只放在这个页面的内存里（刷新页面会重新取一次，后台侧有 6 小时缓存，不会反复烧 PBKDF2）。
 */
async function ensureSession(force = false) {
  sessionErr.value = ''
  try {
    const d = await api.clubSession(force)
    opsConfigured.value = !!d.configured
    opsAccount.value = (d.identity && d.identity.phone) || ''
    if (!d.configured) {
      clubToken.value = ''
      clubMe.value = null
      return
    }
    // 运维页可能不和服务端同一台机器：非本机打开时按"页面的 host + club_port"拼地址
    if (d.api_base || d.club_port) {
      const host = window.location.hostname
      const isLocal = host === '127.0.0.1' || host === 'localhost' || host === ''
      base.value = isLocal ? d.api_base : (window.location.protocol + '//' + host + ':' + d.club_port)
      saveBase()
    }
    if (d.error) {
      sessionErr.value = d.error
      clubToken.value = ''
      clubMe.value = null
      return
    }
    clubToken.value = d.token || ''
    clubMe.value = d.identity || null
  } catch (e) {
    sessionErr.value = e.message
  }
}

async function checkHealth() {
  try {
    const d = await api.clubServerHealth()
    clubUp.value = d.up
    healthAt.value = new Date().toLocaleTimeString()
  } catch (e) {
    clubUp.value = false
    healthAt.value = ''
  }
}

// ---------- 读接口 ----------
async function loadOverview() {
  overview.value = await api.clubOverview()
}

async function loadMembers() {
  const qs = []
  if (q.value.trim()) qs.push('q=' + encodeURIComponent(q.value.trim()))
  if (statusFilter.value) qs.push('status=' + statusFilter.value)
  const d = await api.clubMembers(qs.length ? '?' + qs.join('&') : '')
  members.value = d.items
  memberTotal.value = d.total
}

async function loadTasks() {
  const qs = []
  if (taskStatus.value) qs.push('status=' + taskStatus.value)
  const d = await api.clubTasks(qs.length ? '?' + qs.join('&') : '?size=200')
  tasks.value = d.items
  taskTotal.value = d.total
}

async function loadAll() {
  err.value = ''
  forbidden.value = false
  try {
    cfg.value = await api.clubConfig()
    // 运维页可能不和服务端在同一台机器：默认按"运维页的 host + club_port"拼，localhost 时用配置里的 api_base
    if (!base.value) {
      const host = window.location.hostname
      const isLocal = host === '127.0.0.1' || host === 'localhost' || host === ''
      base.value = isLocal ? cfg.value.api_base : (window.location.protocol + '//' + host + ':' + cfg.value.club_port)
      saveBase()
    }
    await Promise.all([
      loadOverview(),
      api.clubDepts().then(d => { depts.value = d.items }),
      api.clubPlans().then(d => { plans.value = d.items }),
      api.clubLinks().then(d => { links.value = d.items }),
      api.clubAudit(200).then(d => { audit.value = d.items }),
      loadMembers(),
      loadTasks(),
      checkHealth()
    ])
  } catch (e) {
    if (String(e.message).indexOf('forbidden') === 0) {
      forbidden.value = true
    } else {
      err.value = e.message
    }
  }
}

async function backup() {
  err.value = ''
  note.value = ''
  try {
    const d = await api.clubBackup()
    note.value = '已备份：' + d.files.join('、')
  } catch (e) {
    err.value = '备份失败：' + e.message
  }
}

async function refresh() {
  note.value = ''
  await loadAll()
}

// ---------- 写操作（直连 club-server 的真实 API） ----------
async function guard(fn, retried = false) {
  err.value = ''
  note.value = ''
  if (!loggedIn.value) {
    await ensureSession(false)
    if (!loggedIn.value) {
      err.value = sessionErr.value ||
        '运维会话不可用：确认 club-server 在跑，并按提示在 admin.env 里配置 club_user / club_pass'
      return
    }
  }
  try {
    const msg = await fn()
    if (msg) note.value = msg
    await Promise.all([loadOverview(), loadMembers(), loadTasks()])
  } catch (e) {
    /* 令牌过期/被作废（例如运维账号被 retire-ops 重设过口令）→ 刷新一次会话再重试一遍 */
    if (!retried && /AUTH_REQUIRED|401|未登录|缺少令牌/.test(String(e.message))) {
      await ensureSession(true)
      if (loggedIn.value) {
        return guard(fn, true)
      }
    }
    err.value = e.message
  }
}

function assign(m) {
  return guard(async () => {
    const role = prompt('角色（' + ROLE_OPTIONS.map(r => r.code).join(' / ') + '）', m.role || 'member')
    if (!role) return ''
    const deptId = prompt('部门 ID（见「部门」标签页；0 = 不指定）', String(m.dept_id || 0))
    if (deptId === null) return ''
    await clubFetch('/api/v1/members/' + m.id + '/assign', {
      method: 'POST',
      body: JSON.stringify({ role: role.trim(), dept_id: Number(deptId) || 0 })
    })
    return '已分配：' + m.name + ' → ' + role + ' / 部门 ' + deptId
  })
}

function disable(m) {
  return guard(async () => {
    if (!confirm('停用（移出社团）' + m.name + '？该成员有未完成任务时会被拒绝。')) return ''
    await clubFetch('/api/v1/members/' + m.id + '/disable', { method: 'POST', body: '{}' })
    return '已停用：' + m.name
  })
}

function resetPassword(m) {
  return guard(async () => {
    if (!confirm('为 ' + m.name + ' 重置密码？会生成一个新的临时口令。')) return ''
    const d = await clubFetch('/api/v1/members/' + m.id + '/reset-password', { method: 'POST', body: '{}' })
    const temp = d.temporary_password || d.temp_password || JSON.stringify(d)
    try { await navigator.clipboard.writeText(temp) } catch (_) {}
    return '临时口令（已尝试复制到剪贴板）：' + temp
  })
}

function transferPresidency(m) {
  return guard(async () => {
    // 会长专属：运维账号调用会被 club-server 拒（403 FORBIDDEN_ROLE）。
    // 这里保留按钮是为了把口径讲清楚，而不是指望它成功。
    return '「移交会长」是会长专属动作，运维不参与 —— 请让会长本人在 App 里操作'
  })
}

function rotateCode() {
  return guard(async () => {
    if (!confirm('轮换注册口令？旧口令立即失效，需要重新发给新同学。')) return ''
    const d = await clubFetch('/api/v1/register-config/rotate', { method: 'POST', body: '{}' })
    await loadOverview()
    return '新注册口令：' + (d.code || JSON.stringify(d))
  })
}

// 优雅停服：club-server 的 /admin/shutdown 只接受**本机**请求，
// 所以在别的机器上打开运维页时这里会返回 403（这正是它的设计意图）。
function shutdownClub() {
  return guard(async () => {
    if (!confirm('优雅关停 club-server？正在处理的请求会先跑完，随后进程自行退出。')) return ''
    await clubFetch('/admin/shutdown', { method: 'POST', body: '{}' })
    clubToken.value = ''
    clubMe.value = null
    await checkHealth()
    return '已请求关停：club-server 会在 1 秒内退出（可在启动它的窗口看到「服务已停止」）'
  })
}

/* 新增部门：部门增删改在 club-server 里是**会长与运维**才有的权限
 * （副会长不行）—— 这也是"运维与会长同权"在最常用的一处的体现。 */
function createDept() {
  return guard(async () => {
    const name = prompt('新部门名称（例如：外联部）')
    if (!name) return ''
    const d = await clubFetch('/api/v1/depts', {
      method: 'POST',
      body: JSON.stringify({ name: name.trim() })
    })
    await loadAll()
    return '已新增部门：' + ((d.dept && d.dept.name) || name)
  })
}

function copy(t) {
  navigator.clipboard.writeText(t)
  note.value = '已复制：' + t
}

onMounted(async () => {
  await ensureSession(false)
  await loadAll()
})
</script>

<template>
  <div class="card">
    <h2>社团管理 <span class="sub">读社团库（MySQL）· 写走 club-server 真实 API</span></h2>

    <div v-if="forbidden" class="forbidden">
      当前后台账号不是 admin 角色，运维页仅限 admin（后端 /api/club/** 同口径）
    </div>

    <template v-else>
      <!-- 状态条：club-server 在不在 + 会长登录 -->
      <div class="bar">
        <div class="health">
          <span :class="['dot', clubUp ? 'up' : 'down']"></span>
          club-server
          <b>{{ clubUp === null ? '未探测' : (clubUp ? '在线' : '离线') }}</b>
          <span class="muted" v-if="healthAt">{{ healthAt }}</span>
          <button class="btn ghost sm" @click="checkHealth">重新探测</button>
        </div>
        <div class="who">
          <template v-if="loggedIn">
            运维身份：<b>{{ me.name || me.phone }}</b>
            <span class="tag gold">{{ me.role_label || me.role || '-' }}</span>
            <span class="muted">（后台代持，页面不接触社团口令）</span>
            <button class="btn ghost sm" @click="shutdownClub">优雅停服</button>
            <button class="btn ghost sm" @click="clubLogin">刷新运维会话</button>
          </template>
          <template v-else>
            <span class="err inline" v-if="sessionErr">{{ sessionErr }}</span>
            <span class="muted" v-else-if="opsConfigured === false">
              还没有运维会话 → 只能看不能改。两种做法（任选其一）：
              ① 退出后**用运维账号重新登录一次本后台**（手机号 + 运维口令）；
              ② 或把手机号/口令填进 admin.env 的 club_user / club_pass，再重启本后台。
              运维账号由
              <code>club-server init-ops &lt;手机号&gt; &lt;口令&gt; mysql://…</code> 创建。
            </span>
            <span class="muted" v-else>正在获取运维会话…</span>
            <button class="btn ghost sm" @click="ensureSession(true)">重试</button>
          </template>
        </div>
      </div>

      <div class="row base-row">
        <label class="muted">club-server 地址</label>
        <input v-model="base" class="base-input" @change="saveBase">
        <span class="muted">社团库 {{ cfg.club_database }} @ {{ cfg.club_mysql }}（后台只读；审计日志 {{ cfg.club_data_dir }}）</span>
      </div>

      <div class="err">{{ err }}</div>
      <div class="note" v-if="note">{{ note }}</div>

      <!-- 概览 -->
      <div class="stat" v-if="overview">
        <div class="stat-box"><div class="num">{{ overview.members.active }}</div><div class="lab">在册成员</div></div>
        <div class="stat-box"><div class="num">{{ overview.members.pending }}</div><div class="lab">待分配</div></div>
        <div class="stat-box"><div class="num">{{ overview.depts }}</div><div class="lab">部门</div></div>
        <div class="stat-box"><div class="num">{{ overview.tasks.open }}</div><div class="lab">未完成任务</div></div>
        <div class="stat-box warn"><div class="num">{{ overview.tasks.overdue }}</div><div class="lab">逾期任务</div></div>
        <div class="stat-box warn"><div class="num">{{ overview.tasks.blocked }}</div><div class="lab">阻塞任务</div></div>
        <div class="stat-box"><div class="num">{{ overview.plans }}</div><div class="lab">课题</div></div>
      </div>

      <div class="meta" v-if="overview">
        数据在 MySQL（{{ overview.db_backend }}）·
        审计 {{ (overview.audit.bytes / 1024).toFixed(1) }} KB / {{ overview.audit.lines }} 行 ·
        注册口令
        <code v-if="overview.register.has_code">{{ overview.register.code }}</code>
        <span v-else class="muted">未设置</span>
        <button class="btn ghost sm" v-if="overview.register.has_code" @click="copy(overview.register.code)">复制</button>
        <button class="btn ghost sm" @click="rotateCode">轮换</button>
        <button class="btn ghost sm" @click="backup">备份社团库（导出 JSON）</button>
        <button class="btn ghost sm" @click="refresh">刷新</button>
      </div>

      <!-- 标签页 -->
      <div class="tabs">
        <a :class="{ on: tab === 'members' }" @click="tab = 'members'">成员名录</a>
        <a :class="{ on: tab === 'depts' }" @click="tab = 'depts'">部门</a>
        <a :class="{ on: tab === 'tasks' }" @click="tab = 'tasks'">任务</a>
        <a :class="{ on: tab === 'plans' }" @click="tab = 'plans'">课题</a>
        <a :class="{ on: tab === 'links' }" @click="tab = 'links'">招募链接</a>
        <a :class="{ on: tab === 'audit' }" @click="tab = 'audit'">审计日志</a>
      </div>

      <!-- 成员 -->
      <div v-if="tab === 'members'">
        <div class="row">
          <input v-model="q" placeholder="姓名 / 手机号" @keyup.enter="loadMembers">
          <select v-model="statusFilter" @change="loadMembers">
            <option v-for="s in STATUS_OPTIONS" :key="s.code" :value="s.code">{{ s.label }}</option>
          </select>
          <button class="btn ghost" @click="loadMembers">查询</button>
          <span class="muted">共 {{ memberTotal }} 人</span>
        </div>
        <table>
          <thead><tr>
            <th>ID</th><th>姓名</th><th>手机号</th><th>角色</th><th>部门</th><th>状态</th>
            <th>未完成任务</th><th>加入时间</th><th>操作</th>
          </tr></thead>
          <tbody>
            <tr v-for="m in members" :key="m.id">
              <td>{{ m.id }}</td>
              <td>{{ m.name }}<span v-if="m.is_president" class="tag gold">会长</span></td>
              <td>{{ m.phone }}</td>
              <td>{{ m.role_label || '—' }}</td>
              <td>{{ m.dept_name || '—' }}<span v-if="m.dept_hint_name" class="muted">（意向 {{ m.dept_hint_name }}）</span></td>
              <td><span class="tag" :class="m.status">{{ m.status_label }}</span></td>
              <td>{{ m.open_tasks }}</td>
              <td class="muted">{{ m.joined_at || '—' }}</td>
              <td class="ops">
                <button class="btn ghost sm" @click="assign(m)">
                  {{ m.status === 'pending' ? '分配' : (m.status === 'disabled' ? '恢复' : '改派') }}
                </button>
                <button class="btn ghost sm" @click="resetPassword(m)">重置口令</button>
                <button class="btn danger sm" v-if="m.status === 'active' && !m.is_president" @click="disable(m)">停用</button>
                <button class="btn ghost sm" v-if="m.status === 'active' && !m.is_president" @click="transferPresidency(m)">移交会长</button>
              </td>
            </tr>
            <tr v-if="members.length === 0"><td colspan="9" class="muted">没有匹配的成员</td></tr>
          </tbody>
        </table>
      </div>

      <!-- 部门 -->
      <div v-if="tab === 'depts'">
        <div class="row">
          <button class="btn ghost" @click="createDept">新增部门</button>
          <span class="muted">部门增删改是「会长与运维」才有的权限（副会长不行）</span>
        </div>
        <table>
          <thead><tr><th>ID</th><th>名称</th><th>排序</th><th>在用成员</th><th>顶层课题</th></tr></thead>
          <tbody>
            <tr v-for="d in depts" :key="d.id">
              <td>{{ d.id }}</td><td>{{ d.name }}</td><td>{{ d.sort }}</td>
              <td>{{ d.active_members }}</td><td>{{ d.top_plans }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- 任务 -->
      <div v-if="tab === 'tasks'">
        <div class="row">
          <select v-model="taskStatus" @change="loadTasks">
            <option v-for="s in TASK_STATUS_OPTIONS" :key="s.code" :value="s.code">{{ s.label }}</option>
          </select>
          <button class="btn ghost" @click="loadTasks">查询</button>
          <span class="muted">共 {{ taskTotal }} 条（默认不含已删除）</span>
        </div>
        <table>
          <thead><tr>
            <th>ID</th><th>标题</th><th>负责人</th><th>部门</th><th>课题</th><th>状态</th>
            <th>截止</th><th>阻塞原因</th>
          </tr></thead>
          <tbody>
            <tr v-for="t in tasks" :key="t.id">
              <td>{{ t.id }}</td>
              <td>{{ t.title }}</td>
              <td>{{ t.owner_name || '—' }}</td>
              <td>{{ t.dept_name || '—' }}</td>
              <td>{{ t.plan_title || '—' }}</td>
              <td>
                <span class="tag" :class="t.status">{{ t.status_label }}</span>
                <span v-if="t.overdue" class="tag bad">逾期</span>
                <span v-if="t.deleted" class="tag">已删除</span>
              </td>
              <td class="muted">{{ t.due_at || '—' }}</td>
              <td class="muted">{{ t.blocker || '—' }}<span v-if="t.help_dept_name"> → {{ t.help_dept_name }}{{ t.help_member_name ? ' / ' + t.help_member_name : '' }}</span></td>
            </tr>
            <tr v-if="tasks.length === 0"><td colspan="8" class="muted">没有任务</td></tr>
          </tbody>
        </table>
      </div>

      <!-- 课题 -->
      <div v-if="tab === 'plans'">
        <table>
          <thead><tr>
            <th>ID</th><th>层级</th><th>标题</th><th>部门</th><th>负责人</th>
            <th>子课题</th><th>任务（总/完成）</th><th>截止</th>
          </tr></thead>
          <tbody>
            <tr v-for="p in plans" :key="p.id">
              <td>{{ p.id }}</td>
              <td>{{ '　'.repeat(Math.max(0, p.depth - 1)) }}{{ p.depth }}</td>
              <td>{{ p.title }}</td>
              <td>{{ p.dept_name || '—' }}</td>
              <td>{{ p.owner_name || '—' }}</td>
              <td>{{ p.child_count }}</td>
              <td>{{ p.tasks_done }} / {{ p.tasks_total }}</td>
              <td class="muted">{{ p.due_at || '—' }}</td>
            </tr>
            <tr v-if="plans.length === 0"><td colspan="8" class="muted">没有课题</td></tr>
          </tbody>
        </table>
      </div>

      <!-- 招募链接 -->
      <div v-if="tab === 'links'">
        <table>
          <thead><tr><th>部门</th><th>token</th><th>状态</th><th>创建人</th><th>创建时间</th><th>操作</th></tr></thead>
          <tbody>
            <tr v-for="l in links" :key="l.token">
              <td>{{ l.dept_name || '—' }}</td>
              <td><code>{{ l.token }}</code></td>
              <td><span class="tag" :class="l.enabled ? 'active' : 'disabled'">{{ l.enabled ? '启用' : '已停用' }}</span></td>
              <td>{{ l.created_by_name || '—' }}</td>
              <td class="muted">{{ l.created_at || '—' }}</td>
              <td><button class="btn ghost sm" @click="copy(l.path)">复制路径</button></td>
            </tr>
            <tr v-if="links.length === 0"><td colspan="6" class="muted">没有招募链接</td></tr>
          </tbody>
        </table>
      </div>

      <!-- 审计 -->
      <div v-if="tab === 'audit'">
        <div class="muted sm-note">
          来源：审计日志目录下的 audit.log（一行一条）。解析失败的行也会照原样列出（parsed=false）。
        </div>
        <table>
          <thead><tr><th>时间</th><th>操作者</th><th>动作</th><th>对象</th><th>备注</th></tr></thead>
          <tbody>
            <tr v-for="(a, i) in audit" :key="i">
              <td class="muted">{{ a.at }}</td>
              <td>{{ a.actor_name || a.actor_id }}</td>
              <td>{{ a.action }}</td>
              <td>{{ a.target_name || a.target_id }}</td>
              <td class="muted">{{ a.note }}</td>
            </tr>
            <tr v-if="audit.length === 0"><td colspan="5" class="muted">没有审计记录（还没发生敏感操作）</td></tr>
          </tbody>
        </table>
      </div>
    </template>
  </div>
</template>

<style scoped>
h2 .sub { font-size: 12px; font-weight: 400; color: #8a919f; margin-left: 8px; }
.forbidden { background: #fcebeb; color: #a32d2d; padding: 16px; border-radius: 8px; font-size: 14px; }
.bar { display: flex; flex-wrap: wrap; gap: 16px; align-items: center; justify-content: space-between;
  background: #fafbfc; border: 1px solid #eef0f3; border-radius: 10px; padding: 12px 16px; margin-bottom: 12px; }
.health { display: flex; align-items: center; gap: 8px; font-size: 14px; }
.dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
.dot.up { background: #1d9e75; }
.dot.down { background: #e24b4a; }
.who { display: flex; align-items: center; gap: 8px; font-size: 14px; }
.sm-input { width: 150px; padding: 6px 10px; font-size: 13px; }
.btn.sm { padding: 5px 10px; font-size: 12px; }
.base-row { margin-bottom: 12px; font-size: 13px; }
.base-input { width: 260px; padding: 6px 10px; font-size: 13px; }
.muted { color: #8a919f; font-size: 12px; }
.note { background: #f0fbf6; color: #0f6e56; padding: 10px 14px; border-radius: 8px; font-size: 13px; margin: 10px 0; word-break: break-all; }
.err.inline { margin: 0; }
.meta { font-size: 13px; color: #4e5969; margin: 14px 0; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.meta code { background: #f4f6f8; padding: 2px 8px; border-radius: 4px; font-size: 13px; }
.tabs { display: flex; gap: 6px; border-bottom: 1px solid #eef0f3; margin: 8px 0 16px; }
.tabs a { padding: 8px 14px; font-size: 14px; color: #4e5969; cursor: pointer; border-bottom: 2px solid transparent; }
.tabs a.on { color: #0f6e56; border-bottom-color: #1d9e75; font-weight: 600; }
.tag { background: #e6f1fb; color: #185fa5; padding: 2px 8px; border-radius: 4px; font-size: 12px; margin-left: 6px; }
.tag.active { background: #e8f7f1; color: #0f6e56; }
.tag.pending { background: #fdf3e3; color: #9a6700; }
.tag.disabled { background: #f1f2f4; color: #6b7280; }
.tag.blocked, .tag.bad { background: #fcebeb; color: #a32d2d; }
.tag.done { background: #e8f7f1; color: #0f6e56; }
.tag.doing { background: #e6f1fb; color: #185fa5; }
.tag.gold { background: #fdf3e3; color: #9a6700; }
.ops { white-space: nowrap; }
.ops .btn { margin-right: 4px; }
.stat-box.warn { background: #fdf3e3; }
.stat-box.warn .num { color: #9a6700; }
.sm-note { margin-bottom: 10px; }
table td { vertical-align: top; }
</style>
