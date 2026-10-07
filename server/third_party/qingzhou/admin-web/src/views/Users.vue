<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api'

const users = ref([])
const roles = ref([])
const err = ref('')
const forbidden = ref(false)

const newUsername = ref('')
const newPassword = ref('')
const newRoleId = ref(2)

async function load() {
  err.value = ''
  forbidden.value = false
  try {
    users.value = await api.users()
  } catch (e) {
    if (e.message.startsWith('forbidden')) {
      forbidden.value = true
    } else {
      err.value = e.message
    }
  }
}

async function create() {
  err.value = ''
  if (!newUsername.value || !newPassword.value) {
    err.value = '请填写用户名和密码'
    return
  }
  try {
    await api.createUser(newUsername.value, newPassword.value, newRoleId.value)
    newUsername.value = ''
    newPassword.value = ''
    await load()
  } catch (e) {
    err.value = '创建失败：' + e.message
  }
}

async function remove(id) {
  if (!confirm('确认删除该用户？')) return
  try {
    await api.deleteUser(id)
    await load()
  } catch (e) {
    err.value = '删除失败：' + e.message
  }
}

onMounted(async () => {
  await load()
  try { roles.value = await api.roles() } catch (_) {}
})
</script>

<template>
  <div class="card">
    <h2>用户管理</h2>

    <div v-if="forbidden" class="forbidden">
      当前账号无「user:list」权限，无法查看用户列表（请用 admin 登录）
    </div>

    <template v-else>
      <div class="row">
        <input v-model="newUsername" placeholder="用户名">
        <input v-model="newPassword" type="password" placeholder="密码">
        <select v-model="newRoleId">
          <option v-for="r in roles" :key="r.id" :value="r.id">{{ r.name }}</option>
        </select>
        <button class="btn" @click="create">创建用户</button>
      </div>

      <div class="err">{{ err }}</div>

      <table>
        <thead><tr><th>ID</th><th>用户名</th><th>角色</th><th>操作</th></tr></thead>
        <tbody>
          <tr v-for="u in users" :key="u.id">
            <td>{{ u.id }}</td>
            <td>{{ u.username }}</td>
            <td><span class="tag">{{ u.role }}</span></td>
            <td><button class="btn danger" @click="remove(u.id)">删除</button></td>
          </tr>
        </tbody>
      </table>
    </template>
  </div>
</template>

<style scoped>
.forbidden { background: #fcebeb; color: #a32d2d; padding: 16px; border-radius: 8px; font-size: 14px; }
.tag { background: #e6f1fb; color: #185fa5; padding: 2px 8px; border-radius: 4px; font-size: 12px; }
.btn.danger { padding: 5px 12px; }
</style>
