import {money,toCents,paymentProofExtension} from './domain.mjs';
import {bindBatchRecords} from './batches.js';
import {showCreditConfirmation} from './prepaid.js';
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const status=value=>`<span class="badge">${esc(value.replaceAll('_',' '))}</span>`;
const date=value=>new Intl.DateTimeFormat('en-NA',{dateStyle:'medium',timeStyle:'short',timeZone:'Africa/Windhoek'}).format(new Date(value));
const options=(rows,label,key='id')=>rows.map(row=>`<option value="${esc(row[key])}">${esc(label(row))}</option>`).join('');
const input=(label,name,type='text',extra='')=>`<label>${label}<input name="${name}" type="${type}" required ${extra}></label>`;
export function companySelector(state) {
 const companies=state.companies||state.suppliers;
 const selected=companies.find(c=>c.id===state.companyId);
 return `<section class="company-filter"><label for="company-filter">Company<select id="company-filter" data-company-filter ${state.financeLoading?'disabled':''}><option value="">All companies</option>${companies.map(c=>`<option value="${esc(c.id)}" ${c.id===state.companyId?'selected':''}>${esc(c.business_name)}${c.active?'':' (inactive)'}</option>`).join('')}</select></label><p>${selected?'Showing '+esc(selected.business_name)+' only.':'Combined view across all supplier companies.'}</p></section>`;
}
const loading = state => companySelector(state)+'<section class="panel"><p role="status">Loading company records…</p></section>';
export async function command(db,action,args) {
 const {data,error}=await db.functions.invoke('paysme-vouchers',{body:{action,args}});
 if(error){let detail;try{detail=await error.context?.json();}catch{}throw new Error(detail?.error||'Could not complete the request. Check the connection and current status.');}
 if(data?.error)throw new Error(data.error);return data;
}
export function salesPage(state) {
 if(state.financeLoading)return loading(state);
 const supplier=id=>(state.companies||state.suppliers).find(x=>x.id===id)?.business_name||id;
 return companySelector(state)+`<section class="panel"><div class="section-heading"><div><h2>Voucher sales</h2><p>Voucher purchases and purchase-time pricing for the selected company view.</p></div><button data-op="refresh" class="secondary">Refresh</button></div><div class="table-wrap"><table><thead><tr><th>Sale / product</th><th>Voucher</th><th>Supplier / town</th><th>Customer paid</th><th>Supplier due</th><th>Paid at</th></tr></thead><tbody>${state.sales.map(s=>{
 const v=s.paysme_vouchers||state.vouchers.find(x=>x.sale_id===s.id);return `<tr><td><b>#${s.sale_no} · ${esc(s.product_name)}</b><small>${esc(s.status)}</small></td><td>${esc(v?.code||'Unavailable')}<small>${esc(v?.status?.replaceAll('_',' ')||'')}</small></td><td>${esc(s.paysme_voucher_suppliers?.business_name||supplier(s.supplier_id))}<small>${esc(s.recipient_town||'Not recorded')}</small></td><td>${money(s.customer_price_cents)}</td><td>${money(s.supplier_due_cents)}</td><td>${date(s.paid_at)}</td></tr>`;
 }).join('')||'<tr><td colspan="6" class="empty">No paid voucher sales yet. Catalogue setup is available now; wallet purchase integration is reserved for the final phase.</td></tr>'}</tbody></table></div></section>`;
}
export function settlementsPage(state) {
 if(state.financeLoading)return loading(state);
 const admin=state.staff.role==='admin';
 return companySelector(state)+`<section class="panel"><div class="section-heading"><div><h2>Supplier settlement</h2><p>One payment order covers its fixed list of vouchers. Only supplier confirmation releases them.</p></div><button data-op="prepare_batch" ${admin?'':'disabled'}>Prepare payment batch</button></div><div class="table-wrap"><table><thead><tr><th>Payment order</th><th>Supplier</th><th>Vouchers</th><th>Due</th><th>Redeemed</th><th>Status</th><th></th></tr></thead><tbody>${state.batches.map(b=>`<tr><td><b>${esc(b.batch_reference)}</b><small>${date(b.created_at)}</small></td><td>${esc(b.supplier_name)}</td><td>${b.voucher_count}</td><td>${money(b.amount_due_cents)}</td><td>${b.redeemed_count} / ${b.voucher_count}</td><td>${status(b.status)}</td><td><button class="text-button" data-op="batch_details" data-id="${b.id}">Review</button></td></tr>`).join('')||'<tr><td colspan="7" class="empty">No payment batches. Eligible paid vouchers will be grouped by supplier.</td></tr>'}</tbody></table></div></section><section class="panel"><h2>Supplier API credentials</h2><p>Suppliers use server credentials for redemption. They do not need staff accounts. Keep the credential ID for rotation; the secret is shown once.</p><div class="dialog-actions"><button class="secondary" data-op="issue_api_key" ${admin?'':'disabled'}>Issue credential</button><button class="secondary" data-op="revoke_api_key" ${admin?'':'disabled'}>Revoke credential</button></div></section>`;
}
export function reportsPage(state) {
 if(state.financeLoading)return loading(state);
 const due=state.analytics.pending_settlement_cents;
 const consumed=state.analytics.settlement_consumed_cents;
 const planning=state.analytics.planning;
 return companySelector(state)+`<div class="stats">${[['Payment orders',state.analytics.batch_count],['Awaiting settlement',money(due)],['Supplier funding consumed',money(consumed)],['Redemptions',state.analytics.redemption_count]].map(([label,value])=>`<article><span>${label}</span><strong>${esc(value)}</strong></article>`).join('')}</div><section class="panel"><h2>Supplier collection planning</h2><p>Unredeemed paid vouchers by product, recipient town and planned store.</p><div class="table-wrap"><table><thead><tr><th>Company</th><th>Product</th><th>Town</th><th>Planned store</th><th>Vouchers</th></tr></thead><tbody>${planning.map(p=>`<tr><td>${esc(p.supplier_name)}</td><td>${esc(p.product_name)}</td><td>${esc(p.recipient_town)}</td><td>${esc(p.branch_name)}</td><td>${p.voucher_count}</td></tr>`).join('')||'<tr><td colspan="5" class="empty">Planning appears when vouchers are sold.</td></tr>'}</tbody></table></div></section><section class="panel"><h2>Redemption receipts</h2><div class="table-wrap"><table><thead><tr><th>Receipt</th><th>Company</th><th>Voucher</th><th>Redeemed at</th><th>Settlement used</th></tr></thead><tbody>${state.redemptions.map(r=>`<tr><td>${esc(r.receipt_reference)}</td><td>${esc(r.receipt_data.supplier_name||(state.companies||state.suppliers).find(c=>c.id===r.supplier_id)?.business_name||r.supplier_id)}</td><td>${esc(r.receipt_data.voucher_code)}</td><td>${date(r.redeemed_at)}</td><td>${money(r.supplier_due_consumed_cents)}</td></tr>`).join('')||'<tr><td colspan="5" class="empty">No redemptions yet.</td></tr>'}</tbody></table></div></section><p class="muted">Operational lists load the latest 1,000 sales, vouchers, payment orders and redemptions. The summary figures and planning include all records for the selected company view; receipt and sale lists show its latest 1,000 records. These views cover the PaySME voucher programme only. Electricity, water, airtime and other third-party VAS products are excluded.</p>`;
}
function dialog(title,body){const d=document.createElement('dialog');d.innerHTML=`<div class="section-heading"><h2>${esc(title)}</h2><button class="text-button" data-close aria-label="Close">Close</button></div>${body}`;document.body.append(d);d.querySelector('[data-close]').onclick=()=>d.close();d.addEventListener('close',()=>d.remove(),{once:true});d.showModal();return d;}
export function bindOperations({db,state,reload}) {
 document.querySelectorAll('[data-op]:not([data-op="batch_details"])').forEach(button=>button.onclick=async()=>{
  const action=button.dataset.op,id=button.dataset.id;
  if(action==='refresh'){await reload();return;}
  const admin=state.staff.role==='admin';if(!admin&&action!=='batch_details')return;
  openOperation(action,id);
 });
 bindBatchRecords({db,state,openOperation});
 function openOperation(action,id,paymentId,batch){
  const supplierRows=state.companies||state.suppliers;
  const supplierSelect=`<label>Supplier<select name="supplier_id" required><option value="">Select a supplier</option>${supplierRows.filter(s=>s.active).map(s=>`<option value="${esc(s.id)}" ${s.id===state.companyId?'selected':''}>${esc(s.business_name)}</option>`).join('')}</select></label>`;
  let body='';
  if(action==='prepare_batch')body=supplierSelect+input('Cutoff (Namibia time, UTC+02:00)','cutoff_at','datetime-local')+'<p>Includes eligible paid vouchers not yet assigned to a payment order. Batch membership and prices become fixed.</p>';
  const proofField='<label class="wide">Upload proof of payment (POP)<input name="proof" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required><small>PDF or image, up to 5 MB. Included with the supplier payment emails.</small></label>';
  if(action==='record_payment')body=input('Bank transaction reference','bank_reference')+input('Amount actually paid (N$)','amount','number','min="0.01" step="0.01"')+proofField+'<p>Record a completed bank transfer. This action does not send money or release vouchers.</p>';
  if(action==='attach_payment_proof')body=proofField+'<p>Attaches the POP to this existing bank payment without recording another payment. Send a fresh confirmation email afterwards.</p>';
  if(action==='start_confirmation'&&batch?.payment_model==='prepaid')body="<p>PaySME's own unallocated prepaid funds held with this supplier must cover this batch before any email is sent. Both supplier contacts receive the review. Supervisor OTP approval deducts the batch once from PaySME's funds. No new bank payment is needed.</p>";
  else if(action==='start_confirmation')body='<p>Finance receives the batch link. The approval code goes to the registered supervisor email. The batch stays on hold until the supplier completes confirmation. Sending again replaces earlier confirmation links; finance must use the newest email.</p>';
  if(action==='release_prepaid_reservation')body='<label>Reason for releasing PaySME funds<textarea name="note" minlength="3" maxlength="1000" required></textarea></label><p>This releases a pending hold only. The batch remains unapproved and its vouchers stay on hold. Earlier review links are invalidated.</p>';
  if(action==='resolve_discrepancy')body='<label>Investigation and resolution note<textarea name="note" required minlength="3" maxlength="2000"></textarea></label><p>This keeps vouchers on hold. Send a fresh supplier confirmation after recording the resolution.</p>';
  if(action==='issue_api_key')body=supplierSelect+input('Credential label (supplier POS server)','label')+'<label>Restrict to branch (optional)<select name="branch_id"><option value="">All supplier branches</option>'+options(state.branches,b=>b.name+' · '+b.town)+'</select></label>';
  if(action==='revoke_api_key')body=input('Credential ID to revoke','credential_id')+'<p>Revocation immediately blocks further supplier requests using that credential.</p>';
  const titles={release_prepaid_reservation:'Release PaySME pending reservation',prepare_batch:'Prepare payment batch',record_payment:'Record bank payment',attach_payment_proof:'Upload payment POP',start_confirmation:'Request supplier confirmation',resolve_discrepancy:'Resolve discrepancy',issue_api_key:'Issue supplier API credential',revoke_api_key:'Revoke supplier API credential'};
  const d=dialog(titles[action],`<form><div class="form-grid">${body}</div><p role="alert" data-error></p><button type="submit">${action==='start_confirmation'?'Send confirmation email':'Continue'}</button></form>`);
  const form=d.querySelector('form');
  if(action==='prepare_batch'){
   const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Africa/Windhoek',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date());const values=Object.fromEntries(parts.map(p=>[p.type,p.value]));form.elements.cutoff_at.value=`${values.year}-${values.month}-${values.day}T${values.hour}:${values.minute}`;
  }
  if(action==='issue_api_key'){
   const update=()=>{form.elements.branch_id.innerHTML='<option value="">All supplier branches</option>'+options(state.branches.filter(b=>b.supplier_id===form.elements.supplier_id.value&&b.active),b=>b.name+' · '+b.town);};form.elements.supplier_id.onchange=update;update();
  }
  form.onsubmit=async event=>{
   event.preventDefault();const save=form.querySelector('[type=submit]');save.disabled=true;
   try{
    const args=Object.fromEntries(new FormData(form));if(id)args.batch_id=id;
    if(['record_payment','attach_payment_proof'].includes(action)){
     const file=args.proof;const extension=paymentProofExtension(file);delete args.proof;
     const path=`${id}/${crypto.randomUUID()}.${extension}`;
     const upload=await db.storage.from('paysme-voucher-payment-proofs').upload(path,file,{contentType:file.type,upsert:false});
     if(upload.error)throw upload.error;
     args.proof_object_path=path;
     if(action==='attach_payment_proof')args.payment_id=paymentId;
    }
    if(action==='prepare_batch')args.cutoff_at=new Date(args.cutoff_at+':00+02:00').toISOString();
    if(action==='record_payment'){args.amount_cents=toCents(args.amount);delete args.amount;}
    if(action==='start_confirmation')args.portal_url=location.origin+location.pathname;
    if(action==='issue_api_key'&&!args.branch_id)delete args.branch_id;
    const result=await command(db,action,args);if(result.message)state.notice=result.message;else if(action==='start_confirmation'&&result.sent)state.notice='The mail server accepted the confirmation email for finance. Use the newest email; previous links have been replaced.';if(action==='attach_payment_proof')state.notice='POP attached to the existing payment. You can now send a fresh confirmation email.';d.close();await reload();
    if(action==='issue_api_key')dialog('Copy supplier credential',`<p>Credential ID: <code>${esc(result.credential_id)}</code></p><p>Secret (shown once):</p><textarea readonly rows="4" aria-label="Supplier API secret">${esc(result.api_key)}</textarea><p>Store on the supplier server. Never embed in browser or POS frontend source. Keep the credential ID to revoke or rotate it.</p>`);
   }catch(error){form.querySelector('[data-error]').textContent=error.message;save.disabled=false;}
  };
 }
}

export async function showConfirmation({db,root,token}) {
 root.innerHTML='<main class="login"><section class="login-card"><h1>PaySME payment confirmation</h1><p>Loading batch details…</p></section></main>';
 try{
  const b=await command(db,'confirmation_details',{token});
  if(b.confirmation_type)return showCreditConfirmation({db,root,token,data:b,command});
  root.innerHTML=`<main class="login"><section class="login-card"><span class="eyebrow">SUPPLIER PAYMENT</span><h1>${esc(b.supplier_name)}</h1><h2>${esc(b.batch_reference)}</h2><p><b>Amount paid (bank): ${money(b.payment_recorded_cents)}</b></p><p>Batch value (supplier settlement): <b>${money(b.amount_due_cents)}</b><br>${b.voucher_count} vouchers in this batch${b.customer_voucher_value_cents!==undefined&&Number(b.customer_voucher_value_cents)!==Number(b.amount_due_cents)?'<br>Customer value of issued vouchers: '+money(b.customer_voucher_value_cents):''}</p>${b.payments.map(p=>`<p>${esc(p.reference)} · ${money(p.amount_cents)}${p.proof_url?` · <a href="${esc(p.proof_url)}" target="_blank" rel="noreferrer">View proof of payment</a>`:''}</p>`).join('')}<p>Check the payment against your bank records. Request an approval code sent to your registered supervisor${b.supervisor_email_hint?' ('+esc(b.supervisor_email_hint)+')':''}. Your colleague should check the payment and POP before sharing the code.</p>${b.proofs_ready?'':'<p class="notice">Proof of payment is missing. Ask PaySME to attach it and issue a fresh confirmation link.</p>'}<button id="send-approval" ${b.proofs_ready?'':'disabled'}>Email code to supervisor</button><form id="confirm-payment"><label>Supervisor approval code<input name="otp" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required autocomplete="one-time-code"></label><label class="check"><input type="checkbox" required>I confirm our business received the payment covering this batch.</label><button type="submit" ${b.proofs_ready?'':'disabled'}>Confirm payment received</button></form><p role="status" id="confirmation-status"></p><details><summary>Report a payment discrepancy</summary><form id="report-issue"><label>Issue<select name="reason"><option value="payment_not_received">Payment not received</option><option value="incorrect_amount">Amount differs</option><option value="reference_mismatch">Reference differs</option><option value="other">Other</option></select></label><label>Details<textarea name="comment" maxlength="2000" required></textarea></label><button class="secondary" type="submit">Report to PaySME</button></form></details><p class="muted">Link expires ${date(b.expires_at)}. For assistance contact PaySME: support@paysme.site.</p></section></main>`;
  const statusBox=document.querySelector('#confirmation-status');
  const run=async(button,action,args)=>{button.disabled=true;try{const data=await command(db,action,{token,...args});statusBox.textContent=data.message||'Completed successfully.';return data;}catch(error){statusBox.textContent=error.message;return null;}finally{button.disabled=false;}};
  document.querySelector('#send-approval').onclick=async event=>{const button=event.currentTarget;const data=await run(button,'confirmation_otp',{});if(data){button.disabled=true;button.textContent='Code email accepted by mail server';setTimeout(()=>{if(button.isConnected){button.disabled=false;button.textContent='Resend supervisor code';}},60000);}};
  document.querySelector('#confirm-payment').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget;const result=await run(form.querySelector('button'),'confirm_batch',{otp:form.elements.otp.value});if(result?.confirmed)root.innerHTML='<main class="login"><section class="login-card"><h1>Payment confirmed</h1><p>The vouchers in this payment order are now redeemable. Thank you.</p><p>For assistance, contact PaySME.</p></section></main>';};
  document.querySelector('#report-issue').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget;const result=await run(form.querySelector('button'),'report_discrepancy',Object.fromEntries(new FormData(form)));if(result?.reported)root.innerHTML='<main class="login"><section class="login-card"><h1>Discrepancy recorded</h1><p>PaySME will investigate. The vouchers remain on hold until the issue is resolved and your business confirms payment again.</p></section></main>';};
 }catch(error){root.innerHTML=`<main class="login"><section class="login-card"><h1>Confirmation unavailable</h1><p role="alert">${esc(error.message)}</p><p>Contact PaySME for a fresh confirmation link.</p></section></main>`;}
}
