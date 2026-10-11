<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount, nextTick } from 'vue';
import Icon from './components/Icon.vue';
import PatientPages from './components/PatientPages.vue';
import DoctorPages from './components/DoctorPages.vue';
import AdminPages from './components/AdminPages.vue';
import FrameworkGuide from './components/FrameworkGuide.vue';
import MobileNav from './components/MobileNav.vue';
import { data, ui, session, notify, resetDemo, acceptModal, role, page, search, go } from './store.js';
import { menus, descriptions, evidence, ROLE_LABEL } from './pages.js';
const main = ref(null);
const dialog = ref(null);
let previousFocus;
const roles = ROLE_LABEL;
const items = computed(() => menus[role.value]);
const info = computed(() => items.value.find(i => i[0] === page.value) || ['framework', '框架与依据', 'book', 'DOC', '说明']);
const searchResults = computed(() => Object.entries(menus).flatMap(([r, entries]) => entries.map(i => ({ role: r, item: i }))).filter(i => i.item[1].includes(search.value.trim())).slice(0, 6));
const navigate = go;
function switchRole(r) { navigate(menus[r][0][0], r); notify(`已切换${roles[r]}演示视角 · 非授权切换`, 'info'); }
function readHash() {
  const [, r, p] = location.hash.split('/');
  if (menus[r] && (menus[r].some(i => i[0] === p) || p === 'framework')) navigate(p, r);
}
function keyboard(e) {
  if (e.key === 'Escape') { ui.modal = null; ui.sourceOpen = false; ui.mobileNav = false; search.value = ''; }
  if (e.key === 'Tab' && ui.modal && dialog.value) {
    const els = [...dialog.value.querySelectorAll('button,input,select,textarea,a[href]')].filter(el => !el.disabled);
    const first = els[0], last = els.at(-1);
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }
}
watch(() => ui.modal, async m => {
  if (m) { previousFocus = document.activeElement; await nextTick(); dialog.value?.querySelector('button')?.focus(); }
  else previousFocus?.focus?.();
  document.body.style.overflow = m ? 'hidden' : '';
});
onMounted(() => { readHash(); window.addEventListener('hashchange', readHash); window.addEventListener('keydown', keyboard); });
onBeforeUnmount(() => { window.removeEventListener('hashchange', readHash); window.removeEventListener('keydown', keyboard); });
</script>
<template>
  <div class="app-root">
  <a href="#main-content" class="skip-link">跳到主要内容</a>
  <div class="app-shell">
    <button v-if="ui.mobileNav" class="nav-overlay" aria-label="关闭导航" @click="ui.mobileNav=false"></button>
    <aside class="sidebar" :class="{ open: ui.mobileNav }">
      <a class="brand" href="#/patient/triage" @click.prevent="navigate('triage','patient')"><span class="brand-mark"><span></span></span><span><strong>智慧医院</strong><small>SMART HOSPITAL</small></span></a>
      <div class="workspace-label">就诊服务工作台 <span class="badge">演示</span></div>
      <div class="role-tabs" aria-label="演示端切换"><button v-for="(text,r) in roles" :key="r" :class="{active:role===r}" :aria-pressed="role===r" @click="switchRole(r)">{{text}}</button></div>
      <p class="nav-caption">{{roles[role]}}服务</p>
      <nav class="main-nav" aria-label="主要导航"><a v-for="i in items" :key="i[0]" :href="`#/${role}/${i[0]}`" :class="{active:page===i[0]}" :aria-current="page===i[0]?'page':undefined" @click.prevent="navigate(i[0])"><Icon :name="i[2]"/><span>{{i[1]}}</span><span v-if="i[0]==='appointments'" class="nav-counter">{{data.appointments.filter(a=>a.patient_id===7&&a.status==='booked').length}}</span></a></nav>
      <div class="nav-bottom"><a data-reading-aid="讲解" :href="`#/${role}/framework`" :class="{active:page==='framework'}" @click.prevent="navigate('framework')"><Icon name="book"/><span>框架与文档依据</span></a><button @click="resetDemo"><Icon name="reset"/><span>重置演示数据</span></button></div>
      <div class="sidebar-note" data-reading-aid="演示"><Icon name="shield"/><div><strong>隐私与安全优先</strong><p>仅虚构数据 · 不连接医疗服务<br>刷新后恢复初始状态</p></div></div>
      <div class="sidebar-person"><span class="mini-avatar">{{session.name[0]}}</span><span><strong>{{session.name}}</strong><small>演示身份 · {{role}}</small></span><button class="icon-button" aria-label="查看个人中心" @click="navigate(role==='patient'?'profile':role==='doctor'?'queue':'users')"><Icon name="chevron" :size="16"/></button></div>
    </aside>
    <div class="workspace">
      <header class="topbar">
        <div class="breadcrumb"><button class="icon-button mobile-menu" aria-label="打开导航" :aria-expanded="ui.mobileNav" @click="ui.mobileNav=true"><Icon name="menu"/></button><span>智慧医院</span><Icon name="chevron" :size="14"/><strong>{{info[1]}}</strong></div>
        <div class="top-actions"><div class="global-search"><Icon name="search" :size="17"/><input v-model="search" placeholder="搜索页面…" aria-label="搜索页面" @keydown.enter="searchResults[0]&&navigate(searchResults[0].item[0],searchResults[0].role)"/><div v-if="search" class="search-results"><button v-for="r in searchResults" :key="r.item[0]" @click="navigate(r.item[0],r.role)"><span>{{r.item[1]}}</span><small>{{roles[r.role]}}</small></button><p v-if="!searchResults.length" class="muted">没有找到匹配页面</p></div></div><span class="demo-dot" data-reading-aid="演示">本地演示</span><span class="mini-avatar small">{{session.name[0]}}</span></div>
      </header>
      <main id="main-content" ref="main" tabindex="-1">
        <div class="page-heading"><div><div class="eyebrow">{{page==='framework'?'PRODUCT & ENGINEERING':`${roles[role]} / ${info[3]}`}}</div><h1>{{info[1]}}<span class="title-dot"></span></h1><p>{{descriptions[page]}}</p></div><button class="button secondary source-button" data-reading-aid="依据" @click="ui.sourceOpen=!ui.sourceOpen" :aria-expanded="ui.sourceOpen"><Icon name="book" :size="16"/>设计依据</button></div>
        <div v-if="ui.sourceOpen" class="evidence-panel" data-reading-aid="依据"><strong>文档依据与实现边界</strong><code v-for="c in evidence[page]?.slice(0,2)" :key="c">{{c}}</code><p>{{evidence[page]?.[2]}}</p><button class="text-button" @click="navigate('framework')">查看完整框架说明 <Icon name="arrow" :size="15"/></button></div>
        <PatientPages v-if="role==='patient'&&page!=='framework'" :page="page" @navigate="navigate"/>
        <DoctorPages v-else-if="role==='doctor'&&page!=='framework'" :page="page" @navigate="navigate"/>
        <AdminPages v-else-if="role==='admin'&&page!=='framework'" :page="page" @navigate="navigate"/>
        <FrameworkGuide v-else/>
        <footer class="page-footer" data-reading-aid="演示"><span>智慧医院 · 交互设计演示</span><span>虚构数据，不作为诊断、真实挂号或医疗服务</span></footer>
      </main>
      <MobileNav/>
    </div>
  </div>
  <Transition name="toast"><div v-if="ui.toast" :key="ui.toast.message" class="toast-message" :class="ui.toast.type" role="status" aria-live="polite"><Icon :name="ui.toast.type==='error'?'alert':ui.toast.type==='warning'?'info':'check'"/><span>{{ui.toast.message}}</span><button class="icon-button" aria-label="关闭提示" @click="ui.toast=null"><Icon name="close" :size="16"/></button></div></Transition>
  <div v-if="ui.modal" class="modal-backdrop" @click.self="ui.modal=null"><section ref="dialog" class="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title"><span class="modal-symbol" :class="{danger:ui.modal.danger}"><Icon :name="ui.modal.danger?'alert':'shield'" :size="28"/></span><h2 id="modal-title">{{ui.modal.title}}</h2><p>{{ui.modal.message}}</p><div class="modal-actions"><button class="button secondary" @click="ui.modal=null">返回</button><button class="button" :class="{danger:ui.modal.danger}" @click="acceptModal">确认</button></div></section></div>
  </div>
</template>
