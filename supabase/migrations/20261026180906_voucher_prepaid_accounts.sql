-- PaySME outgoing prepayments held at suppliers. All validation fixtures below roll back.
BEGIN;

-- PaySME owns these prepaid funds; the supplier holds them on PaySME's behalf.
-- OUTGOING PaySME bank prepayments increase this asset balance only after supplier OTP approval.
-- Approved voucher batches reduce this asset once, whether redeemed or unredeemed.
-- Vendor sales and the existing PaySME/Utilities wallets are independent and are not changed here.
-- BEFORE sending a prepaid batch approval email, PaySME's own available asset balance must cover it.
-- Example: an available N$30.98 cannot fund a new N$40,000 batch; no email is sent.
alter table public.paysme_voucher_suppliers add column payment_model text not null default 'postpaid' check (payment_model in ('postpaid','prepaid'));
alter table public.paysme_voucher_suppliers add column daily_reconciliation_enabled boolean not null default false;
alter table public.paysme_voucher_suppliers add column prepaid_low_balance_cents bigint not null default 0 check (prepaid_low_balance_cents between 0 and 100000000000000);
alter table public.paysme_voucher_sales add column payment_model text not null default 'postpaid' check (payment_model in ('postpaid','prepaid'));
alter table public.paysme_voucher_payment_batches add column payment_model text not null default 'postpaid' check (payment_model in ('postpaid','prepaid'));
create index paysme_voucher_sales_model_idx on public.paysme_voucher_sales(supplier_id,payment_model,paid_at);

create table paysme_voucher_private.credit_locks (
 supplier_id uuid primary key references public.paysme_voucher_suppliers(id)
);
alter table paysme_voucher_private.credit_locks enable row level security;

create table public.paysme_voucher_prepayments (
 id uuid primary key default gen_random_uuid(),
 prepayment_no bigint generated always as identity unique,
 reference text generated always as ('PV-CREDIT-'::text||prepayment_no::text) stored unique,
 supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 payment_direction text not null default 'paysme_to_supplier' check (payment_direction='paysme_to_supplier'),
 supplier_name text not null, finance_email text not null, supervisor_email text not null,
 deposit_kind text not null check (deposit_kind in ('initial','topup')),
 bank_reference text not null unique check (length(trim(bank_reference)) between 1 and 200),
 amount_cents bigint not null check (amount_cents between 1 and 100000000000000),
 proof_object_path text not null,
 status text not null default 'recorded' check (status in ('recorded','awaiting_confirmation','disputed','confirmed')),
 version integer not null default 1 check (version>0),
 notes text not null default '' check (length(notes)<=4000),
 change_log jsonb not null default '[]'::jsonb,
 recorded_by text not null, created_at timestamptz not null default now(),
 confirmed_at timestamptz, confirmed_by_email text,
 check (finance_email<>supervisor_email),
 check ((status='confirmed')=(confirmed_at is not null))
);
create index paysme_voucher_prepayments_supplier_idx on public.paysme_voucher_prepayments(supplier_id,created_at desc);
create unique index paysme_voucher_prepayments_bank_idx on public.paysme_voucher_prepayments(lower(bank_reference));

create table public.paysme_voucher_credit_ledger (
 id uuid primary key default gen_random_uuid(),
 funds_owner text not null default 'PaySME' check (funds_owner='PaySME'),
 funds_location text not null default 'held_with_supplier' check (funds_location='held_with_supplier'),
 supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 entry_kind text not null check (entry_kind in ('deposit','batch')),
 amount_cents bigint not null,
 prepayment_id uuid unique references public.paysme_voucher_prepayments(id),
 batch_id uuid unique references public.paysme_voucher_payment_batches(id),
 reference text not null, recorded_by text not null,
 created_at timestamptz not null default now(),
 check ((entry_kind='deposit' and amount_cents>0 and prepayment_id is not null and batch_id is null)
     or (entry_kind='batch' and amount_cents<=0 and batch_id is not null and prepayment_id is null))
);
create index paysme_voucher_credit_ledger_supplier_idx on public.paysme_voucher_credit_ledger(supplier_id,created_at,id);
create table public.paysme_voucher_credit_reservations (
 id uuid primary key default gen_random_uuid(),
 supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 batch_id uuid not null references public.paysme_voucher_payment_batches(id),
 amount_cents bigint not null check (amount_cents>=0),
 status text not null default 'reserved' check (status in ('reserved','committed','released')),
 created_at timestamptz not null default now(), created_by text not null,
 committed_at timestamptz, released_at timestamptz, release_note text,
 check ((status='committed')=(committed_at is not null)),
 check ((status='released')=(released_at is not null)),
 check (status<>'released' or length(trim(release_note))>=3)
);
create unique index paysme_voucher_credit_one_reservation_idx on public.paysme_voucher_credit_reservations(batch_id) where status in ('reserved','committed');
create index paysme_voucher_credit_reservations_supplier_idx on public.paysme_voucher_credit_reservations(supplier_id,status,created_at);
create index paysme_voucher_credit_reservations_batch_idx on public.paysme_voucher_credit_reservations(batch_id,created_at);

create table paysme_voucher_private.credit_confirmations (
 id uuid primary key default gen_random_uuid(),
 supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 prepayment_id uuid references public.paysme_voucher_prepayments(id),
 batch_id uuid references public.paysme_voucher_payment_batches(id),
 object_version integer not null,
 token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
 finance_email text not null, supervisor_email text not null,
 created_at timestamptz not null default now(), expires_at timestamptz not null,
 otp_digest text, otp_expires_at timestamptz, otp_last_sent_at timestamptz,
 otp_attempts integer not null default 0 check (otp_attempts between 0 and 5),
 otp_send_count integer not null default 0 check (otp_send_count between 0 and 5),
 consumed_at timestamptz, revoked_at timestamptz,
 check (num_nonnulls(prepayment_id,batch_id)=1), check (finance_email<>supervisor_email),
 check (expires_at>created_at)
);
create index paysme_voucher_credit_confirmations_deposit_idx on paysme_voucher_private.credit_confirmations(prepayment_id);
create index paysme_voucher_credit_confirmations_batch_idx on paysme_voucher_private.credit_confirmations(batch_id);
create index paysme_voucher_credit_confirmations_supplier_idx on paysme_voucher_private.credit_confirmations(supplier_id);
alter table paysme_voucher_private.credit_confirmations enable row level security;
create table public.paysme_voucher_credit_discrepancies (
 id uuid primary key default gen_random_uuid(), supplier_id uuid not null references public.paysme_voucher_suppliers(id),
 prepayment_id uuid references public.paysme_voucher_prepayments(id), batch_id uuid references public.paysme_voucher_payment_batches(id),
 confirmation_id uuid not null unique references paysme_voucher_private.credit_confirmations(id),
 reason text not null check (reason in ('payment_not_received','incorrect_amount','reference_mismatch','other')),
 comment text not null check (length(comment) between 1 and 2000),
 status text not null default 'open' check (status in ('open','resolved')),
 created_at timestamptz not null default now(), reported_by_email text not null,
 resolved_at timestamptz, resolved_by text, resolution_note text,
 check (num_nonnulls(prepayment_id,batch_id)=1),
 check (status<>'resolved' or (resolved_at is not null and resolved_by is not null and length(trim(resolution_note))>=3))
);
create index paysme_voucher_credit_discrepancies_supplier_idx on public.paysme_voucher_credit_discrepancies(supplier_id,status);
create index paysme_voucher_credit_discrepancies_batch_idx on public.paysme_voucher_credit_discrepancies(batch_id) where batch_id is not null;
create index paysme_voucher_credit_discrepancies_payment_idx on public.paysme_voucher_credit_discrepancies(prepayment_id) where prepayment_id is not null;

