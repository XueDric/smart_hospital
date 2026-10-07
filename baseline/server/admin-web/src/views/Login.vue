<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '../api'

const router = useRouter()
/*
 * 不再预填 admin / admin123（2026-09-17 去掉）。
 *
 * 原先这里是 `ref('admin')` / `ref('admin123')` —— 那是 N-29 **之前**的公开默认口令。
 * N-29 起后台种子口令改为首次启动随机生成并写进 admin.env，那对默认值已经登不进去，
 * 预填它只会把人直接带进"登录失败"，还会让人以为口令本来就是 admin123。
 * 现在两个框都留空：口令只存在于 admin.env（后台账号）或 init-ops（运维账号）里，
 * 仓库里任何地方都不该再出现一份"看起来能用的口令"。
 */
const username = ref('')
const password = ref('')
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
      <p class="sub">社团管理 · 运维台</p>
      <label>手机号 / 用户名</label>
      <input v-model="username" placeholder="手机号 或 用户名">
      <label>口令</label>
      <input v-model="password" type="password" placeholder="口令">
      <button class="btn" @click="login">登 录</button>
      <div class="err">{{ err }}</div>
      <p class="hint">
        <b>运维账号</b>：手机号 + 运维口令 —— 即
        <code>club-server init-ops &lt;手机号&gt; &lt;口令&gt;</code> 建的那个（local-deploy §2.2 ②）<br>
        <b>后台账号</b>：<code>admin</code> / <code>user</code>，口令见 <code>build\admin\admin.env</code>
        的 <code>admin_pass</code> / <code>user_pass</code>
      </p>
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
.hint { font-size: 12px; color: #8a919f; margin-top: 16px; line-height: 1.7; }
.hint code { background: #f4f5f7; border-radius: 3px; padding: 1px 4px; }
</style>
