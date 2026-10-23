-- Reuse the existing PaySME staff directory and its own-row RLS.
-- No staff records, Auth accounts or existing application permissions are changed.
create or replace function public.paysme_voucher_access_context()
returns table(display_name text, role text, active boolean)
language sql stable security invoker set search_path = ''
as $$
  select coalesce(nullif(trim(concat_ws(' ', a.name, a.surname)), ''), a.email),
    case
      when a.role = 'super_admin' or a.permissions #> '{vouchers,manage_suppliers}' = 'true'::jsonb then 'admin'
      when a.permissions #> '{vouchers,write}' = 'true'::jsonb then 'operator'
      else 'viewer'
    end,
    true
  from public.admin_users a
  where a.auth_user_id = (select auth.uid())
    and a.is_active and a.setup_status = 'active'
    and (a.role = 'super_admin'
      or a.permissions #> '{vouchers,manage_suppliers}' = 'true'::jsonb
      or a.permissions #> '{vouchers,write}' = 'true'::jsonb
      or a.permissions #> '{vouchers,read}' = 'true'::jsonb);
$$;

create or replace function public.paysme_voucher_is_staff(can_write boolean default false)
returns boolean language sql stable security invoker set search_path = ''
as $$
  select exists(select 1 from public.paysme_voucher_access_context() s
    where not can_write or s.role in ('admin', 'operator'));
$$;

create or replace function public.paysme_voucher_is_admin()
returns boolean language sql stable security invoker set search_path = ''
as $$
  select exists(select 1 from public.paysme_voucher_access_context() s where s.role = 'admin');
$$;

revoke all on function public.paysme_voucher_access_context() from public, anon;
revoke all on function public.paysme_voucher_is_staff(boolean) from public, anon;
revoke all on function public.paysme_voucher_is_admin() from public, anon;
grant execute on function public.paysme_voucher_access_context() to authenticated;
grant execute on function public.paysme_voucher_is_staff(boolean) to authenticated;
grant execute on function public.paysme_voucher_is_admin() to authenticated;

comment on function public.paysme_voucher_access_context() is
  'Voucher access from active existing admin_users. Super admins have full access; other staff require explicit permissions.vouchers booleans. Uses existing staff RLS.';
-- The legacy paysme_voucher_staff table is retained but no longer authorizes access.
