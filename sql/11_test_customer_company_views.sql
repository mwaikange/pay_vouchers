-- Staff-only read/query test. Every fixture is rolled back; no messages or payments.
begin;
do $$
declare actor uuid; tag text:='portal-view-'||gen_random_uuid()::text;
 suppliers uuid[]:='{}'; branches uuid[]:='{}'; products uuid[]:='{}'; customers uuid[]:='{}'; batches uuid[]:='{}';
 i integer; company_index integer; customer_index integer; new_id uuid; sale_id uuid; voucher_id uuid; verification_id uuid; voucher_code text;
begin
 select auth_user_id into actor from public.admin_users where is_active and setup_status='active' and role='super_admin' and auth_user_id is not null limit 1;
 if actor is null then raise exception 'Existing super administrator required'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform set_config('voucher_view_test.baseline',public.paysme_voucher_company_overview()::text,true);
 for i in 1..2 loop
  insert into public.paysme_voucher_suppliers(business_name,finance_contact_name,finance_email,supervisor_name,supervisor_email)
  values(tag||'-supplier-'||i,'Finance','finance@example.invalid','Supervisor','supervisor@example.invalid') returning id into new_id;
  suppliers:=array_append(suppliers,new_id);
  insert into public.paysme_voucher_branches(supplier_id,name,town) values(new_id,'Test store',case when i=1 then 'Keetmanshoop' else 'Windhoek' end) returning id into new_id;
  branches:=array_append(branches,new_id);
  insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents)
  values(suppliers[i],tag||'-product-'||i,50000,2000,60000) returning id into new_id;
  products:=array_append(products,new_id);
  insert into public.paysme_voucher_payment_batches(supplier_id,supplier_name,finance_email,supervisor_email,cutoff_at,voucher_count,amount_due_cents,created_by_staff_reference,status,confirmed_payment_cents,settlement_consumed_cents,redeemed_count,settled_at)
  values(suppliers[i],tag||'-supplier-'||i,'finance@example.invalid','supervisor@example.invalid',now(),case when i=1 then 2 else 1 end,case when i=1 then 100000 else 50000 end,'rollback-view-test',case when i=1 then 'settled' else 'prepared' end,case when i=1 then 100000 else 0 end,case when i=1 then 100000 else 0 end,case when i=1 then 2 else 0 end,case when i=1 then now() else null end) returning id into new_id;
  batches:=array_append(batches,new_id);
 end loop;
 for i in 1..3 loop
  insert into public.paysme_customers(mobile_number,full_name,email,town,source)
  values('+999'||lpad(floor(random()*10000000000)::bigint::text,10,'0'),tag||'-customer-'||i,'recipient@example.invalid','Windhoek',case when i=3 then 'legacy_utility_import' else 'vendor_purchase' end) returning id into new_id;
  customers:=array_append(customers,new_id);
 end loop;
 for i in 1..3 loop
  company_index:=case when i=2 then 2 else 1 end;customer_index:=case when i=3 then 2 else 1 end;
  insert into public.paysme_voucher_sales(request_key,payment_reference,vendor_reference,customer_id,product_id,supplier_id,planned_branch_id,product_name,product_contents,product_description,entitlement_type,supplier_base_cents,markup_cents,instore_price_cents,rebate_cents,rebate_timing,vendor_commission_cents,recipient_town)
  values(gen_random_uuid(),tag||'-sale-'||i,'rollback-test',customers[customer_index],products[company_index],suppliers[company_index],branches[company_index],tag||'-product-'||company_index,'Test combo','Test description','product_bundle',50000,2000,60000,0,'later',0,'Windhoek') returning id into sale_id;
  voucher_code:='PAD-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'))||'-'||upper(encode(extensions.gen_random_bytes(4),'hex'));
  insert into public.paysme_vouchers(sale_id,code,status,redeemable_at,redeemed_at)
  values(sale_id,voucher_code,case when company_index=1 then 'redeemed' else 'awaiting_settlement' end,case when company_index=1 then now() else null end,case when company_index=1 then now() else null end) returning id into voucher_id;
  insert into public.paysme_voucher_batch_items(batch_id,voucher_id,sale_id,supplier_due_cents) values(batches[company_index],voucher_id,sale_id,50000);
  if company_index=1 then
   insert into paysme_voucher_private.redemption_sessions(voucher_id,supplier_id,branch_id,method,status,pos_staff_reference,expires_at,verified_at,consumed_at)
   values(voucher_id,suppliers[1],branches[1],'physical_id','consumed','rollback-test',now()+interval '5 minutes',now(),now()) returning id into verification_id;
   insert into public.paysme_voucher_redemptions(voucher_id,supplier_id,batch_id,branch_id,verification_id,request_key,supplier_due_consumed_cents,receipt_data,pos_staff_reference)
   values(voucher_id,suppliers[1],batches[1],branches[1],verification_id,gen_random_uuid(),50000,jsonb_build_object('voucher_code',voucher_code),'rollback-test');
  end if;
 end loop;
 perform set_config('voucher_view_test.suppliers',to_jsonb(suppliers)::text,true);
 perform set_config('voucher_view_test.customers',to_jsonb(customers)::text,true);
 perform set_config('voucher_view_test.tag',tag,true);
