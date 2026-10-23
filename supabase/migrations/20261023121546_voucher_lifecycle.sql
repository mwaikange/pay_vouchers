-- Phase 2: lifecycle tables only. Run once AFTER the Phase 1 creation script.
-- Existing staff records, Auth settings, vendor wallets and utility tables are not changed.
begin;
do $$
begin
  if to_regclass('public.paysme_voucher_products') is null or to_regclass('public.paysme_customers') is null then
    raise exception 'Run the Phase 1 table-creation script first.';
  end if;
  if to_regnamespace('paysme_voucher_private') is not null or to_regclass('public.paysme_voucher_sales') is not null then
    raise exception 'Voucher lifecycle objects already exist. Stop and review; do not overwrite them.';
  end if;
end $$;

create schema paysme_voucher_private;
revoke all on schema paysme_voucher_private from public, anon, authenticated, service_role;

create table public.paysme_voucher_sales (
  id uuid primary key default gen_random_uuid(),
  sale_no bigint generated always as identity unique,
  request_key uuid not null unique,
  payment_reference text not null unique check (length(trim(payment_reference)) between 1 and 200),
  vendor_reference text not null check (length(trim(vendor_reference)) between 1 and 100),
  customer_id uuid not null references public.paysme_customers(id),
  product_id uuid not null references public.paysme_voucher_products(id),
  supplier_id uuid not null references public.paysme_voucher_suppliers(id),
  planned_branch_id uuid references public.paysme_voucher_branches(id),
  product_name text not null,
  product_contents text not null,
  product_description text not null,
  entitlement_type text not null check (entitlement_type in ('product_bundle','store_credit')),
  redemption_value_cents bigint check (redemption_value_cents between 1 and 100000000000),
  supplier_base_cents bigint not null check (supplier_base_cents between 1 and 100000000000),
  markup_cents bigint not null check (markup_cents between 0 and 100000000000),
  customer_price_cents bigint generated always as (supplier_base_cents + markup_cents) stored,
  instore_price_cents bigint not null check (instore_price_cents between 0 and 100000000000),
  rebate_cents bigint not null check (rebate_cents between 0 and supplier_base_cents),
  rebate_timing text not null check (rebate_timing in ('immediate','later')),
  supplier_due_cents bigint generated always as (supplier_base_cents - case when rebate_timing = 'immediate' then rebate_cents else 0 end) stored,
  vendor_commission_cents bigint not null check (vendor_commission_cents between 0 and 100000000000),
  status text not null default 'paid' check (status in ('paid','refunded','cancelled')),
  paid_at timestamptz not null default now(),
  check (entitlement_type <> 'store_credit' or redemption_value_cents is not null)
);
create index paysme_voucher_sales_supplier_date_idx on public.paysme_voucher_sales(supplier_id,paid_at);
create index paysme_voucher_sales_customer_idx on public.paysme_voucher_sales(customer_id,paid_at desc);
create index paysme_voucher_sales_product_idx on public.paysme_voucher_sales(product_id);
create index paysme_voucher_sales_branch_idx on public.paysme_voucher_sales(planned_branch_id);

create table public.paysme_vouchers (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null unique references public.paysme_voucher_sales(id),
  code text not null unique check (code ~ '^PAD-[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}$'),
  status text not null default 'awaiting_settlement' check (status in ('awaiting_settlement','redeemable','redeemed','cancelled')),
  created_at timestamptz not null default now(),
  redeemable_at timestamptz,
  redeemed_at timestamptz,
  check (status not in ('redeemable','redeemed') or redeemable_at is not null),
  check ((status = 'redeemed') = (redeemed_at is not null)),
  check (status <> 'awaiting_settlement' or redeemable_at is null)
);
create index paysme_vouchers_status_idx on public.paysme_vouchers(status,created_at);

