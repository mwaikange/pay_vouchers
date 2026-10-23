-- Phase 1 only. Review against the linked PaySME database before application.
-- No historical backfill, wallet changes, sales, settlement or redemption in this migration.
begin;

-- Refuse to overwrite an earlier or incompatible voucher installation.
do $$
declare tbl text;
begin
  if to_regclass('auth.users') is null or to_regclass('storage.objects') is null then
    raise exception 'Run this script in the intended Supabase project, not a plain Postgres database.';
  end if;
  foreach tbl in array array['paysme_voucher_staff', 'paysme_voucher_suppliers', 'paysme_voucher_branches', 'paysme_voucher_products', 'paysme_voucher_product_images', 'paysme_customers', 'paysme_voucher_audit_events'] loop
    if to_regclass('public.' || tbl) is not null then
      raise exception 'Table public.% already exists. Stop and review the existing setup; do not overwrite it.', tbl;
    end if;
  end loop;
  if exists (select 1 from storage.buckets where id = 'paysme-voucher-products') then
    raise exception 'Voucher catalogue bucket already exists. Review the existing setup first.';
  end if;
end $$;

create table public.paysme_voucher_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) > 0),
  role text not null default 'operator' check (role in ('admin', 'operator', 'viewer')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.paysme_voucher_staff enable row level security;

create function public.paysme_voucher_is_staff(can_write boolean default false)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.paysme_voucher_staff s
    where s.user_id = (select auth.uid()) and s.active
    and (not can_write or s.role in ('admin', 'operator')));
$$;
revoke all on function public.paysme_voucher_is_staff(boolean) from public, anon;
grant execute on function public.paysme_voucher_is_staff(boolean) to authenticated;
create policy staff_own_membership on public.paysme_voucher_staff for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.paysme_voucher_staff from public, anon, authenticated;
grant select on public.paysme_voucher_staff to authenticated;

create function public.paysme_voucher_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.paysme_voucher_staff s
    where s.user_id = (select auth.uid()) and s.active and s.role = 'admin');
$$;
revoke all on function public.paysme_voucher_is_admin() from public, anon;
grant execute on function public.paysme_voucher_is_admin() to authenticated;

