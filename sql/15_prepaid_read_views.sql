-- Read-only staff drill-down. "Account" always means PaySME funds held with the named supplier.
create function public.paysme_voucher_batch_record(p_batch_id uuid,p_limit integer default 100,p_offset integer default 0) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare _b public.paysme_voucher_payment_batches%rowtype; _limit integer:=least(greatest(p_limit,1),100); _offset integer:=greatest(p_offset,0);
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 select * into _b from public.paysme_voucher_payment_batches b where b.id=p_batch_id;
 if not found then return null; end if;
 return jsonb_build_object('batch',to_jsonb(_b),'limit',_limit,'offset',_offset,'total_count',_b.voucher_count,
  'account',(select to_jsonb(a) from public.paysme_voucher_credit_accounts a where a.supplier_id=_b.supplier_id),
  'payments',(select coalesce(jsonb_agg(to_jsonb(p) order by p.recorded_at,p.id),'[]'::jsonb) from public.paysme_voucher_batch_payments p where p.batch_id=_b.id),
  'discrepancies',(select coalesce(jsonb_agg(x.data),'[]'::jsonb) from (
   select to_jsonb(d) as data from public.paysme_voucher_batch_discrepancies d where d.batch_id=_b.id
   union all select to_jsonb(d) as data from public.paysme_voucher_credit_discrepancies d where d.batch_id=_b.id) x),
  'reservations',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at,r.id),'[]'::jsonb) from public.paysme_voucher_credit_reservations r where r.batch_id=_b.id),
  'items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
   select v.id as voucher_id,v.code as voucher_code,v.status as voucher_status,s.id as sale_id,s.sale_no,s.customer_id,
    s.product_name,s.product_contents,s.customer_price_cents,i.supplier_due_cents,s.recipient_town,br.name as planned_branch,
    r.receipt_reference,r.redeemed_at,actual.name as redeemed_branch
   from public.paysme_voucher_batch_items i join public.paysme_vouchers v on v.id=i.voucher_id join public.paysme_voucher_sales s on s.id=i.sale_id
   left join public.paysme_voucher_branches br on br.id=s.planned_branch_id left join public.paysme_voucher_redemptions r on r.voucher_id=v.id
   left join public.paysme_voucher_branches actual on actual.id=r.branch_id
   where i.batch_id=_b.id order by i.created_at,i.id limit _limit offset _offset) x));
end $$;
revoke all on function public.paysme_voucher_batch_record(uuid,integer,integer) from public,anon;
grant execute on function public.paysme_voucher_batch_record(uuid,integer,integer) to authenticated;
notify pgrst,'reload schema';