do $$ declare t text; begin
 foreach t in array array['paysme_voucher_prepayments','paysme_voucher_credit_ledger','paysme_voucher_credit_reservations','paysme_voucher_credit_discrepancies'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated,service_role',t);
  execute format('create policy staff_read on public.%I for select to authenticated using ((select public.paysme_voucher_is_staff()))',t);
  execute format('create trigger voucher_audit after insert or update on public.%I for each row execute function public.paysme_voucher_audit_change()',t);
 end loop;
end $$;
-- All supplier writes now use the admin-authenticated command, allowing supplier + initial POP to save atomically.
revoke insert,update on public.paysme_voucher_suppliers from authenticated;
revoke all on all tables in schema paysme_voucher_private from public,anon,authenticated,service_role;

create function paysme_voucher_private.immutable_credit() returns trigger
language plpgsql set search_path='' as $$ begin raise exception 'Confirmed supplier credit entries are immutable'; end $$;
create trigger immutable_credit before update or delete on public.paysme_voucher_credit_ledger for each row execute function paysme_voucher_private.immutable_credit();
create function paysme_voucher_private.snapshot_payment_model() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' then
  if new.payment_model is distinct from old.payment_model then raise exception 'Purchase-time payment terms cannot be changed'; end if;
 else
  select s.payment_model into new.payment_model from public.paysme_voucher_suppliers s where s.id=new.supplier_id;
 end if;
 return new;
end $$;
create trigger voucher_payment_model before insert or update of payment_model on public.paysme_voucher_sales for each row execute function paysme_voucher_private.snapshot_payment_model();

create view public.paysme_voucher_credit_accounts with (security_invoker=true) as
select s.id as supplier_id,s.business_name as supplier_name,s.payment_model,s.prepaid_low_balance_cents,
 'PaySME'::text as funds_owner,'held_with_supplier'::text as funds_location,
 coalesce(l.credited,0)::bigint as credited_cents,coalesce(l.charged,0)::bigint as charged_cents,
 coalesce(l.balance,0)::bigint as confirmed_balance_cents,coalesce(r.reserved,0)::bigint as reserved_cents,
 (coalesce(l.balance,0)-coalesce(r.reserved,0))::bigint as available_cents,
 coalesce(d.pending,0)::bigint as pending_deposit_cents,coalesce(l.entries,0)>0 as has_credit_history,
 (select count(*) from public.paysme_voucher_credit_discrepancies q where q.supplier_id=s.id and q.batch_id is not null and q.status='open') as open_batch_issues
from public.paysme_voucher_suppliers s
left join lateral (select sum(x.amount_cents) as balance,sum(x.amount_cents) filter(where x.entry_kind='deposit') as credited,
 -sum(x.amount_cents) filter(where x.entry_kind='batch') as charged,count(*) as entries from public.paysme_voucher_credit_ledger x where x.supplier_id=s.id) l on true
left join lateral (select sum(x.amount_cents) as reserved from public.paysme_voucher_credit_reservations x where x.supplier_id=s.id and x.status='reserved') r on true
left join lateral (select sum(x.amount_cents) as pending from public.paysme_voucher_prepayments x where x.supplier_id=s.id and x.status<>'confirmed') d on true;
revoke all on public.paysme_voucher_credit_accounts from public,anon;
grant select on public.paysme_voucher_credit_accounts to authenticated,service_role;

create function paysme_voucher_private.lock_credit(p_supplier uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 insert into paysme_voucher_private.credit_locks(supplier_id) values(p_supplier) on conflict do nothing;
 perform 1 from paysme_voucher_private.credit_locks l where l.supplier_id=p_supplier for update;
end $$;
create function paysme_voucher_private.credit_balance(p_supplier uuid) returns jsonb
language sql security definer set search_path='' as $$
 select to_jsonb(a) from public.paysme_voucher_credit_accounts a where a.supplier_id=p_supplier;
$$;

create function paysme_voucher_private.prepare_model_batch(p_supplier uuid,p_cutoff timestamptz,p_model text,p_actor text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _sup public.paysme_voucher_suppliers%rowtype; _model text:=p_model; _ids uuid[]; _qty integer; _total bigint; _batch public.paysme_voucher_payment_batches%rowtype;
begin
 select * into _sup from public.paysme_voucher_suppliers s where s.id=p_supplier and s.active for update;
 if not found then raise exception 'Supplier unavailable'; end if;
 if p_cutoff is null or p_cutoff>now() then raise exception 'Choose a cutoff no later than now'; end if;
 if _model is null then
  select s.payment_model into _model from public.paysme_voucher_sales s join public.paysme_vouchers v on v.sale_id=s.id
  where s.supplier_id=p_supplier and s.status='paid' and s.paid_at<=p_cutoff and v.status='awaiting_settlement'
  and not exists(select 1 from public.paysme_voucher_batch_items i where i.voucher_id=v.id) order by s.paid_at,s.id limit 1;
 end if;
 if _model is not null and _model not in ('postpaid','prepaid') then raise exception 'Invalid payment terms'; end if;
 select array_agg(x.id),count(*),coalesce(sum(x.supplier_due_cents),0) into _ids,_qty,_total from (
  select v.id,s.supplier_due_cents from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id
  where s.supplier_id=p_supplier and s.payment_model=_model and s.status='paid' and s.paid_at<=p_cutoff and v.status='awaiting_settlement'
  and not exists(select 1 from public.paysme_voucher_batch_items i where i.voucher_id=v.id) order by v.id for update of v
 ) x;
 if _qty=0 then return null; end if;
 insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference,payment_model)
 values(p_supplier,_sup.business_name,_sup.finance_email,_sup.supervisor_email,p_cutoff,_qty,_total,p_actor,_model) returning * into _batch;
 insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents)
 select _batch.id,v.id,s.id,s.supplier_due_cents from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id where v.id=any(_ids);
 return to_jsonb(_batch);
end $$;
create or replace function paysme_voucher_private.prepare_daily_batches() returns integer
language plpgsql security definer set search_path='' as $$
declare _s record; _model text; _result jsonb; _prepared integer:=0;
 _cutoff timestamptz:=(date_trunc('day',now() at time zone 'Africa/Windhoek') at time zone 'Africa/Windhoek')-interval '1 microsecond';
begin
 perform set_config('request.jwt.claim.sub','',true);
 for _s in select s.id from public.paysme_voucher_suppliers s where s.active order by s.id loop
  foreach _model in array array['postpaid','prepaid'] loop
   _result:=paysme_voucher_private.prepare_model_batch(_s.id,_cutoff,_model,'system:daily-batcher');
   if _result is not null then _prepared:=_prepared+1; end if;
  end loop;
 end loop;
 return _prepared;
end $$;

create function paysme_voucher_private.record_prepayment(p_args jsonb,p_actor text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _s public.paysme_voucher_suppliers%rowtype; _d public.paysme_voucher_prepayments%rowtype;
 _id uuid:=(p_args->>'prepayment_id')::uuid; _reference text:=trim(p_args->>'bank_reference');
begin
 select * into _s from public.paysme_voucher_suppliers s where s.id=(p_args->>'supplier_id')::uuid;
 if not found then raise exception 'Supplier unavailable'; end if;
 if _s.payment_model<>'prepaid' and not exists(select 1 from paysme_voucher_private.credit_locks l where l.supplier_id=_s.id) then raise exception 'Select prepaid terms before recording prepaid funds'; end if;
 if _id is null or _reference is null or length(_reference) not between 1 and 200 then raise exception 'Prepayment ID and bank reference are required'; end if;
 perform paysme_voucher_private.lock_credit(_s.id);
 perform pg_advisory_xact_lock(hashtextextended('voucher-bank:'||lower(_reference),4));
 select * into _d from public.paysme_voucher_prepayments d where d.id=_id;
 if found then
  if _d.supplier_id<>_s.id or _d.bank_reference<>_reference or _d.amount_cents<>(p_args->>'amount_cents')::bigint then raise exception 'Prepayment reference conflicts with an existing record'; end if;
  return to_jsonb(_d)||jsonb_build_object('replayed',true);
 end if;
 if exists(select 1 from public.paysme_voucher_batch_payments x where lower(x.bank_transaction_reference)=lower(_reference)) then raise exception 'This bank reference is already recorded against a batch'; end if;
 if not paysme_voucher_private.valid_payment_proof(_id,p_args->>'proof_object_path') then raise exception 'Upload a valid proof of payment for this prepayment'; end if;
 insert into public.paysme_voucher_prepayments(id,supplier_id,supplier_name,finance_email,supervisor_email,deposit_kind,bank_reference,amount_cents,proof_object_path,recorded_by,notes)
 values(_id,_s.id,_s.business_name,_s.finance_email,_s.supervisor_email,coalesce(p_args->>'deposit_kind','topup'),_reference,(p_args->>'amount_cents')::bigint,p_args->>'proof_object_path',p_actor,coalesce(p_args->>'notes','')) returning * into _d;
 return to_jsonb(_d);
end $$;

create function paysme_voucher_private.credit_details(p_confirmation uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _c paysme_voucher_private.credit_confirmations%rowtype; _d public.paysme_voucher_prepayments%rowtype;
 _b public.paysme_voucher_payment_batches%rowtype; _balance jsonb; _planning jsonb; _reserved bigint;
begin
 select * into _c from paysme_voucher_private.credit_confirmations c where c.id=p_confirmation;
 _balance:=paysme_voucher_private.credit_balance(_c.supplier_id);
 if _c.prepayment_id is not null then
  select * into _d from public.paysme_voucher_prepayments d where d.id=_c.prepayment_id;
  return jsonb_build_object('confirmation_type','prepayment','prepayment_id',_d.id,'batch_reference',_d.reference,'supplier_name',_d.supplier_name,
   'deposit_kind',_d.deposit_kind,'amount_cents',_d.amount_cents,'payment_recorded_cents',_d.amount_cents,'notes',_d.notes,
   'finance_email',_c.finance_email,'supervisor_email',_c.supervisor_email,'expires_at',_c.expires_at,'account',_balance,
   'proofs_ready',paysme_voucher_private.valid_payment_proof(_d.id,_d.proof_object_path),
   'supervisor_email_hint',left(_c.supervisor_email,1)||'***@'||split_part(_c.supervisor_email,'@',2),
   'payments',jsonb_build_array(jsonb_build_object('reference',_d.bank_reference,'amount_cents',_d.amount_cents,'proof_object_path',_d.proof_object_path)));
 end if;
 select * into _b from public.paysme_voucher_payment_batches b where b.id=_c.batch_id;
 select coalesce(sum(r.amount_cents),0) into _reserved from public.paysme_voucher_credit_reservations r where r.batch_id=_b.id and r.status='reserved';
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into _planning from (
  select s.product_name,s.recipient_town,coalesce(br.name,'Not selected') as branch_name,count(*) as voucher_count
  from public.paysme_voucher_batch_items i join public.paysme_voucher_sales s on s.id=i.sale_id
  left join public.paysme_voucher_branches br on br.id=s.planned_branch_id where i.batch_id=_b.id
  group by s.product_name,s.recipient_town,br.name order by s.recipient_town,br.name,s.product_name
 ) x;
 return jsonb_build_object('confirmation_type','prepaid_batch','batch_id',_b.id,'batch_reference',_b.batch_reference,'supplier_name',_b.supplier_name,
  'amount_due_cents',_b.amount_due_cents,'voucher_count',_b.voucher_count,'reserved_for_batch_cents',_reserved,
  'customer_voucher_value_cents',(select coalesce(sum(s.customer_price_cents),0) from public.paysme_voucher_batch_items i join public.paysme_voucher_sales s on s.id=i.sale_id where i.batch_id=_b.id),
  'account',_balance,'balance_after_approval_cents',(_balance->>'confirmed_balance_cents')::bigint-_b.amount_due_cents,
  'finance_email',_c.finance_email,'supervisor_email',_c.supervisor_email,'expires_at',_c.expires_at,
  'supervisor_email_hint',left(_c.supervisor_email,1)||'***@'||split_part(_c.supervisor_email,'@',2),
  'proofs_ready',_reserved=_b.amount_due_cents,'payments','[]'::jsonb,'planning',_planning);
end $$;

create function paysme_voucher_private.start_credit_confirmation(p_batch uuid,p_deposit uuid,p_token text,p_actor text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _b public.paysme_voucher_payment_batches%rowtype; _d public.paysme_voucher_prepayments%rowtype;
 _supplier uuid; _version integer; _finance text; _supervisor text; _balance jsonb; _id uuid;
begin
 if num_nonnulls(p_batch,p_deposit)<>1 or p_token !~ '^[0-9a-f]{64}$' then raise exception 'Invalid confirmation request'; end if;
 if p_batch is not null then select b.supplier_id into _supplier from public.paysme_voucher_payment_batches b where b.id=p_batch;
 else select d.supplier_id into _supplier from public.paysme_voucher_prepayments d where d.id=p_deposit; end if;
 if _supplier is null then raise exception 'Prepaid account record unavailable'; end if;
 perform paysme_voucher_private.lock_credit(_supplier);
 if p_batch is not null then
  select * into _b from public.paysme_voucher_payment_batches b where b.id=p_batch for update;
  if _b.payment_model<>'prepaid' or _b.status in ('settled','disputed') then raise exception 'Resolve any discrepancy before requesting prepaid batch approval'; end if;
  if exists(select 1 from public.paysme_voucher_credit_discrepancies q where q.supplier_id=_supplier and q.batch_id is not null and q.status='open') then raise exception 'Resolve the supplier balance issue before sending prepaid batch approvals'; end if;
  if not exists(select 1 from public.paysme_voucher_credit_reservations r where r.batch_id=_b.id and r.status='reserved') then
   _balance:=paysme_voucher_private.credit_balance(_supplier);
   if (_balance->>'available_cents')::bigint<_b.amount_due_cents then raise exception 'Insufficient confirmed prepaid credit for this batch'; end if;
   insert into public.paysme_voucher_credit_reservations(supplier_id,batch_id,amount_cents,created_by) values(_supplier,_b.id,_b.amount_due_cents,p_actor);
  end if;
  update public.paysme_voucher_payment_batches b set status='awaiting_confirmation',version=b.version+1 where b.id=_b.id returning * into _b;
  _version:=_b.version; _finance:=_b.finance_email; _supervisor:=_b.supervisor_email;
 else
  select * into _d from public.paysme_voucher_prepayments d where d.id=p_deposit for update;
  if _d.status in ('confirmed','disputed') then raise exception 'Prepayment is confirmed or needs discrepancy resolution'; end if;
  if not paysme_voucher_private.valid_payment_proof(_d.id,_d.proof_object_path) then raise exception 'Upload a valid proof of payment for this prepayment'; end if;
  update public.paysme_voucher_prepayments d set status='awaiting_confirmation',version=d.version+1 where d.id=_d.id returning * into _d;
  _version:=_d.version; _finance:=_d.finance_email; _supervisor:=_d.supervisor_email;
 end if;
 update paysme_voucher_private.credit_confirmations c set revoked_at=now() where (c.batch_id=p_batch or c.prepayment_id=p_deposit) and c.consumed_at is null and c.revoked_at is null;
 insert into paysme_voucher_private.credit_confirmations(supplier_id,prepayment_id,batch_id,object_version,token_hash,finance_email,supervisor_email,expires_at)
 values(_supplier,p_deposit,p_batch,_version,paysme_voucher_private.hash(p_token),_finance,_supervisor,now()+interval '48 hours') returning id into _id;
 return paysme_voucher_private.credit_details(_id);
end $$;

create function paysme_voucher_private.credit_confirmation_command(p_action text,p_args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _c paysme_voucher_private.credit_confirmations%rowtype; _b public.paysme_voucher_payment_batches%rowtype;
 _d public.paysme_voucher_prepayments%rowtype; _balance jsonb; _qty integer; _total bigint; _version integer; _status text;
begin
 select * into _c from paysme_voucher_private.credit_confirmations c where c.token_hash=paysme_voucher_private.hash(p_args->>'token');
 if not found then return jsonb_build_object('error','Invalid confirmation link'); end if;
 perform paysme_voucher_private.lock_credit(_c.supplier_id);
 if _c.prepayment_id is not null then
  select * into _d from public.paysme_voucher_prepayments d where d.id=_c.prepayment_id for update;
  _version:=_d.version; _status:=_d.status;
 else
  select * into _b from public.paysme_voucher_payment_batches b where b.id=_c.batch_id for update;
  _version:=_b.version; _status:=_b.status;
 end if;
 select * into _c from paysme_voucher_private.credit_confirmations c where c.id=_c.id for update;
 if _c.consumed_at is not null and p_action='confirm_batch' and _status in ('confirmed','settled') then
  return jsonb_build_object('confirmed',true,'credited',_c.prepayment_id is not null,'replayed',true);
 end if;
 if _c.consumed_at is not null or _c.revoked_at is not null or _c.expires_at<=now() or _c.object_version<>_version or _status<>'awaiting_confirmation' then
  return jsonb_build_object('error','Confirmation link expired, changed or already used. Ask PaySME for a fresh email.');
 end if;
 if p_action='confirmation_details' then return paysme_voucher_private.credit_details(_c.id); end if;
 if p_action='report_discrepancy' then
  insert into public.paysme_voucher_credit_discrepancies(supplier_id,prepayment_id,batch_id,confirmation_id,reason,comment,reported_by_email)
  values(_c.supplier_id,_c.prepayment_id,_c.batch_id,_c.id,p_args->>'reason',p_args->>'comment',_c.finance_email);
  if _c.prepayment_id is not null then update public.paysme_voucher_prepayments d set status='disputed',version=d.version+1 where d.id=_d.id;
  else update public.paysme_voucher_payment_batches b set status='disputed',version=b.version+1 where b.id=_b.id; end if;
  update paysme_voucher_private.credit_confirmations c set revoked_at=now() where (c.batch_id=_c.batch_id or c.prepayment_id=_c.prepayment_id) and c.consumed_at is null;
  return jsonb_build_object('reported',true,'message','Discrepancy recorded. No prepaid credit or voucher release has been approved.');
 end if;
 if _c.prepayment_id is not null and not paysme_voucher_private.valid_payment_proof(_d.id,_d.proof_object_path) then return jsonb_build_object('error','The proof of payment is unavailable. Contact PaySME.'); end if;
 if p_action='confirmation_otp' then
  if _c.otp_send_count>=5 or _c.otp_attempts>=5 or _c.otp_last_sent_at>now()-interval '60 seconds' then return jsonb_build_object('error','Please wait or request a new confirmation link'); end if;
  if p_args->>'otp' !~ '^[0-9]{6}$' then raise exception 'Invalid OTP'; end if;
  update paysme_voucher_private.credit_confirmations c set otp_digest=paysme_voucher_private.hash((p_args->>'token')||':'||(p_args->>'otp')),
   otp_expires_at=now()+interval '10 minutes',otp_last_sent_at=now(),otp_send_count=c.otp_send_count+1 where c.id=_c.id;
  return paysme_voucher_private.credit_details(_c.id);
 end if;
 if p_action<>'confirm_batch' then raise exception 'Unsupported prepaid confirmation action'; end if;
 if _c.otp_digest is null or _c.otp_expires_at<=now() or _c.otp_attempts>=5 then return jsonb_build_object('error','Approval OTP expired or unavailable'); end if;
 if paysme_voucher_private.hash((p_args->>'token')||':'||coalesce(p_args->>'otp',''))<>_c.otp_digest then
  update paysme_voucher_private.credit_confirmations c set otp_attempts=c.otp_attempts+1 where c.id=_c.id;
  return jsonb_build_object('error','Incorrect approval code');
 end if;
 if _c.prepayment_id is not null then
  _balance:=paysme_voucher_private.credit_balance(_c.supplier_id);
  if (_balance->>'confirmed_balance_cents')::bigint+_d.amount_cents>100000000000000 then raise exception 'Prepaid account balance limit exceeded'; end if;
  insert into public.paysme_voucher_credit_ledger(supplier_id,entry_kind,amount_cents,prepayment_id,reference,recorded_by)
  values(_c.supplier_id,'deposit',_d.amount_cents,_d.id,_d.reference,'supervisor-otp:'||_c.id::text);
  update public.paysme_voucher_prepayments d set status='confirmed',confirmed_at=now(),confirmed_by_email=_c.finance_email where d.id=_d.id;
 else
  if not exists(select 1 from public.paysme_voucher_credit_reservations r where r.batch_id=_b.id and r.status='reserved' and r.amount_cents=_b.amount_due_cents) then raise exception 'Batch prepaid credit reservation unavailable'; end if;
  _balance:=paysme_voucher_private.credit_balance(_c.supplier_id);
  if (_balance->>'confirmed_balance_cents')::bigint<(_balance->>'reserved_cents')::bigint then raise exception 'Insufficient confirmed prepaid credit for this batch'; end if;
  select count(*),coalesce(sum(i.supplier_due_cents),0) into _qty,_total from public.paysme_voucher_batch_items i
   join public.paysme_vouchers v on v.id=i.voucher_id join public.paysme_voucher_sales s on s.id=i.sale_id
   where i.batch_id=_b.id and v.status='awaiting_settlement' and s.status='paid' and s.supplier_id=_b.supplier_id and s.payment_model='prepaid';
  if _qty<>_b.voucher_count or _total<>_b.amount_due_cents then raise exception 'Batch membership mismatch; contact PaySME'; end if;
  insert into public.paysme_voucher_credit_ledger(supplier_id,entry_kind,amount_cents,batch_id,reference,recorded_by)
  values(_c.supplier_id,'batch',-_b.amount_due_cents,_b.id,_b.batch_reference,'supervisor-otp:'||_c.id::text);
  update public.paysme_voucher_credit_reservations r set status='committed',committed_at=now() where r.batch_id=_b.id and r.status='reserved';
  update public.paysme_voucher_payment_batches b set status='settled',settled_at=now(),confirmed_payment_cents=b.amount_due_cents where b.id=_b.id;
  update public.paysme_vouchers v set status='redeemable',redeemable_at=now() where v.id in(select i.voucher_id from public.paysme_voucher_batch_items i where i.batch_id=_b.id);
 end if;
 update paysme_voucher_private.credit_confirmations c set consumed_at=now() where c.id=_c.id;
 return jsonb_build_object('confirmed',true,'credited',_c.prepayment_id is not null,'voucher_count',coalesce(_b.voucher_count,0),'account',paysme_voucher_private.credit_balance(_c.supplier_id));
end $$;

create function paysme_voucher_private.invalidate_credit_contacts() returns trigger
language plpgsql security definer set search_path='' as $$ begin
 if old.finance_email is distinct from new.finance_email or old.supervisor_email is distinct from new.supervisor_email then
  update public.paysme_voucher_prepayments d set finance_email=new.finance_email,supervisor_email=new.supervisor_email,version=d.version+1,
   status=case when d.status='awaiting_confirmation' then 'recorded' else d.status end where d.supplier_id=new.id and d.status<>'confirmed';
  update paysme_voucher_private.credit_confirmations c set revoked_at=now() where c.supplier_id=new.id and c.consumed_at is null and c.revoked_at is null;
 end if;
 return new;
end $$;
create trigger voucher_credit_contacts_changed after update of finance_email,supervisor_email on public.paysme_voucher_suppliers for each row execute function paysme_voucher_private.invalidate_credit_contacts();

-- Preserve the existing redemption, recipient verification and postpaid implementation unchanged.
alter function public.paysme_voucher_command(text,jsonb) set schema paysme_voucher_private;
alter function paysme_voucher_private.paysme_voucher_command(text,jsonb) rename to command_before_prepaid;
revoke all on function paysme_voucher_private.command_before_prepaid(text,jsonb) from public,anon,authenticated,service_role;
create function public.paysme_voucher_command(action text,args jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare _a public.admin_users%rowtype; _s public.paysme_voucher_suppliers%rowtype; _b public.paysme_voucher_payment_batches%rowtype;
 _d public.paysme_voucher_prepayments%rowtype; _fields jsonb; _result jsonb; _id uuid; _supplier uuid; _note text; _reference text;
begin
 if jsonb_typeof(args)<>'object' then raise exception 'Invalid request'; end if;
 if action in ('save_supplier','record_prepayment','start_prepayment_confirmation','resolve_credit_discrepancy','amend_prepayment','release_prepaid_reservation','prepare_batch','record_payment','attach_payment_proof','start_confirmation','resolve_discrepancy') then
  select * into _a from public.admin_users a where a.auth_user_id=(args->>'actor_id')::uuid and a.is_active and a.setup_status='active';
  if not found or not (_a.role='super_admin' or coalesce(_a.permissions #> '{vouchers,manage_suppliers}'='true'::jsonb,false)) then raise exception 'Voucher administrator required' using errcode='42501'; end if;
  perform set_config('request.jwt.claim.sub',_a.auth_user_id::text,true);
 end if;
 if action='save_supplier' then
  _fields:=args->'supplier'; _id:=(args->>'supplier_id')::uuid;
  if _id is null or jsonb_typeof(_fields)<>'object' then raise exception 'Supplier details required'; end if;
  insert into public.paysme_voucher_suppliers as target(id,business_name,registration_number,finance_contact_name,finance_email,supervisor_name,supervisor_email,support_email,settlement_terms,active,logo_path,payment_model,daily_reconciliation_enabled,prepaid_low_balance_cents)
  values(_id,trim(_fields->>'business_name'),nullif(trim(_fields->>'registration_number'),''),trim(_fields->>'finance_contact_name'),lower(trim(_fields->>'finance_email')),trim(_fields->>'supervisor_name'),lower(trim(_fields->>'supervisor_email')),nullif(trim(_fields->>'support_email'),''),_fields->>'settlement_terms',coalesce((_fields->>'active')::boolean,true),_fields->>'logo_path',coalesce(_fields->>'payment_model','postpaid'),coalesce((_fields->>'daily_reconciliation_enabled')::boolean,_fields->>'payment_model'='prepaid',false),coalesce((_fields->>'prepaid_low_balance_cents')::bigint,0))
  on conflict(id) do update set business_name=excluded.business_name,registration_number=excluded.registration_number,finance_contact_name=excluded.finance_contact_name,finance_email=excluded.finance_email,supervisor_name=excluded.supervisor_name,supervisor_email=excluded.supervisor_email,support_email=excluded.support_email,settlement_terms=excluded.settlement_terms,active=excluded.active,payment_model=excluded.payment_model,daily_reconciliation_enabled=excluded.daily_reconciliation_enabled,prepaid_low_balance_cents=excluded.prepaid_low_balance_cents,logo_path=case when _fields?'logo_path' then excluded.logo_path else target.logo_path end
  returning * into _s;
  if args?'initial_prepayment' and args->'initial_prepayment'<>'null'::jsonb then
   if _s.payment_model<>'prepaid' then raise exception 'Select prepaid terms before recording prepaid funds'; end if;
   _result:=paysme_voucher_private.record_prepayment((args->'initial_prepayment')||jsonb_build_object('supplier_id',_s.id,'deposit_kind','initial'),_a.auth_user_id::text);
   if _result->>'status'='confirmed' then return jsonb_build_object('saved',true,'supplier_id',_s.id); end if;
   return paysme_voucher_private.start_credit_confirmation(null,(_result->>'id')::uuid,args->>'token',_a.auth_user_id::text)||jsonb_build_object('saved',true,'supplier_id',_s.id);
  end if;
  if _s.payment_model='prepaid' and not exists(select 1 from public.paysme_voucher_prepayments d where d.supplier_id=_s.id) then raise exception 'Record the initial prepaid deposit and POP when selecting prepaid terms'; end if;
  return jsonb_build_object('saved',true,'supplier_id',_s.id);
 elsif action='record_prepayment' then
  _result:=paysme_voucher_private.record_prepayment(args,_a.auth_user_id::text);
  if _result->>'status'='confirmed' then return jsonb_build_object('saved',true,'already_confirmed',true); end if;
  return paysme_voucher_private.start_credit_confirmation(null,(_result->>'id')::uuid,args->>'token',_a.auth_user_id::text);
 elsif action='start_prepayment_confirmation' then
  return paysme_voucher_private.start_credit_confirmation(null,(args->>'prepayment_id')::uuid,args->>'token',_a.auth_user_id::text);
 elsif action='prepare_batch' then
  _result:=paysme_voucher_private.prepare_model_batch((args->>'supplier_id')::uuid,(args->>'cutoff_at')::timestamptz,args->>'payment_model',_a.auth_user_id::text);
  if _result is null then raise exception 'No eligible unbatched vouchers'; end if;
  return _result;
 elsif action='start_confirmation' then
  select * into _b from public.paysme_voucher_payment_batches b where b.id=(args->>'batch_id')::uuid;
  if _b.payment_model='prepaid' then return paysme_voucher_private.start_credit_confirmation(_b.id,null,args->>'token',_a.auth_user_id::text); end if;
 elsif action in ('record_payment','attach_payment_proof') then
  select * into _b from public.paysme_voucher_payment_batches b where b.id=(args->>'batch_id')::uuid;
  if _b.payment_model='prepaid' then raise exception 'Use the supplier prepaid account for this batch; do not record a batch bank payment'; end if;
  if action='record_payment' then
   _reference:=trim(args->>'bank_reference');
   perform pg_advisory_xact_lock(hashtextextended('voucher-bank:'||lower(_reference),4));
   if exists(select 1 from public.paysme_voucher_prepayments d where lower(d.bank_reference)=lower(_reference)) then raise exception 'This bank reference is already recorded as a prepaid deposit'; end if;
  end if;
 elsif action in ('amend_prepayment','resolve_credit_discrepancy') then
  select d.supplier_id into _supplier from public.paysme_voucher_prepayments d where d.id=(args->>'prepayment_id')::uuid;
  if _supplier is null then raise exception 'Prepayment unavailable'; end if;
  perform paysme_voucher_private.lock_credit(_supplier);
  select * into _d from public.paysme_voucher_prepayments d where d.id=(args->>'prepayment_id')::uuid for update;
  if _d.status='confirmed' then raise exception 'Confirmed prepaid deposits cannot be edited'; end if;
  _note:=trim(args->>'note'); if _note is null or length(_note) not between 3 and 1000 then raise exception 'An investigation or amendment note is required'; end if;
  if action='resolve_credit_discrepancy' then
   if _d.status<>'disputed' then raise exception 'Prepayment is not disputed'; end if;
   update public.paysme_voucher_credit_discrepancies x set status='resolved',resolved_at=now(),resolved_by=_a.auth_user_id::text,resolution_note=_note where x.prepayment_id=_d.id and x.status='open';
  else
   if args?'bank_reference' then
    _reference:=trim(args->>'bank_reference');
    if _reference is null or length(_reference) not between 1 and 200 then raise exception 'Prepayment ID and bank reference are required'; end if;
    perform pg_advisory_xact_lock(hashtextextended('voucher-bank:'||lower(_reference),4));
    if exists(select 1 from public.paysme_voucher_batch_payments p where lower(p.bank_transaction_reference)=lower(_reference)) then raise exception 'This bank reference is already recorded against a batch'; end if;
    if exists(select 1 from public.paysme_voucher_prepayments p where lower(p.bank_reference)=lower(_reference) and p.id<>_d.id) then raise exception 'Prepayment reference conflicts with an existing record'; end if;
   end if;
   if args?'proof_object_path' and not paysme_voucher_private.valid_payment_proof(_d.id,args->>'proof_object_path') then raise exception 'Upload a valid proof of payment for this prepayment'; end if;
   if not args?'proof_object_path' and not paysme_voucher_private.valid_payment_proof(_d.id,_d.proof_object_path) then raise exception 'Upload a valid proof of payment for this prepayment'; end if;
  end if;
  update public.paysme_voucher_prepayments d set amount_cents=case when action='amend_prepayment' then coalesce((args->>'amount_cents')::bigint,d.amount_cents) else d.amount_cents end,
   bank_reference=case when action='amend_prepayment' then coalesce(_reference,d.bank_reference) else d.bank_reference end,
   proof_object_path=coalesce(args->>'proof_object_path',d.proof_object_path),version=d.version+1,
   status=case when action='resolve_credit_discrepancy' then 'recorded' when d.status='disputed' then 'disputed' else 'recorded' end,
   change_log=d.change_log||jsonb_build_array(jsonb_build_object('at',now(),'actor',_a.auth_user_id,'action',action,'before_amount_cents',d.amount_cents,'after_amount_cents',coalesce((args->>'amount_cents')::bigint,d.amount_cents),'before_bank_reference',d.bank_reference,'after_bank_reference',coalesce(_reference,d.bank_reference),'note',_note)) where d.id=_d.id;
  update paysme_voucher_private.credit_confirmations c set revoked_at=now() where c.prepayment_id=_d.id and c.consumed_at is null and c.revoked_at is null;
  return jsonb_build_object('saved',true,'fresh_confirmation_required',true);
 elsif action='release_prepaid_reservation' or action='resolve_discrepancy' then
  select * into _b from public.paysme_voucher_payment_batches b where b.id=(args->>'batch_id')::uuid;
  if _b.payment_model='prepaid' then
   perform paysme_voucher_private.lock_credit(_b.supplier_id);
   select * into _b from public.paysme_voucher_payment_batches b where b.id=_b.id for update;
   if _b.status='settled' then raise exception 'A settled batch cannot be changed'; end if;
   _note:=trim(args->>'note'); if _note is null or length(_note) not between 3 and 1000 then raise exception 'An investigation or amendment note is required'; end if;
   if action='release_prepaid_reservation' then
    update public.paysme_voucher_credit_reservations r set status='released',released_at=now(),release_note=_note where r.batch_id=_b.id and r.status='reserved';
   else
    if _b.status<>'disputed' then raise exception 'Batch is not disputed'; end if;
    update public.paysme_voucher_credit_discrepancies x set status='resolved',resolved_at=now(),resolved_by=_a.auth_user_id::text,resolution_note=_note where x.batch_id=_b.id and x.status='open';
   end if;
   update public.paysme_voucher_payment_batches b set status=case when action='release_prepaid_reservation' and b.status='disputed' then 'disputed' else 'prepared' end,version=b.version+1 where b.id=_b.id;
   update paysme_voucher_private.credit_confirmations c set revoked_at=now() where c.batch_id=_b.id and c.consumed_at is null and c.revoked_at is null;
   return jsonb_build_object('saved',true,'fresh_confirmation_required',true);
  elsif action='release_prepaid_reservation' then raise exception 'This batch does not use prepaid credit'; end if;
 elsif action in ('confirmation_details','confirmation_otp','confirm_batch','report_discrepancy') then
  if exists(select 1 from paysme_voucher_private.credit_confirmations c where c.token_hash=paysme_voucher_private.hash(args->>'token')) then
   return paysme_voucher_private.credit_confirmation_command(action,args);
  end if;
 end if;
 return paysme_voucher_private.command_before_prepaid(action,args);
end $$;
revoke all on function public.paysme_voucher_command(text,jsonb) from public,anon,authenticated;
grant execute on function public.paysme_voucher_command(text,jsonb) to service_role;

create function public.paysme_voucher_credit_statement(p_supplier_id uuid,p_limit integer default 50,p_offset integer default 0) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare _limit integer:=least(greatest(p_limit,1),100); _offset integer:=greatest(p_offset,0); begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 return jsonb_build_object('account',(select to_jsonb(a) from public.paysme_voucher_credit_accounts a where a.supplier_id=p_supplier_id),
  'total_count',(select count(*) from public.paysme_voucher_credit_ledger l where l.supplier_id=p_supplier_id),'limit',_limit,'offset',_offset,
  'entries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (select l.* from public.paysme_voucher_credit_ledger l where l.supplier_id=p_supplier_id order by l.created_at desc,l.id desc limit _limit offset _offset) x),
  'prepayments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (select d.* from public.paysme_voucher_prepayments d where d.supplier_id=p_supplier_id order by d.created_at desc,d.id desc limit _limit offset _offset) x),
  'prepayment_count',(select count(*) from public.paysme_voucher_prepayments d where d.supplier_id=p_supplier_id),
  'reservation_count',(select count(*) from public.paysme_voucher_credit_reservations r where r.supplier_id=p_supplier_id and r.status='reserved'),
  'reservations',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (select r.*,b.batch_reference from public.paysme_voucher_credit_reservations r join public.paysme_voucher_payment_batches b on b.id=r.batch_id where r.supplier_id=p_supplier_id and r.status='reserved' order by r.created_at desc,r.id desc limit _limit offset _offset) x));
end $$;
revoke all on function public.paysme_voucher_credit_statement(uuid,integer,integer) from public,anon;
grant execute on function public.paysme_voucher_credit_statement(uuid,integer,integer) to authenticated;
revoke all on all functions in schema paysme_voucher_private from public,anon,authenticated,service_role;
revoke all on all tables in schema paysme_voucher_private from public,anon,authenticated,service_role;
notify pgrst,'reload schema';

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

-- Read-only staff drill-down. "Account" always means PaySME funds held with the named supplier.
create function public.paysme_voucher_batch_record(p_batch_id uuid,p_limit integer default 100,p_offset integer default 0) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare _b public.paysme_voucher_payment_batches%rowtype; _limit integer:=least(greatest(p_limit,1),100); _offset integer:=greatest(p_offset,0);
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 select * into _b from public.paysme_voucher_payment_batches b where b.id=p_batch_id;
 if not found then return null; end if;
 return jsonb_build_object('batch',to_jsonb(_b),'limit',_limit,'offset',_offset,'total_count',_b.voucher_count,
  'account',(select to_jsonb(a) from public.paysme_voucher_credit_accounts a where a.supplier_id=_b.supplier_id),
  'payments',(select coalesce(jsonb_agg(to_jsonb(p) order by p.recorded_at,p.id),'[]'::jsonb) from public.paysme_voucher_batch_payments p where p.batch_id=_b.id),
  'discrepancies',(select coalesce(jsonb_agg(x.data),'[]'::jsonb) from (
   select to_jsonb(d) as data from public.paysme_voucher_batch_discrepancies d where d.batch_id=_b.id
   union all select to_jsonb(d) as data from public.paysme_voucher_credit_discrepancies d where d.batch_id=_b.id) x),
  'reservations',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at,r.id),'[]'::jsonb) from public.paysme_voucher_credit_reservations r where r.batch_id=_b.id),
  'items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
   select v.id as voucher_id,v.code as voucher_code,v.status as voucher_status,s.id as sale_id,s.sale_no,s.customer_id,
    s.product_name,s.product_contents,s.customer_price_cents,i.supplier_due_cents,s.recipient_town,br.name as planned_branch,
    r.receipt_reference,r.redeemed_at,actual.name as redeemed_branch
   from public.paysme_voucher_batch_items i join public.paysme_vouchers v on v.id=i.voucher_id join public.paysme_voucher_sales s on s.id=i.sale_id
   left join public.paysme_voucher_branches br on br.id=s.planned_branch_id left join public.paysme_voucher_redemptions r on r.voucher_id=v.id
   left join public.paysme_voucher_branches actual on actual.id=r.branch_id
   where i.batch_id=_b.id order by i.created_at,i.id limit _limit offset _offset) x));
end $$;
revoke all on function public.paysme_voucher_batch_record(uuid,integer,integer) from public,anon;
grant execute on function public.paysme_voucher_batch_record(uuid,integer,integer) to authenticated;
notify pgrst,'reload schema';

SAVEPOINT validation_fixtures;
-- Rollback-only. PaySME owns the funds held with the supplier. No email/SMS or real money transfer.
do $$
declare
 _actor uuid; _supplier uuid:=gen_random_uuid(); _deposit uuid:=gen_random_uuid(); _topup uuid:=gen_random_uuid(); _third uuid:=gen_random_uuid();
 _branch uuid; _product uuid; _small_product uuid; _history_product uuid; _historical_deposit uuid; _proof text; _bank_proof text;
 _supplier_data jsonb; _out jsonb; _args jsonb; _sale jsonb; _sale_b jsonb; _cash_sale jsonb; _history_sale jsonb;
 _batch jsonb; _batch_b jsonb; _cash_batch jsonb; _history_batch jsonb; _account jsonb; _report jsonb; _jobs jsonb;
 _blocked boolean; _attempt integer; _count integer; _verify uuid; _request uuid:=gen_random_uuid();
 _key text:=repeat('f',64); _worker_key text; _prefix text; _worker_token text; _job jsonb;
 _today date:=(now() at time zone 'Africa/Windhoek')::date;
begin
 select a.auth_user_id into _actor from public.admin_users a where a.role='super_admin' and a.is_active and a.setup_status='active' limit 1;
 if _actor is null then raise exception 'Existing active super administrator required'; end if;
 _supplier_data:=jsonb_build_object('business_name','Rollback PaySME prepayment retailer','finance_contact_name','Finance','finance_email','finance@example.invalid',
  'supervisor_name','Supervisor','supervisor_email','supervisor@example.invalid','payment_model','prepaid','daily_reconciliation_enabled',true);
 _blocked:=false;
 begin perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data)); exception when raise_exception then _blocked:=true; end;
 if not _blocked or exists(select 1 from public.paysme_voucher_suppliers s where s.id=_supplier) then raise exception 'FAIL initial PaySME POP/payment must save atomically with prepaid terms'; end if;
 _proof:=_deposit::text||'/'||gen_random_uuid()::text||'.pdf';
 insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 _out:=public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data,'token',repeat('a',64),
  'initial_prepayment',jsonb_build_object('prepayment_id',_deposit,'bank_reference','rollback-paysme-outgoing-initial','amount_cents',3098,'proof_object_path',_proof)));
 if _out->>'confirmation_type'<>'prepayment' then raise exception 'FAIL initial PaySME prepayment review'; end if;
 _account:=paysme_voucher_private.credit_balance(_supplier);
 if _account->>'funds_owner'<>'PaySME' or _account->>'funds_location'<>'held_with_supplier' or (_account->>'available_cents')::bigint<>0 then raise exception 'FAIL PaySME fund ownership or pending funds spent'; end if;
 if (select d.payment_direction from public.paysme_voucher_prepayments d where d.id=_deposit)<>'paysme_to_supplier' then raise exception 'FAIL prepayment direction reversed'; end if;

 insert into public.paysme_voucher_branches(supplier_id,name,town) values(_supplier,'Requested pilot store','Windhoek') returning id into _branch;
 insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents)
 values(_supplier,'N$40,000 batch test',4000000,100,4100000) returning id into _product;
 insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents)
 values(_supplier,'Small prepaid voucher',1000,100,1200) returning id into _small_product;
 _args:=jsonb_build_object('product_id',_product,'payment_reference','rollback-prepaid-sale-a','request_key',gen_random_uuid(),'vendor_reference','rollback-vendor',
  'branch_id',_branch,'mobile_number','+264810000011','full_name','Rollback recipient','email','recipient@example.invalid','town','Windhoek','id_number','PREPAIDTEST123');
 -- Vendor sales must continue even though PaySME's balance with this supplier is zero/pending.
 _sale:=public.paysme_voucher_command('record_paid_sale',_args);
 if _sale->>'voucher_code' is null then raise exception 'FAIL supplier prepayment incorrectly blocks a Vendor sale'; end if;
 _batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 if _batch->>'payment_model'<>'prepaid' or (_batch->>'amount_due_cents')::bigint<>4000000 then raise exception 'FAIL prepaid purchase/batch snapshot'; end if;
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('a',64),'otp','123456'));
 _out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('a',64),'otp','123456'));
 if _out->>'credited'<>'true' then raise exception 'FAIL PaySME initial prepayment approval'; end if;
 _account:=paysme_voucher_private.credit_balance(_supplier);
 if (_account->>'available_cents')::bigint<>3098 then raise exception 'FAIL initial PaySME N$30.98 balance'; end if;
 _blocked:=false;
 begin perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('c',64)));
 exception when raise_exception then if sqlerrm<>'Insufficient confirmed prepaid credit for this batch' then raise; end if; _blocked:=true; end;
 if not _blocked or exists(select 1 from paysme_voucher_private.credit_confirmations c where c.batch_id=(_batch->>'id')::uuid) then raise exception 'FAIL N$40,000 approval request accepted with PaySME N$30.98 available'; end if;
 if exists(select 1 from public.paysme_voucher_credit_reservations r where r.batch_id=(_batch->>'id')::uuid) then raise exception 'FAIL rejected request reserved funds'; end if;
 _out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('a',64),'otp','123456'));
 if _out->>'replayed'<>'true' or (select count(*) from public.paysme_voucher_credit_ledger l where l.prepayment_id=_deposit)<>1 then raise exception 'FAIL initial prepayment credited twice'; end if;
 _blocked:=false;begin perform public.paysme_voucher_command('amend_prepayment',jsonb_build_object('actor_id',_actor,'prepayment_id',_deposit,'amount_cents',99999999,'note','invalid edit'));exception when raise_exception then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL confirmed PaySME funds edited'; end if;

 _proof:=_topup::text||'/'||gen_random_uuid()::text||'.pdf';
 insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 perform public.paysme_voucher_command('record_prepayment',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'prepayment_id',_topup,'bank_reference','rollback-paysme-topup','amount_cents',3996902,'proof_object_path',_proof,'token',repeat('b',64)));
 if (paysme_voucher_private.credit_balance(_supplier)->>'available_cents')::bigint<>3098 then raise exception 'FAIL pending top-up spent'; end if;
 perform public.paysme_voucher_command('amend_prepayment',jsonb_build_object('actor_id',_actor,'prepayment_id',_topup,'bank_reference','rollback-paysme-topup-corrected','note','Correct bank reference before approval'));
 _out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',repeat('b',64)));if not _out?'error' then raise exception 'FAIL amended payment retained an old approval';end if;
 perform public.paysme_voucher_command('start_prepayment_confirmation',jsonb_build_object('actor_id',_actor,'prepayment_id',_topup,'token',repeat('5',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('5',64),'otp','123456'));
 perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('5',64),'otp','123456'));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('c',64)));
 _account:=paysme_voucher_private.credit_balance(_supplier);
 if (_account->>'confirmed_balance_cents')::bigint<>4000000 or (_account->>'reserved_cents')::bigint<>4000000 or (_account->>'available_cents')::bigint<>0 then raise exception 'FAIL PaySME pending allocation accounting'; end if;
 _sale_b:=public.paysme_voucher_command('record_paid_sale',_args||jsonb_build_object('product_id',_small_product,'request_key',gen_random_uuid(),'payment_reference','rollback-prepaid-sale-b'));
 _batch_b:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 _blocked:=false;begin perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('0',64)));exception when raise_exception then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL PaySME funds reserved for another request spent twice'; end if;
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('d',64)));
 if (select count(*) from public.paysme_voucher_credit_reservations r where r.batch_id=(_batch->>'id')::uuid and r.status='reserved')<>1 then raise exception 'FAIL resend reserved PaySME funds twice'; end if;
 _out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',repeat('c',64)));
 if not _out?'error' then raise exception 'FAIL previous prepaid batch link still valid'; end if;
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('d',64),'otp','123456'));
 for _attempt in 1..5 loop perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('d',64),'otp','999999')); end loop;
 _out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('d',64),'otp','123456'));
 if not _out?'error' or exists(select 1 from public.paysme_voucher_credit_ledger l where l.batch_id=(_batch->>'id')::uuid) then raise exception 'FAIL prepaid supervisor lockout or early deduction'; end if;
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('e',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('e',64),'otp','654321'));
 perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('e',64),'otp','654321'));
 perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('e',64),'otp','654321'));
 if (paysme_voucher_private.credit_balance(_supplier)->>'confirmed_balance_cents')::bigint<>0 or (select count(*) from public.paysme_voucher_credit_ledger l where l.batch_id=(_batch->>'id')::uuid)<>1 then raise exception 'FAIL PaySME batch deducted twice'; end if;

 perform public.paysme_voucher_command('issue_api_key',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'branch_id',_branch,'label','Rollback supplier API','api_key',_key));
 _out:=public.paysme_voucher_command('validate_id',jsonb_build_object('api_key_hash',paysme_voucher_private.hash(_key),'voucher_code',_sale->>'voucher_code','pos_staff_reference','PILOT','id_number','PREPAIDTEST123'));
 _verify:=(_out->>'verification_id')::uuid;if _verify is null then raise exception 'FAIL prepaid voucher ID/API verification';end if;
 _out:=public.paysme_voucher_command('redeem_voucher',jsonb_build_object('api_key_hash',paysme_voucher_private.hash(_key),'voucher_code',_sale->>'voucher_code','pos_staff_reference','PILOT','verification_id',_verify,'request_key',_request));
 if _out->>'receipt_reference' is null or (paysme_voucher_private.credit_balance(_supplier)->>'confirmed_balance_cents')::bigint<>0 then raise exception 'FAIL redemption charged PaySME funds again or required a new balance'; end if;

 _proof:=_third::text||'/'||gen_random_uuid()::text||'.pdf';insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 perform public.paysme_voucher_command('record_prepayment',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'prepayment_id',_third,'bank_reference','rollback-paysme-small-topup','amount_cents',1000,'proof_object_path',_proof,'token',repeat('0',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('0',64),'otp','123456'));perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('0',64),'otp','123456'));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('1',64)));
 perform public.paysme_voucher_command('report_discrepancy',jsonb_build_object('token',repeat('1',64),'reason','incorrect_amount','comment','Our balance records differ; insufficient funds on retailer record'));
 if (select b.status from public.paysme_voucher_payment_batches b where b.id=(_batch_b->>'id')::uuid)<>'disputed' or exists(select 1 from public.paysme_voucher_credit_ledger l where l.batch_id=(_batch_b->>'id')::uuid) then raise exception 'FAIL retailer issue approved a charge';end if;
 perform public.paysme_voucher_command('release_prepaid_reservation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','note','Release hold during investigation'));
 if (paysme_voucher_private.credit_balance(_supplier)->>'available_cents')::bigint<>1000 then raise exception 'FAIL releasing pending hold changed PaySME ledger balance';end if;
 perform public.paysme_voucher_command('resolve_discrepancy',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','note','Retailer and PaySME balances reconciled'));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('2',64)));
 _supplier_data:=_supplier_data||jsonb_build_object('supervisor_email','new-supervisor@example.invalid');
 perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data));
 _out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',repeat('2',64)));if not _out?'error' then raise exception 'FAIL changed supervisor retained approval';end if;
 _out:=public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('3',64)));
 if _out->>'supervisor_email'<>'new-supervisor@example.invalid' then raise exception 'FAIL new supervisor not used';end if;
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('3',64),'otp','123456'));perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('3',64),'otp','123456'));

 -- Terms change is prospective. Existing prepaid charges/vouchers retain their funding.
 _supplier_data:=_supplier_data||jsonb_build_object('payment_model','postpaid');
 perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data));
 _cash_sale:=public.paysme_voucher_command('record_paid_sale',_args||jsonb_build_object('product_id',_small_product,'request_key',gen_random_uuid(),'payment_reference','rollback-cash-after-prepaid'));
 _cash_batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 if _cash_batch->>'payment_model'<>'postpaid' or (select b.payment_model from public.paysme_voucher_payment_batches b where b.id=(_batch->>'id')::uuid)<>'prepaid' then raise exception 'FAIL payment terms rewritten retrospectively';end if;
 _bank_proof:=(_cash_batch->>'id')||'/'||gen_random_uuid()::text||'.pdf';insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_bank_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 perform public.paysme_voucher_command('record_payment',jsonb_build_object('actor_id',_actor,'batch_id',_cash_batch->>'id','bank_reference','rollback-cash-separate-payment','amount_cents',1000,'proof_object_path',_bank_proof));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_cash_batch->>'id','token',repeat('4',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('4',64),'otp','123456'));perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('4',64),'otp','123456'));
 if (paysme_voucher_private.credit_balance(_supplier)->>'confirmed_balance_cents')::bigint<>0 then raise exception 'FAIL cash batch changed PaySME prepaid asset balance';end if;
 if (select count(*) from paysme_voucher_private.notification_outbox j where j.supplier_id=_supplier and j.kind='ready_sms')<>3 then raise exception 'FAIL missing/duplicate ready SMS events';end if;
 _blocked:=false;begin update public.paysme_voucher_credit_ledger l set amount_cents=1 where l.supplier_id=_supplier;exception when raise_exception then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL PaySME asset ledger mutable';end if;

 -- Historical fixtures prove opening + top-ups - approved batches, including UNREDEEMED approved vouchers.
 for _attempt in 1..2 loop
  _historical_deposit:=gen_random_uuid();
  insert into public.paysme_voucher_prepayments(id,supplier_id,supplier_name,finance_email,supervisor_email,deposit_kind,bank_reference,amount_cents,proof_object_path,status,recorded_by,created_at,confirmed_at,confirmed_by_email)
  values(_historical_deposit,_supplier,'Historical test','finance@example.invalid','new-supervisor@example.invalid','topup','historical-'||_historical_deposit::text,case when _attempt=1 then 3000 else 2000 end,_proof,'confirmed',_actor::text,(_today-_attempt)::timestamp at time zone 'Africa/Windhoek',(_today-_attempt)::timestamp at time zone 'Africa/Windhoek','finance@example.invalid');
  insert into public.paysme_voucher_credit_ledger(supplier_id,entry_kind,amount_cents,prepayment_id,reference,recorded_by,created_at)
  values(_supplier,'deposit',case when _attempt=1 then 3000 else 2000 end,_historical_deposit,'Historical PaySME prepayment',_actor::text,(_today-_attempt)::timestamp at time zone 'Africa/Windhoek');
 end loop;
 _supplier_data:=_supplier_data||jsonb_build_object('payment_model','prepaid');perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data));
 insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents) values(_supplier,'Historical unredeemed approved voucher',4000,0,4000) returning id into _history_product;
 _history_sale:=public.paysme_voucher_command('record_paid_sale',_args||jsonb_build_object('product_id',_history_product,'request_key',gen_random_uuid(),'payment_reference','rollback-history-sale'));
 _history_batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 insert into public.paysme_voucher_credit_ledger(supplier_id,entry_kind,amount_cents,batch_id,reference,recorded_by,created_at)
 values(_supplier,'batch',-4000,(_history_batch->>'id')::uuid,_history_batch->>'batch_reference',_actor::text,(_today-1)::timestamp at time zone 'Africa/Windhoek');
 update public.paysme_voucher_payment_batches b set status='settled',settled_at=(_today-1)::timestamp at time zone 'Africa/Windhoek',confirmed_payment_cents=4000 where b.id=(_history_batch->>'id')::uuid;
 update public.paysme_vouchers v set status='redeemable',redeemable_at=(_today-1)::timestamp at time zone 'Africa/Windhoek' where v.sale_id=(_history_sale->>'sale_id')::uuid;
 _report:=paysme_voucher_private.reconciliation_data(_supplier,_today-1);
 if (_report->>'opening_cents')::bigint<>2000 or (_report->>'credited_cents')::bigint<>3000 or (_report->>'charged_cents')::bigint<>4000 or (_report->>'closing_cents')::bigint<>1000 then raise exception 'FAIL PaySME opening/top-up/approved-batch reconciliation';end if;
 perform paysme_voucher_private.queue_reconciliation(_supplier,_today-1);perform paysme_voucher_private.queue_reconciliation(_supplier,_today-1);
 if (select count(*) from paysme_voucher_private.notification_outbox j where j.supplier_id=_supplier and j.kind='daily_email')<>2 then raise exception 'FAIL daily report not queued once to each supplier contact';end if;
 if has_function_privilege('authenticated','public.paysme_voucher_command(text,jsonb)','execute') or has_function_privilege('anon','public.paysme_voucher_claim_notifications(text,integer)','execute') or has_table_privilege('authenticated','public.paysme_voucher_credit_ledger','update') then raise exception 'FAIL financial/worker privileges';end if;
 perform set_config('request.jwt.claim.sub',_actor::text,true);
 _out:=public.paysme_voucher_batch_record((_batch->>'id')::uuid,1,0);
 if (_out->>'total_count')::integer<>1 or jsonb_array_length(_out->'items')<>1 then raise exception 'FAIL paginated staff batch record';end if;
 _out:=public.paysme_voucher_credit_statement(_supplier,1,0);if jsonb_array_length(_out->'entries')<>1 then raise exception 'FAIL prepaid statement pagination';end if;
 execute 'set local role authenticated';
 _out:=public.paysme_voucher_credit_statement(_supplier,1,0);if _out->'account'->>'funds_owner'<>'PaySME' then raise exception 'FAIL staff invoker view / RLS';end if;
 _out:=public.paysme_voucher_batch_record((_batch->>'id')::uuid,1,0);if _out->'batch'->>'payment_model'<>'prepaid' then raise exception 'FAIL staff batch RLS';end if;
 execute 'reset role';

 -- Lease authentication/acknowledgement tested without contacting any provider.
 update paysme_voucher_private.notification_outbox j set created_at='2000-01-01' where j.supplier_id=_supplier;
 _prefix:=floor(extract(epoch from clock_timestamp()))::bigint::text||':'||gen_random_uuid()::text;
 select s.signing_key into _worker_key from paysme_voucher_private.notification_settings s where s.singleton;
 _worker_token:=_prefix||':'||encode(extensions.hmac(_prefix,_worker_key,'sha256'),'hex');
 _jobs:=public.paysme_voucher_claim_notifications(_worker_token,50);
 _blocked:=false;begin perform public.paysme_voucher_claim_notifications(_worker_token,50);exception when insufficient_privilege then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL worker token replay';end if;
 for _job in select value from jsonb_array_elements(_jobs) loop
  if public.paysme_voucher_finish_notification((_job->>'id')::uuid,gen_random_uuid(),true) then raise exception 'FAIL wrong delivery lease accepted';end if;
  if not public.paysme_voucher_finish_notification((_job->>'id')::uuid,(_job->>'lease_id')::uuid,true) then raise exception 'FAIL valid delivery acknowledgement';end if;
  if public.paysme_voucher_finish_notification((_job->>'id')::uuid,(_job->>'lease_id')::uuid,true) then raise exception 'FAIL duplicate delivery acknowledgement';end if;
 end loop;
 if exists(select 1 from public.paysme_voucher_credit_ledger l where l.supplier_id=_supplier and (l.funds_owner<>'PaySME' or l.funds_location<>'held_with_supplier')) then raise exception 'FAIL wrong prepaid fund owner';end if;
