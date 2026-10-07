<script setup>
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'

const route = useRoute()
const router = useRouter()

const isLogin = computed(() => route.path === '/login')

/*
 * me 必须是**响应式**的：登录成功走的是 SPA 跳转（router.push('/')），不会刷新页面，
 * 而本组件只挂载一次 —— 原先写成 `const me = JSON.parse(...)`（一次性快照），
 * 于是"刚登录完"这一刻读到的还是登录前的空对象：侧边栏不会出现「社团管理」入口，
 * 必须手动刷新一次才有。这里改成 ref + 跟随路由重读。
 */
const me = ref(JSON.parse(localStorage.getItem('qz_me') || '{}'))
watch(() => route.path, () => {
  me.value = JSON.parse(localStorage.getItem('qz_me') || '{}')
})

// 运维页放给 admin 角色，或"直接用运维账号登录"的身份（后端 /api/club/** 同口径）
const canOps = computed(() => me.value.can_ops === true || me.value.role === 'admin')
/*
 * 运维账号登录的身份不在后台的 rbac.json 里，后台管理接口（/api/users 等）对它一律 401，
 * 而 api.js 遇到 401 会跳回登录页 —— 所以这里直接把入口藏掉，
 * 免得点一下「用户管理」就被弹回登录页（看着像"登录失效了"）。
 */
const isOpsAccount = computed(() => me.value.is_ops_account === true)

function logout() {
  localStorage.removeItem('qz_token')
  localStorage.removeItem('qz_me')
  router.push('/login')
}
</script>

<template>
  <router-view v-if="isLogin" />

  <div v-else class="layout">
    <aside class="sidebar">
      <div class="brand">轻舟后台</div>
      <nav>
        <router-link to="/">仪表盘</router-link>
        <router-link v-if="!isOpsAccount" to="/users">用户管理</router-link>
        <router-link v-if="canOps" to="/club">社团管理</router-link>
      </nav>
      <div class="who">
        <div class="name">{{ me.username || '-' }} <span class="role">{{ me.role || '' }}</span></div>
        <a @click="logout">退出登录</a>
      </div>
    </aside>
    <main class="content">
      <router-view />
    </main>
  </div>
</template>

<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif; background: #f5f6f8; color: #1f2329; }
.layout { display: flex; min-height: 100vh; }
.sidebar { width: 220px; background: #1f2a37; color: #fff; display: flex; flex-direction: column; }
.brand { font-size: 18px; font-weight: 600; padding: 24px 20px; border-bottom: 1px solid rgba(255,255,255,0.08); }
nav { flex: 1; padding: 12px 0; }
nav a { display: block; padding: 12px 20px; color: #c8d0da; text-decoration: none; font-size: 14px; }
nav a.router-link-active { color: #fff; background: rgba(29,158,117,0.25); border-left: 3px solid #1d9e75; }
.who { padding: 16px 20px; border-top: 1px solid rgba(255,255,255,0.08); font-size: 13px; }
.who .name { margin-bottom: 8px; }
.who .role { color: #8fa1b3; font-size: 12px; }
.who a { color: #1d9e75; cursor: pointer; }
.content { flex: 1; padding: 28px; }
.card { background: #fff; border-radius: 12px; padding: 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.05); }
h2 { font-size: 18px; font-weight: 600; margin-bottom: 20px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 10px 12px; font-size: 14px; border-bottom: 1px solid #eef0f3; }
th { color: #8a919f; font-weight: 500; background: #fafbfc; }
.btn { padding: 8px 16px; border: none; border-radius: 6px; font-size: 13px; cursor: pointer; background: #1d9e75; color: #fff; }
.btn:hover { background: #0f6e56; }
.btn.danger { background: #e24b4a; }
.btn.ghost { background: transparent; color: #1d9e75; border: 1px solid #1d9e75; }
input, select { padding: 9px 12px; border: 1px solid #dcdfe6; border-radius: 6px; font-size: 14px; }
input:focus, select:focus { outline: none; border-color: #1d9e75; }
.err { color: #e24b4a; font-size: 13px; margin-top: 10px; }
.row { display: flex; gap: 12px; align-items: center; margin-bottom: 16px; }
.stat { display: flex; gap: 16px; margin-bottom: 24px; }
.stat-box { flex: 1; background: #f0fbf6; border-radius: 10px; padding: 20px; }
.stat-box .num { font-size: 28px; font-weight: 600; color: #0f6e56; }
.stat-box .lab { font-size: 12px; color: #8a919f; margin-top: 4px; }
</style>
