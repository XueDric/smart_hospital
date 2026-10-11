<script setup>
/* @reading-aid:file 讲解 —— 本组件整体是「框架与文档依据」说明页：技术栈、目录、组件、视觉、构建、出处六类讲解。
   它不承担任何业务功能，删除本文件并摘掉 App.vue 中的 framework 路由后，患者/医生/管理三端闭环完全不受影响。
   生产剥离方式：删除本文件 + 移除 pages.js 的 framework 条目 + 移除 App.vue 的 FrameworkGuide 引入。 */
import { computed, ref } from 'vue'

const tabs = [
  { id: 'stack', label: '技术栈', detail: '分清当前交付、正式客户端与历史参考' },
  { id: 'structure', label: '目录依赖', detail: '现有目录与待建模块，不混为已实现' },
  { id: 'components', label: '组件方案', detail: '公共基础件与业务组合各守边界' },
  { id: 'visual', label: '视觉规范', detail: '浅色医疗青绿，轻量而清晰' },
  { id: 'build', label: '构建运行', detail: '本演示网站的开发、构建与离线打开方式' },
  { id: 'sources', label: '文档依据', detail: '有依据的设计，先契约后参考' },
]
const activeTab = ref('stack')
const currentTab = computed(() => tabs.find((tab) => tab.id === activeTab.value))

function handleTabKey(event, index) {
  let nextIndex
  if (event.key === 'ArrowRight') nextIndex = (index + 1) % tabs.length
  else if (event.key === 'ArrowLeft') nextIndex = (index - 1 + tabs.length) % tabs.length
  else if (event.key === 'Home') nextIndex = 0
  else if (event.key === 'End') nextIndex = tabs.length - 1
  else return
  event.preventDefault()
  activeTab.value = tabs[nextIndex].id
  event.currentTarget.parentElement.querySelectorAll('[role="tab"]')[nextIndex].focus()
}

