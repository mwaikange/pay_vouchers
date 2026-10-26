import test from 'node:test';
import assert from 'node:assert/strict';
import {confirmationReadiness} from '../src/domain.mjs';
import {createHandler} from '../supabase/functions/paysme-vouchers/handler.mjs';
import {prepaidEmail,reconciliationEmail,csv,readySms} from '../supabase/functions/paysme-vouchers/prepaid.mjs';
import {claimNotifications,deliverNotifications} from '../supabase/functions/paysme-vouchers/notifications.mjs';

test('PaySME first gate blocks N$40,000 batch when its own unallocated funds held with supplier are N$30.98',()=>{
 const batch={payment_model:'prepaid',status:'prepared',amount_due_cents:4000000};
 assert.equal(confirmationReadiness(batch,[],{funds_owner:'PaySME',available_cents:3098}).ready,false);
 assert.equal(confirmationReadiness(batch,[],{available_cents:4000000}).ready,true);
 assert.equal(confirmationReadiness(batch,[],{available_cents:4000000,open_batch_issues:1}).ready,false);
 // A resend reuses this batch's already held PaySME funds; it cannot reserve them twice.
 assert.equal(confirmationReadiness({...batch,status:'awaiting_confirmation'},[],{available_cents:3098},[{status:'reserved',amount_cents:4000000}]).ready,true);
 assert.equal(confirmationReadiness(batch,[],{available_cents:3098},[{status:'committed',amount_cents:4000000}]).ready,false);
 for(const status of ['disputed','settled'])assert.equal(confirmationReadiness({...batch,status},[],{available_cents:5000000}).ready,false);
});
const request=action=>new Request('https://voucher.test',{method:'POST',headers:{Authorization:'Bearer staff'},body:JSON.stringify({action,args:{portal_url:'https://payvouchers.vercel.app',batch_id:'batch'}})});
test('database funding rejection happens before POP loading, SMTP calls or SMS calls',async()=>{
 const effects=[];
 const db={auth:{getUser:async()=>({data:{user:{id:'admin'}}})},rpc:async()=>({error:{code:'P0001',message:'Insufficient confirmed prepaid credit for this batch'}})};
 const handler=createHandler({db,sendEmail:async()=>effects.push('email'),sendSms:async()=>effects.push('sms'),loadProofAttachments:async()=>effects.push('proof')});
 const response=await handler(request('start_confirmation'));assert.equal(response.status,409);assert.deepEqual(effects,[]);
 assert.match((await response.json()).error,/Insufficient/);
});
const funded={confirmation_type:'prepaid_batch',batch_reference:'PV-BATCH-20',supplier_name:'Retailer',amount_due_cents:100000,voucher_count:2,reserved_for_batch_cents:100000,
 balance_after_approval_cents:3098,account:{funds_owner:'PaySME',funds_location:'held_with_supplier',confirmed_balance_cents:103098,available_cents:3098},
 payments:[],finance_email:'finance@example.invalid',supervisor_email:'supervisor@example.invalid',planning:[]};
test('funded PaySME batch review goes to both supplier contacts without pretending a new bank payment or requiring another POP',async()=>{
 const emails=[];let proofCalls=0;
 const db={auth:{getUser:async()=>({data:{user:{id:'admin'}}})},rpc:async()=>({data:funded,error:null})};
 const handler=createHandler({db,sendSms:async()=>{},sendEmail:async(...a)=>emails.push(a),loadProofAttachments:async()=>{proofCalls++;throw Error('Batch must use existing PaySME funds');}});
 const response=await handler(request('start_confirmation'));assert.equal(response.status,200);assert.equal((await response.json()).sent,true);
 assert.deepEqual(emails.map(e=>e[0]),['finance@example.invalid','supervisor@example.invalid']);assert.equal(proofCalls,0);
 assert.match(emails[0][2],/PaySME's existing prepayment to your business/);assert.match(emails[0][2],/no new bank transfer/i);
 assert.deepEqual(emails[0][3],[]);
});
test('initial funding email explicitly records money paid BY PaySME TO the supplier',()=>{
 const message=prepaidEmail({...funded,confirmation_type:'prepayment',deposit_kind:'initial',amount_cents:100000,notes:'Setup <script>bad()</script>'},{url:'https://portal.test/#confirm=x'});
 assert.match(message.html,/paid by PaySME to your business/);assert.match(message.html,/PaySME's prepaid funds held with your business/);
 assert.ok(!message.html.includes('<script>'));assert.ok(!message.html.includes('Vendor wallet'));
 const otp=prepaidEmail(funded,{otp:'000123'});assert.match(otp.html,/<h2>000123<\/h2>/);assert.ok(!otp.html.includes('confirm=x'));
});
test('worker rejects missing/forged credentials without claiming or sending a notification',async()=>{
 let calls=0;const db={rpc:async()=>{calls++;return{error:{code:'42501'}};}};
 assert.deepEqual(await claimNotifications(db,null),{unauthorized:true});assert.equal(calls,0);
 assert.deepEqual(await claimNotifications(db,'1793000000:11111111-1111-4111-8111-111111111111:'+ 'a'.repeat(64)),{unauthorized:true});assert.equal(calls,1);
});
test('notification retries acknowledge accepted sends only and never re-run a financial operation',async()=>{
 const calls=[];const db={rpc:async(name,args)=>{calls.push({name,args});return{data:true,error:null};}};
 const jobs=[{id:'one',lease_id:'lease-one',kind:'ready_sms',payload:{mobile:'+264810000001',voucher_code:'PAD-TEST',supplier_name:'Retailer',town:'Windhoek'}},
  {id:'two',lease_id:'lease-two',kind:'ready_sms',payload:{mobile:'+264810000002',voucher_code:'PAD-FAIL',supplier_name:'Retailer'}}];
 const result=await deliverNotifications(jobs,{db,sendEmail:async()=>assert.fail('Not an email event'),sendSms:async(_,body)=>{if(body.includes('PAD-FAIL'))throw Error('provider failure');}});
 assert.deepEqual(result,{accepted:1,failed:1});assert.ok(calls.every(c=>c.name==='paysme_voucher_finish_notification'));
 assert.equal(calls.find(c=>c.args.p_id==='one').args.p_sent,true);assert.equal(calls.find(c=>c.args.p_id==='two').args.p_sent,false);
});
test('daily report CSVs escape supplier text, distinguish planning from redemption and contain no buyer contacts',()=>{
 const message=reconciliationEmail({supplier_name:'<Retailer>',report_date:'2026-10-25',generated_at:'2026-10-26T00:15:00+02:00',current_account:{available_cents:3098},
  entries:[],batches:[],planning:[{branch_name:'=EVIL()',recipient_town:'Town',product_name:'Rice',voucher_count:2,awaiting_count:1,redeemable_count:1}],redemptions:[]});
 assert.match(message.html,/&lt;Retailer&gt;/);assert.match(message.html,/Redemption never deducts/);assert.equal(message.attachments.length,5);
 const planning=new TextDecoder().decode(message.attachments.find(a=>a.filename.startsWith('collection-planning-')).content);assert.ok(planning.includes("'=EVIL()"));assert.ok(!planning.includes('mobile'));
 assert.ok(csv([['x,y','a"b',-10,'-formula']]).includes('"x,y","a""b","-10","\'-formula"'));
 assert.match(readySms({voucher_code:'PAD-123',supplier_name:'Retailer',town:'Windhoek',branch_name:'Central'}),/PAD-123.*ready to redeem/);
});
