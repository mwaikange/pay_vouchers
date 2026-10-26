export const PROOF_BUCKET='paysme-voucher-payment-proofs';
const types={pdf:'application/pdf',jpg:'image/jpeg',png:'image/png',webp:'image/webp'};
export async function loadPaymentProofs(db,payments) {
 if(!payments?.length)throw new Error('Proof of payment is required before sending this email.');
 const files=[];const seen=new Set();let total=0;
 for(const payment of payments){
  const path=payment.proof_object_path;
  if(typeof path!=='string'||!/^[0-9a-f-]{36}\/[0-9a-f-]{36}\.(pdf|jpg|png|webp)$/.test(path))throw new Error('Proof of payment is required before sending this email.');
  if(seen.has(path))continue;seen.add(path);
  const {data,error}=await db.storage.from(PROOF_BUCKET).download(path);
  if(error||!data)throw new Error('The proof of payment could not be loaded. No email was sent.');
  total+=data.size;
  if(!data.size||data.size>5242880||total>15728640)throw new Error('Proof files are too large to email. Upload smaller files before trying again.');
  const extension=path.split('.').pop();
  const reference=String(payment.reference||files.length+1).replace(/[^a-zA-Z0-9_-]/g,'-').slice(0,60);
  files.push({filename:`POP-${reference}.${extension}`,contentType:types[extension],encoding:'binary',content:new Uint8Array(await data.arrayBuffer())});
 }
 return files;
}
export async function signedPaymentProofs(db,payments) {
 return Promise.all(payments.map(async({proof_object_path,...payment})=>{
  if(!proof_object_path)return payment;
  const {data,error}=await db.storage.from(PROOF_BUCKET).createSignedUrl(proof_object_path,900);
  return {...payment,...(!error&&data?.signedUrl?{proof_url:data.signedUrl}:{})};
 }));
}