create table public.paysme_voucher_suppliers (
  id uuid primary key default gen_random_uuid(),
  supplier_no bigint generated always as identity unique,
  business_name text not null check (length(trim(business_name)) > 0),
  registration_number text,
  finance_contact_name text not null check (length(trim(finance_contact_name)) > 0),
  finance_email text not null,
  supervisor_name text not null check (length(trim(supervisor_name)) > 0),
  supervisor_email text not null,
  support_email text,
  settlement_terms text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (finance_email = lower(trim(finance_email)) and finance_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  check (supervisor_email = lower(trim(supervisor_email)) and supervisor_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  check (finance_email <> supervisor_email)
);
create table public.paysme_voucher_branches (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.paysme_voucher_suppliers(id),
  name text not null check (length(trim(name)) > 0),
  town text not null check (length(trim(town)) > 0),
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (supplier_id, name, town)
);
create index paysme_voucher_branches_supplier_idx on public.paysme_voucher_branches(supplier_id);
create table public.paysme_voucher_products (
  id uuid primary key default gen_random_uuid(),
  product_no bigint generated always as identity unique,
  supplier_id uuid not null references public.paysme_voucher_suppliers(id),
  name text not null check (length(trim(name)) > 0),
  description text not null default '',
  product_list text not null default '',
  entitlement_type text not null default 'product_bundle' check (entitlement_type in ('product_bundle', 'store_credit')),
  redemption_value_cents bigint check (redemption_value_cents between 1 and 100000000000),
  supplier_price_cents bigint not null check (supplier_price_cents between 1 and 100000000000),
  markup_cents bigint not null default 0 check (markup_cents between 0 and 100000000000),
  customer_price_cents bigint generated always as (supplier_price_cents + markup_cents) stored,
  instore_price_cents bigint not null check (instore_price_cents between 0 and 100000000000),
  rebate_cents bigint not null default 0 check (rebate_cents between 0 and supplier_price_cents),
  rebate_timing text not null default 'later' check (rebate_timing in ('immediate', 'later')),
  settlement_price_cents bigint generated always as (supplier_price_cents - case when rebate_timing = 'immediate' then rebate_cents else 0 end) stored,
  vendor_commission_cents bigint not null default 0 check (vendor_commission_cents between 0 and 100000000000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (entitlement_type <> 'store_credit' or redemption_value_cents is not null)
);
create index paysme_voucher_products_supplier_idx on public.paysme_voucher_products(supplier_id);
create table public.paysme_voucher_product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.paysme_voucher_products(id),
  object_path text not null unique,
  alt_text text not null default '',
  created_at timestamptz not null default now()
);
create index paysme_voucher_product_images_product_idx on public.paysme_voucher_product_images(product_id);

-- Provisional contact profiles, not proof of legal identity. No raw ID number in this table.
-- Sensitive voucher identity data is introduced separately with restricted server-only access.
create table public.paysme_customers (
  id uuid primary key default gen_random_uuid(),
  customer_no bigint generated always as identity unique,
  mobile_number text not null unique check (mobile_number ~ '^\+[1-9][0-9]{7,14}$'),
  full_name text,
  email text,
  town text,
  mobile_verified_at timestamptz,
  email_verified_at timestamptz,
  marketing_sms_opt_in boolean not null default false,
  marketing_email_opt_in boolean not null default false,
  marketing_preferences_recorded_at timestamptz,
  source text not null default 'vendor_purchase' check (source in ('vendor_purchase', 'legacy_utility_import', 'staff')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((not marketing_sms_opt_in and not marketing_email_opt_in) or marketing_preferences_recorded_at is not null)
);

-- Utilities transaction linkage and backfill are intentionally deferred to the
-- separate, final Vendor app integration phase. Existing tables are untouched.

create table public.paysme_voucher_audit_events (
  id bigint generated always as identity primary key,
  actor_user_id uuid,
  table_name text not null,
  record_id uuid not null,
  action text not null,
  changed_fields text[] not null default '{}',
  created_at timestamptz not null default now()
);

create function public.paysme_voucher_stamp_update()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end;
$$;
create function public.paysme_voucher_audit_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare fields text[]; record_uuid uuid;
begin
  if tg_op = 'UPDATE' then
    select array_agg(n.key) into fields from jsonb_each(to_jsonb(new)) n
    where n.value is distinct from to_jsonb(old) -> n.key and n.key <> 'updated_at';
  else
    select array_agg(field_name) into fields from jsonb_object_keys(to_jsonb(new)) as keys(field_name);
  end if;
  record_uuid := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'user_id')::uuid;
  insert into public.paysme_voucher_audit_events(actor_user_id, table_name, record_id, action, changed_fields)
  values (auth.uid(), tg_table_name, record_uuid, tg_op, coalesce(fields, '{}'));
  return new;
end;
$$;
revoke all on function public.paysme_voucher_stamp_update() from public, anon, authenticated;
revoke all on function public.paysme_voucher_audit_change() from public, anon, authenticated;

do $$ declare tbl text; begin
  foreach tbl in array array['paysme_voucher_suppliers', 'paysme_voucher_branches', 'paysme_voucher_products', 'paysme_voucher_product_images'] loop
    execute format('alter table public.%I enable row level security', tbl);
    execute format('revoke all on public.%I from public, anon, authenticated', tbl);
    execute format('grant select, insert, update on public.%I to authenticated', tbl);
    execute format('create policy staff_read on public.%I for select to authenticated using (public.paysme_voucher_is_staff())', tbl);
    execute format('create policy staff_insert on public.%I for insert to authenticated with check (public.paysme_voucher_is_staff(true))', tbl);
    execute format('create policy staff_update on public.%I for update to authenticated using (public.paysme_voucher_is_staff(true)) with check (public.paysme_voucher_is_staff(true))', tbl);
    execute format('create trigger voucher_audit after insert or update on public.%I for each row execute function public.paysme_voucher_audit_change()', tbl);
    if tbl <> 'paysme_voucher_product_images' then
      execute format('create trigger voucher_stamp before update on public.%I for each row execute function public.paysme_voucher_stamp_update()', tbl);
    end if;
  end loop;
end $$;

-- Approval contacts and settlement terms are administrative settings.
-- Operators can maintain the catalogue but cannot substitute finance approvers.
drop policy staff_insert on public.paysme_voucher_suppliers;
drop policy staff_update on public.paysme_voucher_suppliers;
create policy admin_insert on public.paysme_voucher_suppliers for insert to authenticated
with check (public.paysme_voucher_is_admin());
create policy admin_update on public.paysme_voucher_suppliers for update to authenticated
using (public.paysme_voucher_is_admin()) with check (public.paysme_voucher_is_admin());
create trigger voucher_audit after insert or update on public.paysme_voucher_staff
for each row execute function public.paysme_voucher_audit_change();

alter table public.paysme_customers enable row level security;
revoke all on public.paysme_customers from public, anon, authenticated;
grant select on public.paysme_customers to authenticated;
create policy staff_read on public.paysme_customers for select to authenticated using (public.paysme_voucher_is_staff());
create trigger voucher_stamp before update on public.paysme_customers for each row execute function public.paysme_voucher_stamp_update();
create trigger voucher_audit after insert or update on public.paysme_customers for each row execute function public.paysme_voucher_audit_change();

alter table public.paysme_voucher_audit_events enable row level security;
revoke all on public.paysme_voucher_audit_events from public, anon, authenticated;
grant select on public.paysme_voucher_audit_events to authenticated;
create policy staff_read on public.paysme_voucher_audit_events for select to authenticated using (public.paysme_voucher_is_staff());

grant usage, select on sequence public.paysme_voucher_suppliers_supplier_no_seq, public.paysme_voucher_products_product_no_seq to authenticated;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('paysme-voucher-products', 'paysme-voucher-products', true, 5242880, array['image/jpeg','image/png','image/webp']);
create policy voucher_image_insert on storage.objects for insert to authenticated
with check (bucket_id = 'paysme-voucher-products' and public.paysme_voucher_is_staff(true));
create policy voucher_image_read on storage.objects for select to authenticated
using (bucket_id = 'paysme-voucher-products' and public.paysme_voucher_is_staff());
-- Images are immutable uploads with random paths; no overwrite or delete policy.

-- Explicit trusted-backend privileges; never expose the service-role key in a browser.
grant all on public.paysme_voucher_staff, public.paysme_voucher_suppliers,
  public.paysme_voucher_branches, public.paysme_voucher_products,
  public.paysme_voucher_product_images, public.paysme_customers,
  public.paysme_voucher_audit_events to service_role;
grant usage, select on sequence public.paysme_voucher_suppliers_supplier_no_seq,
  public.paysme_voucher_products_product_no_seq, public.paysme_customers_customer_no_seq,
  public.paysme_voucher_audit_events_id_seq to service_role;
notify pgrst, 'reload schema';

commit;
