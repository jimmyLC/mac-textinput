// Fails the deploy if the public site mentions things it must not, or the release list is malformed.
import { readFileSync, readdirSync } from 'node:fs';
const html = readFileSync(new URL('../public/index.html', import.meta.url), 'utf8');
const bad = [/github/i, /開源|open[- ]?source/i, /@gmail|@hotmail/i];
for (const re of bad) if (re.test(html)) { console.error('public/index.html matches', re); process.exit(1); }
const files = readdirSync(new URL('../public/', import.meta.url));
if (files.join() !== 'index.html') { console.error('unexpected public files:', files); process.exit(1); }
const rel = JSON.parse(readFileSync(new URL('../releases.json', import.meta.url), 'utf8'));
for (const [v, set] of Object.entries(rel)) for (const [n, a] of Object.entries(set))
  if (!/^[0-9a-f]{64}$/.test(a.sha256) || !Number.isInteger(a.bytes) || a.name !== n) { console.error('bad release entry', v, n); process.exit(1); }
console.log('site check ok');
