import test from 'node:test';
import assert from 'node:assert/strict';
import {paymentProofExtension,confirmationReadiness} from '../src/domain.mjs';
import {batchMessage} from '../supabase/functions/paysme-vouchers/core.mjs';
import {loadPaymentProofs,signedPaymentProofs,PROOF_BUCKET} from '../supabase/functions/paysme-vouchers/payment-proofs.mjs';
import {createHandler} from '../supabase/functions/paysme-vouchers/handler.mjs';

const path='11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.pdf';
const payments=[{reference:'BANK-1',amount_cents:110000,proof_object_path:path}];
const batch={batch_reference:'PV-BATCH-1',supplier_name:'Supplier',voucher_count:2,amount_due_cents:100000,status:'payment_submitted'};
test('confirmation remains disabled for absent/partial/unproven payments and disputed or settled batches',()=>{
 assert.equal(confirmationReadiness(batch,[]).ready,false);
 assert.equal(confirmationReadiness(batch,[{amount_cents:100000}]).ready,false);
 assert.equal(confirmationReadiness(batch,[{amount_cents:99999,proof_object_path:path}]).ready,false);
 assert.equal(confirmationReadiness(batch,payments).ready,true);
 assert.equal(confirmationReadiness({...batch,status:'awaiting_confirmation'},payments).ready,true);
 for(const status of ['disputed','settled'])assert.equal(confirmationReadiness({...batch,status},payments).ready,false);
});
test('POP upload permits only supported nonempty files within the size limit',()=>{
 assert.equal(paymentProofExtension({type:'application/pdf',size:5242880}),'pdf');
 for(const file of [{type:'application/pdf',size:0},{type:'image/png',size:5242881},{type:'text/html',size:20}])assert.throws(()=>paymentProofExtension(file));
});
test('payment email distinguishes bank payment, settlement batch value and customer voucher value',()=>{
 const message=batchMessage({...batch,payment_recorded_cents:110000,customer_voucher_value_cents:104000});
 assert.ok(message.includes('Amount paid (bank): N$1100.00'));
 assert.ok(message.includes('Batch value (supplier settlement): N$1000.00'));
 assert.ok(message.includes('Customer value of issued vouchers: N$1040.00'));
 assert.ok(!message.includes('Amount due'));
});
test('POP attachment downloads from the private bucket and preserves exact binary bytes',async()=>{
 const bytes=new Uint8Array([37,80,68,70,0,255,13,10]);const buckets=[];
 const db={storage:{from(bucket){buckets.push(bucket);return{download:async input=>{assert.equal(input,path);return{data:new Blob([bytes],{type:'application/pdf'}),error:null};}};}}};
 const files=await loadPaymentProofs(db,payments.concat(payments));
 assert.deepEqual(buckets,[PROOF_BUCKET]);assert.equal(files.length,1);
 assert.equal(files[0].filename,'POP-BANK-1.pdf');assert.equal(files[0].encoding,'binary');assert.deepEqual(files[0].content,bytes);
});
test('missing, unavailable or oversized proofs stop email preparation',async()=>{
 await assert.rejects(()=>loadPaymentProofs({},[]),/required/);
 await assert.rejects(()=>loadPaymentProofs({},[{proof_object_path:null}]),/required/);
 const db={storage:{from:()=>({download:async()=>({error:{message:'internal provider details'}})})}};
 await assert.rejects(()=>loadPaymentProofs(db,payments),/could not be loaded/);
 const large={storage:{from:()=>({download:async()=>({data:{size:5242881},error:null})})}};
 await assert.rejects(()=>loadPaymentProofs(large,payments),/too large/);
});
test('supplier proof links are short-lived and omit raw storage paths from JSON',async()=>{
 const db={storage:{from:bucket=>({createSignedUrl:async(objectPath,seconds)=>{assert.equal(bucket,PROOF_BUCKET);assert.equal(objectPath,path);assert.equal(seconds,900);return{data:{signedUrl:'https://storage.example.test/signed-pop'},error:null};}})}};
 const [payment]=await signedPaymentProofs(db,payments);assert.equal(payment.proof_object_path,undefined);assert.equal(payment.proof_url,'https://storage.example.test/signed-pop');
});
function handlerFixture({mailFailure=false,proofFailure=false}={}){
 const emails=[];const attachments=[{filename:'POP-BANK-1.pdf',content:new Uint8Array([1,2,3]),contentType:'application/pdf',encoding:'binary'}];
 const db={auth:{getUser:async()=>({data:{user:{id:'staff'}},error:null})},rpc:async(name,{action})=>({data:action==='start_confirmation'?{batch,finance_email:'finance@example.invalid',payment_recorded_cents:110000,customer_voucher_value_cents:104000,payments}:{...batch,payment_recorded_cents:110000,payments,supervisor_email:'supervisor@example.invalid'},error:null})};
 const handler=createHandler({db,sendSms:async()=>{},loadProofAttachments:async()=>{if(proofFailure)throw new Error('The proof of payment could not be loaded. No email was sent.');return attachments;},sendEmail:async(...args)=>{if(mailFailure)throw new Error('The mail server did not accept the email. Please retry after the cooldown or contact PaySME.');emails.push(args);}});
 const request=action=>handler(new Request('https://example.test',{method:'POST',headers:{Authorization:'Bearer staff'},body:JSON.stringify({action,args:action==='start_confirmation'?{portal_url:'https://portal.example.test'}:{token:'a'.repeat(64)}})}));
 return{emails,attachments,request};
}
test('finance email includes POP attachments and the actual bank amount, without releasing vouchers',async()=>{
 const f=handlerFixture();const r=await f.request('start_confirmation');assert.equal(r.status,200);
 assert.equal(f.emails[0][0],'finance@example.invalid');assert.deepEqual(f.emails[0][3],f.attachments);
 assert.ok(f.emails[0][2].includes('N$1100.00'));assert.ok(!f.emails[0][2].includes('Amount due'));
 const body=await r.json();assert.equal(body.sent,true);assert.equal(body.confirmed,undefined);
});
test('supervisor email includes POP and never returns the OTP or full email address',async()=>{
 const f=handlerFixture();const r=await f.request('confirmation_otp');const body=await r.json();
 assert.equal(f.emails[0][0],'supervisor@example.invalid');assert.deepEqual(f.emails[0][3],f.attachments);
 assert.equal(body.supervisor_email_hint,'s***@example.invalid');assert.equal(body.otp,undefined);
 assert.ok(!JSON.stringify(body).includes('supervisor@example.invalid'));assert.match(body.message,/mail server accepted/i);
});
test('mail rejection or missing attachment is never reported as sent',async()=>{
 for(const options of [{mailFailure:true},{proofFailure:true}]){
  const f=handlerFixture(options);const r=await f.request('confirmation_otp');const body=await r.json();
  assert.equal(r.status,503);assert.equal(body.sent,undefined);assert.equal(body.otp,undefined);
 }
});
