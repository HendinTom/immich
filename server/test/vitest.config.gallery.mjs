import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    root: resolve(dirname(fileURLToPath(import.meta.url)), '..'),
    globals: true,
    include: ['test/gallery-review/**/*.spec.ts'],
    hookTimeout: 120000,
  },
  plugins: [swc.vite()],
});
