-- Prepare orders only; no transfers, notifications, or voucher release.
create function paysme_voucher_private.prepare_daily_batches() returns integer
language plpgsql security definer set search_path='' as $$
declare sup public.paysme_voucher_suppliers%rowtype;
 cutoff timestamptz:=(date_trunc('day',now() at time zone 'Africa/Windhoek') at time zone 'Africa/Windhoek')-interval '1 microsecond';
 ids uuid[]; total bigint; qty integer; batch_id uuid; prepared integer:=0;
begin
 perform set_config('request.jwt.claim.sub','',true);
 for sup in select * from public.paysme_voucher_suppliers where active order by id for update loop
   select array_agg(x.id),sum(x.supplier_due_cents),count(*) into ids,total,qty from (
     select v.id,s.supplier_due_cents from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id
     where s.supplier_id=sup.id and s.status='paid' and s.paid_at<=cutoff and v.status='awaiting_settlement'
     and not exists(select 1 from public.paysme_voucher_batch_items i where i.voucher_id=v.id)
     order by v.id for update of v
   ) x;
   if qty>0 then
     insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference)
     values(sup.id,sup.business_name,sup.finance_email,sup.supervisor_email,cutoff,qty,total,'system:daily-batcher') returning id into batch_id;
     insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents)
     select batch_id,v.id,s.id,s.supplier_due_cents from public.paysme_vouchers v join public.paysme_voucher_sales s on s.id=v.sale_id where v.id=any(ids);
     prepared:=prepared+1;
   end if;
 end loop;
 return prepared;
end $$;
revoke all on function paysme_voucher_private.prepare_daily_batches() from public,anon,authenticated,service_role;
do $$ begin
 if coalesce(current_setting('cron.timezone',true),'GMT') not in ('GMT','UTC') then
  raise exception 'Review cron timezone before installing the Namibia daily schedule';
 end if;
end $$;
-- 22:05 UTC = 00:05 Africa/Windhoek. Includes all unbatched paid sales through the prior local day.
select cron.schedule('paysme-voucher-daily-batches','5 22 * * *','select paysme_voucher_private.prepare_daily_batches();');
