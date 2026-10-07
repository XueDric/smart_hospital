<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api'

const stats = ref({ users: 0, roles: 0 })
const perms = ref([])
const err = ref('')

/*
 * 权限点是**后台管理员专属**的接口（/api/perms 要 perm:list 权限）。
 * 用运维账号登录时它必然 401 —— 虽然下面写了 try/catch 想忽略，但没必要白打一发：
 * 先看身份再决定要不要请求（同时也让"为什么这块是空的"有个准确解释）。
 */
const me = JSON.parse(localStorage.getItem('qz_me') || '{}')
const isAdmin = me.role === 'admin'

onMounted(async () => {
  try {
    const d = await api.dashboard()
    stats.value = d.stats
    if (isAdmin) {
      try { perms.value = await api.perms() } catch (_) {}
    }
  } catch (e) {
    err.value = '加载失败：' + e.message
  }
})
</script>

<template>
  <div class="card">
    <h2>仪表盘</h2>
    <div class="stat">
      <div class="stat-box"><div class="num">{{ stats.users }}</div><div class="lab">用户数</div></div>
      <div class="stat-box"><div class="num">{{ stats.roles }}</div><div class="lab">角色数</div></div>
    </div>
    <div class="err">{{ err }}</div>

    <h2 style="margin-top:24px">权限点</h2>
    <table v-if="perms.length">
      <thead><tr><th>ID</th><th>权限码</th><th>名称</th></tr></thead>
      <tbody>
        <tr v-for="p in perms" :key="p.id">
          <td>{{ p.id }}</td>
          <td><code>{{ p.code }}</code></td>
          <td>{{ p.name }}</td>
        </tr>
      </tbody>
    </table>
    <p v-else class="sub">当前账号无查看权限的权限（admin 可见全部权限点）</p>
  </div>
</template>

<style scoped>
.sub { font-size: 13px; color: #8a919f; }
code { background: #f0f2f5; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
</style>
