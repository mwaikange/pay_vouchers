do $repair$
declare definition text;
begin
 select pg_get_functiondef('public.paysme_voucher_command(text,jsonb)'::regprocedure) into definition;
 if position('sum(s.customer_price_cents)' in definition)=0 then raise exception 'Expected payment total expression not found'; end if;
 definition:=replace(definition,
 '(select coalesce(sum(s.customer_price_cents),0) from public.paysme_voucher_batch_items i join public.paysme_voucher_sales s on s.id=i.sale_id where i.batch_id=b.id)',
 '(select coalesce(sum(sale_totals.customer_price_cents),0) from public.paysme_voucher_batch_items total_items join public.paysme_voucher_sales sale_totals on sale_totals.id=total_items.sale_id where total_items.batch_id=b.id)');
 if position('sum(s.customer_price_cents)' in definition)>0 then raise exception 'Payment total repair incomplete'; end if;
 execute definition||';';
end $repair$;
