begin;
-- Service-only transactional backend. Browser access goes through authenticated Edge routes.
create table paysme_voucher_private.identity_key (
 id boolean primary key default true check(id), secret bytea not null
);
insert into paysme_voucher_private.identity_key(secret) values(extensions.gen_random_bytes(32));
create table paysme_voucher_private.supplier_api_keys (
 id uuid primary key default gen_random_uuid(), supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 branch_id uuid references public.paysme_voucher_branches(id), label text not null,
 key_hash text not null unique, created_at timestamptz not null default now(), revoked_at timestamptz,
 rate_window timestamptz not null default now(), rate_count integer not null default 0
);
create index voucher_keys_supplier_idx on paysme_voucher_private.supplier_api_keys(supplier_id);
create index voucher_keys_branch_idx on paysme_voucher_private.supplier_api_keys(branch_id);
alter table paysme_voucher_private.identity_key enable row level security;
alter table paysme_voucher_private.supplier_api_keys enable row level security;
revoke all on all tables in schema paysme_voucher_private from public,anon,authenticated,service_role;

create function paysme_voucher_private.hash(value text) returns text
language sql immutable strict set search_path='' as $$ select encode(sha256(convert_to(value,'UTF8')),'hex'); $$;
create function paysme_voucher_private.id_hash(value text) returns text
language sql stable strict set search_path='' as $$
 select encode(extensions.hmac(convert_to(upper(regexp_replace(value,'[^a-zA-Z0-9]','','g')),'UTF8'),secret,'sha256'),'hex')
 from paysme_voucher_private.identity_key where id;
$$;

