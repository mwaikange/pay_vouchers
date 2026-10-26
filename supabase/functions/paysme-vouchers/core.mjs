export const STAFF_ACTIONS = new Set(['prepare_batch','record_payment','attach_payment_proof','start_confirmation','resolve_discrepancy','issue_api_key','revoke_api_key']);
export const CONFIRM_ACTIONS = new Set(['confirmation_details','confirmation_otp','confirm_batch','report_discrepancy']);
export const SUPPLIER_ACTIONS = new Set(['verify_voucher','validate_id','request_recipient_otp','validate_recipient_otp','redeem_voucher','get_receipt']);
export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const randomToken = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), n => n.toString(16).padStart(2,'0')).join('');
export function randomOtp() { let n; do { n=crypto.getRandomValues(new Uint32Array(1))[0]; } while(n>=4294000000); return String(n%1000000).padStart(6,'0'); }
export async function hash(value) { return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))), n=>n.toString(16).padStart(2,'0')).join(''); }
export function confirmationUrl(base,token) {
 const url=new URL(base);
 if(url.protocol!=='https:' || url.username || url.password || ['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new Error('Publish the portal on HTTPS before sending supplier confirmation emails.');
 url.search=''; url.hash='confirm='+token; return url.href;
}
const amount = cents => 'N$'+(Number(cents)/100).toFixed(2);
export function batchMessage(batch) {
 return `${escapeHtml(batch.batch_reference)}<br>Supplier: ${escapeHtml(batch.supplier_name)}<br>Vouchers in batch: ${escapeHtml(batch.voucher_count)}<br><b>Amount paid (bank): ${amount(batch.payment_recorded_cents ?? 0)}</b><br>Batch value (supplier settlement): ${amount(batch.amount_due_cents)}${batch.customer_voucher_value_cents!==undefined&&Number(batch.customer_voucher_value_cents)!==Number(batch.amount_due_cents)?'<br>Customer value of issued vouchers: '+amount(batch.customer_voucher_value_cents):''}`;
}

export function emailHint(email) {
 const [name,domain]=String(email||'').split('@');
 return domain?`${name.slice(0,1)}***@${domain}`:'registered supervisor';
}
export function paymentMessage(payments=[]) {
 return payments.map(payment=>`${escapeHtml(payment.reference)} · ${amount(payment.amount_cents)}`).join('<br>');
}
export function receiptHtml(receipt,width='80') {
 if(!['58','80'].includes(String(width))) throw new Error('Receipt width must be 58 or 80 mm.');
 const e=escapeHtml;
 return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${e(receipt.receipt_reference)}</title><style>@page{size:auto;margin:3mm}body{width:calc(${width}mm - 6mm);margin:3mm auto;font:12px monospace;color:#000}h1{font-size:16px}hr{border:0;border-top:1px dashed #000}button{margin:16px 0}@media print{button{display:none}body{margin:0}}</style></head><body><h1>PaySME Vouchers</h1><b>${e(receipt.supplier_name)}</b><p>${e(receipt.branch_name)}</p><hr><p>${e(receipt.receipt_reference)}<br>${e(receipt.redeemed_at)}</p><p>Voucher: ${e(receipt.voucher_code)}</p><b>${e(receipt.product_name)}</b><p>${e(receipt.product_contents)}</p>${receipt.entitlement_type==='store_credit'?'<p>Store credit: '+amount(receipt.store_credit_cents)+'</p>':''}<p>Customer paid: ${amount(receipt.customer_price_cents)}</p><hr><p>Redeemed successfully</p><p>${e(receipt.support)}</p><button onclick="window.print()">Print receipt</button></body></html>`;
}