const stackCards = [
  {
    status: '本次新实现', title: 'Vue 3 + Vite 交互演示',
    text: '当前 frontend-interactive 是浏览器演示网站，使用 Vue 3 单文件组件与 CSS，展示三端流程和契约边界。不是鸿蒙工程，也不代表管理 Web 技术栈已定。',
    tags: ['Composition API', '<script setup>', '本地演示数据'],
  },
  {
    status: '现有服务端', title: '仓颉 1.2.0 + 轻舟 v0.12.0',
    text: 'server/ 为自包含服务端，P0–P5 已完成。直接 SQL + 事务，MySQL / MariaDB 11.4；框架与数据库驱动使用副本随业务构建。',
    tags: ['不透明 Bearer Token', '原生 SSE', 'MariaDB 3317'],
  },
  {
    status: '正式客户端 · 待建', title: 'ArkTS + ArkUI 原生',
    text: '鸿蒙患者端 entry/ 尚未建立。使用 ArkTS 状态管理 V2、统一路由和网络层；参照交互与协议，不直接复用 Vue UI 代码。',
    tags: ['状态管理 V2', 'DevEco Studio', 'entry → feature → common-core'],
  },
  {
    status: '历史参考 · 非当前交付', title: 'Vue 3 / Element Plus 参考系统',
    text: '可借鉴患者、医生与管理端的页面流程和医疗青绿视觉，但不能照搬响应解析器。正式管理端另立一期，Q4 技术栈仍未拍板。',
    tags: ['只作设计参照', '不等于已建管理端', '不等于 FastAPI 后端'],
  },
]
const contractRules = [
  { title: '角色只看 role', text: 'patient_id 只是 ref_id 的便利字段；医生登录时可等于 doctor.id，管理员时为 0，不能据此判断患者身份。' },
  { title: '不是 JWT，也没有 refresh', text: '令牌是 64 hex 不透明字符串；30 天 TTL + 服务端滑动续期。401 统一清登录态并重新登录，不实现 /auth/refresh。' },
  { title: '只有 limit，没有真正分页', text: '没有 page / cursor / total，超限静默夹住；count == limit 只能提示“可能还有更多”，不能伪造总页数。' },
  { title: '患者权限不能借道', text: '患者业务不能调用 /api/v1/admin/**、/api/v1/doctor/** 或知识库搜索接口。开发态身份头不能用于正式授权。' },
]
const componentGroups = [
  { title: '基础控件', location: '未来 common-core/ui', items: ['HButton：主 / 次 / 危险 / 禁用态', 'HInput：单行、多行、错误与聚焦态', 'HCard / HListItem：清晰的信息层级', 'HTag：状态文字 + 语义颜色'] },
  { title: '反馈与流程', location: '公共能力统一封装', items: ['HBanner：429 倒计时、开发态告警、退号 warning', 'HDialog：挂号 / 退号二次确认，危急强提醒', 'HEmpty / HLoading：空态与一次性分诊等待', 'HProgress：预问诊 filled / total_slots'] },
  { title: '业务复合件', location: '由各 feature 组合', items: ['TriageOptionCard：可信科室、医生与真实号源', 'ChatBubble：预问诊文本逐段追加', 'ScheduleItem / AppointmentItem：余号与订单状态', 'EmrSection：七段病历、必填与锁定只读态'] },
]
const redlines = [
  { number: '01', title: '危急征象只引导急诊 / 人工', text: 'red_flag === true 时 options 必须为空；不展示推荐科室，不在客户端自拼号源，也不猜测命中的危急关键词。', citation: '对接说明 §10.2；页面清单 §8.1 P-2' },
  { number: '02', title: '一次挂号意图，一个 client_token', text: '点击时生成并保留幂等键，失败重试复用；换号源换新 token。409 SLOT_GONE 刷新列表，不反复提交抢同一个号。', citation: '对接说明 §8.1 / §8.4；页面清单 §8.1 P-4' },
  { number: '03', title: '挂号与 AI 必须在线直连', text: '分诊、预问诊和挂号不进入离线补发队列。请求失败明确提示；离线可浏览的是本地演示，不是真实问诊或预约成功。', citation: '对接说明 §10.3；页面清单 §4 / §10' },
]
const documentSources = [
  { title: '前端开发梳理与页面清单', path: 'docs/前端开发梳理与页面清单.md', sections: '§0–§5 · §7–§10', text: '仓库边界、栈与目录、权限和接口约定、18 页清单、服务端缺口、三条业务红线。本页组织的主要依据。' },
  { title: '前端对接唯一口径', path: 'docs/FRONTEND-INTEGRATION.md', sections: '§3–§4 · §6–§10 · §11', text: '信封三种失败形状、不透明令牌与角色、患者禁用路径、SSE 字节格式、幂等与退号语义、HTTPS 与历史文档勘误。' },
  { title: '三人团队鸿蒙端分工', path: 'docs/分工.md', sections: '§3.1.1 · §3.3 · §4.1 / §4.4', text: 'A 基础架构与患者端，B 医生端与联调，C 设计与公共层；单向依赖、V2 状态、vp/fp 规范。第一章的 FastAPI 描述仅为旧参考。' },
  { title: '仓库 README', path: 'README.md', sections: '当前进度 · 目录结构 · 阅读顺序 · Q3 / Q4', text: '服务端已完成、鸿蒙仍待建；患者主闭环六页已决，管理端技术栈未决；内存 Store 已拆除，ADR-0001 已至 rev.7。' },
  { title: '原始框架效果预览', path: 'docs/frontend-preview.html', sections: '#overview / #structure / #components / #style / #build', text: '借鉴轻卡片、模块树、依赖图和页面规范对照布局；静态预览不是工程，管理端 Web 图示也不是已确认选型。' },
]
const repositoryTree = `smart_hospital/
├── server/                 已有服务端（仓颉 + 轻舟）
│   ├── src/                业务、路由、鉴权、AI 与验收
│   ├── tests/              验收与联调脚本
│   └── third_party/        轻舟 + MariaDB 驱动使用副本
├── docs/                   契约、页面清单、分工与交接
├── README.md               进度与阅读入口
└── entry/                  仅预留名称，鸿蒙工程尚未建`
const demoTree = `frontend-interactive/       本次新增的独立 Web 演示
├── src/
│   ├── App.vue             演示入口与页面装配
│   └── components/
│       └── FrameworkGuide.vue
├── package.json            npm 开发与构建命令
└── dist/index.html         构建后内联资源入口`
const harmonyTree = `HarmonyOS 工程（建议，未创建）
├── entry/                  壳、装配、签名
├── feature-patient/        患者主闭环
├── feature-doctor/         接诊与病历
└── common-core/
    ├── router/ + net/      路由、HTTP、Token 与 SSE
    ├── ui/ + state/        公共组件与 ArkTS V2
    └── store/ + session/ + theme/`