end $$;

ROLLBACK TO SAVEPOINT validation_fixtures;
RELEASE SAVEPOINT validation_fixtures;

SAVEPOINT validation_fixtures;
-- Complete rollback-only integration test. Run as postgres; never sends email/SMS.
do $$
declare
 attempt integer; actor uuid; supplier uuid; other_supplier uuid; branch uuid; product uuid;
 sale1 jsonb; sale2 jsonb; sale3 jsonb; batch jsonb; out jsonb; receipt jsonb;
 args jsonb; batch_id uuid; verify_id uuid; token text:=repeat('a',64); key text:=repeat('b',64);
 blocked boolean; proof text; payment uuid;
begin
 select auth_user_id into actor from public.admin_users where role='super_admin' and is_active and setup_status='active' limit 1;
 if actor is null then raise exception 'Existing super administrator required'; end if;
 if has_function_privilege('authenticated','public.paysme_voucher_command(text,jsonb)','EXECUTE') or has_function_privilege('anon','public.paysme_voucher_command(text,jsonb)','EXECUTE') then raise exception 'FAIL server RPC exposed'; end if;
 insert into public.paysme_voucher_suppliers(business_name,finance_contact_name,finance_email,supervisor_name,supervisor_email)
 values('Rollback pilot supplier','Finance','finance@example.invalid','Supervisor','supervisor@example.invalid') returning id into supplier;
 insert into public.paysme_voucher_suppliers(business_name,finance_contact_name,finance_email,supervisor_name,supervisor_email)
 values('Other pilot supplier','Finance','other-finance@example.invalid','Supervisor','other-supervisor@example.invalid') returning id into other_supplier;
 insert into public.paysme_voucher_branches(supplier_id,name,town) values(supplier,'Pilot store','Keetmanshoop') returning id into branch;
 insert into public.paysme_voucher_products(supplier_id,name,product_list,supplier_price_cents,markup_cents,instore_price_cents)
 values(supplier,'Vegetable combo','Rice, cabbage, sugar',50000,2000,60000) returning id into product;
 args:=jsonb_build_object('product_id',product,'payment_reference','pilot-1','request_key',gen_random_uuid(),'vendor_reference','pilot-vendor','branch_id',branch,'mobile_number','+264810000001','full_name','Pilot recipient','email','recipient@example.invalid','town','Keetmanshoop','id_number','PILOT-12345');
 sale1:=public.paysme_voucher_command('record_paid_sale',args);
 out:=public.paysme_voucher_command('record_paid_sale',args);
 if out->>'voucher_code'<>sale1->>'voucher_code' or out->>'replayed'<>'true' then raise exception 'FAIL sale idempotency'; end if;
 sale2:=public.paysme_voucher_command('record_paid_sale',args||jsonb_build_object('payment_reference','pilot-2','request_key',gen_random_uuid()));
 batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',actor,'supplier_id',supplier,'cutoff_at',now()));
 batch_id:=(batch->>'id')::uuid;
 proof:=batch_id::text||'/'||gen_random_uuid()::text||'.pdf';
 blocked:=false;
 begin perform public.paysme_voucher_command('record_payment',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'bank_reference','pilot-no-proof','amount_cents',100000)); exception when others then blocked:=true; end;
 if not blocked then raise exception 'FAIL payment without proof accepted'; end if;
 insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 if (batch->>'amount_due_cents')::bigint<>100000 or (batch->>'voucher_count')::int<>2 then raise exception 'FAIL batch total'; end if;
 sale3:=public.paysme_voucher_command('record_paid_sale',args||jsonb_build_object('payment_reference','pilot-3','request_key',gen_random_uuid()));
 perform public.paysme_voucher_command('record_payment',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'bank_reference','pilot-bank-1','amount_cents',49000,'proof_object_path',proof));
 blocked:=false;
 begin perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token));
 exception when others then blocked:=true; end;
 if not blocked then raise exception 'FAIL partial payment released confirmation'; end if;
 perform public.paysme_voucher_command('record_payment',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'bank_reference','pilot-bank-2','amount_cents',51000,'proof_object_path',proof));
 out:=public.paysme_voucher_command('record_payment',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'bank_reference','pilot-bank-2','amount_cents',51000,'proof_object_path',proof));
 update public.paysme_voucher_batch_payments set proof_object_path=null where bank_transaction_reference='pilot-bank-2' returning id into payment;
 blocked:=false;
 begin perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token)); exception when others then blocked:=true; end;
 if not blocked then raise exception 'FAIL confirmation without every POP accepted'; end if;
 perform public.paysme_voucher_command('attach_payment_proof',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'payment_id',payment,'proof_object_path',proof));
 if (select sum(pay.amount_cents) from public.paysme_voucher_batch_payments pay where pay.batch_id=(batch->>'id')::uuid)<>100000 or (select count(*) from public.paysme_voucher_batch_payments pay where pay.batch_id=(batch->>'id')::uuid)<>2 then raise exception 'FAIL POP attachment changed bank payment totals'; end if;
 if out->>'replayed'<>'true' then raise exception 'FAIL payment idempotency'; end if;
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token));
 perform public.paysme_voucher_command('report_discrepancy',jsonb_build_object('token',token,'reason','reference_mismatch','comment','Check reference'));
 perform public.paysme_voucher_command('resolve_discrepancy',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'note','Reference checked with bank'));
 if exists(select 1 from public.paysme_vouchers where code=sale1->>'voucher_code' and status='redeemable') then raise exception 'FAIL resolution released voucher'; end if;
 out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',token,'otp','123456'));
 if not out ? 'error' then raise exception 'FAIL revoked link accepted'; end if;
 token:=repeat('c',64);
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token));
 update public.paysme_voucher_suppliers set supervisor_email='changed@example.invalid' where id=supplier;
 out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',token));
 if not out ? 'error' then raise exception 'FAIL changed contacts left link active'; end if;
 token:=repeat('d',64);
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token));
 update paysme_voucher_private.supplier_confirmations set created_at=now()-interval '3 days',expires_at=now()-interval '1 hour' where token_hash=paysme_voucher_private.hash(token);
 out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',token));
 if not out ? 'error' then raise exception 'FAIL expired confirmation accepted'; end if;
 token:=repeat('f',64);
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',token,'otp','123456'));
 out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',token,'otp','000000'));
 if not out ? 'error' then raise exception 'FAIL wrong supervisor OTP'; end if;
 for attempt in 1..4 loop perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',token,'otp','000000')); end loop;
 out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',token,'otp','123456'));
 if not out ? 'error' then raise exception 'FAIL supervisor OTP lockout'; end if;
 token:=repeat('9',64);
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',actor,'batch_id',batch_id,'token',token));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',token,'otp','123456'));
 out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',token,'otp','123456'));
 if out->>'confirmed'<>'true' then raise exception 'FAIL settlement %',out; end if;
 out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',token,'otp','123456'));
 if not out ? 'error' then raise exception 'FAIL confirmation replay'; end if;
 if (select status from public.paysme_vouchers where code=sale3->>'voucher_code')<>'awaiting_settlement' then raise exception 'FAIL unbatched voucher released'; end if;
 perform public.paysme_voucher_command('issue_api_key',jsonb_build_object('actor_id',actor,'supplier_id',supplier,'branch_id',branch,'label','Pilot POS','api_key',key));
 args:=jsonb_build_object('api_key_hash',paysme_voucher_private.hash(key),'voucher_code',sale1->>'voucher_code','pos_staff_reference','cashier-pilot');
 out:=public.paysme_voucher_command('validate_id',args||jsonb_build_object('id_number','WRONG'));
 if not out ? 'error' then raise exception 'FAIL wrong ID'; end if;
 out:=public.paysme_voucher_command('validate_id',args||jsonb_build_object('id_number','PILOT12345'));
 verify_id:=(out->>'verification_id')::uuid;
 if verify_id is null then raise exception 'FAIL physical ID validation %',out; end if;
 args:=args||jsonb_build_object('verification_id',verify_id,'request_key',gen_random_uuid());
 update paysme_voucher_private.redemption_sessions set created_at=now()-interval '20 minutes',expires_at=now()-interval '1 minute' where id=verify_id;
 out:=public.paysme_voucher_command('redeem_voucher',args);
 if not out ? 'error' then raise exception 'FAIL expired identity verification accepted'; end if;
 out:=public.paysme_voucher_command('validate_id',args||jsonb_build_object('id_number','PILOT12345'));
 args:=args||jsonb_build_object('verification_id',out->>'verification_id');
 receipt:=public.paysme_voucher_command('redeem_voucher',args);
 if receipt->>'receipt_reference' is null then raise exception 'FAIL redemption %',receipt; end if;
 out:=public.paysme_voucher_command('redeem_voucher',args);
 if out->>'receipt_reference'<>receipt->>'receipt_reference' or out->>'replayed'<>'true' then raise exception 'FAIL redemption retry'; end if;
 out:=public.paysme_voucher_command('get_receipt',args);
 if out->>'receipt_reference'<>receipt->>'receipt_reference' then raise exception 'FAIL receipt reprint'; end if;
 out:=public.paysme_voucher_command('redeem_voucher',args||jsonb_build_object('request_key',gen_random_uuid()));
 if not out ? 'error' then raise exception 'FAIL double redemption'; end if;
 args:=args||jsonb_build_object('voucher_code',sale2->>'voucher_code');
 out:=public.paysme_voucher_command('request_recipient_otp',args||jsonb_build_object('sms_otp','234567','email_otp','345678'));
 verify_id:=(out->>'verification_id')::uuid;
 if verify_id is null then raise exception 'FAIL OTP request %',out; end if;
 args:=args||jsonb_build_object('verification_id',verify_id);
 out:=public.paysme_voucher_command('validate_recipient_otp',args||jsonb_build_object('sms_otp','234567','email_otp','000000'));
 if not out ? 'error' then raise exception 'FAIL one OTP accepted'; end if;
 out:=public.paysme_voucher_command('validate_recipient_otp',args||jsonb_build_object('sms_otp','234567','email_otp','345678'));
 if out->>'verified'<>'true' then raise exception 'FAIL dual OTP %',out; end if;
 out:=public.paysme_voucher_command('redeem_voucher',args||jsonb_build_object('request_key',gen_random_uuid()));
 if out->>'receipt_reference' is null then raise exception 'FAIL OTP redemption %',out; end if;
 if not exists(select 1 from public.paysme_voucher_payment_batches where id=batch_id and redeemed_count=2 and settlement_consumed_cents=100000) then raise exception 'FAIL batch consumption'; end if;
 -- An API key for another supplier cannot inspect the voucher.
 perform public.paysme_voucher_command('issue_api_key',jsonb_build_object('actor_id',actor,'supplier_id',other_supplier,'label','Other POS','api_key',repeat('e',64)));
 insert into public.paysme_voucher_branches(supplier_id,name,town) values(other_supplier,'Other branch','Windhoek') returning id into branch;
 out:=public.paysme_voucher_command('verify_voucher',args||jsonb_build_object('api_key_hash',paysme_voucher_private.hash(repeat('e',64)),'branch_id',branch));
 if not out ? 'error' then raise exception 'FAIL supplier isolation'; end if;
