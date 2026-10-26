import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { browserConfig } from './config.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
await mkdir(path.join(root, 'dist', 'src'), { recursive: true });
await mkdir(path.join(root, 'sql'), { recursive: true });
await copyFile(path.join(root, 'supabase/migrations/20261023000100_voucher_foundation.sql'), path.join(root, 'sql/01_create_voucher_foundation.sql'));
for (const file of ['index.html', 'src/main.js', 'src/domain.mjs', 'src/operations.js', 'src/customers.js', 'src/prepaid.js', 'src/batches.js', 'src/style.css']) {
  await copyFile(path.join(root, file), path.join(root, 'dist', file));
}
const config = await browserConfig(root);
if (config) await writeFile(path.join(root, 'dist/config.js'), `globalThis.PAYSME_VOUCHERS_CONFIG = ${JSON.stringify(config)};\n`);
else await copyFile(path.join(root, 'config.js'), path.join(root, 'dist/config.js'));
const html = await readFile(path.join(root, 'dist/index.html'), 'utf8');
if (!html.includes('/config.js')) throw new Error('Missing browser configuration script.');
console.log('Static portal built in dist/. No npm installation required.');

