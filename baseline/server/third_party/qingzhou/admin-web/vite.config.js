import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      // 开发期把 /api 代理到 QingZhou 后端，避免跨域
      '/api': 'http://127.0.0.1:3000'
    }
  },
  build: {
    outDir: 'dist'
  }
})
