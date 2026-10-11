<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '../api'

const router = useRouter()
const username = ref('admin')
const password = ref('admin123')
const err = ref('')

async function login() {
  err.value = ''
  try {
    const data = await api.login(username.value, password.value)
    localStorage.setItem('qz_token', data.token)
    const me = await api.me()
    localStorage.setItem('qz_me', JSON.stringify(me))
    router.push('/')
  } catch (e) {
    err.value = '登录失败：' + e.message
  }
}
</script>

<template>
  <div class="login-page">
    <div class="login-card">
      <h1>轻舟后台管理系统</h1>
      <p class="sub">QingZhou · Vue 3 前后端分离示例</p>
      <label>用户名</label>
      <input v-model="username" placeholder="admin">
      <label>密码</label>
      <input v-model="password" type="password" placeholder="admin123">
      <button class="btn" @click="login">登 录</button>
      <div class="err">{{ err }}</div>
      <p class="hint">admin/admin123（管理员） · user/user123（普通用户）</p>
    </div>
  </div>
</template>

<style scoped>
.login-page { min-height: 100vh; display: flex; align-items: center; justify-content: center; }
.login-card { background: #fff; border-radius: 12px; padding: 36px; width: 380px; box-shadow: 0 2px 12px rgba(0,0,0,0.06); }
h1 { font-size: 20px; font-weight: 600; margin-bottom: 6px; }
.sub { font-size: 13px; color: #8a919f; margin-bottom: 24px; }
label { display: block; font-size: 13px; margin: 14px 0 6px; color: #4e5969; }
input { width: 100%; }
.btn { width: 100%; margin-top: 20px; padding: 11px; }
.hint { font-size: 12px; color: #b0b8c4; margin-top: 16px; text-align: center; }
</style>
