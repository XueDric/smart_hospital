import { createApp } from 'vue'
import { createRouter, createWebHistory } from 'vue-router'
import App from './App.vue'
import Login from './views/Login.vue'
import Dashboard from './views/Dashboard.vue'
import Users from './views/Users.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', component: Login },
    { path: '/', component: Dashboard },
    { path: '/users', component: Users }
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
