import {salesPage,settlementsPage,reportsPage,bindOperations,showConfirmation} from './operations.js';
import {customersPage,bindCustomers,customerRoute} from './customers.js';
import { approvalEmails, pricing, money, toCents, catalogueImageExtension } from './domain.mjs';

const root = document.querySelector('#app');
const config = globalThis.PAYSME_VOUCHERS_CONFIG || {};
const url = config.supabaseUrl;
const key = config.supabaseAnonKey;
const createClient = globalThis.supabase?.createClient;
const db = url && key && createClient ? createClient(url, key, { auth: { storageKey: 'paysme-vouchers-staff-auth' } }) : null;
const state = { page: customerRoute(location.hash) ? 'customers' : 'overview', staff: null, suppliers: [], products: [], branches: [], customers: [], images: [], notice: '', companyId: '', companies: [], financeLoading: false, customerId: customerRoute(location.hash), customerRecord: null, customerBusy: false, customerError: '', towns: [] };
let generation = 0;
const confirmationToken=new URLSearchParams(location.hash.slice(1)).get('confirm');
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const canWrite = () => state.staff && state.staff.role !== 'viewer';
const canManageSuppliers = () => state.staff?.role === 'admin';
const supplierName = id => state.suppliers.find(s => s.id === id)?.business_name || 'Supplier';
const badge = active => `<span class="badge ${active ? 'green' : ''}">${active ? 'Active' : 'Inactive'}</span>`;
const pricingHelp = {
  "supplier": "The agreed supplier price before any additional rebate, inclusive of VAT. Example: N$500. If this already includes every supplier discount, leave the separate rebate at zero.",
  "markup": "The VAT-inclusive amount added to the supplier base price to set the customer price. Supplier N$500 + markup N$20 = customer N$520. Vendors already benefit from their account top-up discount; no additional voucher commission is paid.",
  "instore": "The normal VAT-inclusive store price for the same product. It is used to show the customer saving, not to calculate supplier payment. Store N$600 minus customer N$520 = saving N$80.",
  "rebate": "An additional VAT-inclusive discount or rebate agreed with the supplier, separate from the base price and markup. Do not enter a discount twice. Example: a further N$10 rebate on a N$500 base price.",
  "rebate_timing": "Earned / received later: pay the supplier N$500 now and claim or receive the N$10 rebate later. Deduct from settlement: pay N$490 now. Neither option changes the customer price.",
  "commission": "No additional vendor commission is paid on voucher sales. Vendors already receive their benefit as a discount when topping up their account. This value is fixed at zero.",
  "entitlement_type": "Specified product / combo: the voucher is exchanged for the listed products. Store credit: the voucher provides a defined amount to spend at the supplier. Store credit value is entered separately from the customer purchase price.",
  "redemption_value": "For store-credit vouchers only: the VAT-inclusive shopping value the customer can spend. Example: N$600 store credit sold for N$520. Leave this blank for a specified product or combo; its normal store price does not automatically become cash credit."
};
function labeledControl(label, name, control) {
  const help = pricingHelp[name];
  if (!help) return `<label>${esc(label)}${control}</label>`;
  const id = `editor-${name}`, helpId = `${id}-help`;
  const input = control.replace(/^<(input|select)/, tag => `${tag} id="${id}" aria-describedby="${helpId}"`);
  return `<div class="help-field"><div class="field-heading"><label for="${id}">${esc(label)}</label><button type="button" class="info-button" data-field-help aria-expanded="false" aria-controls="${helpId}" aria-label="Explain ${esc(label)}" title="${esc(help)}"><span aria-hidden="true">i</span></button></div>${input}<p class="field-help" id="${helpId}" hidden>${esc(help)}</p></div>`;
}
const field = (label, name, value = '', type = 'text', required = false) => labeledControl(label, name, `<input name="${name}" type="${type}" value="${esc(value)}" ${required ? 'required' : ''} ${type === 'number' ? 'min="0" step="0.01"' : ''}>`);
const textArea = (label, name, value = '') => `<label class="wide">${esc(label)}<textarea name="${name}" rows="3">${esc(value)}</textarea></label>`;
const select = (label, name, options, current = '') => labeledControl(label, name, `<select name="${name}" required>${options.map(([value, title]) => `<option value="${esc(value)}" ${value === current ? 'selected' : ''}>${esc(title)}</option>`).join('')}</select>`);
const statusField = active => select('Status', 'active', [['true', 'Active'], ['false', 'Inactive']], String(active ?? true));

