-- Public catalogue imagery uses the existing bucket and its staff upload policies.
alter table public.paysme_voucher_suppliers add column logo_path text;
alter table public.paysme_voucher_suppliers add constraint voucher_supplier_logo_path
 check (logo_path is null or logo_path ~ '^suppliers/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$');