const successEnvelope = '{ "ok": true, "data": { … } }'
const failureEnvelope = '{ "ok": false, "error": { "code": "SLOT_GONE", "message": "…" } }'
const flatFailures = '{ "code": 400, "message": "Invalid JSON body", "data": null }\n{ "error": "Not Found", "path": "…" }'
const sseFrame = 'data: {"event":"delta","data":{"text":"问诊文本"}}\\n\\n'
</script>

<template>
  <div class="framework-guide">
    <header class="page-intro fg-intro">
      <span class="badge">框架与依据</span>
      <h2>看清当前实现，再规划正式工程</h2>
      <p class="muted">当前交付是 Vue 3 + Vite 交互演示；现有业务服务端为仓颉 + 轻舟，鸿蒙客户端仍待建，管理 Web 选型未决。</p>
      <div class="fg-chips">
        <span>患者主闭环 6 页</span><span>服务端 P0–P5 已完成</span><span>契约优先，设计参考其次</span>
      </div>
    </header>

    <div class="fg-tabs" role="tablist" aria-label="框架与依据分类">
      <button
        v-for="(tab, index) in tabs" :id="`framework-tab-${tab.id}`" :key="tab.id"
        class="fg-tab" :class="{ 'is-active': activeTab === tab.id }" type="button" role="tab"
        :aria-selected="activeTab === tab.id" :tabindex="activeTab === tab.id ? 0 : -1"
        aria-controls="framework-panel" @click="activeTab = tab.id" @keydown="handleTabKey($event, index)"
      >{{ tab.label }}</button>
    </div>

    <section id="framework-panel" class="fg-panel" role="tabpanel" :aria-labelledby="`framework-tab-${activeTab}`" tabindex="0">
      <div class="section-heading fg-heading">
        <div><h3>{{ currentTab.label }}</h3><p class="muted">{{ currentTab.detail }}</p></div>
        <span class="fg-section-count">{{ String(tabs.findIndex((tab) => tab.id === activeTab) + 1).padStart(2, '0') }} / 06</span>
      </div>

      <template v-if="activeTab === 'stack'">
        <div class="grid-two fg-grid-two">
          <article v-for="item in stackCards" :key="item.title" class="card">
            <span class="fg-eyebrow">{{ item.status }}</span><h4>{{ item.title }}</h4><p class="muted">{{ item.text }}</p>
            <div class="fg-chips"><span v-for="tag in item.tags" :key="tag">{{ tag }}</span></div>
          </article>
        </div>
        <aside class="soft-panel fg-callout">
          <strong>旧参考系统 ≠ 当前服务端</strong>
          <p>《分工.md》第一章的 FastAPI + LangChain + ReAct Agent 描述不能当作当前技术栈。现有实现以 <code>server/src/</code> 与对接说明为准；旧“乐观锁扣号”已被原子 SQL 扣号取代，内存 Store 已整体拆除。</p>
          <small class="fg-cite">依据：页面清单 §0 / §3；README「当前进度」P0 / P4；分工 §一为历史背景。</small>
        </aside>
        <div class="card fg-envelope">
          <h4>统一响应信封，不能照搬参考解析器</h4>
          <div class="fg-grid-two">
            <div><span class="fg-eyebrow">当前项目</span><pre>{{ successEnvelope }}</pre><pre>{{ failureEnvelope }}</pre></div>
            <div><span class="fg-eyebrow">参考系统 · 仅对比</span><pre>{ code, message, data }</pre><p class="muted">成功与失败先判断 <code>ok</code> 是否存在，不以 <code>code === 200</code> 判断本项目业务成功。</p></div>
          </div>
          <details class="fg-details"><summary>还需兼容的框架层失败</summary><pre>{{ flatFailures }}</pre><p class="muted">这两类没有 ok；/health 则是根路径平铺响应，需单独解析。业务接口统一 /api/v1。</p></details>
          <small class="fg-cite">依据：对接说明 §3.1 / §3.2；页面清单 §4 / §7。</small>
        </div>
        <div class="fg-grid-two">
          <article v-for="rule in contractRules" :key="rule.title" class="card fg-rule"><h4>{{ rule.title }}</h4><p class="muted">{{ rule.text }}</p></article>
        </div>
        <p class="fg-cite">依据：对接说明 §3.5 / §4.1 / §4.2 / §6；页面清单 §1 / §5.2 / §9。</p>
      </template>

      <template v-else-if="activeTab === 'structure'">
        <div class="fg-grid-two">
          <article class="card"><span class="fg-eyebrow">原业务仓库基线</span><h4>已有业务工程仅 server</h4><pre class="fg-tree">{{ repositoryTree }}</pre><p class="fg-cite">README「目录结构」；页面清单 §0 / §2。entry 不是已存在的可编译工程。</p></article>
          <article class="card"><span class="fg-eyebrow">本次新增 · 与鸿蒙分开</span><h4>独立浏览器演示目录</h4><pre class="fg-tree">{{ demoTree }}</pre><p class="fg-cite">本次 Web 实现；只用于页面流程演示，不改变 README 中正式客户端待建的结论。</p></article>
        </div>
        <div class="fg-grid-two">
          <article class="card"><h4>鸿蒙建议结构</h4><pre class="fg-tree">{{ harmonyTree }}</pre><p class="muted">不默认创建 feature-admin；是否采用 Web、是否纳入原生工程，要等 Q4 决策。以上只是一份建议，不是当前目录事实。</p></article>
          <article class="card">
            <h4>单向依赖，不跨业务 import</h4>
            <div class="fg-dependency" aria-label="entry 壳依赖 feature，feature 依赖 common-core，业务模块不互相依赖">
              <div class="fg-dep-node fg-dep-primary"><strong>entry</strong><span>入口 / 装配 / 签名</span></div>
              <span class="fg-dep-arrow" aria-hidden="true">↓</span>
              <div class="fg-dep-features"><div class="fg-dep-node"><strong>feature-patient</strong><span>患者页面</span></div><div class="fg-dep-node"><strong>feature-doctor</strong><span>医生页面</span></div></div>
              <span class="fg-dep-arrow" aria-hidden="true">↓</span>
              <div class="fg-dep-node fg-dep-primary"><strong>common-core</strong><span>router / net / ui / state / store / session / theme</span></div>
            </div>
            <p class="muted">feature 通过公共路由与网络层协作。A、B 不直接互相依赖，C 维护统一公共能力。</p>
            <small class="fg-cite">依据：分工 §3.1.1 / §3.3.2 / §4.1；页面清单 §5.2。</small>
          </article>
        </div>
      </template>

      <template v-else-if="activeTab === 'components'">
        <aside class="soft-panel fg-callout"><strong>这是组件划分方案，不是已交付组件库清单</strong><p>本 Web 演示使用 Vue SFC 与轻量 CSS；以下 H* 名称是未来鸿蒙封装建议。公共层负责基础能力，feature 负责业务组合，避免过早引入重型依赖。</p></aside>
        <div class="fg-grid-three">
          <article v-for="group in componentGroups" :key="group.title" class="card"><span class="fg-eyebrow">{{ group.location }}</span><h4>{{ group.title }}</h4><ul class="fg-list"><li v-for="item in group.items" :key="item">{{ item }}</li></ul></article>
        </div>
        <article class="card">
          <h4>网络公共层：SSE 必须保持字节与事件边界</h4>
          <pre>{{ sseFrame }}</pre>
          <div class="fg-grid-two">
            <ol class="fg-list"><li>严格按 <code>\n\n</code> 分帧，剥掉 <code>data: </code> 后整体解析 JSON。</li><li>TCP chunk 不等于完整帧；保留 UTF-8 解码状态，或积累完整帧字节后解码，不能逐 chunk 直接 toString。</li><li>流无 content-length；业务数据在 <code>{ event, data }</code> 的内层 data。</li></ol>
            <ol class="fg-list" start="4"><li>先从 meta 获取并持久化 session_id；再入页先 GET 已有会话，404 才开新流。</li><li>以 done 为显式终止；连接结束但未收到 done 视为失败，客户端设置超时。</li><li>仅预问诊走 SSE，分诊是一次性 JSON。form 仅 complete 后展示；“无”是有效答案，空串不推进。</li></ol>
          </div>
          <small class="fg-cite">依据：对接说明 §7.2–§7.5；页面清单 §8.1 P-3。</small>
        </article>
        <article class="card"><h4>业务状态不由 UI 猜成功</h4><p class="muted">退号成功看 <code>data.status === 'cancelled'</code>，不是仅看 HTTP 200；<code>slot_restored === false</code> 必须展示 warning。病历锁定后只读，医生完成接诊前必须已锁定病历。</p><small class="fg-cite">依据：对接说明 §8.2；页面清单 §8.1 P-5 / §8.2 D-1、D-2。</small></article>
        <p class="fg-cite">组件划分依据：分工 C2-1；页面清单 §8 各页「所需组件」。</p>
      </template>

      <template v-else-if="activeTab === 'visual'">
        <div class="fg-grid-two">
          <article class="card"><h4>轻量浅色视觉</h4><p class="muted">白色卡片、浅灰背景与医疗青绿强调。不使用深色大面积面板；通过描边、间距和小面积语义色建立层级。</p>
            <div class="fg-swatches"><div class="fg-swatch fg-swatch-primary"><strong>主色</strong><code>#00a9a7</code></div><div class="fg-swatch fg-swatch-soft"><strong>柔和强调</strong><code>#e4f6f6</code></div><div class="fg-swatch fg-swatch-surface"><strong>卡片底色</strong><code>#ffffff</code></div><div class="fg-swatch fg-swatch-background"><strong>页面底色</strong><code>#f4f7f8</code></div></div>
            <p class="fg-cite">参考：frontend-preview.html #style；分工 C1-1。当前网页用 CSS 变量集中表达颜色。</p>
          </article>
          <article class="card"><h4>设计规范与平台单位分开</h4><ul class="fg-list"><li>鸿蒙：vp 单位、8vp 基线网格、热区不小于 40vp × 40vp。</li><li>鸿蒙文字：手机基准 16fp，随系统动态字阶变化。</li><li>当前 Web：CSS px / rem，按钮热区至少 40px，使用系统字体。</li><li>卡片圆角约 12px、轻描边、低阴影；小屏对比列折叠为单列。</li><li>未来鸿蒙浅 / 深双模式通过颜色资源切换；本次网页只做浅色，不把深色资源规划误作当前功能。</li></ul><small class="fg-cite">依据：分工 C1-1 / C1-2 / C1-3 / C2-4；页面清单 §5.2。</small></article>
        </div>
        <article class="card"><h4>状态靠文字，也靠语义色</h4><div class="fg-status-row"><span class="fg-status fg-status-ok">已完成</span><span class="fg-status fg-status-warning">待确认</span><span class="fg-status fg-status-danger">危急提醒</span><span class="fg-status fg-status-neutral">已取消</span></div><p class="muted">不能只用红 / 绿传达状态。所有交互有可见焦点；页签支持方向键、Home / End 切换。关键错误保留文字说明，不以颜色或短暂 Toast 替代危急强提醒。</p></article>
      </template>

      <template v-else-if="activeTab === 'build'">
        <div class="fg-grid-two">
          <article class="card"><span class="fg-eyebrow">当前 Vue 网站</span><h4>在 frontend-interactive 目录执行</h4><ol class="fg-command-list"><li><code>npm install</code><span>安装项目依赖</span></li><li><code>npm run dev</code><span>Vite 开发预览与热更新</span></li><li><code>npm run build</code><span>构建到 dist/</span></li><li><code>npm run preview</code><span>预览已构建网站</span></li></ol><p class="muted">需要本机 Node.js 与 npm；实际开发 / 预览地址以终端输出为准。本页不自动安装依赖或启动服务。</p></article>
          <article class="card"><span class="fg-eyebrow">便捷预览</span><h4>离线打开与本地 Node 服务</h4><div class="fg-run-option"><strong>双击 dist/index.html</strong><p class="muted">本工程构建结果内联脚本和样式，可以 file:// 双击离线运行，不依赖外部 CDN。请先完成 npm run build。</p></div><div class="fg-run-option"><strong>frontend-interactive/start-preview.cmd</strong><p class="muted">双击独立工程中的启动脚本，使用本地 Node HTTP 服务预览演示；地址为 http://127.0.0.1:5178。</p></div><p class="fg-cite">仅演示页面与本地交互可离线。真实 AI、预问诊、挂号必须在线，不能据离线演示结果认为已经落库。</p></article>
        </div>
        <div class="fg-grid-two">
          <article class="card"><h4>未来鸿蒙构建，与 npm 无关</h4><p class="muted">待 entry 工程建立后，用 DevEco Studio / hvigor 构建、预览器与 Inspector 联调，并配置签名。不要把 Web dist 当作 HAP 安装包。</p><small class="fg-cite">依据：分工 A1-1 / B3-2 / C1 设计工具建议。</small></article>
          <article class="card"><h4>真实接口接入的边界</h4><p class="muted">通过明确构建配置选择 BaseURL；release 处理患者标识、凭据或病历必须 HTTPS，不探测后静默降级。记录 x-request-id，不记录 token、口令或病历正文。</p><small class="fg-cite">依据：对接说明 §10.1 / §10.5。Web 脚本仅适用于本次演示工程。</small></article>
        </div>
      </template>

      <template v-else-if="activeTab === 'sources'">
        <aside class="soft-panel fg-callout"><strong>事实优先级：server/src/ + 对接说明 → 最新清单 → 历史参考</strong><p>有冲突时以源码与 FRONTEND-INTEGRATION 为准；交接快照、旧 Vue UI 或分工的历史背景不覆盖当前服务端事实。本页不把参考设计误称为已实现功能。</p></aside>
        <div class="fg-grid-two"><article v-for="doc in documentSources" :key="doc.path" class="card"><span class="fg-eyebrow">{{ doc.sections }}</span><h4>{{ doc.title }}</h4><code class="fg-document-path">{{ doc.path }}</code><p class="muted">{{ doc.text }}</p></article></div>
        <div class="fg-heading"><div><h4>三大业务红线</h4><p class="muted">视觉可以迭代，强一致与医疗安全边界不能省略。</p></div></div>
        <div class="fg-grid-three"><article v-for="line in redlines" :key="line.number" class="card fg-redline"><span class="fg-redline-number">{{ line.number }}</span><h4>{{ line.title }}</h4><p class="muted">{{ line.text }}</p><small class="fg-cite">{{ line.citation }}</small></article></div>
        <p class="fg-cite">MVP 范围：登录 / 分诊 / 预问诊 / 约号 / 我的预约 / 我的（README Q3；页面清单 §8.4）。就诊记录、设备会话为扩展展示；无患者自助注册、改密或消息推送接口，不能虚构端点。</p>
      </template>
    </section>
  </div>
