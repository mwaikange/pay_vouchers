-- Rollback-only integration test using existing staff, without changing memberships.
begin;
do $$
declare staff_id uuid; blocked_id uuid;
begin
 select auth_user_id into staff_id from public.admin_users
 where is_active and setup_status='active' and role='super_admin' and auth_user_id is not null limit 1;
 if staff_id is null then raise exception 'No active existing super administrator'; end if;
 perform set_config('voucher_test.admin',staff_id::text,true);
 select auth_user_id into blocked_id from public.admin_users
 where role<>'super_admin' and auth_user_id is not null
 and not coalesce(permissions #> '{vouchers,read}'='true'::jsonb,false)
 and not coalesce(permissions #> '{vouchers,write}'='true'::jsonb,false)
 and not coalesce(permissions #> '{vouchers,manage_suppliers}'='true'::jsonb,false) limit 1;
 perform set_config('voucher_test.blocked',coalesce(blocked_id,gen_random_uuid())::text,true);
end $$;
set local role anon;
do $$ begin
 if has_function_privilege(current_user,'public.paysme_voucher_access_context()','EXECUTE') then
 raise exception 'FAIL anonymous access RPC'; end if;
 if has_table_privilege(current_user,'public.paysme_voucher_suppliers','SELECT') then
 raise exception 'FAIL anonymous suppliers'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',current_setting('voucher_test.admin'),true);
set local role authenticated;
do $$
declare test_id uuid;
begin
 if not public.paysme_voucher_is_admin() or not public.paysme_voucher_is_staff(true) then
 raise exception 'FAIL existing super administrator denied'; end if;
 if (select count(*) from public.paysme_voucher_access_context())<>1 then
 raise exception 'FAIL access context'; end if;
 insert into public.paysme_voucher_suppliers
 (business_name,finance_contact_name,finance_email,supervisor_name,supervisor_email)
 values ('Rollback permission test','Test finance','finance@example.invalid','Test supervisor','supervisor@example.invalid')
 returning id into test_id;
 perform set_config('voucher_test.supplier',test_id::text,true);
 if not exists(select 1 from public.paysme_voucher_suppliers where id=test_id) then
 raise exception 'FAIL super administrator cannot read inserted supplier'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',current_setting('voucher_test.blocked'),true);
set local role authenticated;
do $$
declare blocked boolean:=false;
begin
 if public.paysme_voucher_is_staff() or public.paysme_voucher_is_admin() then
 raise exception 'FAIL unrelated staff gained voucher access'; end if;
 if exists(select 1 from public.paysme_voucher_suppliers where id=current_setting('voucher_test.supplier')::uuid) then
 raise exception 'FAIL supplier RLS'; end if;
 begin
 insert into public.paysme_voucher_suppliers
 (business_name,finance_contact_name,finance_email,supervisor_name,supervisor_email)
 values ('Blocked test','Test','finance@example.invalid','Test','supervisor@example.invalid');
 exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'FAIL unauthorized supplier write'; end if;
end $$;
reset role;
rollback;
select 'PASS: existing super administrator allowed; unrelated staff and anonymous users blocked; test data rolled back' as result;