-- One service-only entry point keeps locks, permissions and state transitions together.
-- The Edge handler verifies staff JWTs or supplies a credential hash; it never trusts caller actor IDs.
create function public.paysme_voucher_command(action text, args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 a public.admin_users%rowtype; sup public.paysme_voucher_suppliers%rowtype;
 p public.paysme_voucher_products%rowtype; s public.paysme_voucher_sales%rowtype;
 v public.paysme_vouchers%rowtype; b public.paysme_voucher_payment_batches%rowtype;
 c paysme_voucher_private.supplier_confirmations%rowtype;
 k paysme_voucher_private.supplier_api_keys%rowtype;
 recipient paysme_voucher_private.voucher_recipients%rowtype;
 verification paysme_voucher_private.redemption_sessions%rowtype;
 receipt public.paysme_voucher_redemptions%rowtype;
 batch_uuid uuid; new_id uuid; cust_id uuid; ids uuid[]; total bigint; qty integer;
 branch_uuid uuid; staff_ref text; result jsonb; normalized_id text;
begin
 if jsonb_typeof(args)<>'object' then raise exception 'Invalid request'; end if;
 -- Staff operations use the existing directory and current permissions on every call.
 if action in ('prepare_batch','record_payment','start_confirmation','resolve_discrepancy','issue_api_key','revoke_api_key') then
   select * into a from public.admin_users where auth_user_id=(args->>'actor_id')::uuid and is_active and setup_status='active';
   if not found or not (a.role='super_admin' or coalesce(a.permissions #> '{vouchers,manage_suppliers}'='true'::jsonb,false)) then
     raise exception 'Voucher administrator required' using errcode='42501';
   end if;
   staff_ref:=a.auth_user_id::text;
   perform set_config('request.jwt.claim.sub',staff_ref,true);
 end if;

 if action='record_paid_sale' then
   -- INTERNAL ONLY: no Edge route exposes this until atomic wallet integration is implemented.
   perform pg_advisory_xact_lock(hashtextextended(args->>'request_key',1));
   select * into s from public.paysme_voucher_sales where request_key=(args->>'request_key')::uuid;
   if found then
     if s.payment_reference<>args->>'payment_reference' or s.product_id<>(args->>'product_id')::uuid then raise exception 'Idempotency conflict'; end if;
     select * into v from public.paysme_vouchers where sale_id=s.id;
     return jsonb_build_object('sale_id',s.id,'voucher_code',v.code,'replayed',true);
   end if;
   select * into p from public.paysme_voucher_products where id=(args->>'product_id')::uuid and active for share;
   if not found then raise exception 'Product unavailable'; end if;
   select * into sup from public.paysme_voucher_suppliers where id=p.supplier_id and active for share;
   if not found then raise exception 'Supplier unavailable'; end if;
   branch_uuid:=(args->>'branch_id')::uuid;
   if branch_uuid is not null and not exists(select 1 from public.paysme_voucher_branches where id=branch_uuid and supplier_id=sup.id and active) then raise exception 'Invalid branch'; end if;
   normalized_id:=upper(regexp_replace(args->>'id_number','[^a-zA-Z0-9]','','g'));
   if length(normalized_id) not between 5 and 40 then raise exception 'Valid recipient ID required'; end if;
   -- Reuse provisional contact profiles only; a mobile match is never proof of identity.
   insert into public.paysme_customers(mobile_number,full_name,email,town,source)
   values(args->>'mobile_number',args->>'full_name',lower(trim(args->>'email')),args->>'town','vendor_purchase')
   on conflict (mobile_number) do update set mobile_number=excluded.mobile_number returning id into cust_id;
   insert into public.paysme_voucher_sales(request_key,payment_reference,vendor_reference,customer_id,product_id,supplier_id,planned_branch_id,
     product_name,product_contents,product_description,entitlement_type,redemption_value_cents,supplier_base_cents,markup_cents,instore_price_cents,rebate_cents,rebate_timing,vendor_commission_cents)
   values((args->>'request_key')::uuid,args->>'payment_reference',args->>'vendor_reference',cust_id,p.id,sup.id,branch_uuid,
     p.name,coalesce(p.product_list,''),coalesce(p.description,''),p.entitlement_type,p.redemption_value_cents,p.supplier_price_cents,p.markup_cents,p.instore_price_cents,p.rebate_cents,p.rebate_timing,p.vendor_commission_cents)
   returning * into s;
   insert into public.paysme_vouchers(sale_id,code) values(s.id,'PAD-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'))) returning * into v;
   insert into paysme_voucher_private.voucher_recipients(voucher_id,full_name,mobile_number,email,town,id_fingerprint,id_last4)
   values(v.id,args->>'full_name',args->>'mobile_number',lower(trim(args->>'email')),args->>'town',paysme_voucher_private.id_hash(normalized_id),right(normalized_id,4));
   return jsonb_build_object('sale_id',s.id,'voucher_code',v.code,'status',v.status);
 end if;

 if action='prepare_batch' then
   select * into sup from public.paysme_voucher_suppliers where id=(args->>'supplier_id')::uuid and active for update;
   if not found then raise exception 'Active supplier required'; end if;
   if (args->>'cutoff_at')::timestamptz>now() then raise exception 'Cutoff cannot be in the future'; end if;
   select array_agg(eligible.id),sum(eligible.supplier_due_cents),count(*) into ids,total,qty from (
     select vv.id,ss.supplier_due_cents from public.paysme_vouchers vv join public.paysme_voucher_sales ss on ss.id=vv.sale_id
     where ss.supplier_id=sup.id and ss.status='paid' and ss.paid_at<=(args->>'cutoff_at')::timestamptz and vv.status='awaiting_settlement'
     and not exists(select 1 from public.paysme_voucher_batch_items i where i.voucher_id=vv.id)
     order by vv.id for update of vv
   ) eligible;
   if qty=0 then raise exception 'No eligible unbatched paid vouchers'; end if;
   insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference)
   values(sup.id,sup.business_name,sup.finance_email,sup.supervisor_email,(args->>'cutoff_at')::timestamptz,qty,total,staff_ref) returning * into b;
   insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents)
   select b.id,vv.id,ss.id,ss.supplier_due_cents from public.paysme_vouchers vv join public.paysme_voucher_sales ss on ss.id=vv.sale_id where vv.id=any(ids);
   return to_jsonb(b);
 end if;

 if action in ('record_payment','start_confirmation','resolve_discrepancy') then
   select * into b from public.paysme_voucher_payment_batches where id=(args->>'batch_id')::uuid for update;
   if not found or b.status='settled' then raise exception 'Batch unavailable or already settled'; end if;
   if action='record_payment' then
     select to_jsonb(pay) into result from public.paysme_voucher_batch_payments pay where bank_transaction_reference=trim(args->>'bank_reference');
     if result is not null then
       if result->>'batch_id'<>b.id::text or (result->>'amount_cents')::bigint<>(args->>'amount_cents')::bigint then raise exception 'Payment reference already used'; end if;
       return jsonb_build_object('replayed',true);
     end if;
     insert into public.paysme_voucher_batch_payments(batch_id,bank_transaction_reference,amount_cents,recorded_by_staff_reference)
     values(b.id,trim(args->>'bank_reference'),(args->>'amount_cents')::bigint,staff_ref);
     update public.paysme_voucher_payment_batches set version=version+1,status=case when status='disputed' then 'disputed' else 'payment_submitted' end where id=b.id;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null and revoked_at is null;
     return jsonb_build_object('recorded',true);
   elsif action='resolve_discrepancy' then
     if b.status<>'disputed' or length(trim(args->>'note')) not between 3 and 2000 then raise exception 'Resolution note required for disputed batch'; end if;
     update public.paysme_voucher_batch_discrepancies set status='resolved',resolved_at=now(),resolved_by_staff_reference=staff_ref,resolution_note=args->>'note' where batch_id=b.id and status='open';
     update public.paysme_voucher_payment_batches set status='payment_submitted',version=version+1 where id=b.id;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null and revoked_at is null;
     return jsonb_build_object('resolved',true,'supplier_reconfirmation_required',true);
   else
     if b.status='disputed' then raise exception 'Resolve discrepancy before requesting confirmation'; end if;
     select coalesce(sum(amount_cents),0) into total from public.paysme_voucher_batch_payments where batch_id=b.id;
     if total<b.amount_due_cents then raise exception 'Record the full payment before requesting confirmation'; end if;
     if length(args->>'token')<>64 then raise exception 'Invalid confirmation token'; end if;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null and revoked_at is null;
     update public.paysme_voucher_payment_batches set status='awaiting_confirmation',version=version+1 where id=b.id returning * into b;
     insert into paysme_voucher_private.supplier_confirmations(batch_id,batch_version,token_hash,finance_email,supervisor_email,expires_at)
     values(b.id,b.version,paysme_voucher_private.hash(args->>'token'),b.finance_email,b.supervisor_email,now()+interval '48 hours');
     return jsonb_build_object('batch',to_jsonb(b),'finance_email',b.finance_email);
   end if;
 end if;

 if action in ('confirmation_details','confirmation_otp','confirm_batch','report_discrepancy') then
   -- Lock order is always batch then challenge, including payment edits and revocations.
   select batch_id into batch_uuid from paysme_voucher_private.supplier_confirmations where token_hash=paysme_voucher_private.hash(args->>'token');
   select * into b from public.paysme_voucher_payment_batches where id=batch_uuid for update;
   select * into c from paysme_voucher_private.supplier_confirmations where token_hash=paysme_voucher_private.hash(args->>'token') for update;
   if c.id is null or c.consumed_at is not null or c.revoked_at is not null or c.expires_at<=now() or c.batch_version<>b.version or b.status<>'awaiting_confirmation' then
     return jsonb_build_object('error','Confirmation link is invalid, expired or already used');
   end if;
   select coalesce(sum(amount_cents),0) into total from public.paysme_voucher_batch_payments where batch_id=b.id;
   if action='confirmation_details' then
     return jsonb_build_object('batch_reference',b.batch_reference,'supplier_name',b.supplier_name,'amount_due_cents',b.amount_due_cents,'payment_recorded_cents',total,'voucher_count',b.voucher_count,'expires_at',c.expires_at,
       'payments',(select coalesce(jsonb_agg(jsonb_build_object('reference',bank_transaction_reference,'amount_cents',amount_cents,'recorded_at',recorded_at)),'[]'::jsonb) from public.paysme_voucher_batch_payments where batch_id=b.id));
   elsif action='confirmation_otp' then
     if c.otp_send_count>=5 or c.otp_attempts>=5 or c.otp_last_sent_at>now()-interval '60 seconds' then return jsonb_build_object('error','Please wait or request a new confirmation link'); end if;
     if args->>'otp' !~ '^[0-9]{6}$' then raise exception 'Invalid OTP'; end if;
     update paysme_voucher_private.supplier_confirmations set otp_digest=paysme_voucher_private.hash((args->>'token')||':'||(args->>'otp')),otp_expires_at=now()+interval '10 minutes',otp_last_sent_at=now(),otp_send_count=otp_send_count+1 where id=c.id;
     return jsonb_build_object('supervisor_email',c.supervisor_email,'batch_reference',b.batch_reference,'supplier_name',b.supplier_name,'amount_due_cents',b.amount_due_cents,'voucher_count',b.voucher_count,'payment_recorded_cents',total);
   elsif action='report_discrepancy' then
     insert into public.paysme_voucher_batch_discrepancies(batch_id,confirmation_id,reason,comment,reported_by_email)
     values(b.id,c.id,args->>'reason',coalesce(args->>'comment',''),c.finance_email);
     update public.paysme_voucher_payment_batches set status='disputed',version=version+1 where id=b.id;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null;
     return jsonb_build_object('reported',true,'message','PaySME will investigate. Vouchers remain on hold.');
   else
     if c.otp_digest is null or c.otp_expires_at<=now() or c.otp_attempts>=5 then return jsonb_build_object('error','Approval OTP expired or unavailable'); end if;
     if paysme_voucher_private.hash((args->>'token')||':'||coalesce(args->>'otp',''))<>c.otp_digest then
       update paysme_voucher_private.supplier_confirmations set otp_attempts=otp_attempts+1 where id=c.id;
       return jsonb_build_object('error','Incorrect approval code');
     end if;
     if total<b.amount_due_cents then raise exception 'Insufficient recorded payment'; end if;
     select count(*),coalesce(sum(i.supplier_due_cents),0) into qty,total from public.paysme_voucher_batch_items i join public.paysme_vouchers vv on vv.id=i.voucher_id join public.paysme_voucher_sales ss on ss.id=i.sale_id
       where i.batch_id=b.id and vv.status='awaiting_settlement' and ss.status='paid' and ss.supplier_id=b.supplier_id;
     if qty<>b.voucher_count or total<>b.amount_due_cents then raise exception 'Batch membership mismatch; contact PaySME'; end if;
     update public.paysme_voucher_payment_batches set status='settled',settled_at=now(),confirmed_payment_cents=(select sum(amount_cents) from public.paysme_voucher_batch_payments where batch_id=b.id) where id=b.id;
     update public.paysme_vouchers set status='redeemable',redeemable_at=now() where id in(select voucher_id from public.paysme_voucher_batch_items where batch_id=b.id);
     update paysme_voucher_private.supplier_confirmations set consumed_at=now() where id=c.id;
     return jsonb_build_object('confirmed',true,'voucher_count',b.voucher_count);
   end if;
 end if;

 if action='issue_api_key' then
   select * into sup from public.paysme_voucher_suppliers where id=(args->>'supplier_id')::uuid and active;
   if not found or length(args->>'api_key')<64 or length(trim(args->>'label')) not between 1 and 100 then raise exception 'Invalid supplier credential request'; end if;
   branch_uuid:=(args->>'branch_id')::uuid;
   if branch_uuid is not null and not exists(select 1 from public.paysme_voucher_branches where id=branch_uuid and supplier_id=sup.id and active) then raise exception 'Invalid credential branch'; end if;
   insert into paysme_voucher_private.supplier_api_keys(supplier_id,branch_id,label,key_hash)
   values(sup.id,branch_uuid,args->>'label',paysme_voucher_private.hash(args->>'api_key')) returning id into new_id;
   insert into public.paysme_voucher_audit_events(actor_user_id,table_name,record_id,action) values(a.auth_user_id,'supplier_api_keys',new_id,'issued');
   return jsonb_build_object('credential_id',new_id);
 elsif action='revoke_api_key' then
   update paysme_voucher_private.supplier_api_keys set revoked_at=now() where id=(args->>'credential_id')::uuid;
   insert into public.paysme_voucher_audit_events(actor_user_id,table_name,record_id,action) values(a.auth_user_id,'supplier_api_keys',(args->>'credential_id')::uuid,'revoked');
   return jsonb_build_object('revoked',true);
 end if;

 if action in ('verify_voucher','validate_id','request_recipient_otp','validate_recipient_otp','redeem_voucher','get_receipt') then
   select * into k from paysme_voucher_private.supplier_api_keys where key_hash=args->>'api_key_hash' and revoked_at is null for update;
   if not found or not exists(select 1 from public.paysme_voucher_suppliers where id=k.supplier_id and active) then return jsonb_build_object('error','Invalid supplier credential'); end if;
   if k.rate_window>now()-interval '1 minute' and k.rate_count>=120 then return jsonb_build_object('error','Rate limit exceeded'); end if;
   update paysme_voucher_private.supplier_api_keys set rate_count=case when rate_window<=now()-interval '1 minute' then 1 else rate_count+1 end,rate_window=case when rate_window<=now()-interval '1 minute' then now() else rate_window end where id=k.id;
   branch_uuid:=coalesce(k.branch_id,(args->>'branch_id')::uuid);
   if not exists(select 1 from public.paysme_voucher_branches where id=branch_uuid and supplier_id=k.supplier_id and active) then return jsonb_build_object('error','Active supplier branch required'); end if;
   staff_ref:=trim(args->>'pos_staff_reference');
   if length(staff_ref) not between 1 and 100 or staff_ref is null then return jsonb_build_object('error','POS staff reference required'); end if;
   select vv.* into v from public.paysme_vouchers vv join public.paysme_voucher_sales ss on ss.id=vv.sale_id where vv.code=upper(trim(args->>'voucher_code')) and ss.supplier_id=k.supplier_id;
   if not found then return jsonb_build_object('error','Voucher unavailable'); end if;
   select * into s from public.paysme_voucher_sales where id=v.sale_id;
   select batch_id into batch_uuid from public.paysme_voucher_batch_items where voucher_id=v.id;
   -- Batch first, voucher second: consistent with settlement to prevent deadlocks.
   select * into b from public.paysme_voucher_payment_batches where id=batch_uuid for update;
   select * into v from public.paysme_vouchers where id=v.id for update;
   if action='get_receipt' then
     select * into receipt from public.paysme_voucher_redemptions where voucher_id=v.id and supplier_id=k.supplier_id;
     if not found then return jsonb_build_object('error','No redemption receipt available'); end if;
     return receipt.receipt_data||jsonb_build_object('receipt_reference',receipt.receipt_reference,'redeemed_at',receipt.redeemed_at);
   end if;
   if action='redeem_voucher' then
     select * into receipt from public.paysme_voucher_redemptions where supplier_id=k.supplier_id and request_key=(args->>'request_key')::uuid;
     if found then
       if receipt.voucher_id<>v.id or receipt.branch_id<>branch_uuid then return jsonb_build_object('error','Idempotency conflict'); end if;
       return receipt.receipt_data||jsonb_build_object('receipt_reference',receipt.receipt_reference,'redeemed_at',receipt.redeemed_at,'replayed',true);
     end if;
   end if;
   if action='verify_voucher' then
     return jsonb_build_object('voucher_code',v.code,'status',v.status,'product_name',s.product_name,'product_contents',s.product_contents,'entitlement_type',s.entitlement_type,'store_credit_cents',s.redemption_value_cents,'customer_price_cents',s.customer_price_cents,'redeemable',v.status='redeemable' and b.status='settled');
   end if;
   if v.status<>'redeemable' or b.id is null or b.status<>'settled' or s.status<>'paid' or b.confirmed_payment_cents<b.amount_due_cents then return jsonb_build_object('error','Voucher is not redeemable'); end if;
   select * into recipient from paysme_voucher_private.voucher_recipients where voucher_id=v.id for update;
   if not found then return jsonb_build_object('error','Recipient record unavailable; contact PaySME'); end if;
   if action='validate_id' then
     if recipient.id_locked_until>now() then return jsonb_build_object('error','Identity check temporarily locked; contact PaySME'); end if;
     if paysme_voucher_private.id_hash(coalesce(args->>'id_number',''))<>recipient.id_fingerprint then
       update paysme_voucher_private.voucher_recipients set id_failures=case when id_locked_until<=now() then 1 else least(id_failures+1,5) end,
         id_locked_until=case when id_failures>=4 then now()+interval '15 minutes' else null end where voucher_id=v.id;
       return jsonb_build_object('error','Identity did not match');
     end if;
     update paysme_voucher_private.voucher_recipients set id_failures=0,id_locked_until=null where voucher_id=v.id;
     insert into paysme_voucher_private.redemption_sessions(voucher_id,supplier_id,branch_id,method,status,pos_staff_reference,expires_at,verified_at)
     values(v.id,k.supplier_id,branch_uuid,'physical_id','verified',staff_ref,now()+interval '5 minutes',now()) returning id into new_id;
     return jsonb_build_object('verification_id',new_id,'expires_in_seconds',300);
   elsif action='request_recipient_otp' then
     if (select count(*) from paysme_voucher_private.redemption_sessions where voucher_id=v.id and method='sms_email_otp' and created_at>now()-interval '1 hour')>=5
       or exists(select 1 from paysme_voucher_private.redemption_sessions where voucher_id=v.id and method='sms_email_otp' and created_at>now()-interval '60 seconds') then return jsonb_build_object('error','OTP request limit reached; contact PaySME'); end if;
     if args->>'sms_otp' !~ '^[0-9]{6}$' or args->>'email_otp' !~ '^[0-9]{6}$' or args->>'sms_otp'=args->>'email_otp' then raise exception 'Invalid OTP pair'; end if;
     new_id:=gen_random_uuid();
     insert into paysme_voucher_private.redemption_sessions(id,voucher_id,supplier_id,branch_id,method,status,sms_digest,email_digest,pos_staff_reference,expires_at)
     values(new_id,v.id,k.supplier_id,branch_uuid,'sms_email_otp','pending',paysme_voucher_private.hash(new_id::text||':'||(args->>'sms_otp')),paysme_voucher_private.hash(new_id::text||':'||(args->>'email_otp')),staff_ref,now()+interval '10 minutes');
     return jsonb_build_object('verification_id',new_id,'mobile_number',recipient.mobile_number,'email',recipient.email);
   end if;
   select * into verification from paysme_voucher_private.redemption_sessions where id=(args->>'verification_id')::uuid and voucher_id=v.id and supplier_id=k.supplier_id and branch_id=branch_uuid and pos_staff_reference=staff_ref for update;
   if not found or verification.expires_at<=now() or verification.status in ('failed','consumed') then return jsonb_build_object('error','Verification unavailable or expired'); end if;
   if action='validate_recipient_otp' then
     if verification.method<>'sms_email_otp' or verification.status<>'pending' or verification.attempts>=5 then return jsonb_build_object('error','OTP verification unavailable'); end if;
     if paysme_voucher_private.hash(verification.id::text||':'||coalesce(args->>'sms_otp',''))<>verification.sms_digest or paysme_voucher_private.hash(verification.id::text||':'||coalesce(args->>'email_otp',''))<>verification.email_digest then
       update paysme_voucher_private.redemption_sessions set attempts=attempts+1,status=case when attempts>=4 then 'failed' else 'pending' end where id=verification.id;
       return jsonb_build_object('error','OTP pair did not match');
     end if;
     update paysme_voucher_private.redemption_sessions set status='verified',verified_at=now(),expires_at=now()+interval '5 minutes' where id=verification.id;
     return jsonb_build_object('verified',true,'verification_id',verification.id,'expires_in_seconds',300);
   end if;
   if action='redeem_voucher' then
     if verification.status<>'verified' then return jsonb_build_object('error','Complete identity verification first'); end if;
     if b.settlement_consumed_cents+s.supplier_due_cents>b.amount_due_cents or b.redeemed_count>=b.voucher_count then raise exception 'Batch funding limit exceeded'; end if;
     result:=jsonb_build_object('voucher_code',v.code,'supplier_name',b.supplier_name,'branch_name',(select name from public.paysme_voucher_branches where id=branch_uuid),
       'product_name',s.product_name,'product_contents',s.product_contents,'entitlement_type',s.entitlement_type,'store_credit_cents',s.redemption_value_cents,'customer_price_cents',s.customer_price_cents,'currency','NAD','support','Contact PaySME: support@paysme.site','verification_method',verification.method);
     insert into public.paysme_voucher_redemptions(voucher_id,supplier_id,batch_id,branch_id,verification_id,request_key,supplier_due_consumed_cents,receipt_data,pos_staff_reference)
     values(v.id,k.supplier_id,b.id,branch_uuid,verification.id,(args->>'request_key')::uuid,s.supplier_due_cents,result,staff_ref) returning * into receipt;
     update public.paysme_vouchers set status='redeemed',redeemed_at=now() where id=v.id;
     update public.paysme_voucher_payment_batches set settlement_consumed_cents=settlement_consumed_cents+s.supplier_due_cents,redeemed_count=redeemed_count+1 where id=b.id;
     update paysme_voucher_private.redemption_sessions set status='consumed',consumed_at=now() where id=verification.id;
     return result||jsonb_build_object('receipt_reference',receipt.receipt_reference,'redeemed_at',receipt.redeemed_at);
   end if;
 end if;
 raise exception 'Unknown voucher operation';