function showLogin(message = '') {
  const setupMessage = !createClient ? 'The Supabase client could not load. Check the browser connection and reload this page.' : 'Connection setup required. Enter the project publishable/anon key in config.js or .env.local.';
  root.innerHTML = `<main class="login"><div class="brand">P<span>▰</span> PaySME <small>VOUCHERS</small></div><section class="login-card"><span class="eyebrow">STAFF WORKSPACE</span><h1>Welcome back.</h1><p>Manage suppliers and your voucher catalogue.</p>${message ? `<p role="alert" class="notice">${esc(message)}</p>` : ''}${db ? `<form id="login">${field('Email address', 'email', '', 'email', true)}${field('Password', 'password', '', 'password', true)}<button type="submit">Sign in →</button></form><p class="muted">Access is available to authorized PaySME staff.</p>` : `<p class="notice">${setupMessage}</p>`}</section><p class="login-footer">Supplier confirmation links do not require a staff account.</p></main>`;
  const form = document.querySelector('#login');
  if (form) {
    form.elements.email.autocomplete = 'username'; form.elements.password.autocomplete = 'current-password';
    form.addEventListener('submit', async event => {
      event.preventDefault(); const button = form.querySelector('button'); button.disabled = true; button.textContent = 'Signing in…';
      try {
        const data = new FormData(form);
        const { error } = await db.auth.signInWithPassword({ email: data.get('email').trim(), password: data.get('password') });
        if (error) throw error;
      } catch { showLogin('Unable to sign in. Check your credentials and try again.'); }
    });
  }
}

async function loadWorkspace() {
  const current = ++generation;
  try {
    const { data: { user }, error: userError } = await db.auth.getUser();
    if (current !== generation) return;
    if (userError || !user) { state.staff = null; showLogin(); return; }
    const { data: access, error } = await db.rpc('paysme_voucher_access_context');
    const staff = access?.[0];
    if (error) throw new Error('Voucher database setup is not available. Ask the PaySME administrator to verify the migration.');
    if (!staff?.active) {
      await db.auth.signOut(); showLogin('Your account does not have active PaySME Vouchers staff access.'); return;
    }
    const scoped = query => state.companyId ? query.eq('supplier_id',state.companyId) : query;
    const tables = ['suppliers', 'products', 'branches', 'customerDirectory', 'images','sales','vouchers','batches','redemptions','analytics','companies','towns'];
    const results = await Promise.all([
      db.from('paysme_voucher_suppliers').select('*').order('created_at', { ascending: false }).limit(250),
      db.from('paysme_voucher_products').select('*').order('created_at', { ascending: false }).limit(250),
      db.from('paysme_voucher_branches').select('*').order('town').limit(250),
      db.rpc('paysme_voucher_customer_directory',{p_search:state.customerDirectory?.search||'',p_offset:state.customerDirectory?.offset||0,p_limit:50}),
      db.from('paysme_voucher_product_images').select('*').order('created_at').limit(1000),
      scoped(db.from('paysme_voucher_sales').select('*,paysme_vouchers(code,status),paysme_voucher_suppliers(business_name)').order('paid_at',{ascending:false})).limit(1000),
      db.from('paysme_vouchers').select('*').order('created_at',{ascending:false}).limit(1000),
      scoped(db.from('paysme_voucher_payment_batches').select('*').order('created_at',{ascending:false})).limit(1000),
      scoped(db.from('paysme_voucher_redemptions').select('*').order('redeemed_at',{ascending:false})).limit(1000),
      db.rpc('paysme_voucher_company_overview',{p_supplier_id:state.companyId||null}),
      db.rpc('paysme_voucher_companies'),
      db.from('namibian_towns').select('name').eq('is_active',true).order('name').limit(1000)
    ]);
    if (current !== generation) return;
    for (const result of results) if (result.error) throw result.error;
    state.staff = staff;
    results.forEach((result, index) => { state[tables[index]] = result.data; });
    state.customers = state.customerDirectory.customers;
    state.financeLoading = false;
    render();
  } catch (error) {
    if (current !== generation) return;
    state.staff = null;
    root.innerHTML = `<main class="login"><section class="login-card"><h1>Workspace unavailable</h1><p role="alert">${esc(error.message)}</p><button id="retry">Retry</button><button id="exit" class="secondary">Sign out</button></section></main>`;
    document.querySelector('#retry').onclick = loadWorkspace;
    document.querySelector('#exit').onclick = () => db.auth.signOut();
  }
}