end $$;
set local role authenticated;
do $$
declare supplier_ids jsonb:=current_setting('voucher_view_test.suppliers')::jsonb;
 customer_ids jsonb:=current_setting('voucher_view_test.customers')::jsonb;
 baseline jsonb:=current_setting('voucher_view_test.baseline')::jsonb;
 a jsonb; b jsonb; combined jsonb; directory jsonb; next_page jsonb; customer jsonb;
begin
 a:=public.paysme_voucher_company_overview((supplier_ids->>0)::uuid);
 b:=public.paysme_voucher_company_overview((supplier_ids->>1)::uuid);
 combined:=public.paysme_voucher_company_overview();
 if (a->>'paid_sales')::int<>2 or (b->>'paid_sales')::int<>1 or (combined->>'paid_sales')::bigint<>(baseline->>'paid_sales')::bigint+3 then raise exception 'FAIL company sale totals'; end if;
 if (a->>'customer_paid_cents')::bigint<>104000 or (b->>'customer_paid_cents')::bigint<>52000 then raise exception 'FAIL company prices'; end if;
 if (a->>'pending_settlement_cents')::bigint<>0 or (b->>'pending_settlement_cents')::bigint<>50000 then raise exception 'FAIL company settlement totals'; end if;
 if (a->>'redemption_count')::int<>2 or (b->>'redemption_count')::int<>0 or (a->>'settlement_consumed_cents')::bigint<>100000 then raise exception 'FAIL company redemption totals'; end if;
 if jsonb_array_length(a->'planning')<>0 or jsonb_array_length(b->'planning')<>1 or b->'planning'->0->>'supplier_id'<>supplier_ids->>1 then raise exception 'FAIL company planning'; end if;
 directory:=public.paysme_voucher_customer_directory(current_setting('voucher_view_test.tag'),0,1);
 next_page:=public.paysme_voucher_customer_directory(current_setting('voucher_view_test.tag'),1,1);
 if (directory->>'total_count')::int<>2 or jsonb_array_length(directory->'customers')<>1 or directory->'customers'->0->>'id'=next_page->'customers'->0->>'id' then raise exception 'FAIL voucher-only directory/pagination'; end if;
 if directory->'customers'->0 ? 'mobile_number' or directory->'customers'->0 ? 'email' then raise exception 'FAIL directory masking'; end if;
 customer:=public.paysme_voucher_customer_record((customer_ids->>0)::uuid,0,1);
 if (customer->'summary'->>'purchase_count')::int<>2 or (customer->'summary'->>'paid_value_cents')::bigint<>104000 or jsonb_array_length(customer->'purchases')<>1 then raise exception 'FAIL full customer totals and paged history'; end if;
 next_page:=public.paysme_voucher_customer_record((customer_ids->>0)::uuid,1,1);
 if customer->'purchases'->0->>'sale_id'=next_page->'purchases'->0->>'sale_id' then raise exception 'FAIL duplicate customer history pages'; end if;
 if customer->'purchases'->0->>'supplier_id'=next_page->'purchases'->0->>'supplier_id' then raise exception 'FAIL customer history across companies'; end if;
 if public.paysme_voucher_customer_record((customer_ids->>2)::uuid) is not null then raise exception 'FAIL VAS-only customer visible'; end if;
 if has_function_privilege('anon','public.paysme_voucher_customer_record(uuid,integer,integer)','EXECUTE') then raise exception 'FAIL anonymous customer access'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
set local role authenticated;
do $$ declare blocked integer:=0; begin
 begin perform public.paysme_voucher_companies(); exception when insufficient_privilege then blocked:=blocked+1; end;
 begin perform public.paysme_voucher_customer_directory(); exception when insufficient_privilege then blocked:=blocked+1; end;
 begin perform public.paysme_voucher_customer_record((current_setting('voucher_view_test.customers')::jsonb->>0)::uuid); exception when insufficient_privilege then blocked:=blocked+1; end;
 begin perform public.paysme_voucher_company_overview(); exception when insufficient_privilege then blocked:=blocked+1; end;
 if blocked<>4 then raise exception 'FAIL non-staff data access'; end if;
end $$;
reset role;
rollback;
select 'PASS: voucher-only customer records, all-history pagination, company totals/planning, directory masking and staff authorization' as result;