-- Daily batching uses the prior Namibia calendar day and never releases vouchers.
 update public.paysme_voucher_sales set paid_at=now()-interval '2 days' where id=(sale3->>'sale_id')::uuid;
 perform paysme_voucher_private.prepare_daily_batches();
 if not exists(select 1 from public.paysme_voucher_payment_batches b join public.paysme_voucher_batch_items i on i.batch_id=b.id join public.paysme_vouchers v on v.id=i.voucher_id where v.code=sale3->>'voucher_code' and b.created_by_staff_reference='system:daily-batcher' and b.status='prepared' and v.status='awaiting_settlement') then raise exception 'FAIL daily batching'; end if;
 perform paysme_voucher_private.prepare_daily_batches();
 if (select count(*) from public.paysme_voucher_batch_items i join public.paysme_vouchers v on v.id=i.voucher_id where v.code=sale3->>'voucher_code')<>1 then raise exception 'FAIL daily duplicate membership'; end if;
end $$;

ROLLBACK TO SAVEPOINT validation_fixtures;
RELEASE SAVEPOINT validation_fixtures;

SAVEPOINT validation_fixtures;
-- Staff-only read/query test. Every fixture is rolled back; no messages or payments.
do $$
declare actor uuid; tag text:='portal-view-'||gen_random_uuid()::text;
 suppliers uuid[]:='{}'; branches uuid[]:='{}'; products uuid[]:='{}'; customers uuid[]:='{}'; batches uuid[]:='{}';
 i integer; company_index integer; customer_index integer; new_id uuid; sale_id uuid; voucher_id uuid; verification_id uuid; voucher_code text;
