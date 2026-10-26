import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.104.0';
import {SMTPClient} from 'https://deno.land/x/denomailer@1.6.0/mod.ts';
import {createHandler} from './handler.mjs';
import {emailHint} from './core.mjs';
import {loadPaymentProofs,signedPaymentProofs} from './payment-proofs.mjs';

const base=Deno.env.get('SUPABASE_URL')!;
const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const db=createClient(base,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
async function sendEmail(to:string,subject:string,html:string,attachments:any[]=[]) {
 const required=['SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','SMTP_FROM_EMAIL'];
 if(required.some(name=>!Deno.env.get(name)))throw new Error('Email service is not configured');
 const port=Number(Deno.env.get('SMTP_PORT')||'587');
 const tls=Deno.env.get('SMTP_TLS')===undefined?port===465:Deno.env.get('SMTP_TLS')==='true';
 const eventId=crypto.randomUUID();
 const client=new SMTPClient({connection:{hostname:Deno.env.get('SMTP_HOST')!,port,tls,auth:{username:Deno.env.get('SMTP_USERNAME')!,password:Deno.env.get('SMTP_PASSWORD')!}},client:{warning:'error'}});
 try {
  await client.send({from:`${Deno.env.get('SMTP_FROM_NAME')||'PaySME'} <${Deno.env.get('SMTP_FROM_EMAIL')}>`,to,subject,content:'auto',html,attachments,replyTo:Deno.env.get('SMTP_REPLY_TO')||'support@paysme.site'});
  console.info('Voucher email accepted by SMTP',{event_id:eventId,kind:subject.startsWith('PaySME supervisor')?'supervisor_approval':'voucher_notification',recipient_hint:emailHint(to),attachment_count:attachments.length});
 } catch(error) {
  console.error('Voucher email rejected by SMTP',{event_id:eventId,smtp_code:String(error?.message||'').match(/\b[245][0-9]{2}\b/)?.[0]||null});
  throw new Error('The mail server did not accept the email. Please retry after the cooldown or contact PaySME.');
 } finally {try{await client.close();}catch{/* A close failure does not undo an accepted email. */}}
}
async function sendSms(mobile:string,content:string) {
 const response=await fetch(base+'/functions/v1/send-sms',{method:'POST',headers:{Authorization:'Bearer '+serviceKey,apikey:serviceKey,'Content-Type':'application/json'},body:JSON.stringify({action:'send_single',payload:{mobile,content}})});
 if(!response.ok)throw new Error('SMS service unavailable');
 const result=await response.json();if(result.error||result.success===false)throw new Error('SMS not accepted');
}
Deno.serve(createHandler({db,sendEmail,sendSms,loadProofAttachments:payments=>loadPaymentProofs(db,payments),proofLinks:payments=>signedPaymentProofs(db,payments)}));
