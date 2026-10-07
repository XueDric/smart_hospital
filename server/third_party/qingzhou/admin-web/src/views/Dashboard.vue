<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api'

const stats = ref({ users: 0, roles: 0 })
const perms = ref([])
const err = ref('')

onMounted(async () => {
  try {
    const d = await api.dashboard()
    stats.value = d.stats
    // 尝试加载权限列表（无权限则忽略，仅展示可用性）
    try { perms.value = await api.perms() } catch (_) {}
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