end $$;
revoke all on function public.paysme_voucher_command(text,jsonb) from public,anon,authenticated;
grant execute on function public.paysme_voucher_command(text,jsonb) to service_role;
revoke all on all functions in schema paysme_voucher_private from public,anon,authenticated,service_role;

-- Staff have read access to ledger snapshots, never direct financial writes.
do $$ declare tbl text; begin
 foreach tbl in array array['paysme_voucher_sales','paysme_vouchers','paysme_voucher_payment_batches','paysme_voucher_batch_items','paysme_voucher_batch_payments','paysme_voucher_batch_discrepancies','paysme_voucher_redemptions'] loop
   execute format('grant select on public.%I to authenticated',tbl);
   execute format('create policy voucher_staff_read on public.%I for select to authenticated using ((select public.paysme_voucher_is_staff()))',tbl);
 end loop;
end $$;

create function paysme_voucher_private.invalidate_contacts() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.finance_email is distinct from new.finance_email or old.supervisor_email is distinct from new.supervisor_email then
   update public.paysme_voucher_payment_batches set finance_email=new.finance_email,supervisor_email=new.supervisor_email,version=version+1,
     status=case when status='awaiting_confirmation' then 'payment_submitted' else status end
   where supplier_id=new.id and status<>'settled';
   update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id in(select id from public.paysme_voucher_payment_batches where supplier_id=new.id and status<>'settled') and consumed_at is null and revoked_at is null;
 end if;
 return new;
