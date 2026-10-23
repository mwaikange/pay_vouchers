-- Additive, read-only portal queries. Existing sale/wallet integration is unchanged.
create function public.paysme_voucher_companies() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'business_name',s.business_name,'active',s.active) order by s.business_name,s.id),'[]'::jsonb) from public.paysme_voucher_suppliers s);
end $$;

create function public.paysme_voucher_customer_directory(p_search text default '',p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; page_size integer:=least(greatest(coalesce(p_limit,50),1),100); page_offset integer:=greatest(coalesce(p_offset,0),0); search_text text:=left(trim(coalesce(p_search,'')),200);
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 with customers as (
  select c.id,c.customer_no,c.full_name,c.town,right(c.mobile_number,4) as mobile_last4,
   count(s.id) as purchase_count,count(s.id) filter(where s.status='paid') as paid_purchase_count,
   coalesce(sum(s.customer_price_cents) filter(where s.status='paid'),0) as paid_value_cents,max(s.paid_at) as last_purchase_at
  from public.paysme_customers c join public.paysme_voucher_sales s on s.customer_id=c.id
  where search_text='' or strpos(lower(coalesce(c.full_name,'')),lower(search_text))>0
   or strpos(c.mobile_number,search_text)>0 or strpos('CUS-'||c.customer_no::text,upper(search_text))>0
  group by c.id,c.customer_no,c.full_name,c.town,c.mobile_number
 ), page as (select * from customers order by last_purchase_at desc,id limit page_size offset page_offset)
 select jsonb_build_object('customers',(select coalesce(jsonb_agg(to_jsonb(p) order by p.last_purchase_at desc,p.id),'[]'::jsonb) from page p),
  'total_count',(select count(*) from customers),'offset',page_offset,'limit',page_size,'search',search_text) into result;
 return result;
end $$;

create function public.paysme_voucher_customer_record(p_customer_id uuid,p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare profile jsonb; summary jsonb; purchases jsonb; page_size integer:=least(greatest(coalesce(p_limit,50),1),100); page_offset integer:=greatest(coalesce(p_offset,0),0);
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 select jsonb_build_object('id',c.id,'customer_no',c.customer_no,'full_name',c.full_name,'mobile_number',c.mobile_number,'email',c.email,'town',c.town,'created_at',c.created_at)
 into profile from public.paysme_customers c where c.id=p_customer_id and exists(select 1 from public.paysme_voucher_sales s where s.customer_id=c.id);
 if profile is null then return null; end if;
 select jsonb_build_object('purchase_count',count(*),'paid_purchase_count',count(*) filter(where s.status='paid'),
  'paid_value_cents',coalesce(sum(s.customer_price_cents) filter(where s.status='paid'),0),'last_purchase_at',max(s.paid_at),
  'redeemed_count',count(*) filter(where v.status='redeemed')) into summary
 from public.paysme_voucher_sales s left join public.paysme_vouchers v on v.sale_id=s.id where s.customer_id=p_customer_id;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc,x.sale_id),'[]'::jsonb) into purchases from (
  select s.id as sale_id,s.sale_no,s.product_id,p.product_no,s.product_name,s.product_contents,s.status as sale_status,s.customer_price_cents,s.paid_at,s.recipient_town,
   s.supplier_id,sup.business_name as supplier_name,br.name as branch_name,v.code as voucher_code,v.status as voucher_status,
   b.batch_reference,b.status as batch_status,r.receipt_reference
  from public.paysme_voucher_sales s
  join public.paysme_voucher_suppliers sup on sup.id=s.supplier_id
  left join public.paysme_voucher_products p on p.id=s.product_id
  left join public.paysme_voucher_branches br on br.id=s.planned_branch_id
  left join public.paysme_vouchers v on v.sale_id=s.id
  left join public.paysme_voucher_batch_items i on i.sale_id=s.id
  left join public.paysme_voucher_payment_batches b on b.id=i.batch_id
  left join public.paysme_voucher_redemptions r on r.voucher_id=v.id
  where s.customer_id=p_customer_id order by s.paid_at desc,s.id limit page_size offset page_offset
 ) x;
 return jsonb_build_object('profile',profile,'summary',summary,'purchases',purchases,'offset',page_offset,'limit',page_size);
end $$;

create function public.paysme_voucher_company_overview(p_supplier_id uuid default null) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not public.paysme_voucher_is_staff() then raise exception 'Staff access required' using errcode='42501'; end if;
 return jsonb_build_object('supplier_id',p_supplier_id,
 'paid_sales',(select count(*) from public.paysme_voucher_sales s where s.status='paid' and (p_supplier_id is null or s.supplier_id=p_supplier_id)),
 'customer_paid_cents',(select coalesce(sum(s.customer_price_cents),0) from public.paysme_voucher_sales s where s.status='paid' and (p_supplier_id is null or s.supplier_id=p_supplier_id)),
 'batch_count',(select count(*) from public.paysme_voucher_payment_batches b where p_supplier_id is null or b.supplier_id=p_supplier_id),
 'pending_settlement_cents',(select coalesce(sum(b.amount_due_cents),0) from public.paysme_voucher_payment_batches b where b.status<>'settled' and (p_supplier_id is null or b.supplier_id=p_supplier_id)),
 'settlement_consumed_cents',(select coalesce(sum(b.settlement_consumed_cents),0) from public.paysme_voucher_payment_batches b where p_supplier_id is null or b.supplier_id=p_supplier_id),
 'redemption_count',(select count(*) from public.paysme_voucher_redemptions r where p_supplier_id is null or r.supplier_id=p_supplier_id),
 'planning',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
  select s.supplier_id,sup.business_name as supplier_name,s.product_id,s.product_name,s.recipient_town,coalesce(br.name,'Not selected') as branch_name,count(*) as voucher_count
  from public.paysme_voucher_sales s join public.paysme_vouchers v on v.sale_id=s.id
  join public.paysme_voucher_suppliers sup on sup.id=s.supplier_id left join public.paysme_voucher_branches br on br.id=s.planned_branch_id
  where s.status='paid' and v.status in ('awaiting_settlement','redeemable') and (p_supplier_id is null or s.supplier_id=p_supplier_id)
  group by s.supplier_id,sup.business_name,s.product_id,s.product_name,s.recipient_town,br.name
  order by sup.business_name,s.recipient_town,s.product_name,s.product_id
 ) x));
end $$;

revoke all on function public.paysme_voucher_companies() from public,anon;
revoke all on function public.paysme_voucher_customer_directory(text,integer,integer) from public,anon;
revoke all on function public.paysme_voucher_customer_record(uuid,integer,integer) from public,anon;
revoke all on function public.paysme_voucher_company_overview(uuid) from public,anon;
grant execute on function public.paysme_voucher_companies() to authenticated;
grant execute on function public.paysme_voucher_customer_directory(text,integer,integer) to authenticated;
grant execute on function public.paysme_voucher_customer_record(uuid,integer,integer) to authenticated;
grant execute on function public.paysme_voucher_company_overview(uuid) to authenticated;
notify pgrst,'reload schema';