begin
 select auth_user_id into actor from public.admin_users where is_active and setup_status='active' and role='super_admin' and auth_user_id is not null limit 1;
 if actor is null then raise exception 'Existing super administrator required'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform set_config('voucher_view_test.baseline',public.paysme_voucher_company_overview()::text,true);
 for i in 1..2 loop
  insert into public.paysme_voucher_suppliers(business_name,finance_contact_name,finance_email,supervisor_name,supervisor_email)
  values(tag||'-supplier-'||i,'Finance','finance@example.invalid','Supervisor','supervisor@example.invalid') returning id into new_id;
  suppliers:=array_append(suppliers,new_id);
  insert into public.paysme_voucher_branches(supplier_id,name,town) values(new_id,'Test store',case when i=1 then 'Keetmanshoop' else 'Windhoek' end) returning id into new_id;
  branches:=array_append(branches,new_id);
  insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents)
  values(suppliers[i],tag||'-product-'||i,50000,2000,60000) returning id into new_id;
  products:=array_append(products,new_id);
  insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference,status,confirmed_payment_cents,settlement_consumed_cents,redeemed_count,settled_at)
  values(suppliers[i],tag||'-supplier-'||i,'finance@example.invalid','supervisor@example.invalid',now(),case when i=1 then 2 else 1 end,case when i=1 then 100000 else 50000 end,'rollback-view-test',case when i=1 then 'settled' else 'prepared' end,case when i=1 then 100000 else 0 end,case when i=1 then 100000 else 0 end,case when i=1 then 2 else 0 end,case when i=1 then now() else null end) returning id into new_id;
  batches:=array_append(batches,new_id);
 end loop;
 for i in 1..3 loop
  insert into public.paysme_customers(mobile_number,full_name,email,town,source)
  values('+999'||lpad(floor(random()*10000000000)::bigint::text,10,'0'),tag||'-customer-'||i,'recipient@example.invalid','Windhoek',case when i=3 then 'legacy_utility_import' else 'vendor_purchase' end) returning id into new_id;
  customers:=array_append(customers,new_id);
 end loop;
 for i in 1..3 loop
  company_index:=case when i=2 then 2 else 1 end;customer_index:=case when i=3 then 2 else 1 end;
  insert into public.paysme_voucher_sales(request_key,payment_reference,vendor_reference,customer_id,product_id,supplier_id,planned_branch_id,product_name,product_contents,product_description,entitlement_type,supplier_base_cents,markup_cents,instore_price_cents,rebate_cents,rebate_timing,vendor_commission_cents,recipient_town)
  values(gen_random_uuid(),tag||'-sale-'||i,'rollback-test',customers[customer_index],products[company_index],suppliers[company_index],branches[company_index],tag||'-product-'||company_index,'Test combo','Test description','product_bundle',50000,2000,60000,0,'later',0,'Windhoek') returning id into sale_id;
  voucher_code:='PAD-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'));
  insert into public.paysme_vouchers(sale_id,code,status,redeemable_at,redeemed_at)
  values(sale_id,voucher_code,case when company_index=1 then 'redeemed' else 'awaiting_settlement' end,case when company_index=1 then now() else null end,case when company_index=1 then now() else null end) returning id into voucher_id;
  insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents) values(batches[company_index],voucher_id,sale_id,50000);
  if company_index=1 then
   insert into paysme_voucher_private.redemption_sessions(voucher_id,supplier_id,branch_id,method,status,pos_staff_reference,expires_at,verified_at,consumed_at)
   values(voucher_id,suppliers[1],branches[1],'physical_id','consumed','rollback-test',now()+interval '5 minutes',now(),now()) returning id into verification_id;
   insert into public.paysme_voucher_redemptions(voucher_id,supplier_id,batch_id,branch_id,verification_id,request_key,supplier_due_consumed_cents,receipt_data,pos_staff_reference)
   values(voucher_id,suppliers[1],batches[1],branches[1],verification_id,gen_random_uuid(),50000,jsonb_build_object('voucher_code',voucher_code),'rollback-test');
  end if;
 end loop;
 perform set_config('voucher_view_test.suppliers',to_jsonb(suppliers)::text,true);
 perform set_config('voucher_view_test.customers',to_jsonb(customers)::text,true);
 perform set_config('voucher_view_test.tag',tag,true);