end $$;
revoke all on function paysme_voucher_private.invalidate_contacts() from public,anon,authenticated,service_role;
create trigger voucher_contacts_changed after update of finance_email,supervisor_email on public.paysme_voucher_suppliers for each row execute function paysme_voucher_private.invalidate_contacts();
notify pgrst,'reload schema';

-- Purchase-time town snapshot supports supplier planning without exposing identity data.
alter table public.paysme_voucher_sales add column recipient_town text;
update public.paysme_voucher_sales s set recipient_town=r.town from public.paysme_vouchers v join paysme_voucher_private.voucher_recipients r on r.voucher_id=v.id where v.sale_id=s.id;
alter table public.paysme_voucher_sales alter column recipient_town set not null;
alter table public.paysme_voucher_sales add constraint voucher_town_valid check(length(trim(recipient_town)) between 1 and 150);
create or replace function public.paysme_voucher_command(action text, args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 a public.admin_users%rowtype; sup public.paysme_voucher_suppliers%rowtype;
 p public.paysme_voucher_products%rowtype; s public.paysme_voucher_sales%rowtype;
 v public.paysme_vouchers%rowtype; b public.paysme_voucher_payment_batches%rowtype;
 c paysme_voucher_private.supplier_confirmations%rowtype;
 k paysme_voucher_private.supplier_api_keys%rowtype;
 recipient paysme_voucher_private.voucher_recipients%rowtype;
 verification paysme_voucher_private.redemption_sessions%rowtype;
 receipt public.paysme_voucher_redemptions%rowtype;
 batch_uuid uuid; new_id uuid; cust_id uuid; ids uuid[]; total bigint; qty integer;
 branch_uuid uuid; staff_ref text; result jsonb; normalized_id text;
begin
 if jsonb_typeof(args)<>'object' then raise exception 'Invalid request'; end if;
 -- Staff operations use the existing directory and current permissions on every call.
 if action in ('prepare_batch','record_payment','start_confirmation','resolve_discrepancy','issue_api_key','revoke_api_key') then
   select * into a from public.admin_users where auth_user_id=(args->>'actor_id')::uuid and is_active and setup_status='active';
   if not found or not (a.role='super_admin' or coalesce(a.permissions #> '{vouchers,manage_suppliers}'='true'::jsonb,false)) then
     raise exception 'Voucher administrator required' using errcode='42501';
   end if;
   staff_ref:=a.auth_user_id::text;
   perform set_config('request.jwt.claim.sub',staff_ref,true);
 end if;

 if action='record_paid_sale' then
   -- INTERNAL ONLY: no Edge route exposes this until atomic wallet integration is implemented.
   perform pg_advisory_xact_lock(hashtextextended(args->>'request_key',1));
   select * into s from public.paysme_voucher_sales where request_key=(args->>'request_key')::uuid;
   if found then
     if s.payment_reference<>args->>'payment_reference' or s.product_id<>(args->>'product_id')::uuid then raise exception 'Idempotency conflict'; end if;
     select * into v from public.paysme_vouchers where sale_id=s.id;
     return jsonb_build_object('sale_id',s.id,'voucher_code',v.code,'replayed',true);
   end if;
   select * into p from public.paysme_voucher_products where id=(args->>'product_id')::uuid and active for share;
   if not found then raise exception 'Product unavailable'; end if;
   select * into sup from public.paysme_voucher_suppliers where id=p.supplier_id and active for share;
   if not found then raise exception 'Supplier unavailable'; end if;
   branch_uuid:=(args->>'branch_id')::uuid;
   if branch_uuid is not null and not exists(select 1 from public.paysme_voucher_branches where id=branch_uuid and supplier_id=sup.id and active) then raise exception 'Invalid branch'; end if;
   normalized_id:=upper(regexp_replace(args->>'id_number','[^a-zA-Z0-9]','','g'));
   if length(normalized_id) not between 5 and 40 then raise exception 'Valid recipient ID required'; end if;
   -- Reuse provisional contact profiles only; a mobile match is never proof of identity.
   insert into public.paysme_customers(mobile_number,full_name,email,town,source)
   values(args->>'mobile_number',args->>'full_name',lower(trim(args->>'email')),args->>'town','vendor_purchase')
   on conflict (mobile_number) do update set mobile_number=excluded.mobile_number returning id into cust_id;
   insert into public.paysme_voucher_sales(request_key,payment_reference,vendor_reference,customer_id,product_id,supplier_id,planned_branch_id,recipient_town,
     product_name,product_contents,product_description,entitlement_type,redemption_value_cents,supplier_base_cents,markup_cents,instore_price_cents,rebate_cents,rebate_timing,vendor_commission_cents)
   values((args->>'request_key')::uuid,args->>'payment_reference',args->>'vendor_reference',cust_id,p.id,sup.id,branch_uuid,args->>'town',
     p.name,coalesce(p.product_list,''),coalesce(p.description,''),p.entitlement_type,p.redemption_value_cents,p.supplier_price_cents,p.markup_cents,p.instore_price_cents,p.rebate_cents,p.rebate_timing,p.vendor_commission_cents)
   returning * into s;
   insert into public.paysme_vouchers(sale_id,code) values(s.id,'PAD-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'))) returning * into v;
   insert into paysme_voucher_private.voucher_recipients(voucher_id,full_name,mobile_number,email,town,id_fingerprint,id_last4)
   values(v.id,args->>'full_name',args->>'mobile_number',lower(trim(args->>'email')),args->>'town',paysme_voucher_private.id_hash(normalized_id),right(normalized_id,4));
   return jsonb_build_object('sale_id',s.id,'voucher_code',v.code,'status',v.status);
 end if;

 if action='prepare_batch' then
   select * into sup from public.paysme_voucher_suppliers where id=(args->>'supplier_id')::uuid and active for update;
   if not found then raise exception 'Active supplier required'; end if;
   if (args->>'cutoff_at')::timestamptz>now() then raise exception 'Cutoff cannot be in the future'; end if;
   select array_agg(eligible.id),sum(eligible.supplier_due_cents),count(*) into ids,total,qty from (
     select vv.id,ss.supplier_due_cents from public.paysme_vouchers vv join public.paysme_voucher_sales ss on ss.id=vv.sale_id
     where ss.supplier_id=sup.id and ss.status='paid' and ss.paid_at<=(args->>'cutoff_at')::timestamptz and vv.status='awaiting_settlement'
     and not exists(select 1 from public.paysme_voucher_batch_items i where i.voucher_id=vv.id)
     order by vv.id for update of vv
   ) eligible;
   if qty=0 then raise exception 'No eligible unbatched paid vouchers'; end if;
   insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference)
   values(sup.id,sup.business_name,sup.finance_email,sup.supervisor_email,(args->>'cutoff_at')::timestamptz,qty,total,staff_ref) returning * into b;
   insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents)
   select b.id,vv.id,ss.id,ss.supplier_due_cents from public.paysme_vouchers vv join public.paysme_voucher_sales ss on ss.id=vv.sale_id where vv.id=any(ids);
   return to_jsonb(b);
 end if;

 if action in ('record_payment','start_confirmation','resolve_discrepancy') then
   select * into b from public.paysme_voucher_payment_batches where id=(args->>'batch_id')::uuid for update;
   if not found or b.status='settled' then raise exception 'Batch unavailable or already settled'; end if;
   if action='record_payment' then
     select to_jsonb(pay) into result from public.paysme_voucher_batch_payments pay where bank_transaction_reference=trim(args->>'bank_reference');
     if result is not null then
       if result->>'batch_id'<>b.id::text or (result->>'amount_cents')::bigint<>(args->>'amount_cents')::bigint then raise exception 'Payment reference already used'; end if;
       return jsonb_build_object('replayed',true);
     end if;
     insert into public.paysme_voucher_batch_payments(batch_id,bank_transaction_reference,amount_cents,recorded_by_staff_reference)
     values(b.id,trim(args->>'bank_reference'),(args->>'amount_cents')::bigint,staff_ref);
     update public.paysme_voucher_payment_batches set version=version+1,status=case when status='disputed' then 'disputed' else 'payment_submitted' end where id=b.id;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null and revoked_at is null;
     return jsonb_build_object('recorded',true);
   elsif action='resolve_discrepancy' then
     if b.status<>'disputed' or length(trim(args->>'note')) not between 3 and 2000 then raise exception 'Resolution note required for disputed batch'; end if;
     update public.paysme_voucher_batch_discrepancies set status='resolved',resolved_at=now(),resolved_by_staff_reference=staff_ref,resolution_note=args->>'note' where batch_id=b.id and status='open';
     update public.paysme_voucher_payment_batches set status='payment_submitted',version=version+1 where id=b.id;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null and revoked_at is null;
     return jsonb_build_object('resolved',true,'supplier_reconfirmation_required',true);
   else
     if b.status='disputed' then raise exception 'Resolve discrepancy before requesting confirmation'; end if;
     select coalesce(sum(amount_cents),0) into total from public.paysme_voucher_batch_payments where batch_id=b.id;
     if total<b.amount_due_cents then raise exception 'Record the full payment before requesting confirmation'; end if;
     if length(args->>'token')<>64 then raise exception 'Invalid confirmation token'; end if;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null and revoked_at is null;
     update public.paysme_voucher_payment_batches set status='awaiting_confirmation',version=version+1 where id=b.id returning * into b;
     insert into paysme_voucher_private.supplier_confirmations(batch_id,batch_version,token_hash,finance_email,supervisor_email,expires_at)
     values(b.id,b.version,paysme_voucher_private.hash(args->>'token'),b.finance_email,b.supervisor_email,now()+interval '48 hours');
     return jsonb_build_object('batch',to_jsonb(b),'finance_email',b.finance_email);
   end if;
 end if;

 if action in ('confirmation_details','confirmation_otp','confirm_batch','report_discrepancy') then
   -- Lock order is always batch then challenge, including payment edits and revocations.
   select batch_id into batch_uuid from paysme_voucher_private.supplier_confirmations where token_hash=paysme_voucher_private.hash(args->>'token');
   select * into b from public.paysme_voucher_payment_batches where id=batch_uuid for update;
   select * into c from paysme_voucher_private.supplier_confirmations where token_hash=paysme_voucher_private.hash(args->>'token') for update;
   if c.id is null or c.consumed_at is not null or c.revoked_at is not null or c.expires_at<=now() or c.batch_version<>b.version or b.status<>'awaiting_confirmation' then
     return jsonb_build_object('error','Confirmation link is invalid, expired or already used');
   end if;
   select coalesce(sum(amount_cents),0) into total from public.paysme_voucher_batch_payments where batch_id=b.id;
   if action='confirmation_details' then
     return jsonb_build_object('batch_reference',b.batch_reference,'supplier_name',b.supplier_name,'amount_due_cents',b.amount_due_cents,'payment_recorded_cents',total,'voucher_count',b.voucher_count,'expires_at',c.expires_at,
       'payments',(select coalesce(jsonb_agg(jsonb_build_object('reference',bank_transaction_reference,'amount_cents',amount_cents,'recorded_at',recorded_at)),'[]'::jsonb) from public.paysme_voucher_batch_payments where batch_id=b.id));
   elsif action='confirmation_otp' then
     if c.otp_send_count>=5 or c.otp_attempts>=5 or c.otp_last_sent_at>now()-interval '60 seconds' then return jsonb_build_object('error','Please wait or request a new confirmation link'); end if;
     if args->>'otp' !~ '^[0-9]{6}$' then raise exception 'Invalid OTP'; end if;
     update paysme_voucher_private.supplier_confirmations set otp_digest=paysme_voucher_private.hash((args->>'token')||':'||(args->>'otp')),otp_expires_at=now()+interval '10 minutes',otp_last_sent_at=now(),otp_send_count=otp_send_count+1 where id=c.id;
     return jsonb_build_object('supervisor_email',c.supervisor_email,'batch_reference',b.batch_reference,'supplier_name',b.supplier_name,'amount_due_cents',b.amount_due_cents,'voucher_count',b.voucher_count,'payment_recorded_cents',total);
   elsif action='report_discrepancy' then
     insert into public.paysme_voucher_batch_discrepancies(batch_id,confirmation_id,reason,comment,reported_by_email)
     values(b.id,c.id,args->>'reason',coalesce(args->>'comment',''),c.finance_email);
     update public.paysme_voucher_payment_batches set status='disputed',version=version+1 where id=b.id;
     update paysme_voucher_private.supplier_confirmations set revoked_at=now() where batch_id=b.id and consumed_at is null;
     return jsonb_build_object('reported',true,'message','PaySME will investigate. Vouchers remain on hold.');
   else
     if c.otp_digest is null or c.otp_expires_at<=now() or c.otp_attempts>=5 then return jsonb_build_object('error','Approval OTP expired or unavailable'); end if;
     if paysme_voucher_private.hash((args->>'token')||':'||coalesce(args->>'otp',''))<>c.otp_digest then
       update paysme_voucher_private.supplier_confirmations set otp_attempts=otp_attempts+1 where id=c.id;
       return jsonb_build_object('error','Incorrect approval code');
     end if;
     if total<b.amount_due_cents then raise exception 'Insufficient recorded payment'; end if;
     select count(*),coalesce(sum(i.supplier_due_cents),0) into qty,total from public.paysme_voucher_batch_items i join public.paysme_vouchers vv on vv.id=i.voucher_id join public.paysme_voucher_sales ss on ss.id=i.sale_id
       where i.batch_id=b.id and vv.status='awaiting_settlement' and ss.status='paid' and ss.supplier_id=b.supplier_id;
     if qty<>b.voucher_count or total<>b.amount_due_cents then raise exception 'Batch membership mismatch; contact PaySME'; end if;
     update public.paysme_voucher_payment_batches set status='settled',settled_at=now(),confirmed_payment_cents=(select sum(amount_cents) from public.paysme_voucher_batch_payments where batch_id=b.id) where id=b.id;
     update public.paysme_vouchers set status='redeemable',redeemable_at=now() where id in(select voucher_id from public.paysme_voucher_batch_items where batch_id=b.id);
     update paysme_voucher_private.supplier_confirmations set consumed_at=now() where id=c.id;
     return jsonb_build_object('confirmed',true,'voucher_count',b.voucher_count);
   end if;
 end if;

 if action='issue_api_key' then
   select * into sup from public.paysme_voucher_suppliers where id=(args->>'supplier_id')::uuid and active;
   if not found or length(args->>'api_key')<64 or length(trim(args->>'label')) not between 1 and 100 then raise exception 'Invalid supplier credential request'; end if;
   branch_uuid:=(args->>'branch_id')::uuid;
   if branch_uuid is not null and not exists(select 1 from public.paysme_voucher_branches where id=branch_uuid and supplier_id=sup.id and active) then raise exception 'Invalid credential branch'; end if;
   insert into paysme_voucher_private.supplier_api_keys(supplier_id,branch_id,label,key_hash)
   values(sup.id,branch_uuid,args->>'label',paysme_voucher_private.hash(args->>'api_key')) returning id into new_id;
   insert into public.paysme_voucher_audit_events(actor_user_id,table_name,record_id,action) values(a.auth_user_id,'supplier_api_keys',new_id,'issued');
   return jsonb_build_object('credential_id',new_id);
 elsif action='revoke_api_key' then
   update paysme_voucher_private.supplier_api_keys set revoked_at=now() where id=(args->>'credential_id')::uuid;
   insert into public.paysme_voucher_audit_events(actor_user_id,table_name,record_id,action) values(a.auth_user_id,'supplier_api_keys',(args->>'credential_id')::uuid,'revoked');
   return jsonb_build_object('revoked',true);
 end if;

 if action in ('verify_voucher','validate_id','request_recipient_otp','validate_recipient_otp','redeem_voucher','get_receipt') then
   select * into k from paysme_voucher_private.supplier_api_keys where key_hash=args->>'api_key_hash' and revoked_at is null for update;
   if not found or not exists(select 1 from public.paysme_voucher_suppliers where id=k.supplier_id and active) then return jsonb_build_object('error','Invalid supplier credential'); end if;
   if k.rate_window>now()-interval '1 minute' and k.rate_count>=120 then return jsonb_build_object('error','Rate limit exceeded'); end if;
   update paysme_voucher_private.supplier_api_keys set rate_count=case when rate_window<=now()-interval '1 minute' then 1 else rate_count+1 end,rate_window=case when rate_window<=now()-interval '1 minute' then now() else rate_window end where id=k.id;
   branch_uuid:=coalesce(k.branch_id,(args->>'branch_id')::uuid);
   if not exists(select 1 from public.paysme_voucher_branches where id=branch_uuid and supplier_id=k.supplier_id and active) then return jsonb_build_object('error','Active supplier branch required'); end if;
   staff_ref:=trim(args->>'pos_staff_reference');
   if length(staff_ref) not between 1 and 100 or staff_ref is null then return jsonb_build_object('error','POS staff reference required'); end if;
   select vv.* into v from public.paysme_vouchers vv join public.paysme_voucher_sales ss on ss.id=vv.sale_id where vv.code=upper(trim(args->>'voucher_code')) and ss.supplier_id=k.supplier_id;
   if not found then return jsonb_build_object('error','Voucher unavailable'); end if;
   select * into s from public.paysme_voucher_sales where id=v.sale_id;
   select batch_id into batch_uuid from public.paysme_voucher_batch_items where voucher_id=v.id;
   -- Batch first, voucher second: consistent with settlement to prevent deadlocks.
   select * into b from public.paysme_voucher_payment_batches where id=batch_uuid for update;
   select * into v from public.paysme_vouchers where id=v.id for update;
   if action='get_receipt' then
     select * into receipt from public.paysme_voucher_redemptions where voucher_id=v.id and supplier_id=k.supplier_id;
     if not found then return jsonb_build_object('error','No redemption receipt available'); end if;
     return receipt.receipt_data||jsonb_build_object('receipt_reference',receipt.receipt_reference,'redeemed_at',receipt.redeemed_at);
   end if;
   if action='redeem_voucher' then
     select * into receipt from public.paysme_voucher_redemptions where supplier_id=k.supplier_id and request_key=(args->>'request_key')::uuid;
     if found then
       if receipt.voucher_id<>v.id or receipt.branch_id<>branch_uuid then return jsonb_build_object('error','Idempotency conflict'); end if;
       return receipt.receipt_data||jsonb_build_object('receipt_reference',receipt.receipt_reference,'redeemed_at',receipt.redeemed_at,'replayed',true);
     end if;
   end if;
   if action='verify_voucher' then
     return jsonb_build_object('voucher_code',v.code,'status',v.status,'product_name',s.product_name,'product_contents',s.product_contents,'entitlement_type',s.entitlement_type,'store_credit_cents',s.redemption_value_cents,'customer_price_cents',s.customer_price_cents,'redeemable',v.status='redeemable' and b.status='settled');
   end if;
   if v.status<>'redeemable' or b.id is null or b.status<>'settled' or s.status<>'paid' or b.confirmed_payment_cents<b.amount_due_cents then return jsonb_build_object('error','Voucher is not redeemable'); end if;
   select * into recipient from paysme_voucher_private.voucher_recipients where voucher_id=v.id for update;
   if not found then return jsonb_build_object('error','Recipient record unavailable; contact PaySME'); end if;
   if action='validate_id' then
     if recipient.id_locked_until>now() then return jsonb_build_object('error','Identity check temporarily locked; contact PaySME'); end if;
     if paysme_voucher_private.id_hash(coalesce(args->>'id_number',''))<>recipient.id_fingerprint then
       update paysme_voucher_private.voucher_recipients set id_failures=case when id_locked_until<=now() then 1 else least(id_failures+1,5) end,
         id_locked_until=case when id_locked_until<=now() then null when id_failures>=4 then now()+interval '15 minutes' else null end where voucher_id=v.id;
       return jsonb_build_object('error','Identity did not match');
     end if;
     update paysme_voucher_private.voucher_recipients set id_failures=0,id_locked_until=null where voucher_id=v.id;
     insert into paysme_voucher_private.redemption_sessions(voucher_id,supplier_id,branch_id,method,status,pos_staff_reference,expires_at,verified_at)
     values(v.id,k.supplier_id,branch_uuid,'physical_id','verified',staff_ref,now()+interval '5 minutes',now()) returning id into new_id;
     return jsonb_build_object('verification_id',new_id,'expires_in_seconds',300);
   elsif action='request_recipient_otp' then
     if (select count(*) from paysme_voucher_private.redemption_sessions where voucher_id=v.id and method='sms_email_otp' and created_at>now()-interval '1 hour')>=5
       or exists(select 1 from paysme_voucher_private.redemption_sessions where voucher_id=v.id and method='sms_email_otp' and created_at>now()-interval '60 seconds') then return jsonb_build_object('error','OTP request limit reached; contact PaySME'); end if;
     if args->>'sms_otp' !~ '^[0-9]{6}$' or args->>'email_otp' !~ '^[0-9]{6}$' or args->>'sms_otp'=args->>'email_otp' then raise exception 'Invalid OTP pair'; end if;
     new_id:=gen_random_uuid();
     insert into paysme_voucher_private.redemption_sessions(id,voucher_id,supplier_id,branch_id,method,status,sms_digest,email_digest,pos_staff_reference,expires_at)
     values(new_id,v.id,k.supplier_id,branch_uuid,'sms_email_otp','pending',paysme_voucher_private.hash(new_id::text||':'||(args->>'sms_otp')),paysme_voucher_private.hash(new_id::text||':'||(args->>'email_otp')),staff_ref,now()+interval '10 minutes');
     return jsonb_build_object('verification_id',new_id,'mobile_number',recipient.mobile_number,'email',recipient.email);
   end if;
   select * into verification from paysme_voucher_private.redemption_sessions where id=(args->>'verification_id')::uuid and voucher_id=v.id and supplier_id=k.supplier_id and branch_id=branch_uuid and pos_staff_reference=staff_ref for update;
   if not found or verification.expires_at<=now() or verification.status in ('failed','consumed') then return jsonb_build_object('error','Verification unavailable or expired'); end if;
   if action='validate_recipient_otp' then
     if verification.method<>'sms_email_otp' or verification.status<>'pending' or verification.attempts>=5 then return jsonb_build_object('error','OTP verification unavailable'); end if;
     if paysme_voucher_private.hash(verification.id::text||':'||coalesce(args->>'sms_otp',''))<>verification.sms_digest or paysme_voucher_private.hash(verification.id::text||':'||coalesce(args->>'email_otp',''))<>verification.email_digest then
       update paysme_voucher_private.redemption_sessions set attempts=attempts+1,status=case when attempts>=4 then 'failed' else 'pending' end where id=verification.id;
       return jsonb_build_object('error','OTP pair did not match');
     end if;
     update paysme_voucher_private.redemption_sessions set status='verified',verified_at=now(),expires_at=now()+interval '5 minutes' where id=verification.id;
     return jsonb_build_object('verified',true,'verification_id',verification.id,'expires_in_seconds',300);
   end if;
   if action='redeem_voucher' then
     if verification.status<>'verified' then return jsonb_build_object('error','Complete identity verification first'); end if;
     if b.settlement_consumed_cents+s.supplier_due_cents>b.amount_due_cents or b.redeemed_count>=b.voucher_count then raise exception 'Batch funding limit exceeded'; end if;
     result:=jsonb_build_object('voucher_code',v.code,'supplier_name',b.supplier_name,'branch_name',(select name from public.paysme_voucher_branches where id=branch_uuid),
       'product_name',s.product_name,'product_contents',s.product_contents,'entitlement_type',s.entitlement_type,'store_credit_cents',s.redemption_value_cents,'customer_price_cents',s.customer_price_cents,'currency','NAD','support','Contact PaySME: support@paysme.site','verification_method',verification.method);
     insert into public.paysme_voucher_redemptions(voucher_id,supplier_id,batch_id,branch_id,verification_id,request_key,supplier_due_consumed_cents,receipt_data,pos_staff_reference)
     values(v.id,k.supplier_id,b.id,branch_uuid,verification.id,(args->>'request_key')::uuid,s.supplier_due_cents,result,staff_ref) returning * into receipt;
     update public.paysme_vouchers set status='redeemed',redeemed_at=now() where id=v.id;
     update public.paysme_voucher_payment_batches set settlement_consumed_cents=settlement_consumed_cents+s.supplier_due_cents,redeemed_count=redeemed_count+1 where id=b.id;
     update paysme_voucher_private.redemption_sessions set status='consumed',consumed_at=now() where id=verification.id;
     return result||jsonb_build_object('receipt_reference',receipt.receipt_reference,'redeemed_at',receipt.redeemed_at);
   end if;
 end if;
 raise exception 'Unknown voucher operation';
