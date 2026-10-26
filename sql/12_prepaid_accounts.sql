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
