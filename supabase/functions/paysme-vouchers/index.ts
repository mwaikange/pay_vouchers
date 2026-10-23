import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.104.0';
import {SMTPClient} from 'https://deno.land/x/denomailer@1.6.0/mod.ts';
import {createHandler} from './handler.mjs';

const base=Deno.env.get('SUPABASE_URL')!;
const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const db=createClient(base,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
async function sendEmail(to:string,subject:string,html:string) {
 const required=['SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','SMTP_FROM_EMAIL'];
 if(required.some(name=>!Deno.env.get(name)))throw new Error('Email service is not configured');
 const client=new SMTPClient({connection:{hostname:Deno.env.get('SMTP_HOST')!,port:Number(Deno.env.get('SMTP_PORT')||'587'),tls:true,auth:{username:Deno.env.get('SMTP_USERNAME')!,password:Deno.env.get('SMTP_PASSWORD')!}}});
 try { await client.send({from:`${Deno.env.get('SMTP_FROM_NAME')||'PaySME'} <${Deno.env.get('SMTP_FROM_EMAIL')}>`,to,subject,html}); }
 finally {await client.close();}
}
async function sendSms(mobile:string,content:string) {
 const response=await fetch(base+'/functions/v1/send-sms',{method:'POST',headers:{Authorization:'Bearer '+serviceKey,apikey:serviceKey,'Content-Type':'application/json'},body:JSON.stringify({action:'send_single',payload:{mobile,content}})});
 if(!response.ok)throw new Error('SMS service unavailable');
 const result=await response.json();if(result.error||result.success===false)throw new Error('SMS not accepted');
}
Deno.serve(createHandler({db,sendEmail,sendSms}));
