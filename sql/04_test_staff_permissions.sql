-- Optional real RLS smoke test, AFTER staff enrollment.
-- Run the complete script in one SQL Editor execution, as postgres.
-- All sample rows and temporary role/active changes are ROLLED BACK.
begin;
do $$
declare staff_id uuid;
begin
  select user_id into staff_id from public.paysme_voucher_staff
  where active and role = 'admin' order by created_at limit 1;
  if staff_id is null then raise exception 'Enroll an administrator with script 02 first.'; end if;
  perform set_config('paysme_test.admin_id', staff_id::text, true);
end $$;

-- An anonymous caller cannot read the staff portal tables.
set local role anon;
do $$
declare blocked boolean := false;
begin
  begin perform count(*) from public.paysme_voucher_suppliers;
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'FAIL: anonymous supplier access was not blocked'; end if;
end $$;
reset role;

-- A signed-in user without voucher membership sees no catalogue and cannot write.
select set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
set local role authenticated;
do $$
declare blocked boolean := false;
begin
  if public.paysme_voucher_is_staff() then raise exception 'FAIL: non-staff recognized as staff'; end if;
  if exists(select 1 from public.paysme_voucher_suppliers) then raise exception 'FAIL: non-staff can read suppliers'; end if;
  begin
    insert into public.paysme_voucher_branches(supplier_id, name, town)
    values(gen_random_uuid(), 'Blocked branch', 'Test town');
  exception when insufficient_privilege then blocked := true; end;
  if not blocked then raise exception 'FAIL: non-staff write was not blocked'; end if;
end $$;
reset role;

-- An enrolled administrator can create suppliers and products.
select set_config('request.jwt.claim.sub', current_setting('paysme_test.admin_id'), true);
set local role authenticated;
do $$
declare supplier_id uuid; product_id uuid; actual_price bigint;
begin
  if not public.paysme_voucher_is_admin() then raise exception 'FAIL: enrolled administrator not recognized'; end if;
  insert into public.paysme_voucher_suppliers(business_name, finance_contact_name, finance_email, supervisor_name, supervisor_email)
  values('ROLLBACK ONLY - voucher permission test', 'Finance', 'finance@example.invalid', 'Supervisor', 'supervisor@example.invalid') returning id into supplier_id;
  perform set_config('paysme_test.supplier_id', supplier_id::text, true);
  insert into public.paysme_voucher_products(supplier_id, name, supplier_price_cents, markup_cents, instore_price_cents)
  values(supplier_id, 'ROLLBACK ONLY - combo', 50000, 2000, 60000) returning id, customer_price_cents into product_id, actual_price;
  if actual_price <> 52000 then raise exception 'FAIL: customer price should be 52000 cents'; end if;
  perform set_config('paysme_test.product_id', product_id::text, true);
end $$;
reset role;

-- Operators can maintain products but cannot replace supplier approvers.
update public.paysme_voucher_staff set role = 'operator' where user_id = current_setting('paysme_test.admin_id')::uuid;
set local role authenticated;
do $$
declare affected integer;
begin
  update public.paysme_voucher_products set description = 'Operator catalogue edit'
  where id = current_setting('paysme_test.product_id')::uuid;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'FAIL: operator catalogue edit failed'; end if;
  update public.paysme_voucher_suppliers set supervisor_email = 'substitute@example.invalid'
  where id = current_setting('paysme_test.supplier_id')::uuid;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: operator can replace supplier approval contacts'; end if;
end $$;
reset role;

-- Viewers can read but cannot modify product data.
update public.paysme_voucher_staff set role = 'viewer' where user_id = current_setting('paysme_test.admin_id')::uuid;
set local role authenticated;
do $$
declare affected integer;
begin
  if not exists(select 1 from public.paysme_voucher_products where id = current_setting('paysme_test.product_id')::uuid) then
    raise exception 'FAIL: viewer cannot read the test product';
  end if;
  update public.paysme_voucher_products set description = 'Blocked viewer edit'
  where id = current_setting('paysme_test.product_id')::uuid;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: viewer product write was not blocked'; end if;
end $$;
reset role;

-- Disabling membership takes effect even if the Auth session remains valid.
update public.paysme_voucher_staff set active = false where user_id = current_setting('paysme_test.admin_id')::uuid;
set local role authenticated;
do $$
begin
  if public.paysme_voucher_is_staff() or exists(select 1 from public.paysme_voucher_products) then
    raise exception 'FAIL: inactive staff can still access catalogue data';
  end if;
end $$;
reset role;
rollback;
select 'PASS: anonymous, non-staff, admin, operator, viewer and disabled-staff checks completed. Test changes rolled back.' as result;