</template>

<style scoped>
.framework-guide {
  --fg-primary: #00a9a7;
  --fg-primary-ink: #007a79;
  --fg-soft: #e4f6f6;
  --fg-ink: #22343c;
  --fg-muted: #61727b;
  --fg-line: #e0e9ec;
  --fg-surface: #ffffff;
  --fg-background: #f4f7f8;
  color: var(--fg-ink);
  line-height: 1.65;
  min-width: 0;
}
.fg-intro { margin-bottom: 24px; }
.fg-intro h2 { font-size: clamp(22px, 3vw, 30px); margin: 12px 0 8px; line-height: 1.4; }
.framework-guide p { margin: 8px 0 0; }
.framework-guide .muted { color: var(--fg-muted); }
.framework-guide .badge, .fg-eyebrow { color: var(--fg-primary-ink); font-size: 12px; font-weight: 650; }
.framework-guide .badge { background: var(--fg-soft); border-radius: 20px; padding: 5px 12px; display: inline-block; }
.fg-chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
.fg-chips span { border: 1px solid var(--fg-line); border-radius: 20px; padding: 3px 10px; background: var(--fg-background); color: var(--fg-muted); font-size: 12px; }
.fg-tabs { display: flex; flex-wrap: wrap; gap: 6px; padding: 6px; background: var(--fg-surface); border: 1px solid var(--fg-line); border-radius: 14px; margin-bottom: 24px; }
.fg-tab { flex: 1 1 110px; min-height: 42px; padding: 10px 14px; border: 0; border-radius: 10px; background: transparent; color: var(--fg-muted); font: inherit; font-size: 14px; cursor: pointer; white-space: nowrap; }
.fg-tab:hover { background: var(--fg-background); color: var(--fg-primary-ink); }
.fg-tab.is-active { background: var(--fg-soft); color: var(--fg-primary-ink); font-weight: 700; }
.fg-tab:focus-visible, .fg-panel:focus-visible, .fg-details summary:focus-visible { outline: 2px solid var(--fg-primary-ink); outline-offset: 3px; }
.fg-panel { display: grid; gap: 20px; }
.fg-heading { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; }
.fg-heading h3 { margin: 0; font-size: 21px; }
.fg-heading h4 { margin: 0; }
.fg-heading p { margin-top: 4px; font-size: 14px; }
.fg-section-count { color: var(--fg-primary-ink); background: var(--fg-soft); font-size: 12px; padding: 4px 10px; border-radius: 8px; white-space: nowrap; }
.fg-grid-two, .fg-grid-three { display: grid; gap: 18px; }
.fg-grid-two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
.fg-grid-three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.framework-guide .card { min-width: 0; padding: 22px; background: var(--fg-surface); border: 1px solid var(--fg-line); border-radius: 14px; box-shadow: 0 4px 16px -12px #244d5e33; }
.framework-guide h4 { margin: 8px 0 10px; line-height: 1.5; font-size: 16px; }
.framework-guide .card > h4:first-child { margin-top: 0; }
.framework-guide .card p, .fg-list { font-size: 14px; }
.fg-callout { background: var(--fg-soft); color: var(--fg-primary-ink); border: 1px solid #cfe9e8; border-radius: 12px; padding: 18px 22px; font-size: 14px; }
.fg-callout p { color: #426d70; }
.framework-guide code, .framework-guide pre { font-family: Consolas, "SFMono-Regular", monospace; font-size: 12px; }
.framework-guide code { overflow-wrap: anywhere; }
.framework-guide pre { display: block; margin: 10px 0; padding: 12px 14px; white-space: pre-wrap; overflow-wrap: anywhere; background: var(--fg-background); border: 1px solid var(--fg-line); border-radius: 9px; color: #355d67; line-height: 1.8; }
.framework-guide .fg-tree { font-size: 12px; white-space: pre; overflow-x: auto; overflow-wrap: normal; }
.fg-details { margin: 14px 0; border-top: 1px solid var(--fg-line); padding-top: 12px; }
.fg-details summary { cursor: pointer; font-size: 13px; color: var(--fg-primary-ink); min-height: 32px; }
.fg-cite { display: block; font-size: 12px; color: var(--fg-muted); margin-top: 14px; overflow-wrap: anywhere; }
.fg-rule h4 { font-size: 15px; }
.fg-dependency { display: flex; flex-direction: column; align-items: center; margin: 16px 0; }
.fg-dep-node { padding: 12px; border: 1px solid var(--fg-line); border-radius: 10px; background: var(--fg-background); text-align: center; min-width: 0; width: 100%; }
.fg-dep-node strong, .fg-dep-node span { display: block; }
.fg-dep-node strong { font-size: 14px; }
.fg-dep-node span { color: var(--fg-muted); font-size: 12px; margin-top: 2px; overflow-wrap: anywhere; }
.fg-dep-primary { background: var(--fg-soft); border-color: #bddfdf; }
.fg-dep-primary strong { color: var(--fg-primary-ink); }
.fg-dep-arrow { color: var(--fg-primary-ink); font-size: 24px; height: 38px; }
.fg-dep-features { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; width: 100%; }
.fg-list { padding-left: 20px; margin: 12px 0 0; color: var(--fg-muted); }
.fg-list li { margin-bottom: 10px; padding-left: 2px; overflow-wrap: anywhere; }
.fg-swatches { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; margin-top: 18px; }
.fg-swatch { padding: 18px 14px; border-radius: 10px; border: 1px solid var(--fg-line); }
.fg-swatch strong, .fg-swatch code { display: block; }
.fg-swatch code { margin-top: 5px; }
.fg-swatch-primary { background: var(--fg-primary); color: #ffffff; border-color: var(--fg-primary); }
.fg-swatch-soft { background: var(--fg-soft); color: var(--fg-primary-ink); }
.fg-swatch-surface { background: var(--fg-surface); }
.fg-swatch-background { background: var(--fg-background); }
.fg-status-row { display: flex; flex-wrap: wrap; gap: 10px; margin: 16px 0; }
.fg-status { display: inline-block; padding: 5px 12px; border-radius: 20px; font-size: 13px; font-weight: 650; }
.fg-status-ok { background: #e7f7f0; color: #197957; }
.fg-status-warning { background: #fff3df; color: #956000; }
.fg-status-danger { background: #fdeceb; color: #b54038; }
.fg-status-neutral { background: #edf1f3; color: #637580; }
.fg-command-list { list-style: none; padding: 0; margin: 18px 0; counter-reset: commands; }
.fg-command-list li { counter-increment: commands; display: grid; grid-template-columns: 24px minmax(0, 1fr); gap: 3px 10px; padding: 12px 0; border-bottom: 1px solid var(--fg-line); }
.fg-command-list li::before { content: counter(commands); color: var(--fg-primary-ink); font-size: 12px; grid-row: span 2; }
.fg-command-list code { font-size: 14px; color: var(--fg-primary-ink); }
.fg-command-list span { font-size: 13px; color: var(--fg-muted); }
.fg-run-option { margin-top: 18px; padding-bottom: 16px; border-bottom: 1px solid var(--fg-line); }
.fg-run-option strong { font-size: 14px; overflow-wrap: anywhere; }
.fg-document-path { display: block; color: var(--fg-primary-ink); padding: 7px 10px; background: var(--fg-background); border-radius: 6px; margin-bottom: 10px; }
.framework-guide .fg-redline { border-top: 3px solid #e48a7c; }
.fg-redline-number { display: inline-flex; align-items: center; justify-content: center; width: 32px; height: 32px; border-radius: 10px; background: #fff0eb; color: #b45442; font-size: 12px; font-weight: 700; }
@media (max-width: 1050px) { .fg-grid-three { grid-template-columns: 1fr; } }
@media (max-width: 760px) {
  .fg-grid-two { grid-template-columns: 1fr; }
  .framework-guide .card { padding: 18px; }
  .fg-callout { padding: 16px 18px; }
  .fg-tabs { gap: 4px; }
  .fg-tab { flex-basis: calc(33.333% - 4px); padding: 9px 6px; font-size: 13px; }
  .fg-heading { gap: 10px; }
  .fg-heading h3 { font-size: 19px; }
}
@media (max-width: 420px) {
  .fg-tab { flex-basis: calc(50% - 4px); }
  .fg-dep-features { grid-template-columns: 1fr; }
  .fg-swatches { gap: 8px; }
  .fg-swatch { padding: 14px 10px; }
  .framework-guide .fg-tree { font-size: 11px; }
}
</style>
