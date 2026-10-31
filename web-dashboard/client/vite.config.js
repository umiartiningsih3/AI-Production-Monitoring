import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Hasil build masuk ke client/dist dan dilayani oleh server Node (port 3000).
// `npm run dev` juga bisa dipakai (port 5173) — permintaan /api diteruskan ke server.
export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 1500 },
  server: { proxy: { '/api': 'http://localhost:3000' } },
});