create table public.paysme_voucher_payment_batches (
  id uuid primary key default gen_random_uuid(),
  batch_no bigint generated always as identity unique,
  batch_reference text generated always as ('PV-BATCH-'::text || batch_no::text) stored unique,
  supplier_id uuid not null references public.paysme_voucher_suppliers(id),
  supplier_name text not null,
  finance_email text not null,
  supervisor_email text not null,
  cutoff_at timestamptz not null,
  voucher_count integer not null check (voucher_count > 0),
  amount_due_cents bigint not null check (amount_due_cents between 0 and 100000000000000),
  status text not null default 'prepared' check (status in ('prepared','payment_submitted','awaiting_confirmation','disputed','settled')),
  version integer not null default 1 check (version > 0),
  confirmed_payment_cents bigint not null default 0 check (confirmed_payment_cents between 0 and 100000000000000),
  unallocated_credit_cents bigint generated always as (greatest(confirmed_payment_cents - amount_due_cents,0::bigint)) stored,
  settlement_consumed_cents bigint not null default 0 check (settlement_consumed_cents >= 0),
  redeemed_count integer not null default 0 check (redeemed_count >= 0),
  created_by_staff_reference text not null,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  check (lower(trim(finance_email)) <> lower(trim(supervisor_email))),
  check (settlement_consumed_cents <= amount_due_cents),
  check (redeemed_count <= voucher_count),
  check (status <> 'settled' or (settled_at is not null and confirmed_payment_cents >= amount_due_cents)),
  check (redeemed_count = 0 or status = 'settled')
);
create index paysme_voucher_batches_supplier_status_idx on public.paysme_voucher_payment_batches(supplier_id,status,created_at);

create table public.paysme_voucher_batch_items (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.paysme_voucher_payment_batches(id),
  voucher_id uuid not null unique references public.paysme_vouchers(id),
  sale_id uuid not null unique references public.paysme_voucher_sales(id),
  supplier_due_cents bigint not null check (supplier_due_cents between 0 and 100000000000),
  created_at timestamptz not null default now()
);
create index paysme_voucher_batch_items_batch_idx on public.paysme_voucher_batch_items(batch_id);

create table public.paysme_voucher_batch_payments (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.paysme_voucher_payment_batches(id),
  bank_transaction_reference text not null unique check (length(trim(bank_transaction_reference)) between 1 and 200),
  amount_cents bigint not null check (amount_cents between 1 and 100000000000000),
  proof_object_path text,
  recorded_by_staff_reference text not null,
  recorded_at timestamptz not null default now()
);
create index paysme_voucher_batch_payments_batch_idx on public.paysme_voucher_batch_payments(batch_id);

create table paysme_voucher_private.supplier_confirmations (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.paysme_voucher_payment_batches(id),
  batch_version integer not null,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  finance_email text not null,
  supervisor_email text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  otp_digest text check (otp_digest ~ '^[0-9a-f]{64}$'),
  otp_expires_at timestamptz,
  otp_attempts integer not null default 0 check (otp_attempts between 0 and 5),
  otp_send_count integer not null default 0 check (otp_send_count between 0 and 5),
  otp_last_sent_at timestamptz,
  consumed_at timestamptz,
  revoked_at timestamptz,
  check (expires_at > created_at),
  check (finance_email <> supervisor_email)
);
create index paysme_voucher_confirmations_batch_idx on paysme_voucher_private.supplier_confirmations(batch_id);

create table public.paysme_voucher_batch_discrepancies (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.paysme_voucher_payment_batches(id),
  confirmation_id uuid not null unique references paysme_voucher_private.supplier_confirmations(id),
  reason text not null check (reason in ('payment_not_received','incorrect_amount','reference_mismatch','other')),
  comment text not null check (length(comment) <= 2000),
  reported_by_email text not null,
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_staff_reference text,
  resolution_note text,
  check (status <> 'resolved' or (resolved_at is not null and length(trim(resolution_note)) > 0 and resolved_by_staff_reference is not null))
);
create index paysme_voucher_discrepancies_batch_idx on public.paysme_voucher_batch_discrepancies(batch_id,status);

