import test from 'node:test';
import assert from 'node:assert/strict';
import { toCents, pricing, approvalEmails, normalizeMobile, catalogueImageExtension } from '../src/domain.mjs';

test('supplier logos and product pictures accept only nonempty supported images up to 5 MB', () => {
  assert.equal(catalogueImageExtension({ type: 'image/png', size: 100 }), 'png');
  assert.equal(catalogueImageExtension({ type: 'image/jpeg', size: 5242880 }), 'jpg');
  assert.equal(catalogueImageExtension({ type: 'image/webp', size: 100 }), 'webp');
  for (const file of [{ type: 'image/svg+xml', size: 100 }, { type: 'image/png', size: 0 }, { type: 'image/png', size: 5242881 }]) assert.throws(() => catalogueImageExtension(file));
});
test('agreed example: supplier 500, markup 20, store 600, customer saves 80', () => {
  const p = pricing({ supplier: '500', markup: '20', instore: '600', rebate: '10', commission: '5' });
  assert.equal(p.customerCents, 52000); assert.equal(p.savingCents, 8000);
  assert.equal(p.supplierCents, 50000); assert.equal(p.rebateCents, 1000);
});
test('money conversion rejects rounding, negative values and overflow', () => {
  assert.equal(toCents('0.29'), 29); assert.equal(toCents('500.5'), 50050);
  for (const value of ['-1', '1.001', '1e5', '', 'NaN', '999999999999999999']) assert.throws(() => toCents(value));
  assert.throws(() => pricing({ supplier: '1', markup: '0', instore: '2', rebate: '2' }));
});
test('approval emails must be distinct after normalization', () => {
  assert.throws(() => approvalEmails('Finance@example.com', ' finance@example.com '));
  assert.throws(() => approvalEmails('bad', 'supervisor@example.com'));
  assert.deepEqual(approvalEmails(' Finance@EXAMPLE.com ', 'Boss@example.com'), { finance_email: 'finance@example.com', supervisor_email: 'boss@example.com' });
});
test('Namibian phone formats normalize consistently without claiming identity verification', () => {
  for (const number of ['081 234 5678', '264812345678', '+264812345678', '00264812345678']) assert.equal(normalizeMobile(number), '+264812345678');
  assert.throws(() => normalizeMobile('123'));
});
