import {money} from './domain.mjs';
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date=value=>value?new Intl.DateTimeFormat('en-NA',{dateStyle:'medium',timeStyle:'short',timeZone:'Africa/Windhoek'}).format(new Date(value)):'Not recorded';
const readable=value=>String(value||'Not recorded').replaceAll('_',' ');
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
let requestSequence=0;
export function customerRoute(hash){const id=new URLSearchParams(hash.replace(/^#/,'')).get('customer');return id&&uuid.test(id)?id:null;}
function pagination(offset,limit,total){return `<div class="list-pagination"><span>${total?offset+1:0}–${Math.min(offset+limit,total)} of ${total}</span><div><button class="secondary" data-customer-page="${Math.max(0,offset-limit)}" ${offset===0?'disabled':''}>Previous</button><button class="secondary" data-customer-page="${offset+limit}" ${offset+limit>=total?'disabled':''}>Next</button></div></div>`;}
export function customersPage(state){
 if(state.customerId)return customerRecordPage(state);
 const d=state.customerDirectory||{customers:[],total_count:0,offset:0,limit:50,search:''};
 return `<section class="panel"><div class="section-heading"><div><h2>Voucher customers</h2><p>Customers of the PaySME voucher programme. Select a customer to view their voucher purchases.</p></div><span class="badge">${d.total_count} customers</span></div><p class="notice">This directory covers PaySME vouchers only. Electricity, water, airtime and other third-party VAS purchases are outside this programme.</p><form id="customer-search" class="customer-search"><label>Find a voucher customer<input name="search" maxlength="200" value="${esc(d.search)}" placeholder="Name, customer number or mobile"></label><button class="secondary" type="submit" ${state.customerBusy?'disabled':''}>Search</button></form>${state.customerError?`<p class="notice" role="alert">${esc(state.customerError)}</p>`:''}${state.customerBusy?'<p role="status">Loading voucher customers…</p>':`<div class="table-wrap"><table><thead><tr><th>Customer</th><th>Mobile</th><th>Town</th><th>Voucher purchases</th><th>Paid voucher value</th><th>Last purchase</th></tr></thead><tbody>${d.customers.map(c=>`<tr><td><a class="customer-link" href="#customer=${c.id}">${esc(c.full_name||'Voucher customer')}</a><small>CUS-${c.customer_no}</small></td><td>•••• ${esc(c.mobile_last4)}</td><td>${esc(c.town||'Not recorded')}</td><td>${c.purchase_count}</td><td>${money(c.paid_value_cents)}</td><td>${date(c.last_purchase_at)}</td></tr>`).join('')||'<tr><td colspan="6" class="empty">No matching voucher customers. Profiles appear after a voucher purchase is recorded.</td></tr>'}</tbody></table></div>${pagination(d.offset,d.limit,d.total_count)}`}</section>`;
}
function customerRecordPage(state){
 const back='<a href="#customers" class="customer-link">← Back to voucher customers</a>';
 if(state.customerBusy||!state.customerRecord&&!state.customerError)return `<section class="panel">${back}<h2>Customer record</h2><p role="status">Loading voucher purchase history…</p></section>`;
 if(state.customerError)return `<section class="panel">${back}<h2>Customer record unavailable</h2><p role="alert">${esc(state.customerError)}</p><button class="secondary" data-customer-retry>Retry</button></section>`;
 const {profile:c,summary:s,purchases,offset,limit}=state.customerRecord;
 return `<section class="panel">${back}<div class="section-heading customer-record-heading"><div><span class="eyebrow">CUS-${c.customer_no} · PAYSME VOUCHERS</span><h2>${esc(c.full_name||'Voucher customer')}</h2></div><span class="badge">Voucher programme only</span></div><dl class="customer-profile"><div><dt>Mobile</dt><dd>${esc(c.mobile_number)}</dd></div><div><dt>Email</dt><dd>${esc(c.email||'Not recorded')}</dd></div><div><dt>Town</dt><dd>${esc(c.town||'Not recorded')}</dd></div><div><dt>Last voucher purchase</dt><dd>${date(s.last_purchase_at)}</dd></div></dl></section><div class="stats">${[['Voucher purchases',s.purchase_count],['Paid voucher purchases',s.paid_purchase_count],['Paid voucher value',money(s.paid_value_cents)],['Vouchers redeemed',s.redeemed_count]].map(([label,value])=>`<article><span>${label}</span><strong>${esc(value)}</strong></article>`).join('')}</div><section class="panel"><h2>Voucher purchase history</h2><p>All voucher purchases for this customer, across supplier companies. Cancelled and refunded sale records remain visible; paid voucher value includes only sales currently marked paid.</p><div class="table-wrap"><table><thead><tr><th>Sale / date</th><th>Company / product</th><th>Voucher</th><th>Customer paid</th><th>Store / town</th><th>Payment order / receipt</th></tr></thead><tbody>${purchases.map(p=>`<tr><td><b>#${p.sale_no}</b><small>${date(p.paid_at)}</small><small>${esc(readable(p.sale_status))}</small></td><td><b>${esc(p.supplier_name)}</b><small>${esc(p.product_name)}${p.product_no?' · #'+p.product_no:''}</small></td><td>${esc(p.voucher_code||'Not issued')}<small>${esc(readable(p.voucher_status))}</small></td><td>${money(p.customer_price_cents)}</td><td>${esc(p.branch_name||'Not selected')}<small>${esc(p.recipient_town)}</small></td><td>${esc(p.batch_reference||'Not batched')}<small>${esc(p.receipt_reference||'Not redeemed')}</small></td></tr>`).join('')||'<tr><td colspan="6" class="empty">No voucher purchases on this page.</td></tr>'}</tbody></table></div>${pagination(offset,limit,s.purchase_count)}</section>`;
}
export function bindCustomers({db,state,render}){
 if(state.page!=='customers')return;
 const get=async(detail,offset=0,search='')=>{
  const request=++requestSequence,id=state.customerId;
  state.customerBusy=true;state.customerError='';render();
  try{
   const {data,error}=await db.rpc(detail?'paysme_voucher_customer_record':'paysme_voucher_customer_directory',detail?{p_customer_id:id,p_offset:offset,p_limit:50}:{p_search:search,p_offset:offset,p_limit:50});
   if(request!==requestSequence||!state.staff||state.page!=='customers'||state.customerId!==id)return;
   if(error)throw error;if(detail&&!data)throw new Error('This customer has no voucher-programme purchase record.');
   if(detail)state.customerRecord=data;else {state.customerDirectory=data;state.customers=data.customers;}
  }catch(error){if(request!==requestSequence||!state.staff||state.page!=='customers'||state.customerId!==id)return;state.customerError=error.message||'Unable to load voucher purchases.';}
  finally{if(request===requestSequence){state.customerBusy=false;if(state.staff&&state.page==='customers'&&state.customerId===id)render();}}
 };
 if(state.customerId&&!state.customerRecord&&!state.customerBusy&&!state.customerError){void get(true);return;}
 document.querySelector('#customer-search')?.addEventListener('submit',event=>{event.preventDefault();void get(false,0,new FormData(event.currentTarget).get('search').trim());});
 document.querySelectorAll('[data-customer-page]').forEach(button=>button.onclick=()=>{if(!state.customerBusy)void get(Boolean(state.customerId),Number(button.dataset.customerPage),state.customerDirectory?.search||'');});
 document.querySelector('[data-customer-retry]')?.addEventListener('click',()=>{void get(true,state.customerRecord?.offset||0);});
}