create table paysme_voucher_private.voucher_recipients (
  voucher_id uuid primary key references public.paysme_vouchers(id),
  full_name text not null check (length(trim(full_name)) between 1 and 200),
  mobile_number text not null check (mobile_number ~ '^\+[1-9][0-9]{7,14}$'),
  email text not null check (email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  town text not null check (length(trim(town)) between 1 and 150),
  id_fingerprint text not null check (id_fingerprint ~ '^[0-9a-f]{64}$'),
  id_last4 text check (id_last4 ~ '^[0-9A-Za-z]{1,4}$'),
  id_failures integer not null default 0 check (id_failures between 0 and 5),
  id_locked_until timestamptz,
  created_at timestamptz not null default now()
);

create table paysme_voucher_private.redemption_sessions (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.paysme_vouchers(id),
  supplier_id uuid not null references public.paysme_voucher_suppliers(id),
  branch_id uuid not null references public.paysme_voucher_branches(id),
  method text not null check (method in ('physical_id','sms_email_otp')),
  status text not null check (status in ('pending','verified','failed','consumed')),
  sms_digest text check (sms_digest ~ '^[0-9a-f]{64}$'),
  email_digest text check (email_digest ~ '^[0-9a-f]{64}$'),
  attempts integer not null default 0 check (attempts between 0 and 5),
  pos_staff_reference text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  verified_at timestamptz,
  consumed_at timestamptz,
  check (expires_at > created_at),
  check (status not in ('verified','consumed') or verified_at is not null),
  check (method <> 'sms_email_otp' or (sms_digest is not null and email_digest is not null and sms_digest <> email_digest))
);
create index paysme_voucher_redemption_sessions_voucher_idx on paysme_voucher_private.redemption_sessions(voucher_id,created_at desc);

create table public.paysme_voucher_redemptions (
  id uuid primary key default gen_random_uuid(),
  receipt_no bigint generated always as identity unique,
  receipt_reference text generated always as ('PV-RECEIPT-'::text || receipt_no::text) stored unique,
  voucher_id uuid not null unique references public.paysme_vouchers(id),
  supplier_id uuid not null references public.paysme_voucher_suppliers(id),
  batch_id uuid not null references public.paysme_voucher_payment_batches(id),
  branch_id uuid not null references public.paysme_voucher_branches(id),
  verification_id uuid not null unique references paysme_voucher_private.redemption_sessions(id),
  request_key uuid not null,
  supplier_due_consumed_cents bigint not null check (supplier_due_consumed_cents between 0 and 100000000000),
  receipt_data jsonb not null check (jsonb_typeof(receipt_data) = 'object'),
  pos_staff_reference text not null,
  redeemed_at timestamptz not null default now(),
  unique (supplier_id,request_key)
);
create index paysme_voucher_redemptions_batch_idx on public.paysme_voucher_redemptions(batch_id);
create index paysme_voucher_redemptions_supplier_date_idx on public.paysme_voucher_redemptions(supplier_id,redeemed_at);
create index paysme_voucher_redemptions_branch_idx on public.paysme_voucher_redemptions(branch_id);

-- Financial tables are intentionally server-only until the existing staff auth
-- and supplier credentials are connected through authenticated Edge Functions.
do $$ declare tbl text; begin
  foreach tbl in array array['paysme_voucher_sales','paysme_vouchers','paysme_voucher_payment_batches','paysme_voucher_batch_items','paysme_voucher_batch_payments','paysme_voucher_batch_discrepancies','paysme_voucher_redemptions'] loop
    execute format('alter table public.%I enable row level security',tbl);
    execute format('revoke all on public.%I from public,anon,authenticated,service_role',tbl);
    execute format('grant select on public.%I to service_role',tbl);
    execute format('create trigger voucher_audit after insert or update on public.%I for each row execute function public.paysme_voucher_audit_change()',tbl);
  end loop;
end $$;
alter table paysme_voucher_private.supplier_confirmations enable row level security;
alter table paysme_voucher_private.voucher_recipients enable row level security;
alter table paysme_voucher_private.redemption_sessions enable row level security;
revoke all on all tables in schema paysme_voucher_private from public,anon,authenticated,service_role;
revoke all on all sequences in schema paysme_voucher_private from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
