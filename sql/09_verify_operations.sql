-- Read-only deployment checks. No customer details or credentials returned.
select c.relname as table_name,c.relrowsecurity as rls_enabled,
 has_table_privilege('anon',c.oid,'SELECT') as anonymous_select,
 has_table_privilege('authenticated',c.oid,'INSERT') as browser_insert,
 has_table_privilege('authenticated',c.oid,'UPDATE') as browser_update
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('paysme_voucher_sales','paysme_vouchers','paysme_voucher_payment_batches','paysme_voucher_batch_items','paysme_voucher_batch_payments','paysme_voucher_batch_discrepancies','paysme_voucher_redemptions') order by c.relname;
-- Expect RLS true and every displayed privilege false. Staff SELECT uses RLS.

select has_function_privilege('anon','public.paysme_voucher_command(text,jsonb)','EXECUTE') as anonymous_rpc,
 has_function_privilege('authenticated','public.paysme_voucher_command(text,jsonb)','EXECUTE') as browser_rpc,
 has_function_privilege('service_role','public.paysme_voucher_command(text,jsonb)','EXECUTE') as backend_rpc;
-- false, false, true

select jobname,schedule,active from cron.job where jobname='paysme-voucher-daily-batches';
-- Active, 5 22 * * * UTC (00:05 Namibia).
select status,start_time,end_time from cron.job_run_details
where jobid=(select jobid from cron.job where jobname='paysme-voucher-daily-batches') order by start_time desc limit 10;

select count(*) as batch_invariant_violations from public.paysme_voucher_payment_batches b
where b.voucher_count<>(select count(*) from public.paysme_voucher_batch_items where batch_id=b.id)
 or b.amount_due_cents<>(select coalesce(sum(supplier_due_cents),0) from public.paysme_voucher_batch_items where batch_id=b.id)
 or b.settlement_consumed_cents>b.amount_due_cents or b.redeemed_count>b.voucher_count;
-- Expect 0.
