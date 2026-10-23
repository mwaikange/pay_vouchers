-- Read-only verification after the foundation and script 05. Does not expose customer data.
select c.relname as table_name, c.relrowsecurity as rls_enabled,
  has_table_privilege('anon', c.oid, 'SELECT') as anonymous_can_select,
  has_table_privilege('authenticated', c.oid, 'INSERT') as authenticated_has_insert_grant,
  (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as policy_count
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in (
  'paysme_voucher_staff', 'paysme_voucher_suppliers', 'paysme_voucher_branches',
  'paysme_voucher_products', 'paysme_voucher_product_images', 'paysme_customers', 'paysme_voucher_audit_events'
) order by c.relname;
-- Expect seven rows: RLS enabled true, anonymous_can_select false.
-- INSERT grants are further restricted by the role/active membership policies.

select count(*) as active_super_administrators
from public.admin_users
where is_active and setup_status = 'active' and role = 'super_admin' and auth_user_id is not null;
-- Expect at least one existing staff super administrator.

select id, public as public_catalogue_images, file_size_limit, allowed_mime_types
from storage.buckets where id = 'paysme-voucher-products';
-- Expect one catalogue-image bucket, 5 MiB, JPEG/PNG/WebP only.

select policyname, cmd from pg_policies
where schemaname = 'storage' and policyname in ('voucher_image_insert', 'voucher_image_read');
-- Expect INSERT and SELECT policies. No anonymous customer access is granted.