end $$;

create function public.paysme_voucher_overview() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 return jsonb_build_object(
 'paid_sales',(select count(*) from public.paysme_voucher_sales where status='paid'),
 'customer_paid_cents',(select coalesce(sum(customer_price_cents),0) from public.paysme_voucher_sales where status='paid'),
 'batch_count',(select count(*) from public.paysme_voucher_payment_batches),
 'pending_settlement_cents',(select coalesce(sum(amount_due_cents),0) from public.paysme_voucher_payment_batches where status<>'settled'),
 'settlement_consumed_cents',(select coalesce(sum(settlement_consumed_cents),0) from public.paysme_voucher_payment_batches),
 'redemption_count',(select count(*) from public.paysme_voucher_redemptions),
 'planning',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
   select s.product_name,s.recipient_town,coalesce(br.name,'Not selected') as branch_name,count(*) as voucher_count
   from public.paysme_voucher_sales s join public.paysme_vouchers v on v.sale_id=s.id
   left join public.paysme_voucher_branches br on br.id=s.planned_branch_id
   where s.status='paid' and v.status in ('awaiting_settlement','redeemable')
   group by s.product_name,s.recipient_town,br.name order by s.recipient_town,s.product_name
 ) x));
end $$;
revoke all on function public.paysme_voucher_overview() from public,anon;
grant execute on function public.paysme_voucher_overview() to authenticated;
notify pgrst,'reload schema';

