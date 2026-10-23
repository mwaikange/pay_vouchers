import test from 'node:test';
import assert from 'node:assert/strict';
import {customerRoute,customersPage} from '../src/customers.js';
import {salesPage,settlementsPage,reportsPage} from '../src/operations.js';

const companyId='11111111-1111-1111-1111-111111111111';
const customerId='22222222-2222-2222-2222-222222222222';
const companies=[{id:companyId,business_name:'Example & Company',active:true},{id:'33333333-3333-3333-3333-333333333333',business_name:'Archived supplier',active:false}];
const finance={companyId,companies,staff:{role:'admin'},suppliers:companies,sales:[],vouchers:[],batches:[],redemptions:[],analytics:{pending_settlement_cents:50000,settlement_consumed_cents:0,batch_count:1,redemption_count:0,planning:[]}};

test('customer links accept UUID customer routes and ignore confirmation or malformed hashes',()=>{
 assert.equal(customerRoute('#customer='+customerId),customerId);
 assert.equal(customerRoute('#confirm=secret'),null);
 assert.equal(customerRoute('#customer=<script>'),null);
});
test('voucher customer directory links to individual records and displays masked contacts only',()=>{
 const html=customersPage({customerDirectory:{customers:[{id:customerId,customer_no:12,full_name:'<script>bad()</script>',mobile_last4:'1234',town:'Windhoek',purchase_count:3,paid_value_cents:156000,last_purchase_at:'2026-10-23T12:00:00Z'}],total_count:1,offset:0,limit:50,search:''}});
 assert.ok(html.includes('#customer='+customerId));assert.ok(html.includes('•••• 1234'));assert.ok(!html.includes('<script>'));assert.ok(html.includes('PaySME vouchers only'));assert.ok(html.includes('third-party VAS'));
});
test('customer history totals and pagination cover the complete history rather than the loaded page',()=>{
 const html=customersPage({customerId,customerRecord:{profile:{id:customerId,customer_no:12,full_name:'Test customer',mobile_number:'+264810001234',email:'person@example.invalid',town:'Windhoek'},summary:{purchase_count:102,paid_purchase_count:102,paid_value_cents:5304000,redeemed_count:40,last_purchase_at:'2026-10-23T12:00:00Z'},purchases:[],offset:50,limit:50}});
 assert.ok(html.includes('51–100 of 102'));assert.match(html,/data-customer-page="100"\s*>Next/);assert.ok(html.includes('All voucher purchases for this customer'));assert.ok(html.includes('5304')||html.includes('53,040'));
});
test('every finance page offers combined and individual company views, including historical inactive suppliers',()=>{
 for(const render of [salesPage,settlementsPage,reportsPage]){
  const html=render(finance);assert.ok(html.includes('All companies'));assert.ok(html.includes(`value="${companyId}" selected`));assert.ok(html.includes('Archived supplier (inactive)'));assert.ok(html.includes('Example &amp; Company'));
 }
});
test('company changes hide the previous financial data while the new scope is loading',()=>{
 const state={...finance,financeLoading:true,sales:[{product_name:'OLD-COMPANY-PRIVATE-ROW'}],batches:[{supplier_name:'OLD-COMPANY-PRIVATE-ROW'}],redemptions:[{receipt_reference:'OLD-COMPANY-PRIVATE-ROW'}]};
 for(const render of [salesPage,settlementsPage,reportsPage]){const html=render(state);assert.ok(html.includes('Loading company records'));assert.ok(!html.includes('OLD-COMPANY-PRIVATE-ROW'));}
});
