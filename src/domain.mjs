export function toCents(value) {
  const text = String(value).trim();
  if (!/^\d+(\.\d{1,2})?$/.test(text)) throw new Error('Enter a non-negative amount with at most two decimal places.');
  const [whole, fraction = ''] = text.split('.');
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  if (!Number.isSafeInteger(cents) || cents > 100000000000) throw new Error('Amount is too large.');
  return cents;
}
export function pricing({ supplier, markup, instore, rebate = '0', commission = '0' }) {
  const supplierCents = toCents(supplier), markupCents = toCents(markup), instoreCents = toCents(instore);
  const rebateCents = toCents(rebate), commissionCents = toCents(commission);
  if (supplierCents === 0) throw new Error('Supplier price must be greater than zero.');
  if (rebateCents > supplierCents) throw new Error('Rebate cannot exceed supplier price.');
  return { supplierCents, markupCents, instoreCents, rebateCents, commissionCents,
    customerCents: supplierCents + markupCents,
    savingCents: instoreCents - supplierCents - markupCents };
}
export function approvalEmails(finance, supervisor) {
  const normalize = value => String(value).trim().toLowerCase();
  const emails = [normalize(finance), normalize(supervisor)];
  if (emails.some(email => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) throw new Error('Enter two valid approval email addresses.');
  if (emails[0] === emails[1]) throw new Error('Finance and supervisor email addresses must differ.');
  return { finance_email: emails[0], supervisor_email: emails[1] };
}
export function normalizeMobile(value) {
  let phone = String(value).replace(/[\s()-]/g, '');
  if (/^0\d{9}$/.test(phone)) phone = '+264' + phone.slice(1);
  else if (/^264\d{9}$/.test(phone)) phone = '+' + phone;
  else if (phone.startsWith('00')) phone = '+' + phone.slice(2);
  if (!/^\+[1-9]\d{7,14}$/.test(phone)) throw new Error('Enter a valid international mobile number.');
  return phone;
}
export const money = cents => new Intl.NumberFormat('en-NA', { style: 'currency', currency: 'NAD', currencyDisplay: 'code' }).format(Number(cents) / 100).replace('NAD', 'N$');

export function catalogueImageExtension(file) {
  const extensions = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
  if (!extensions[file?.type] || !file.size || file.size > 5242880) throw new Error('Choose a JPEG, PNG or WebP picture no larger than 5 MB.');
  return extensions[file.type];
}

export function paymentProofExtension(file) {
  const extensions = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
  if (!extensions[file?.type] || !file.size || file.size > 5242880) throw new Error('Choose a PDF, JPEG, PNG or WebP proof of payment no larger than 5 MB.');
  return extensions[file.type];
}

export function confirmationReadiness(batch,payments) {
  const paidCents=payments.reduce((sum,payment)=>sum+Number(payment.amount_cents),0);
  return {paidCents,ready:payments.length>0&&Number.isSafeInteger(paidCents)&&paidCents>=Number(batch.amount_due_cents)&&payments.every(payment=>Boolean(payment.proof_object_path))&&!['disputed','settled'].includes(batch.status)};
}
