import {reconciliationEmail,readySms} from './prepaid.mjs';
export async function deliverNotifications(jobs,{db,sendEmail,sendSms}) {
 const counts={accepted:0,failed:0};let next=0;
 const run=async()=>{while(next<jobs.length){const job=jobs[next++];let sent=false;
  try{
   if(job.kind==='ready_sms')await sendSms(job.payload.mobile,readySms(job.payload));
   else if(job.kind==='daily_email'){const message=reconciliationEmail(job.payload);await sendEmail(job.payload.to,message.subject,message.html,message.attachments);}
   else throw new Error('Unknown notification kind');
   sent=true;
  }catch{console.error('Voucher notification delivery failed',{event_id:job.id,kind:job.kind});}
  try{const {data,error}=await db.rpc('paysme_voucher_finish_notification',{p_id:job.id,p_lease_id:job.lease_id,p_sent:sent});if(error||data!==true)throw new Error('Lease acknowledgement failed');}
  catch{console.error('Voucher notification acknowledgement failed',{event_id:job.id});counts.failed++;continue;}
  if(sent)counts.accepted++;else counts.failed++;
 }};
 await Promise.all(Array.from({length:Math.min(5,jobs.length)},run));return counts;
}
export async function claimNotifications(db,token) {
 if(typeof token!=='string'||!/^\d{10}:[0-9a-f-]{36}:[0-9a-f]{64}$/.test(token))return{unauthorized:true};
 const {data,error}=await db.rpc('paysme_voucher_claim_notifications',{p_worker_token:token,p_limit:50});
 if(error)return error.code==='42501'?{unauthorized:true}:{unavailable:true};
 if(!Array.isArray(data))return{unavailable:true};return{jobs:data};
}
