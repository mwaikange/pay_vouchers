import { readFile } from 'node:fs/promises';
import path from 'node:path';

export function validateBrowserConfig(url, key) {
  const parsed = new URL(url);
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') throw new Error('Use the Supabase project HTTPS origin.');
  if (key.startsWith('sb_secret_')) throw new Error('A secret key cannot be shipped to the browser.');
  if (!key.startsWith('sb_publishable_')) {
    try {
      const parts = key.split('.');
      if (parts.length !== 3) throw new Error();
      const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
      if (claims.role !== 'anon') throw new Error();
      const projectRef = parsed.hostname.split('.')[0];
      if (claims.ref && claims.ref !== projectRef) throw new Error();
    } catch { throw new Error('Use a publishable key or an anon JWT for this project, never a service-role key.'); }
  }
  if (!key.trim() || key !== key.trim()) throw new Error('Invalid public key.');
  return { supabaseUrl: parsed.origin, supabaseAnonKey: key };
}

export async function browserConfig(root) {
  const settings = {};
  for (const file of ['.env', '.env.local']) {
    let content;
    try { content = await readFile(path.join(root, file), 'utf8'); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    for (const line of content.split(/\r?\n/)) {
      const match = line.match(/^\s*(VITE_SUPABASE_URL|VITE_SUPABASE_ANON_KEY)\s*=\s*(.*?)\s*$/);
      if (match) settings[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2');
    }
  }
  const url = process.env.VITE_SUPABASE_URL || settings.VITE_SUPABASE_URL;
  const key = process.env.VITE_SUPABASE_ANON_KEY || settings.VITE_SUPABASE_ANON_KEY;
  if (!url && !key) {
    const source = await readFile(path.join(root, 'config.js'), 'utf8');
    const match = source.match(/globalThis\.PAYSME_VOUCHERS_CONFIG\s*=\s*(\{[\s\S]*\})\s*;/);
    if (!match) throw new Error('config.js must contain the public configuration as a JSON object.');
    const fallback = JSON.parse(match[1]);
    if (!fallback.supabaseAnonKey) return null;
    return validateBrowserConfig(fallback.supabaseUrl, fallback.supabaseAnonKey);
  }
  if (!url || !key) throw new Error('Set both VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.');
  return validateBrowserConfig(url, key);
}