function overview() {
  return `<div class="hero"><div><span class="eyebrow">YOUR VOUCHER NETWORK</span><h2>More value.<br>More possibilities.</h2><p>Build the catalogue that connects businesses<br>with PaySME customers.</p><button data-action="supplier" ${canWrite() ? '' : 'disabled'}>Add a supplier ↗</button></div><div class="ticket"><span>PaySME VOUCHERS</span><div class="ticket-line"></div><strong>Built for<br>everyday value.</strong><span>BUSINESSES · PRODUCTS · PEOPLE</span></div></div><div class="stats">${[['Suppliers loaded', state.suppliers.length], ['Products loaded', state.products.length], ['Branches loaded', state.branches.length], ['Voucher customers', state.customerDirectory.total_count]].map(([label, count]) => `<article><span>${label}</span><strong>${count}</strong></article>`).join('')}</div><section class="panel"><div class="section-heading"><div><h2>Your first steps</h2><p>Prepare the network before voucher sales begin.</p></div><span class="badge">Voucher operations</span></div><div class="steps"><article><b>01</b><h3>Load suppliers</h3><p>Business details and the two finance approval contacts.</p></article><article><b>02</b><h3>Build the catalogue</h3><p>Product contents, pictures, customer pricing and supplier terms.</p></article><article><b>03</b><h3>Prepare settlement</h3><p>Review payment batches, supplier confirmation and redemption records.</p></article></div></section><p class="muted">Lists load up to 250 suppliers, products and branches, and paginated voucher customer profiles. Supplier, product and branch counts describe loaded records.</p>`;
}
function suppliers() {
  return `<section class="panel"><div class="section-heading"><div><h2>Supplier directory</h2><p>Manage businesses and payment approval contacts.</p></div><button data-action="supplier" ${canWrite() ? '' : 'disabled'}>+ Add supplier</button></div><div class="table-wrap"><table><thead><tr><th>Business</th><th>Finance confirmation</th><th>Supervisor approval</th><th>Status</th><th></th></tr></thead><tbody>${state.suppliers.map(s => `<tr><td><b>${esc(s.business_name)}</b><small>SUP-${s.supplier_no}</small></td><td>${esc(s.finance_email)}</td><td>${esc(s.supervisor_email)}</td><td>${badge(s.active)}</td><td><button class="text-button" data-action="supplier" data-id="${s.id}">${canWrite() ? 'Edit' : 'View'}</button></td></tr>`).join('') || '<tr><td colspan="5" class="empty">Add your first supplier to start building the catalogue.</td></tr>'}</tbody></table></div></section><section class="panel"><div class="section-heading"><div><h2>Branches & towns</h2><p>Collection locations for supplier planning.</p></div><button class="secondary" data-action="branch" ${canWrite() && state.suppliers.length ? '' : 'disabled'}>+ Add branch</button></div><div class="branch-list">${state.branches.map(b => `<button class="branch" data-action="branch" data-id="${b.id}"><b>${esc(b.name)}</b><span>${esc(supplierName(b.supplier_id))} · ${esc(b.town)}</span>${badge(b.active)}</button>`).join('') || '<p class="empty">No branches added yet.</p>'}</div></section>`;
}
function products() {
  return `<section><div class="section-heading"><div><h2>Product catalogue</h2><p>All prices include VAT and the PaySME markup. Rebates are recorded separately.</p></div><button data-action="product" ${canWrite() && state.suppliers.length ? '' : 'disabled'}>+ Add product</button></div><div class="products">${state.products.map(p => {
    const picture = state.images.find(i => i.product_id === p.id);
    const pictureUrl = picture && db.storage.from('paysme-voucher-products').getPublicUrl(picture.object_path).data.publicUrl;
    return `<article class="product-card">${pictureUrl ? `<img src="${esc(pictureUrl)}" alt="${esc(picture.alt_text || p.name)}" loading="lazy">` : '<div class="product-placeholder">PaySME<span>VOUCHERS</span></div>'}<div class="product-body"><div class="section-heading"><small>${esc(supplierName(p.supplier_id))} · #${p.product_no}</small>${badge(p.active)}</div><h3>${esc(p.name)}</h3><p>${esc(p.product_list || p.description || 'No description yet.')}</p><strong>${money(p.customer_price_cents)}</strong><div class="price-meta"><span>In store ${money(p.instore_price_cents)}</span><span>${p.instore_price_cents >= p.customer_price_cents ? 'Save ' + money(p.instore_price_cents - p.customer_price_cents) : 'Above reference price'}</span></div><div class="card-actions"><button class="secondary" data-action="product" data-id="${p.id}">${canWrite() ? 'Edit product' : 'View product'}</button>${canWrite() ? `<button class="text-button" data-action="image" data-id="${p.id}">Add picture</button>` : ''}</div></div></article>`;
  }).join('') || '<div class="panel empty">Add a supplier, then create your first product.</div>'}</div></section>`;
}
function customers() { return customersPage(state); }
function render() {
  const pages = { overview, suppliers, products, customers, sales:()=>salesPage(state), settlements:()=>settlementsPage(state), reports:()=>reportsPage(state) };
  root.innerHTML = `<div class="workspace"><aside><div class="brand">P<span>▰</span> PaySME<small>VOUCHERS</small></div><div class="nav-label">WORKSPACE</div><nav>${Object.keys(pages).map(page => `<button data-page="${page}" class="${state.page === page ? 'selected' : ''}">${{ overview: '◈', suppliers: '▦', products: '▱', customers: '◎' }[page]||'•'} <span>${page[0].toUpperCase() + page.slice(1)}</span></button>`).join('')}</nav><div class="sidebar-note"><b>Made for everyday value.</b><p>Powered by PaySME</p></div></aside><div class="content"><header><div><span class="eyebrow">PAYSME VOUCHERS</span><h1>${state.page[0].toUpperCase() + state.page.slice(1)}</h1></div><div class="account"><span><b>${esc(state.staff.display_name)}</b><small>${esc(state.staff.role)}</small></span><button class="secondary" id="signout">Sign out</button></div></header><main><p class="currency-note">All monetary amounts are in N$ and inclusive of VAT. No additional VAT is added.</p>${state.notice ? `<p class="notice" role="status">${esc(state.notice)}</p>` : ''}${pages[state.page]()}</main></div></div>`;
  document.querySelectorAll('[data-page]').forEach(button => { button.onclick = () => { state.page = button.dataset.page; state.notice = ''; if(state.page !== 'customers') { state.customerId=null; state.customerRecord=null; state.customerBusy=false; state.customerError=''; if(location.hash.startsWith('#customer')) history.replaceState(null,'',location.pathname+location.search); } render(); }; });
  document.querySelectorAll('[data-action]').forEach(button => {
    if (button.dataset.action === 'supplier' && !canManageSuppliers()) {
      if (button.dataset.id) button.textContent = 'View'; else button.disabled = true;
    }
    button.onclick = () => openEditor(button.dataset.action, button.dataset.id);
  });
  bindOperations({db,state,reload:loadWorkspace});
  bindCustomers({db,state,render});
  document.querySelector('[data-company-filter]')?.addEventListener('change',async event=>{
    state.companyId=event.currentTarget.value;
    state.financeLoading=true;render();
    await loadWorkspace();
  });
  document.querySelector('#signout').onclick = async () => { generation++; state.staff = null; state.notice = ''; state.companyId=''; state.customerId=null; state.customerRecord=null; state.customerDirectory=null; state.customerBusy=false; state.customerError=''; state.sales=[]; state.vouchers=[]; state.batches=[]; state.redemptions=[]; state.analytics=null; state.companies=[]; state.suppliers = []; state.products = []; state.customers = []; state.branches = []; state.images = []; await db.auth.signOut(); showLogin(); };
}

function openEditor(kind, id) {
  let data = {}, body = '', table = '';
  const supplierOptions = state.suppliers.map(s => [s.id, s.business_name]);
  if (kind === 'supplier') {
    data = state.suppliers.find(s => s.id === id) || {}; table = 'paysme_voucher_suppliers';
    body = field('Business name', 'business_name', data.business_name, 'text', true) + field('Registration number', 'registration_number', data.registration_number) + field('Finance contact name', 'finance_contact_name', data.finance_contact_name, 'text', true) + field('Finance confirmation email', 'finance_email', data.finance_email, 'email', true) + field('Supervisor name', 'supervisor_name', data.supervisor_name, 'text', true) + field('Supervisor approval email', 'supervisor_email', data.supervisor_email, 'email', true) + field('Operational contact email', 'support_email', data.support_email, 'email') + statusField(data.active) + textArea('Settlement terms / notes', 'settlement_terms', data.settlement_terms);
    const logoUrl = data.logo_path && db.storage.from('paysme-voucher-products').getPublicUrl(data.logo_path).data.publicUrl;
    body += `<section class="wide supplier-logo-upload"><label>Supplier logo (optional)<input name="logo" type="file" accept="image/jpeg,image/png,image/webp"></label><p class="muted">JPEG, PNG or WebP, up to 5 MB. Shown to vendors when selecting this supplier.</p>${logoUrl ? `<img src="${esc(logoUrl)}" alt="${esc(data.business_name || 'Supplier')} logo" width="100" height="100" style="object-fit:contain">` : ''}<img id="supplier-logo-preview" alt="Selected supplier logo" width="100" height="100" style="object-fit:contain" hidden></section>`;
  } else if (kind === 'branch') {
    data = state.branches.find(b => b.id === id) || {}; table = 'paysme_voucher_branches';
    body = select('Supplier', 'supplier_id', supplierOptions, data.supplier_id) + field('Branch name', 'name', data.name, 'text', true) + select('Town', 'town', [['','Select town'], ...state.towns.map(t=>[t.name,t.name])], data.town || '') + statusField(data.active) + textArea('Address', 'address', data.address);
  } else if (kind === 'product') {
    data = state.products.find(p => p.id === id) || {}; table = 'paysme_voucher_products';
    const price = name => data[name] === undefined ? '0.00' : (Number(data[name]) / 100).toFixed(2);
    body = '<p class="notice wide">All amounts entered below are inclusive of VAT. Do not add VAT again. Select an i button for an explanation.</p>' + select('Supplier', 'supplier_id', supplierOptions, data.supplier_id) + field('Product name', 'name', data.name, 'text', true) + select('Customer entitlement', 'entitlement_type', [['product_bundle', 'Specified product / combo'], ['store_credit', 'Store credit']], data.entitlement_type || 'product_bundle') + statusField(data.active) + textArea('Description', 'description', data.description) + textArea('Product list / contents', 'product_list', data.product_list) + field('Supplier base price (N$)', 'supplier', price('supplier_price_cents'), 'number', true) + field('PaySME markup (N$)', 'markup', price('markup_cents'), 'number', true) + field('In-store reference price (N$)', 'instore', price('instore_price_cents'), 'number', true) + field('Supplier rebate (N$)', 'rebate', price('rebate_cents'), 'number', true) + select('Rebate treatment', 'rebate_timing', [['later', 'Earned / received later'], ['immediate', 'Deduct from settlement']], data.rebate_timing || 'later') + field('Vendor commission (N$)', 'commission', price('vendor_commission_cents'), 'number', true) + '<p class="notice wide" id="price-preview"></p>';
    body += field('Store credit value (N$, required only for store credit)', 'redemption_value', data.redemption_value_cents ? (Number(data.redemption_value_cents) / 100).toFixed(2) : '', 'number');
  } else if (kind === 'image') {
    body = '<p class="wide">Catalogue pictures only. JPEG, PNG or WebP, up to 5 MB.</p><label class="wide">Picture<input name="image" type="file" accept="image/jpeg,image/png,image/webp" required></label>' + field('Picture description', 'alt_text', '', 'text', true);
  } else return;
  const dialog = document.createElement('dialog');
  dialog.innerHTML = `<div class="section-heading"><h2>${id && kind !== 'image' ? 'Edit' : 'Add'} ${kind === 'image' ? 'product picture' : kind}</h2><button class="text-button" type="button" id="close-editor" aria-label="Close">✕</button></div><form id="editor"><div class="form-grid">${body}</div><p id="form-error" role="alert"></p><div class="dialog-actions"><button type="button" class="secondary" id="cancel-editor">Cancel</button>${canWrite() ? '<button type="submit">Save</button>' : ''}</div></form>`;
  document.body.append(dialog); dialog.showModal();
  const close = () => dialog.close();
  dialog.addEventListener('close', () => dialog.remove(), { once: true });
  dialog.querySelector('#close-editor').onclick = close; dialog.querySelector('#cancel-editor').onclick = close;
  const form = dialog.querySelector('form');
  if (kind === 'supplier') {
    let previewUrl;
    form.elements.logo.onchange = () => {
      const image = dialog.querySelector('#supplier-logo-preview');
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      image.hidden = true;
      const file = form.elements.logo.files[0];
      if (!file) return;
      try { catalogueImageExtension(file); previewUrl = URL.createObjectURL(file); image.src = previewUrl; image.hidden = false; dialog.querySelector('#form-error').textContent = ''; }
      catch (error) { dialog.querySelector('#form-error').textContent = error.message; }
    };
    dialog.addEventListener('close', () => { if (previewUrl) URL.revokeObjectURL(previewUrl); }, { once: true });
  }
  if (kind === 'product') {
    form.elements.commission.value = '0.00';
    form.elements.commission.readOnly = true;
  }
  dialog.querySelectorAll('[data-field-help]').forEach(button => {
    button.onclick = () => {
      const expanded = button.getAttribute('aria-expanded') === 'true';
      button.setAttribute('aria-expanded', String(!expanded));
      dialog.querySelector('#' + button.getAttribute('aria-controls')).hidden = expanded;
    };
  });
  const editable = kind === 'supplier' ? canManageSuppliers() : canWrite();
  if (!editable) form.querySelector('[type="submit"]')?.remove();
  const preview = () => {
    if (kind !== 'product') return;
    try { const p = pricing(Object.fromEntries(new FormData(form))); dialog.querySelector('#price-preview').textContent = `Customer pays ${money(p.customerCents)} · Saving ${money(p.savingCents)}. All amounts include VAT. No additional vendor commission.`; }
    catch (error) { dialog.querySelector('#price-preview').textContent = error.message; }
  };
  form.addEventListener('input', preview); preview();
  if (!editable) form.querySelectorAll('input,textarea,select').forEach(element => { element.disabled = true; });
  form.onsubmit = async event => {
    event.preventDefault(); if (!editable) return;
    const saveButton = form.querySelector('[type="submit"]'); saveButton.disabled = true;
    const errorBox = dialog.querySelector('#form-error'); errorBox.textContent = '';
    try {
      const values = Object.fromEntries(new FormData(form));
      let result;
      if (kind === 'image') {
        const file = values.image;
        const extension = catalogueImageExtension(file);
        const path = `${id}/${crypto.randomUUID()}.${extension}`;
        const upload = await db.storage.from('paysme-voucher-products').upload(path, file, { contentType: file.type, upsert: false });
        if (upload.error) throw upload.error;
        result = await db.from('paysme_voucher_product_images').insert({ product_id: id, object_path: path, alt_text: values.alt_text.trim() });
        if (result.error) throw new Error('The picture uploaded, but its catalogue record could not be saved. Ask an administrator to review storage before retrying.');
      } else {
        let payload = { ...values, active: values.active === 'true' };
        delete payload.logo;
        Object.keys(payload).forEach(k => { if (typeof payload[k] === 'string') payload[k] = payload[k].trim(); });
        if (kind === 'supplier') {
          Object.assign(payload, approvalEmails(values.finance_email, values.supervisor_email));
          if (values.logo?.size) {
            const extension = catalogueImageExtension(values.logo);
            const supplierId = id || crypto.randomUUID();
            const path = `suppliers/${supplierId}/${crypto.randomUUID()}.${extension}`;
            const upload = await db.storage.from('paysme-voucher-products').upload(path, values.logo, { contentType: values.logo.type, upsert: false });
            if (upload.error) throw upload.error;
            payload.logo_path = path;
            if (!id) payload.id = supplierId;
          }
        }
        if (kind === 'branch' && !state.towns.some(t=>t.name===payload.town)) throw new Error('Select a town from the list.');
        if (kind === 'product') {
          values.commission = '0';
          const p = pricing(values);
          for (const name of ['supplier', 'markup', 'instore', 'rebate', 'commission', 'redemption_value']) delete payload[name];
          const creditValue = values.entitlement_type === 'store_credit' ? toCents(values.redemption_value) : null;
          if (creditValue === 0) throw new Error('Enter a store credit value greater than zero.');
          payload.redemption_value_cents = creditValue;
          Object.assign(payload, { supplier_price_cents: p.supplierCents, markup_cents: p.markupCents, instore_price_cents: p.instoreCents, rebate_cents: p.rebateCents, vendor_commission_cents: p.commissionCents });
        }
        result = id ? await db.from(table).update(payload).eq('id', id).select('id').single() : await db.from(table).insert(payload).select('id').single();
        if (result.error) throw result.error;
      }
      state.notice = 'Saved successfully.'; close(); await loadWorkspace();
    } catch (error) { errorBox.textContent = error.message; saveButton.disabled = false; }
  };
}

window.addEventListener('hashchange',()=>{
  if(!state.staff||confirmationToken)return;
  const id=customerRoute(location.hash);
  if(id||location.hash==='#customers') {
    state.page='customers';state.customerId=id;state.customerRecord=null;state.customerBusy=false;state.customerError='';render();
  }
});

if(confirmationToken&&db){showConfirmation({db,root,token:confirmationToken});}
else {
showLogin();
if (db) {
  db.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') { generation++; state.staff = null; document.querySelectorAll('dialog').forEach(d => d.close()); showLogin(); }
    else if (event === 'INITIAL_SESSION' || event === 'SIGNED_IN') setTimeout(loadWorkspace, 0);
  });
}

}

