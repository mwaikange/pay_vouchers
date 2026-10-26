import {STAFF_ACTIONS,CONFIRM_ACTIONS,SUPPLIER_ACTIONS,randomToken,randomOtp,hash,confirmationUrl,batchMessage,escapeHtml,receiptHtml,emailHint,paymentMessage} from './core.mjs';
import {prepaidEmail} from './prepaid.mjs';
import {claimNotifications,deliverNotifications} from './notifications.mjs';

const headers={'Content-Type':'application/json','Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info,x-voucher-api-key','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
const supplierRoutes={'verify':'verify_voucher','validate-id':'validate_id','request-otp':'request_recipient_otp','validate-otp':'validate_recipient_otp','redeem':'redeem_voucher','receipt':'get_receipt'};
async function readBody(req) {
 const reader=req.body?.getReader(); if(!reader) throw new Error('Request body required');
 let size=0; const chunks=[];
 while(true) { const {done,value}=await reader.read(); if(done)break; size+=value.length; if(size>16384){await reader.cancel();throw new Error('Request too large');} chunks.push(value); }
 const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 return JSON.parse(new TextDecoder().decode(bytes));
}
export function createHandler({db,sendEmail,sendSms,backgroundTask,loadProofAttachments=async()=>[],proofLinks=async payments=>payments.map(({proof_object_path,...payment})=>payment)}) {
 return async req=>{
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply({service:'PaySME Vouchers',message:'Use the authenticated POST API.'},405);
  let action;
  try {
   const input=await readBody(req);
   if(!input||typeof input!=='object'||Array.isArray(input))return reply({error:'Invalid request'},400);
   const routeAction=supplierRoutes[new URL(req.url).pathname.split('/').filter(Boolean).pop()];
   action=routeAction||input.action;
   if(action==='process_notifications'){
    const claimed=await claimNotifications(db,req.headers.get('x-voucher-worker-token'));
    if(claimed.unauthorized)return reply({error:'Worker authentication required'},401);
    if(claimed.unavailable)return reply({error:'Notification worker unavailable'},503);
    const delivery=deliverNotifications(claimed.jobs,{db,sendEmail,sendSms});
    if(backgroundTask){backgroundTask(delivery);return reply({queued:claimed.jobs.length},202);}
    return reply(await delivery);
   }
   if(!STAFF_ACTIONS.has(action)&&!CONFIRM_ACTIONS.has(action)&&!SUPPLIER_ACTIONS.has(action))return reply({error:'Unsupported operation'},400);
   const rawArgs=routeAction?(input.args||input):input.args;
   if(!rawArgs||typeof rawArgs!=='object'||Array.isArray(rawArgs))return reply({error:'Invalid arguments'},400);
   const args={...rawArgs}; delete args.action; delete args.actor_id; delete args.api_key_hash; delete args.api_key;
   let rawKey; let token; let otp; let smsOtp; let emailOtp;
   if(STAFF_ACTIONS.has(action)) {
    const auth=req.headers.get('Authorization')||'';
    const match=auth.match(/^Bearer (.+)$/i);if(!match)return reply({error:'Staff sign-in required'},401);
    const {data,error}=await db.auth.getUser(match[1]);if(error||!data.user)return reply({error:'Staff sign-in required'},401);
    args.actor_id=data.user.id;
    if(['start_confirmation','record_prepayment','start_prepayment_confirmation'].includes(action)||(action==='save_supplier'&&args.initial_prepayment)){
     token=randomToken();args.token=token;args.confirmation_url=confirmationUrl(args.portal_url,token);
    }
    if(action==='issue_api_key'){rawKey='PVK-'+randomToken();args.api_key=rawKey;}
   } else if(CONFIRM_ACTIONS.has(action)) {
    if(typeof args.token!=='string'||!/^[0-9a-f]{64}$/.test(args.token))return reply({error:'Invalid confirmation link'},400);
    if(action==='confirmation_otp'){otp=randomOtp();args.otp=otp;}
   } else {
    const apiKey=req.headers.get('x-voucher-api-key');if(!apiKey||apiKey.length<64||apiKey.length>200)return reply({error:'Supplier API credential required'},401);
    args.api_key_hash=await hash(apiKey);
    if(action==='request_recipient_otp'){smsOtp=randomOtp();do{emailOtp=randomOtp();}while(emailOtp===smsOtp);args.sms_otp=smsOtp;args.email_otp=emailOtp;}
   }
   const {data,error}=await db.rpc('paysme_voucher_command',{action,args});
   if(error) {
    // SQL validation errors contain no recipient details; never log request bodies or secrets.
    if(error.code==='42501')return reply({error:'Voucher administrator access required'},403);
    const safeMessages=new Set(['Upload a valid proof of payment before recording the bank payment','Upload a valid proof of payment for this batch','Recorded payment not found in this batch','Attach proof of payment to every bank payment before sending confirmation','Record the full payment before requesting confirmation','Upload a valid proof of payment for this prepayment','Record the initial prepaid deposit and POP when selecting prepaid terms','Insufficient confirmed prepaid credit for this batch','This bank reference is already recorded against a batch','This bank reference is already recorded as a prepaid deposit','Prepayment reference conflicts with an existing record','Select prepaid terms before recording prepaid funds','Confirmed prepaid deposits cannot be edited','Prepayment is confirmed or needs discrepancy resolution','Resolve any discrepancy before requesting prepaid batch approval','An investigation or amendment note is required','Use the supplier prepaid account for this batch; do not record a batch bank payment','No eligible unbatched vouchers','Choose a cutoff no later than now','Prepaid account balance limit exceeded','Resolve the supplier balance issue before sending prepaid batch approvals']);
    return reply({error:safeMessages.has(error.message)?error.message:'Operation could not be completed. Check the current status and request fields.'},409);
   }
   if(data?.error)return reply({error:data.error},409);
   if(data?.confirmation_type&&['start_confirmation','save_supplier','record_prepayment','start_prepayment_confirmation','confirmation_otp'].includes(action)){
    const deposit=data.confirmation_type==='prepayment';
    const attachments=deposit?await loadProofAttachments(data.payments||[]):[];
    const message=prepaidEmail(data,{url:args.confirmation_url,otp:action==='confirmation_otp'?otp:undefined});
    if(action==='confirmation_otp'){
     await sendEmail(data.supervisor_email,message.subject,message.html,attachments);
     const hint=emailHint(data.supervisor_email);
     return reply({sent:true,message:`The mail server accepted the approval-code email for ${hint}. Check that inbox and its spam folder.`,supervisor_email_hint:hint});
    }
    await sendEmail(data.finance_email,message.subject,message.html,attachments);
    // Both retailer contacts review PaySME's payment/allocation. This path runs only after the database's funding check succeeds.
    await sendEmail(data.supervisor_email,message.subject,message.html,attachments);
    return reply({saved:data.saved||false,supplier_id:data.supplier_id,prepayment_id:data.prepayment_id,sent:true,batch_reference:data.batch_reference,
     message:deposit?"The mail server accepted the PaySME prepayment review email for finance and supervisor. PaySME's funds remain pending until OTP approval.":"The mail server accepted the PaySME batch review email for finance and supervisor. PaySME's funds are reserved until OTP approval."});
   }
   if(action==='start_confirmation') {
    const b={...data.batch,payment_recorded_cents:data.payment_recorded_cents,customer_voucher_value_cents:data.customer_voucher_value_cents};
    const attachments=await loadProofAttachments(data.payments||[]);
    await sendEmail(data.finance_email,'PaySME payment confirmation: '+b.batch_reference,
     `<h2>Bank payment confirmation</h2><p>${batchMessage(b)}</p><p>Bank payment references:<br>${paymentMessage(data.payments)}</p><p>Proof of payment is attached. Compare the payment with your bank records, then request the approval code sent to your registered supervisor.</p><p><a href="${escapeHtml(args.confirmation_url)}">Review batch payment</a></p><p>This link expires in 48 hours. For discrepancies, report the issue on the confirmation page. Contact PaySME: support@paysme.site.</p>`,attachments);
    return reply({sent:true,batch_reference:b.batch_reference});
   }
   if(action==='confirmation_otp') {
    const attachments=await loadProofAttachments(data.payments||[]);
    await sendEmail(data.supervisor_email,'PaySME supervisor approval: '+data.batch_reference,
     `<h2>Bank payment approval</h2><p>${batchMessage(data)}</p><p>Bank payment references:<br>${paymentMessage(data.payments)}</p><p>Proof of payment is attached. Check the payment independently. If correct, give this approval code to your finance colleague:</p><h2>${otp}</h2><p>Expires in 10 minutes. If anything differs, do not share the code; contact PaySME: support@paysme.site.</p>`,attachments);
    const hint=emailHint(data.supervisor_email);
    return reply({sent:true,message:`The mail server accepted the approval-code email for ${hint}. Check that inbox and its spam folder.`,supervisor_email_hint:hint});
   }
   if(action==='confirmation_details'){
    const {finance_email,supervisor_email,...details}=data;
    return reply({...details,payments:await proofLinks(data.payments||[])});
   }
   if(action==='request_recipient_otp') {
    // Both deliveries must succeed. A failed delivery never grants verification or redemption.
    await sendEmail(data.email,'PaySME voucher redemption code',`<p>Your voucher redemption email code is <b>${emailOtp}</b>. It expires in 10 minutes. Present both your SMS and email codes at the supplier store. If you did not request this, contact PaySME.</p>`);
    await sendSms(data.mobile_number,`PaySME voucher SMS code: ${smsOtp}. Expires in 10 minutes. Present this and your email code at the store. Need help? Contact PaySME.`);
    return reply({verification_id:data.verification_id,sent:true,expires_in_seconds:600});
   }
   if(action==='issue_api_key')return reply({...data,api_key:rawKey,message:'Copy now. This key is shown once. Store it only on the supplier server.'});
   if(action==='get_receipt'&&rawArgs.format==='html')return reply({receipt:data,html:receiptHtml(data,String(rawArgs.width||'80'))});
   return reply(data);
  } catch(error) {
   if(error instanceof SyntaxError)return reply({error:'Invalid JSON request'},400);
   if(error.message?.startsWith('Publish the portal'))return reply({error:error.message},400);
   if(error.message==='Request too large')return reply({error:error.message},413);
   if(['Proof of payment is required before sending this email.','The proof of payment could not be loaded. No email was sent.','Proof files are too large to email. Upload smaller files before trying again.','The mail server did not accept the email. Please retry after the cooldown or contact PaySME.'].includes(error.message))return reply({error:error.message},503);
   // No provider error bodies, OTPs, ID numbers or email addresses in public errors/logs.
   console.error('Voucher operation failed',{action:typeof action==='string'?action:'invalid',event_id:crypto.randomUUID()});
   return reply({error:'Request or notification could not be completed. No confirmation or redemption was granted by a notification failure. Retry after the cooldown or contact PaySME.'},503);
  }
 };
}