end $$;
set local role authenticated;
do $$
declare supplier_ids jsonb:=current_setting('voucher_view_test.suppliers')::jsonb;
 customer_ids jsonb:=current_setting('voucher_view_test.customers')::jsonb;
 baseline jsonb:=current_setting('voucher_view_test.baseline')::jsonb;
 a jsonb; b jsonb; combined jsonb; directory jsonb; next_page jsonb; customer jsonb;
begin
 a:=public.paysme_voucher_company_overview((supplier_ids->>0)::uuid);
 b:=public.paysme_voucher_company_overview((supplier_ids->>1)::uuid);
 combined:=public.paysme_voucher_company_overview();
 if (a->>'paid_sales')::int<>2 or (b->>'paid_sales')::int<>1 or (combined->>'paid_sales')::bigint<>(baseline->>'paid_sales')::bigint+3 then raise exception 'FAIL company sale totals'; end if;
 if (a->>'customer_paid_cents')::bigint<>104000 or (b->>'customer_paid_cents')::bigint<>52000 then raise exception 'FAIL company prices'; end if;
 if (a->>'pending_settlement_cents')::bigint<>0 or (b->>'pending_settlement_cents')::bigint<>50000 then raise exception 'FAIL company settlement totals'; end if;
 if (a->>'redemption_count')::int<>2 or (b->>'redemption_count')::int<>0 or (a->>'settlement_consumed_cents')::bigint<>100000 then raise exception 'FAIL company redemption totals'; end if;
 if jsonb_array_length(a->'planning')<>0 or jsonb_array_length(b->'planning')<>1 or b->'planning'->0->>'supplier_id'<>supplier_ids->>1 then raise exception 'FAIL company planning'; end if;
 directory:=public.paysme_voucher_customer_directory(current_setting('voucher_view_test.tag'),0,1);
 next_page:=public.paysme_voucher_customer_directory(current_setting('voucher_view_test.tag'),1,1);
 if (directory->>'total_count')::int<>2 or jsonb_array_length(directory->'customers')<>1 or directory->'customers'->0->>'id'=next_page->'customers'->0->>'id' then raise exception 'FAIL voucher-only directory/pagination'; end if;
 if directory->'customers'->0 ? 'mobile_number' or directory->'customers'->0 ? 'email' then raise exception 'FAIL directory masking'; end if;
 customer:=public.paysme_voucher_customer_record((customer_ids->>0)::uuid,0,1);
 if (customer->'summary'->>'purchase_count')::int<>2 or (customer->'summary'->>'paid_value_cents')::bigint<>104000 or jsonb_array_length(customer->'purchases')<>1 then raise exception 'FAIL full customer totals and paged history'; end if;
 next_page:=public.paysme_voucher_customer_record((customer_ids->>0)::uuid,1,1);
 if customer->'purchases'->0->>'sale_id'=next_page->'purchases'->0->>'sale_id' then raise exception 'FAIL duplicate customer history pages'; end if;
 if customer->'purchases'->0->>'supplier_id'=next_page->'purchases'->0->>'supplier_id' then raise exception 'FAIL customer history across companies'; end if;
 if public.paysme_voucher_customer_record((customer_ids->>2)::uuid) is not null then raise exception 'FAIL VAS-only customer visible'; end if;
 if has_function_privilege('anon','public.paysme_voucher_customer_record(uuid,integer,integer)','EXECUTE') then raise exception 'FAIL anonymous customer access'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
set local role authenticated;
do $$ declare blocked integer:=0; begin
 begin perform public.paysme_voucher_companies(); exception when insufficient_privilege then blocked:=blocked+1; end;
 begin perform public.paysme_voucher_customer_directory(); exception when insufficient_privilege then blocked:=blocked+1; end;
 begin perform public.paysme_voucher_customer_record((current_setting('voucher_view_test.customers')::jsonb->>0)::uuid); exception when insufficient_privilege then blocked:=blocked+1; end;
 begin perform public.paysme_voucher_company_overview(); exception when insufficient_privilege then blocked:=blocked+1; end;
 if blocked<>4 then raise exception 'FAIL non-staff data access'; end if;
end $$;
reset role;

ROLLBACK TO SAVEPOINT validation_fixtures;
RELEASE SAVEPOINT validation_fixtures;

COMMIT;
