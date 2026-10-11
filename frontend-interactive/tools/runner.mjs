import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const local = createRequire(path.join(root, 'package.json'));
const isolated = process.env.WB_NODE_WORKSPACE || path.join(process.env.USERPROFILE || os.homedir(), '.workbuddy-ai/binaries/node/workspace');
const fallback = createRequire(path.join(isolated, 'package.json'));
export function resolvePackage(name) { try { return local.resolve(name); } catch { return fallback.resolve(name); } }
const vitePath = path.join(path.dirname(resolvePackage('vite/package.json')), 'dist/node/index.js');
const vite = await import(pathToFileURL(vitePath).href);
const vuePath = path.join(path.dirname(resolvePackage('@vitejs/plugin-vue')), 'index.mjs');
const vue = (await import(pathToFileURL(vuePath).href)).default;
const inline = { name: 'offline-html', enforce: 'post', generateBundle(_, bundle) {
  const html = bundle['index.html'];
  if (!html) return;
  let content = html.source;
  for (const [name, asset] of Object.entries(bundle)) {
    if (name.endsWith('.js') && asset.type === 'chunk' && asset.isEntry) {
      content = content.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/, () => '<script>window.addEventListener("DOMContentLoaded",function(){' + asset.code.replace(/<\/script/gi, '<\\/script') + '});</script>');
      delete bundle[name];
    } else if (name.endsWith('.css')) {
      content = content.replace(/<link\b[^>]*href=["'][^"']+\.css["'][^>]*>/, () => '<style>' + asset.source + '</style>');
      delete bundle[name];
    }
  }
  html.source = content;
}};
const config = { root, configFile: false, base: './', plugins: [vue(), inline], resolve: { alias: { vue: resolvePackage('vue/dist/vue.runtime.esm-bundler.js') } },
  server: { host: '127.0.0.1', port: 5178, strictPort: true },
  build: { emptyOutDir: false, cssCodeSplit: false, assetsInlineLimit: 1000000, rollupOptions: { output: { inlineDynamicImports: true } } }
};
if (process.argv[2] === 'build') {
  await vite.build(config);
  const outputs = path.resolve(root, '../outputs');
  if (fs.existsSync(outputs)) fs.copyFileSync(path.join(root, 'dist/index.html'), path.join(outputs, 'smart-hospital-interactive.html'));
  console.log('Built offline entry: dist/index.html');
} else {
  const server = await vite.createServer(config); await server.listen(); server.printUrls();
}
