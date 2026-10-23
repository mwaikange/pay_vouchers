-- Deprecated: do not create separate voucher staff memberships.
-- Apply 05_use_existing_staff.sql after the existing foundation.
-- Staff sign in with their existing PaySME Auth credentials.
select role, is_active, setup_status, count(*) as accounts
from public.admin_users group by role, is_active, setup_status;
