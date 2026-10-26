-- Transactional notification queue. No historical SMS backfill and no approval by notification.
create table public.paysme_voucher_reconciliations (
 id uuid primary key default gen_random_uuid(), supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 report_date date not null, generated_at timestamptz not null default now(), report_data jsonb not null,
 unique(supplier_id,report_date)
);
alter table public.paysme_voucher_reconciliations enable row level security;
revoke all on public.paysme_voucher_reconciliations from public,anon,authenticated,service_role;
grant select on public.paysme_voucher_reconciliations to authenticated,service_role;
create policy staff_read on public.paysme_voucher_reconciliations for select to authenticated using ((select public.paysme_voucher_is_staff()));
create table paysme_voucher_private.notification_settings (
 singleton boolean primary key default true check(singleton), signing_key text not null default encode(extensions.gen_random_bytes(32),'hex')
);
insert into paysme_voucher_private.notification_settings(singleton) values(true);
create table paysme_voucher_private.notification_requests (nonce uuid primary key,created_at timestamptz not null default now());
create table paysme_voucher_private.notification_outbox (
 id uuid primary key default gen_random_uuid(), event_key text not null unique,
 kind text not null check(kind in ('ready_sms','daily_email')),
 supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 voucher_id uuid references public.paysme_vouchers(id), reconciliation_id uuid references public.paysme_voucher_reconciliations(id),
 recipient_role text check(recipient_role in ('finance','supervisor')),
 status text not null default 'pending' check(status in ('pending','processing','sent','failed','skipped')),
 attempts integer not null default 0,available_at timestamptz not null default now(),
 lease_id uuid,locked_until timestamptz,created_at timestamptz not null default now(),sent_at timestamptz,
 last_error text,
 check ((kind='ready_sms' and voucher_id is not null and reconciliation_id is null and recipient_role is null)
     or (kind='daily_email' and voucher_id is null and reconciliation_id is not null and recipient_role is not null))
);
create index paysme_voucher_outbox_pending_idx on paysme_voucher_private.notification_outbox(available_at,created_at) where status in ('pending','processing');
create index paysme_voucher_outbox_supplier_idx on paysme_voucher_private.notification_outbox(supplier_id,created_at desc);
do $$ declare t text; begin
 foreach t in array array['notification_settings','notification_requests','notification_outbox'] loop
  execute format('alter table paysme_voucher_private.%I enable row level security',t);
  execute format('revoke all on paysme_voucher_private.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function paysme_voucher_private.enqueue_voucher_ready() returns trigger
language plpgsql security definer set search_path='' as $$ begin
 if new.status='redeemable' and old.status is distinct from new.status then
  insert into paysme_voucher_private.notification_outbox(event_key,kind,supplier_id,voucher_id)
  select 'ready:'||new.id::text,'ready_sms',s.supplier_id,new.id from public.paysme_voucher_sales s where s.id=new.sale_id
  on conflict(event_key) do nothing;
 end if;
 return new;
end $$;
create trigger voucher_ready_sms after update of status on public.paysme_vouchers for each row execute function paysme_voucher_private.enqueue_voucher_ready();

create function paysme_voucher_private.reconciliation_data(p_supplier uuid,p_day date) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _start timestamptz:=p_day::timestamp at time zone 'Africa/Windhoek'; _end timestamptz:=(p_day+1)::timestamp at time zone 'Africa/Windhoek';
 _s public.paysme_voucher_suppliers%rowtype; _opening bigint; _credits bigint; _charges bigint; _closing bigint; _reserved bigint;
 _entries jsonb; _planning jsonb; _batches jsonb; _redemptions jsonb; _bank_payments jsonb; _bank_paid bigint;
begin
 select * into _s from public.paysme_voucher_suppliers s where s.id=p_supplier;
 if not found then raise exception 'Supplier unavailable'; end if;
 if p_day is null or p_day>=(now() at time zone 'Africa/Windhoek')::date then raise exception 'Choose a completed Namibia calendar day'; end if;
 select coalesce(sum(l.amount_cents) filter(where l.created_at<_start),0),
  coalesce(sum(l.amount_cents) filter(where l.created_at>=_start and l.entry_kind='deposit'),0),
  coalesce(-sum(l.amount_cents) filter(where l.created_at>=_start and l.entry_kind='batch'),0),coalesce(sum(l.amount_cents),0)
 into _opening,_credits,_charges,_closing from public.paysme_voucher_credit_ledger l where l.supplier_id=p_supplier and l.created_at<_end;
 select coalesce(sum(r.amount_cents),0) into _reserved from public.paysme_voucher_credit_reservations r where r.supplier_id=p_supplier
  and r.created_at<_end and (r.committed_at is null or r.committed_at>=_end) and (r.released_at is null or r.released_at>=_end);
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into _entries from (
  select l.id,l.created_at,l.entry_kind,l.reference,l.amount_cents,l.batch_id,l.prepayment_id
  from public.paysme_voucher_credit_ledger l where l.supplier_id=p_supplier and l.created_at>=_start and l.created_at<_end order by l.created_at,l.id
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into _batches from (
  select b.id,b.batch_reference,b.payment_model,b.voucher_count,b.amount_due_cents,b.status,b.created_at,b.settled_at,b.redeemed_count
  from public.paysme_voucher_payment_batches b where b.supplier_id=p_supplier
   and ((b.created_at>=_start and b.created_at<_end) or (b.settled_at>=_start and b.settled_at<_end) or b.status<>'settled') order by b.created_at,b.id
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into _planning from (
  select s.product_name,s.recipient_town,coalesce(br.name,'Not selected') as branch_name,
   count(*) filter(where v.status='awaiting_settlement') as awaiting_count,count(*) filter(where v.status='redeemable') as redeemable_count,
   count(*) as voucher_count,sum(s.supplier_due_cents) as supplier_value_cents
  from public.paysme_voucher_sales s join public.paysme_vouchers v on v.sale_id=s.id left join public.paysme_voucher_branches br on br.id=s.planned_branch_id
  where s.supplier_id=p_supplier and s.status='paid' and v.status in ('awaiting_settlement','redeemable')
  group by s.product_name,s.recipient_town,br.name order by s.recipient_town,br.name,s.product_name
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into _redemptions from (
  select br.name as branch_name,count(*) as voucher_count,sum(r.supplier_due_consumed_cents) as supplier_value_cents
  from public.paysme_voucher_redemptions r join public.paysme_voucher_branches br on br.id=r.branch_id
  where r.supplier_id=p_supplier and r.redeemed_at>=_start and r.redeemed_at<_end group by br.name order by br.name
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb),coalesce(sum(x.amount_cents),0) into _bank_payments,_bank_paid from (
  select p.recorded_at,p.bank_transaction_reference,p.amount_cents,b.batch_reference from public.paysme_voucher_batch_payments p
  join public.paysme_voucher_payment_batches b on b.id=p.batch_id where b.supplier_id=p_supplier and p.recorded_at>=_start and p.recorded_at<_end
  order by p.recorded_at,p.id
 ) x;
 return jsonb_build_object('supplier_id',p_supplier,'supplier_name',_s.business_name,'payment_model',_s.payment_model,'report_date',p_day,
  'generated_at',now(),'period_start',_start,'period_end',_end,'currency','NAD','opening_cents',_opening,'credited_cents',_credits,
  'charged_cents',_charges,'closing_cents',_closing,'reserved_at_close_cents',_reserved,'available_at_close_cents',_closing-_reserved,
  'current_account',paysme_voucher_private.credit_balance(p_supplier),'entries',_entries,'batches',_batches,'planning',_planning,'redemptions',_redemptions,'bank_payments',_bank_payments,'bank_paid_cents',_bank_paid);
end $$;

create function paysme_voucher_private.queue_reconciliation(p_supplier uuid,p_day date) returns uuid
language plpgsql security definer set search_path='' as $$ declare _id uuid; begin
 perform paysme_voucher_private.lock_credit(p_supplier);
 select r.id into _id from public.paysme_voucher_reconciliations r where r.supplier_id=p_supplier and r.report_date=p_day;
 if _id is null then
  insert into public.paysme_voucher_reconciliations(supplier_id,report_date,report_data)
  values(p_supplier,p_day,paysme_voucher_private.reconciliation_data(p_supplier,p_day)) returning id into _id;
 end if;
 insert into paysme_voucher_private.notification_outbox(event_key,kind,supplier_id,reconciliation_id,recipient_role)
 select 'daily:'||_id::text||':'||x.role,'daily_email',p_supplier,_id,x.role from (values('finance'),('supervisor')) x(role)
 on conflict(event_key) do nothing;
 return _id;
end $$;
create function public.paysme_voucher_request_reconciliation(p_supplier_id uuid,p_report_date date) returns jsonb
language plpgsql security definer set search_path='' as $$ declare _id uuid; begin
 if not public.paysme_voucher_is_admin() then raise exception 'Voucher administrator required' using errcode='42501'; end if;
 _id:=paysme_voucher_private.queue_reconciliation(p_supplier_id,p_report_date);
 return jsonb_build_object('queued',true,'reconciliation_id',_id,'message','Daily reconciliation queued for finance and supervisor. Existing deliveries are not duplicated.');
end $$;
create function paysme_voucher_private.prepare_daily_reconciliations() returns integer
language plpgsql security definer set search_path='' as $$ declare _s record; _count integer:=0; begin
 for _s in select s.id from public.paysme_voucher_suppliers s where s.active and s.daily_reconciliation_enabled order by s.id loop
  perform paysme_voucher_private.queue_reconciliation(_s.id,(now() at time zone 'Africa/Windhoek')::date-1); _count:=_count+1;
 end loop;
 return _count;
end $$;

-- Only a short-lived, single-use HMAC token enters pg_net's request headers. The signing key stays private.
create function paysme_voucher_private.dispatch_notifications() returns bigint
language plpgsql security definer set search_path='' as $$
declare _key text; _prefix text:=floor(extract(epoch from clock_timestamp()))::bigint::text||':'||gen_random_uuid()::text; _token text; begin
 select s.signing_key into _key from paysme_voucher_private.notification_settings s where s.singleton;
 _token:=_prefix||':'||encode(extensions.hmac(_prefix,_key,'sha256'),'hex');
 return net.http_post(url:='https://zvoqrqdnuupdefsuiurt.supabase.co/functions/v1/paysme-vouchers',
  headers:=jsonb_build_object('Content-Type','application/json','x-voucher-worker-token',_token),
  body:='{"action":"process_notifications","args":{}}'::jsonb,timeout_milliseconds:=5000);
end $$;
create function public.paysme_voucher_claim_notifications(p_worker_token text,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _parts text[]; _key text; _prefix text; _nonce uuid; _job record; _jobs jsonb:='[]'::jsonb; _payload jsonb; _recipient text;
begin
 if p_worker_token is null or p_worker_token !~ '^[0-9]{10}:[0-9a-f-]{36}:[0-9a-f]{64}$' then raise exception 'Worker authentication required' using errcode='42501'; end if;
 _parts:=string_to_array(p_worker_token,':'); _prefix:=_parts[1]||':'||_parts[2];
 select s.signing_key into _key from paysme_voucher_private.notification_settings s where s.singleton;
 if abs(extract(epoch from clock_timestamp())-_parts[1]::bigint)>120 or encode(extensions.hmac(_prefix,_key,'sha256'),'hex')<>_parts[3] then raise exception 'Worker authentication required' using errcode='42501'; end if;
 insert into paysme_voucher_private.notification_requests(nonce) values(_parts[2]::uuid) on conflict do nothing returning nonce into _nonce;
 if _nonce is null then raise exception 'Worker request already used' using errcode='42501'; end if;
 delete from paysme_voucher_private.notification_requests r where r.created_at<now()-interval '10 minutes';
 update paysme_voucher_private.notification_outbox j set status='failed',last_error='Delivery lease expired; review before retrying',lease_id=null,locked_until=null
 where j.status='processing' and j.locked_until<now() and j.attempts>=5;
 for _job in
  with candidates as (select j.id from paysme_voucher_private.notification_outbox j
   where ((j.status='pending' and j.available_at<=now()) or (j.status='processing' and j.locked_until<now())) and j.attempts<5
   order by case when j.kind='ready_sms' then 0 else 1 end,j.created_at,j.id for update skip locked limit least(greatest(p_limit,1),50))
  update paysme_voucher_private.notification_outbox j set status='processing',lease_id=gen_random_uuid(),locked_until=now()+interval '3 minutes',attempts=j.attempts+1
  from candidates q where j.id=q.id returning j.*
 loop
  _payload:=null; _recipient:=null;
  if _job.kind='ready_sms' then
   select jsonb_build_object('mobile',r.mobile_number,'voucher_code',v.code,'supplier_name',sup.business_name,'product_name',s.product_name,'town',s.recipient_town,'branch_name',br.name)
   into _payload from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id
   join public.paysme_voucher_suppliers sup on sup.id=s.supplier_id join paysme_voucher_private.voucher_recipients r on r.voucher_id=v.id
   left join public.paysme_voucher_branches br on br.id=s.planned_branch_id where v.id=_job.voucher_id and v.status='redeemable' and s.status='paid';
  else
   select r.report_data into _payload from public.paysme_voucher_reconciliations r where r.id=_job.reconciliation_id;
   select case when _job.recipient_role='finance' then s.finance_email else s.supervisor_email end into _recipient from public.paysme_voucher_suppliers s where s.id=_job.supplier_id;
   _payload:=_payload||jsonb_build_object('to',_recipient);
  end if;
  if _payload is null then
   update paysme_voucher_private.notification_outbox j set status='skipped',lease_id=null,locked_until=null where j.id=_job.id;
  else
   _jobs:=_jobs||jsonb_build_array(jsonb_build_object('id',_job.id,'lease_id',_job.lease_id,'kind',_job.kind,'payload',_payload));
  end if;
 end loop;
 return _jobs;
end $$;
create function public.paysme_voucher_finish_notification(p_id uuid,p_lease_id uuid,p_sent boolean) returns boolean
language plpgsql security definer set search_path='' as $$ declare _count integer; begin
 update paysme_voucher_private.notification_outbox j set status=case when p_sent then 'sent' when j.attempts>=5 then 'failed' else 'pending' end,
  sent_at=case when p_sent then now() else null end,lease_id=null,locked_until=null,
  last_error=case when p_sent then null else 'Delivery was not confirmed by the provider' end,
  available_at=now()+make_interval(secs=>least(3600,(power(2,j.attempts)*30)::integer))
 where j.id=p_id and j.lease_id=p_lease_id and j.status='processing';
 get diagnostics _count=row_count; return _count=1;
end $$;
create function public.paysme_voucher_delivery_status(p_supplier_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$ begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 return jsonb_build_object('pending',(select count(*) from paysme_voucher_private.notification_outbox j where (p_supplier_id is null or j.supplier_id=p_supplier_id) and j.status in ('pending','processing')),
  'failed',(select count(*) from paysme_voucher_private.notification_outbox j where (p_supplier_id is null or j.supplier_id=p_supplier_id) and j.status='failed'),
  'jobs',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (select j.id,j.kind,j.status,j.attempts,j.created_at,j.sent_at,j.last_error,j.recipient_role,
   coalesce(v.code,r.report_date::text) as reference from paysme_voucher_private.notification_outbox j left join public.paysme_vouchers v on v.id=j.voucher_id
   left join public.paysme_voucher_reconciliations r on r.id=j.reconciliation_id where (p_supplier_id is null or j.supplier_id=p_supplier_id)
   order by j.created_at desc,j.id desc limit 50) x));
end $$;
create function public.paysme_voucher_retry_notification(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ declare _count integer; begin
 if not public.paysme_voucher_is_admin() then raise exception 'Voucher administrator required' using errcode='42501'; end if;
 update paysme_voucher_private.notification_outbox j set status='pending',attempts=0,available_at=now(),lease_id=null,locked_until=null,last_error=null where j.id=p_id and j.status='failed';
 get diagnostics _count=row_count;
 insert into public.paysme_voucher_audit_events(actor_user_id,table_name,record_id,action) values(auth.uid(),'notification_outbox',p_id,'retry_requested');
 return jsonb_build_object('queued',_count=1);
end $$;
revoke all on function public.paysme_voucher_claim_notifications(text,integer),public.paysme_voucher_finish_notification(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.paysme_voucher_claim_notifications(text,integer),public.paysme_voucher_finish_notification(uuid,uuid,boolean) to service_role;
revoke all on function public.paysme_voucher_request_reconciliation(uuid,date),public.paysme_voucher_delivery_status(uuid),public.paysme_voucher_retry_notification(uuid) from public,anon;
grant execute on function public.paysme_voucher_request_reconciliation(uuid,date),public.paysme_voucher_delivery_status(uuid),public.paysme_voucher_retry_notification(uuid) to authenticated;
revoke all on all functions in schema paysme_voucher_private from public,anon,authenticated,service_role;
-- 00:15 Namibia: previous-day financial statement plus current outstanding branch planning.
select cron.schedule('paysme-voucher-daily-reconciliation','15 22 * * *','select paysme_voucher_private.prepare_daily_reconciliations();');
select cron.schedule('paysme-voucher-notifications','* * * * *','select paysme_voucher_private.dispatch_notifications();');
notify pgrst,'reload schema';
