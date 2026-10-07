import { createApp } from 'vue'
import { createRouter, createWebHistory } from 'vue-router'
import App from './App.vue'
import Login from './views/Login.vue'
import Dashboard from './views/Dashboard.vue'
import Users from './views/Users.vue'
import Club from './views/Club.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', component: Login },
    { path: '/', component: Dashboard },
    { path: '/users', component: Users },
    // 社团管理运维页：读社团库 MySQL + 转发写操作到 club-server（见 views/Club.vue）
    { path: '/club', component: Club }
  ]
})

// 简单路由守卫：未登录跳登录页
router.beforeEach((to) => {
  const token = localStorage.getItem('qz_token')
  if (to.path !== '/login' && !token) {
    return '/login'
  }
})

createApp(App).use(router).mount('#app')
