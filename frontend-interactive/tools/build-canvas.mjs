import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.resolve(root, '../outputs');
fs.mkdirSync(outputDir, { recursive: true });

const APP_MARK = "'./dist/index.html'; /* @app-url */";
const APP_OUT = "'./smart-hospital-interactive.html'; /* @app-url */";

// 1) 画布：源文件指向 ./dist/index.html，交付副本改指同目录下的构建产物
const src = path.join(root, 'canvas.html');
let html = fs.readFileSync(src, 'utf8');
if (!html.includes(APP_MARK)) throw new Error('canvas.html 缺少 @app-url 标记，无法改写应用路径');
html = html.replace(APP_MARK, APP_OUT);

const canvasOut = path.join(outputDir, 'smart-hospital-canvas-preview.html');
fs.writeFileSync(canvasOut, html, 'utf8');

// 2) 应用本体：从 dist 刷新到 outputs，保证两个交付件同目录、相对路径可用
const distIndex = path.join(root, 'dist/index.html');
if (!fs.existsSync(distIndex)) throw new Error('未找到 dist/index.html，请先执行 npm run build');
const appOut = path.join(outputDir, 'smart-hospital-interactive.html');
fs.copyFileSync(distIndex, appOut);

const kb = n => Math.round(fs.statSync(n).size / 1024) + ' KB';
console.log('画布 →', path.relative(process.cwd(), canvasOut), kb(canvasOut));
console.log('应用 →', path.relative(process.cwd(), appOut), kb(appOut));
