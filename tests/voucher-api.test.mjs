import test from 'node:test';
import assert from 'node:assert/strict';
import {createHandler} from '../supabase/functions/paysme-vouchers/handler.mjs';
import {hash,receiptHtml,confirmationUrl} from '../supabase/functions/paysme-vouchers/core.mjs';

function fixture(result={ok:true}) {
 const calls=[],emails=[],sms=[];
 const handler=createHandler({db:{auth:{getUser:async token=>token==='valid'?{data:{user:{id:'real-user'}},error:null}:{data:{},error:true}},rpc:async(name,input)=>{calls.push({name,...input});return {data:result,error:null};}},sendEmail:async(...args)=>emails.push(args),sendSms:async(...args)=>sms.push(args)});
 const request=(action,args={},headers={})=>handler(new Request('https://example.test/api',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify({action,args})}));
 return {calls,emails,sms,request};
}
test('funding registration is never exposed through supplier or staff Edge requests',async()=>{
 const f=fixture();const r=await f.request('record_paid_sale',{}, {Authorization:'Bearer valid'});assert.equal(r.status,400);assert.equal(f.calls.length,0);
});
test('staff actors come from validated Auth, never request fields',async()=>{
 const f=fixture();assert.equal((await f.request('prepare_batch',{})).status,401);
 assert.equal((await f.request('prepare_batch',{}, {Authorization:'Bearer invalid'})).status,401);
 await f.request('prepare_batch',{actor_id:'forged'}, {Authorization:'Bearer valid'});
 assert.equal(f.calls[0].args.actor_id,'real-user');
});
test('supplier scope comes from a hashed credential and cannot be injected',async()=>{
 const f=fixture();const key='PVK-'+'a'.repeat(64);
 assert.equal((await f.request('verify_voucher',{})).status,401);
 await f.request('verify_voucher',{api_key_hash:'forged',actor_id:'forged'},{'x-voucher-api-key':key});
 assert.equal(f.calls[0].args.api_key_hash,await hash(key));assert.equal(f.calls[0].args.actor_id,undefined);
});
test('recipient OTP endpoint delivers distinct codes and returns neither code nor contacts',async()=>{
 const f=fixture({verification_id:'session',email:'person@example.test',mobile_number:'+264810000001'});
 const r=await f.request('request_recipient_otp',{}, {'x-voucher-api-key':'a'.repeat(64)});
 const body=await r.json();assert.equal(body.verification_id,'session');assert.equal(body.email,undefined);assert.equal(body.mobile_number,undefined);
 const {sms_otp,email_otp}=f.calls[0].args;assert.match(sms_otp,/^\d{6}$/);assert.notEqual(sms_otp,email_otp);
 assert.ok(f.emails[0][2].includes(email_otp));assert.ok(f.sms[0][1].includes(sms_otp));assert.ok(!JSON.stringify(body).includes(sms_otp));
});
test('supervisor OTP is sent to the registered supervisor and omitted from response',async()=>{
 const f=fixture({supervisor_email:'supervisor@example.test',batch_reference:'PV-BATCH-1',supplier_name:'Test supplier',voucher_count:2,amount_due_cents:100000});
 const r=await f.request('confirmation_otp',{token:'a'.repeat(64)});
 assert.equal(f.emails[0][0],'supervisor@example.test');const body=await r.text();assert.ok(!body.includes(f.calls[0].args.otp));assert.ok(!body.includes('supervisor@example.test'));
});
test('confirmation links require HTTPS and put the secret in the URL fragment',()=>{
 assert.throws(()=>confirmationUrl('http://localhost:4173','secret'));
 const url=new URL(confirmationUrl('https://portal.example.test/?x=y','secret'));assert.equal(url.hash,'#confirm=secret');assert.equal(url.search,'');
});
test('receipt templates escape supplier content, enforce printer sizes, and never invent store credit',()=>{
 const receipt={receipt_reference:'PV-RECEIPT-1',supplier_name:'<script>bad()</script>',product_name:'Combo',entitlement_type:'product_bundle',customer_price_cents:52000};
 const html=receiptHtml(receipt,'58');assert.ok(html.includes('58mm'));assert.ok(html.includes('&lt;script&gt;'));assert.ok(!html.includes('<script>'));assert.ok(!html.includes('Store credit:'));assert.throws(()=>receiptHtml(receipt,'1000'));
});
test('oversized API requests are rejected before database execution',async()=>{
 const f=fixture();const r=await f.request('confirmation_details',{token:'a'.repeat(17000)});assert.equal(r.status,413);assert.equal(f.calls.length,0);
});
test('supplier URL paths select the operation and cannot be replaced by a body action',async()=>{
 const calls=[];const handler=createHandler({db:{rpc:async(name,args)=>{calls.push(args);return{data:{status:'redeemable'},error:null};}},sendEmail:async()=>{},sendSms:async()=>{}});
 const result=await handler(new Request('https://example.test/functions/v1/paysme-vouchers/verify',{method:'POST',headers:{'x-voucher-api-key':'a'.repeat(64)},body:JSON.stringify({voucher_code:'PAD-EXAMPLE',pos_staff_reference:'cashier',action:'record_paid_sale'})}));
 assert.equal(result.status,200);assert.equal(calls[0].action,'verify_voucher');assert.equal(calls[0].args.voucher_code,'PAD-EXAMPLE');
});