-- Prepare orders only; no transfers, notifications, or voucher release.
create function paysme_voucher_private.prepare_daily_batches() returns integer
language plpgsql security definer set search_path='' as $$
declare sup public.paysme_voucher_suppliers%rowtype;
 cutoff timestamptz:=(date_trunc('day',now() at time zone 'Africa/Windhoek') at time zone 'Africa/Windhoek')-interval '1 microsecond';
 ids uuid[]; total bigint; qty integer; batch_id uuid; prepared integer:=0;
begin
 perform set_config('request.jwt.claim.sub','',true);
 for sup in select * from public.paysme_voucher_suppliers where active order by id for update loop
   select array_agg(x.id),sum(x.supplier_due_cents),count(*) into ids,total,qty from (
     select v.id,s.supplier_due_cents from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id
     where s.supplier_id=sup.id and s.status='paid' and s.paid_at<=cutoff and v.status='awaiting_settlement'
     and not exists(select 1 from public.paysme_voucher_batch_items i where i.voucher_id=v.id)
     order by v.id for update of v
   ) x;
   if qty>0 then
     insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference)
     values(sup.id,sup.business_name,sup.finance_email,sup.supervisor_email,cutoff,qty,total,'system:daily-batcher') returning id into batch_id;
     insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents)
     select batch_id,v.id,s.id,s.supplier_due_cents from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id where v.id=any(ids);
     prepared:=prepared+1;
   end if;
 end loop;
 return prepared;
end $$;
revoke all on function paysme_voucher_private.prepare_daily_batches() from public,anon,authenticated,service_role;
do $$ begin
 if coalesce(current_setting('cron.timezone',true),'GMT') not in ('GMT','UTC') then
  raise exception 'Review cron timezone before installing the Namibia daily schedule';
 end if;
end $$;
-- 22:05 UTC = 00:05 Africa/Windhoek. Includes all unbatched paid sales through the prior local day.
select cron.schedule('paysme-voucher-daily-batches','5 22 * * *','select paysme_voucher_private.prepare_daily_batches();');

commit;
