import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api/menu':   'http://localhost:5001',
      '/api/orders': 'http://localhost:5002',
    },
  },
})
