import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  base: '/admin/',
  plugins: [vue()],
  server: {
    proxy: { '/admin/api': 'http://127.0.0.1:5150' },
  },
  build: {
    rollupOptions: {
      output: {
        entryFileNames: 'assets/admin.js',
        assetFileNames: 'assets/admin[extname]',
      },
    },
  },
});
