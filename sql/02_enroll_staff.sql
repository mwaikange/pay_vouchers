-- Run AFTER 01_create_voucher_foundation.sql, as the Supabase SQL Editor administrator.
-- Replace ONLY the email and display name below with the staff account you want to use.
-- This enrolls an existing Auth account; it never creates or changes a password.
begin;
do $$
declare
  staff_email text := 'REPLACE_WITH_YOUR_STAFF_EMAIL';
  staff_name text := 'PaySME Administrator';
  staff_user_id uuid;
begin
  if staff_email = 'REPLACE_WITH_YOUR_STAFF_EMAIL' or position('@' in staff_email) = 0 then
    raise exception 'Replace staff_email in this script with your existing Supabase Auth email.';
  end if;
  select id into staff_user_id from auth.users
  where lower(email) = lower(trim(staff_email));
  if staff_user_id is null then
    raise exception 'No active Auth account found for %. Create or invite that user under Authentication > Users first, then rerun this script.', staff_email;
  end if;
  insert into public.paysme_voucher_staff(user_id, display_name, role, active)
  values (staff_user_id, staff_name, 'admin', true)
  on conflict (user_id) do update set display_name = excluded.display_name, role = 'admin', active = true;
end $$;
commit;
select display_name, role, active from public.paysme_voucher_staff order by created_at;
