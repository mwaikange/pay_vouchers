import {escapeHtml as e} from './core.mjs';
const money=value=>'N$'+(Number(value||0)/100).toFixed(2);
export function prepaidSummary(data) {
 const a=data.account||{};
 if(data.confirmation_type==='prepayment')return `<p><b>${e(data.batch_reference)}</b> · ${e(data.supplier_name)}</p><p>Amount paid by PaySME to your business: <b>${money(data.amount_cents)}</b><br>PaySME's confirmed balance held with your business: ${money(a.confirmed_balance_cents)}<br>PaySME's available unallocated funds: ${money(a.available_cents)}</p>${data.notes?`<p>PaySME notes: ${e(data.notes)}</p>`:''}`;
 return `<p><b>${e(data.batch_reference)}</b> · ${e(data.supplier_name)}</p><p>${e(data.voucher_count)} vouchers<br>Batch deduction: <b>${money(data.amount_due_cents)}</b><br>PaySME's confirmed balance held with your business: ${money(a.confirmed_balance_cents)}<br>PaySME funds reserved for this batch: ${money(data.reserved_for_batch_cents)}<br>PaySME funds available for other batches: ${money(a.available_cents)}<br>PaySME balance after this approval: <b>${money(data.balance_after_approval_cents)}</b></p><p>This batch uses PaySME's existing prepayment to your business. There is no new bank transfer to verify.</p>`;
}
export function prepaidEmail(data,{url,otp}={}) {
 const deposit=data.confirmation_type==='prepayment';
 const title=deposit?(data.deposit_kind==='initial'?'Prepaid account setup':'Prepaid account top-up'):'Prepaid batch allocation';
 const introduction=deposit?(data.deposit_kind==='initial'?"PaySME is setting up its prepaid voucher balance with your business. PaySME has paid the amount below to your business. Please verify it against the attached proof of payment.":"PaySME has paid your business to top up PaySME's prepaid balance held with you. Please confirm the amount against the attached proof of payment."):"PaySME's records show enough available funds held with your business to cover this batch. Review the batch and the matching balance in your records. Approval deducts the batch value once from PaySME's balance and makes the vouchers redeemable. If your balance differs or is insufficient, report an issue instead of approving.";
 const approval=otp?`<p>${deposit?'Check the payment received from PaySME and its POP independently.':"Check that PaySME's prepaid balance held with your business covers this allocation."} If correct, share this approval code with your finance colleague:</p><h2>${e(otp)}</h2><p>The code expires in 10 minutes. Do not share it if any amount differs.</p>`:`<p><a href="${e(url)}">${deposit?'Review PaySME prepayment':'Review PaySME batch allocation'}</a></p><p>Finance opens the link and requests a separate approval code sent only to the registered supervisor. This link expires in 48 hours.</p>`;
 const planning=(data.planning||[]).map(p=>`<tr><td>${e(p.branch_name)}</td><td>${e(p.recipient_town)}</td><td>${e(p.product_name)}</td><td>${e(p.voucher_count)}</td></tr>`).join('');
 return {subject:(otp?'PaySME supervisor approval: ':'PaySME '+title.toLowerCase()+': ')+data.batch_reference,
  html:`<h2>${title}</h2><p>${introduction}</p>${prepaidSummary(data)}${deposit?"<p>The POP is attached. Approval increases PaySME's prepaid funds held with your business only; individual batches require their own approval.</p>":''}${planning?`<h3>Requested collection planning</h3><table><tr><th>Requested branch</th><th>Town</th><th>Product</th><th>Vouchers</th></tr>${planning}</table><p>These are customer collection intentions, not completed redemptions.</p>`:''}${approval}<p>Report a discrepancy on the review page if anything differs. Contact PaySME: support@paysme.site.</p>`};
}
export function csv(rows) {
 return '\uFEFF'+rows.map(row=>row.map(value=>{let s=String(value??'');if(typeof value==='string'&&/^[\s]*[=+\-@]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"';}).join(',')).join('\r\n')+'\r\n';
}
const attachment=(filename,rows)=>({filename,contentType:'text/csv; charset=utf-8',encoding:'binary',content:new TextEncoder().encode(csv(rows))});
export function reconciliationEmail(data) {
 const a=data.current_account||{};
 const low=Number(a.available_cents)<Number(a.prepaid_low_balance_cents||0);
 const financials=data.payment_model==='postpaid'&&!Number(a.credited_cents)?`<p>Cash supplier terms. PaySME bank payments recorded for this day: <b>${money(data.bank_paid_cents)}</b>. Payment records and batch values are listed separately in the attached CSVs.</p>`:`<p>PaySME's opening funds held with your business: ${money(data.opening_cents)}<br>PaySME prepayments approved: ${money(data.credited_cents)}<br>Approved batch deductions: ${money(data.charged_cents)}<br><b>PaySME's closing funds held with your business: ${money(data.closing_cents)}</b><br>Reserved at close: ${money(data.reserved_at_close_cents)}<br>Unallocated at close: ${money(data.available_at_close_cents)}</p><p>PaySME's currently available funds: <b>${money(a.available_cents)}</b><br>PaySME payments awaiting approval: ${money(a.pending_deposit_cents)}${low?'<br><b>PaySME funds are below the account alert level.</b>':''}</p>`;
 return {subject:`PaySME daily reconciliation: ${data.supplier_name} · ${data.report_date}`,
  html:`<h2>Daily voucher reconciliation</h2><p>${e(data.supplier_name)} · ${e(data.report_date)} · Namibia time</p>${financials}<p>Statement, bank payment and batch CSVs cover the report's financial period. Collection planning shows outstanding vouchers as at ${e(data.generated_at)}. Requested branches are planning information; actual redemptions are reported separately. Redemption never deducts PaySME's prepaid funds a second time.</p><p>Contact PaySME: support@paysme.site.</p>`,
  attachments:[
   attachment(`bank-payments-${data.report_date}.csv`,[['Recorded at','Bank reference','Batch','Amount paid by PaySME (N$)'],...(data.bank_payments||[]).map(x=>[x.recorded_at,x.bank_transaction_reference,x.batch_reference,Number(x.amount_cents)/100])]),
   attachment(`statement-${data.report_date}.csv`,[['Recorded at','Type','Reference','Amount (N$)'],...(data.entries||[]).map(x=>[x.created_at,x.entry_kind,x.reference,Number(x.amount_cents)/100])]),
   attachment(`batches-${data.report_date}.csv`,[['Batch','Payment terms','Vouchers','Supplier value (N$)','Status','Redeemed'],...(data.batches||[]).map(x=>[x.batch_reference,x.payment_model,x.voucher_count,Number(x.amount_due_cents)/100,x.status,x.redeemed_count])]),
   attachment(`collection-planning-${data.report_date}.csv`,[['Requested branch','Town','Product','Awaiting approval','Ready to redeem','Outstanding','Supplier value (N$)'],...(data.planning||[]).map(x=>[x.branch_name,x.recipient_town,x.product_name,x.awaiting_count,x.redeemable_count,x.voucher_count,Number(x.supplier_value_cents)/100])]),
   attachment(`actual-redemptions-${data.report_date}.csv`,[['Actual branch','Vouchers redeemed','Supplier value (N$)'],...(data.redemptions||[]).map(x=>[x.branch_name,x.voucher_count,Number(x.supplier_value_cents)/100])])
  ]};
}
export function readySms(data) {
 const location=[data.branch_name?.slice(0,60),data.town?.slice(0,40)].filter(Boolean).join(', ');
 return `PaySME: Voucher ${data.voucher_code} for ${String(data.supplier_name).slice(0,80)} is ready to redeem.${location?' Requested collection: '+location+'.':''} Bring your ID. Help: support@paysme.site.`;
}
