-- Rollback-only. PaySME owns the funds held with the supplier. No email/SMS or real money transfer.
begin;
do $$
declare
 _actor uuid; _supplier uuid:=gen_random_uuid(); _deposit uuid:=gen_random_uuid(); _topup uuid:=gen_random_uuid(); _third uuid:=gen_random_uuid();
 _branch uuid; _product uuid; _small_product uuid; _history_product uuid; _historical_deposit uuid; _proof text; _bank_proof text;
 _supplier_data jsonb; _out jsonb; _args jsonb; _sale jsonb; _sale_b jsonb; _cash_sale jsonb; _history_sale jsonb;
 _batch jsonb; _batch_b jsonb; _cash_batch jsonb; _history_batch jsonb; _account jsonb; _report jsonb; _jobs jsonb;
 _blocked boolean; _attempt integer; _count integer; _verify uuid; _request uuid:=gen_random_uuid();
 _key text:=repeat('f',64); _worker_key text; _prefix text; _worker_token text; _job jsonb;
 _today date:=(now() at time zone 'Africa/Windhoek')::date;
begin
 select a.auth_user_id into _actor from public.admin_users a where a.role='super_admin' and a.is_active and a.setup_status='active' limit 1;
 if _actor is null then raise exception 'Existing active super administrator required'; end if;
 _supplier_data:=jsonb_build_object('business_name','Rollback PaySME prepayment retailer','finance_contact_name','Finance','finance_email','finance@example.invalid',
  'supervisor_name','Supervisor','supervisor_email','supervisor@example.invalid','payment_model','prepaid','daily_reconciliation_enabled',true);
 _blocked:=false;
 begin perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data)); exception when raise_exception then _blocked:=true; end;
 if not _blocked or exists(select 1 from public.paysme_voucher_suppliers s where s.id=_supplier) then raise exception 'FAIL initial PaySME POP/payment must save atomically with prepaid terms'; end if;
 _proof:=_deposit::text||'/'||gen_random_uuid()::text||'.pdf';
 insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 _out:=public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data,'token',repeat('a',64),
  'initial_prepayment',jsonb_build_object('prepayment_id',_deposit,'bank_reference','rollback-paysme-outgoing-initial','amount_cents',3098,'proof_object_path',_proof)));
 if _out->>'confirmation_type'<>'prepayment' then raise exception 'FAIL initial PaySME prepayment review'; end if;
 _account:=paysme_voucher_private.credit_balance(_supplier);
 if _account->>'funds_owner'<>'PaySME' or _account->>'funds_location'<>'held_with_supplier' or (_account->>'available_cents')::bigint<>0 then raise exception 'FAIL PaySME fund ownership or pending funds spent'; end if;
 if (select d.payment_direction from public.paysme_voucher_prepayments d where d.id=_deposit)<>'paysme_to_supplier' then raise exception 'FAIL prepayment direction reversed'; end if;

 insert into public.paysme_voucher_branches(supplier_id,name,town) values(_supplier,'Requested pilot store','Windhoek') returning id into _branch;
 insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents)
 values(_supplier,'N$40,000 batch test',4000000,100,4100000) returning id into _product;
 insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents)
 values(_supplier,'Small prepaid voucher',1000,100,1200) returning id into _small_product;
 _args:=jsonb_build_object('product_id',_product,'payment_reference','rollback-prepaid-sale-a','request_key',gen_random_uuid(),'vendor_reference','rollback-vendor',
  'branch_id',_branch,'mobile_number','+264810000011','full_name','Rollback recipient','email','recipient@example.invalid','town','Windhoek','id_number','PREPAIDTEST123');
 -- Vendor sales must continue even though PaySME's balance with this supplier is zero/pending.
 _sale:=public.paysme_voucher_command('record_paid_sale',_args);
 if _sale->>'voucher_code' is null then raise exception 'FAIL supplier prepayment incorrectly blocks a Vendor sale'; end if;
 _batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 if _batch->>'payment_model'<>'prepaid' or (_batch->>'amount_due_cents')::bigint<>4000000 then raise exception 'FAIL prepaid purchase/batch snapshot'; end if;
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('a',64),'otp','123456'));
 _out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('a',64),'otp','123456'));
 if _out->>'credited'<>'true' then raise exception 'FAIL PaySME initial prepayment approval'; end if;
 _account:=paysme_voucher_private.credit_balance(_supplier);
 if (_account->>'available_cents')::bigint<>3098 then raise exception 'FAIL initial PaySME N$30.98 balance'; end if;
 _blocked:=false;
 begin perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('c',64)));
 exception when raise_exception then if sqlerrm<>'Insufficient confirmed prepaid credit for this batch' then raise; end if; _blocked:=true; end;
 if not _blocked or exists(select 1 from paysme_voucher_private.credit_confirmations c where c.batch_id=(_batch->>'id')::uuid) then raise exception 'FAIL N$40,000 approval request accepted with PaySME N$30.98 available'; end if;
 if exists(select 1 from public.paysme_voucher_credit_reservations r where r.batch_id=(_batch->>'id')::uuid) then raise exception 'FAIL rejected request reserved funds'; end if;
 _out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('a',64),'otp','123456'));
 if _out->>'replayed'<>'true' or (select count(*) from public.paysme_voucher_credit_ledger l where l.prepayment_id=_deposit)<>1 then raise exception 'FAIL initial prepayment credited twice'; end if;
 _blocked:=false;begin perform public.paysme_voucher_command('amend_prepayment',jsonb_build_object('actor_id',_actor,'prepayment_id',_deposit,'amount_cents',99999999,'note','invalid edit'));exception when raise_exception then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL confirmed PaySME funds edited'; end if;

 _proof:=_topup::text||'/'||gen_random_uuid()::text||'.pdf';
 insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 perform public.paysme_voucher_command('record_prepayment',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'prepayment_id',_topup,'bank_reference','rollback-paysme-topup','amount_cents',3996902,'proof_object_path',_proof,'token',repeat('b',64)));
 if (paysme_voucher_private.credit_balance(_supplier)->>'available_cents')::bigint<>3098 then raise exception 'FAIL pending top-up spent'; end if;
 perform public.paysme_voucher_command('amend_prepayment',jsonb_build_object('actor_id',_actor,'prepayment_id',_topup,'bank_reference','rollback-paysme-topup-corrected','note','Correct bank reference before approval'));
 _out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',repeat('b',64)));if not _out?'error' then raise exception 'FAIL amended payment retained an old approval';end if;
 perform public.paysme_voucher_command('start_prepayment_confirmation',jsonb_build_object('actor_id',_actor,'prepayment_id',_topup,'token',repeat('5',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('5',64),'otp','123456'));
 perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('5',64),'otp','123456'));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('c',64)));
 _account:=paysme_voucher_private.credit_balance(_supplier);
 if (_account->>'confirmed_balance_cents')::bigint<>4000000 or (_account->>'reserved_cents')::bigint<>4000000 or (_account->>'available_cents')::bigint<>0 then raise exception 'FAIL PaySME pending allocation accounting'; end if;
 _sale_b:=public.paysme_voucher_command('record_paid_sale',_args||jsonb_build_object('product_id',_small_product,'request_key',gen_random_uuid(),'payment_reference','rollback-prepaid-sale-b'));
 _batch_b:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 _blocked:=false;begin perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('0',64)));exception when raise_exception then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL PaySME funds reserved for another request spent twice'; end if;
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('d',64)));
 if (select count(*) from public.paysme_voucher_credit_reservations r where r.batch_id=(_batch->>'id')::uuid and r.status='reserved')<>1 then raise exception 'FAIL resend reserved PaySME funds twice'; end if;
 _out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',repeat('c',64)));
 if not _out?'error' then raise exception 'FAIL previous prepaid batch link still valid'; end if;
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('d',64),'otp','123456'));
 for _attempt in 1..5 loop perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('d',64),'otp','999999')); end loop;
 _out:=public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('d',64),'otp','123456'));
 if not _out?'error' or exists(select 1 from public.paysme_voucher_credit_ledger l where l.batch_id=(_batch->>'id')::uuid) then raise exception 'FAIL prepaid supervisor lockout or early deduction'; end if;
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch->>'id','token',repeat('e',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('e',64),'otp','654321'));
 perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('e',64),'otp','654321'));
 perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('e',64),'otp','654321'));
 if (paysme_voucher_private.credit_balance(_supplier)->>'confirmed_balance_cents')::bigint<>0 or (select count(*) from public.paysme_voucher_credit_ledger l where l.batch_id=(_batch->>'id')::uuid)<>1 then raise exception 'FAIL PaySME batch deducted twice'; end if;

 perform public.paysme_voucher_command('issue_api_key',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'branch_id',_branch,'label','Rollback supplier API','api_key',_key));
 _out:=public.paysme_voucher_command('validate_id',jsonb_build_object('api_key_hash',paysme_voucher_private.hash(_key),'voucher_code',_sale->>'voucher_code','pos_staff_reference','PILOT','id_number','PREPAIDTEST123'));
 _verify:=(_out->>'verification_id')::uuid;if _verify is null then raise exception 'FAIL prepaid voucher ID/API verification';end if;
 _out:=public.paysme_voucher_command('redeem_voucher',jsonb_build_object('api_key_hash',paysme_voucher_private.hash(_key),'voucher_code',_sale->>'voucher_code','pos_staff_reference','PILOT','verification_id',_verify,'request_key',_request));
 if _out->>'receipt_reference' is null or (paysme_voucher_private.credit_balance(_supplier)->>'confirmed_balance_cents')::bigint<>0 then raise exception 'FAIL redemption charged PaySME funds again or required a new balance'; end if;

 _proof:=_third::text||'/'||gen_random_uuid()::text||'.pdf';insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 perform public.paysme_voucher_command('record_prepayment',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'prepayment_id',_third,'bank_reference','rollback-paysme-small-topup','amount_cents',1000,'proof_object_path',_proof,'token',repeat('0',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('0',64),'otp','123456'));perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('0',64),'otp','123456'));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('1',64)));
 perform public.paysme_voucher_command('report_discrepancy',jsonb_build_object('token',repeat('1',64),'reason','incorrect_amount','comment','Our balance records differ; insufficient funds on retailer record'));
 if (select b.status from public.paysme_voucher_payment_batches b where b.id=(_batch_b->>'id')::uuid)<>'disputed' or exists(select 1 from public.paysme_voucher_credit_ledger l where l.batch_id=(_batch_b->>'id')::uuid) then raise exception 'FAIL retailer issue approved a charge';end if;
 perform public.paysme_voucher_command('release_prepaid_reservation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','note','Release hold during investigation'));
 if (paysme_voucher_private.credit_balance(_supplier)->>'available_cents')::bigint<>1000 then raise exception 'FAIL releasing pending hold changed PaySME ledger balance';end if;
 perform public.paysme_voucher_command('resolve_discrepancy',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','note','Retailer and PaySME balances reconciled'));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('2',64)));
 _supplier_data:=_supplier_data||jsonb_build_object('supervisor_email','new-supervisor@example.invalid');
 perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data));
 _out:=public.paysme_voucher_command('confirmation_details',jsonb_build_object('token',repeat('2',64)));if not _out?'error' then raise exception 'FAIL changed supervisor retained approval';end if;
 _out:=public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_batch_b->>'id','token',repeat('3',64)));
 if _out->>'supervisor_email'<>'new-supervisor@example.invalid' then raise exception 'FAIL new supervisor not used';end if;
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('3',64),'otp','123456'));perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('3',64),'otp','123456'));

 -- Terms change is prospective. Existing prepaid charges/vouchers retain their funding.
 _supplier_data:=_supplier_data||jsonb_build_object('payment_model','postpaid');
 perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data));
 _cash_sale:=public.paysme_voucher_command('record_paid_sale',_args||jsonb_build_object('product_id',_small_product,'request_key',gen_random_uuid(),'payment_reference','rollback-cash-after-prepaid'));
 _cash_batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 if _cash_batch->>'payment_model'<>'postpaid' or (select b.payment_model from public.paysme_voucher_payment_batches b where b.id=(_batch->>'id')::uuid)<>'prepaid' then raise exception 'FAIL payment terms rewritten retrospectively';end if;
 _bank_proof:=(_cash_batch->>'id')||'/'||gen_random_uuid()::text||'.pdf';insert into storage.objects(bucket_id,name,metadata) values('paysme-voucher-payment-proofs',_bank_proof,'{"mimetype":"application/pdf","size":100}'::jsonb);
 perform public.paysme_voucher_command('record_payment',jsonb_build_object('actor_id',_actor,'batch_id',_cash_batch->>'id','bank_reference','rollback-cash-separate-payment','amount_cents',1000,'proof_object_path',_bank_proof));
 perform public.paysme_voucher_command('start_confirmation',jsonb_build_object('actor_id',_actor,'batch_id',_cash_batch->>'id','token',repeat('4',64)));
 perform public.paysme_voucher_command('confirmation_otp',jsonb_build_object('token',repeat('4',64),'otp','123456'));perform public.paysme_voucher_command('confirm_batch',jsonb_build_object('token',repeat('4',64),'otp','123456'));
 if (paysme_voucher_private.credit_balance(_supplier)->>'confirmed_balance_cents')::bigint<>0 then raise exception 'FAIL cash batch changed PaySME prepaid asset balance';end if;
 if (select count(*) from paysme_voucher_private.notification_outbox j where j.supplier_id=_supplier and j.kind='ready_sms')<>3 then raise exception 'FAIL missing/duplicate ready SMS events';end if;
 _blocked:=false;begin update public.paysme_voucher_credit_ledger l set amount_cents=1 where l.supplier_id=_supplier;exception when raise_exception then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL PaySME asset ledger mutable';end if;

 -- Historical fixtures prove opening + top-ups - approved batches, including UNREDEEMED approved vouchers.
 for _attempt in 1..2 loop
  _historical_deposit:=gen_random_uuid();
  insert into public.paysme_voucher_prepayments(id,supplier_id,supplier_name,finance_email,supervisor_email,deposit_kind,bank_reference,amount_cents,proof_object_path,status,recorded_by,created_at,confirmed_at,confirmed_by_email)
  values(_historical_deposit,_supplier,'Historical test','finance@example.invalid','new-supervisor@example.invalid','topup','historical-'||_historical_deposit::text,case when _attempt=1 then 3000 else 2000 end,_proof,'confirmed',_actor::text,(_today-_attempt)::timestamp at time zone 'Africa/Windhoek',(_today-_attempt)::timestamp at time zone 'Africa/Windhoek','finance@example.invalid');
  insert into public.paysme_voucher_credit_ledger(supplier_id,entry_kind,amount_cents,prepayment_id,reference,recorded_by,created_at)
  values(_supplier,'deposit',case when _attempt=1 then 3000 else 2000 end,_historical_deposit,'Historical PaySME prepayment',_actor::text,(_today-_attempt)::timestamp at time zone 'Africa/Windhoek');
 end loop;
 _supplier_data:=_supplier_data||jsonb_build_object('payment_model','prepaid');perform public.paysme_voucher_command('save_supplier',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'supplier',_supplier_data));
 insert into public.paysme_voucher_products(supplier_id,name,supplier_price_cents,markup_cents,instore_price_cents) values(_supplier,'Historical unredeemed approved voucher',4000,0,4000) returning id into _history_product;
 _history_sale:=public.paysme_voucher_command('record_paid_sale',_args||jsonb_build_object('product_id',_history_product,'request_key',gen_random_uuid(),'payment_reference','rollback-history-sale'));
 _history_batch:=public.paysme_voucher_command('prepare_batch',jsonb_build_object('actor_id',_actor,'supplier_id',_supplier,'cutoff_at',now()));
 insert into public.paysme_voucher_credit_ledger(supplier_id,entry_kind,amount_cents,batch_id,reference,recorded_by,created_at)
 values(_supplier,'batch',-4000,(_history_batch->>'id')::uuid,_history_batch->>'batch_reference',_actor::text,(_today-1)::timestamp at time zone 'Africa/Windhoek');
 update public.paysme_voucher_payment_batches b set status='settled',settled_at=(_today-1)::timestamp at time zone 'Africa/Windhoek',confirmed_payment_cents=4000 where b.id=(_history_batch->>'id')::uuid;
 update public.paysme_vouchers v set status='redeemable',redeemable_at=(_today-1)::timestamp at time zone 'Africa/Windhoek' where v.sale_id=(_history_sale->>'sale_id')::uuid;
 _report:=paysme_voucher_private.reconciliation_data(_supplier,_today-1);
 if (_report->>'opening_cents')::bigint<>2000 or (_report->>'credited_cents')::bigint<>3000 or (_report->>'charged_cents')::bigint<>4000 or (_report->>'closing_cents')::bigint<>1000 then raise exception 'FAIL PaySME opening/top-up/approved-batch reconciliation';end if;
 perform paysme_voucher_private.queue_reconciliation(_supplier,_today-1);perform paysme_voucher_private.queue_reconciliation(_supplier,_today-1);
 if (select count(*) from paysme_voucher_private.notification_outbox j where j.supplier_id=_supplier and j.kind='daily_email')<>2 then raise exception 'FAIL daily report not queued once to each supplier contact';end if;
 if has_function_privilege('authenticated','public.paysme_voucher_command(text,jsonb)','execute') or has_function_privilege('anon','public.paysme_voucher_claim_notifications(text,integer)','execute') or has_table_privilege('authenticated','public.paysme_voucher_credit_ledger','update') then raise exception 'FAIL financial/worker privileges';end if;
 perform set_config('request.jwt.claim.sub',_actor::text,true);
 _out:=public.paysme_voucher_batch_record((_batch->>'id')::uuid,1,0);
 if (_out->>'total_count')::integer<>1 or jsonb_array_length(_out->'items')<>1 then raise exception 'FAIL paginated staff batch record';end if;
 _out:=public.paysme_voucher_credit_statement(_supplier,1,0);if jsonb_array_length(_out->'entries')<>1 then raise exception 'FAIL prepaid statement pagination';end if;
 execute 'set local role authenticated';
 _out:=public.paysme_voucher_credit_statement(_supplier,1,0);if _out->'account'->>'funds_owner'<>'PaySME' then raise exception 'FAIL staff invoker view / RLS';end if;
 _out:=public.paysme_voucher_batch_record((_batch->>'id')::uuid,1,0);if _out->'batch'->>'payment_model'<>'prepaid' then raise exception 'FAIL staff batch RLS';end if;
 execute 'reset role';

 -- Lease authentication/acknowledgement tested without contacting any provider.
 update paysme_voucher_private.notification_outbox j set created_at='2000-01-01' where j.supplier_id=_supplier;
 _prefix:=floor(extract(epoch from clock_timestamp()))::bigint::text||':'||gen_random_uuid()::text;
 select s.signing_key into _worker_key from paysme_voucher_private.notification_settings s where s.singleton;
 _worker_token:=_prefix||':'||encode(extensions.hmac(_prefix,_worker_key,'sha256'),'hex');
 _jobs:=public.paysme_voucher_claim_notifications(_worker_token,50);
 _blocked:=false;begin perform public.paysme_voucher_claim_notifications(_worker_token,50);exception when insufficient_privilege then _blocked:=true;end;
 if not _blocked then raise exception 'FAIL worker token replay';end if;
 for _job in select value from jsonb_array_elements(_jobs) loop
  if public.paysme_voucher_finish_notification((_job->>'id')::uuid,gen_random_uuid(),true) then raise exception 'FAIL wrong delivery lease accepted';end if;
  if not public.paysme_voucher_finish_notification((_job->>'id')::uuid,(_job->>'lease_id')::uuid,true) then raise exception 'FAIL valid delivery acknowledgement';end if;
  if public.paysme_voucher_finish_notification((_job->>'id')::uuid,(_job->>'lease_id')::uuid,true) then raise exception 'FAIL duplicate delivery acknowledgement';end if;
 end loop;
 if exists(select 1 from public.paysme_voucher_credit_ledger l where l.supplier_id=_supplier and (l.funds_owner<>'PaySME' or l.funds_location<>'held_with_supplier')) then raise exception 'FAIL wrong prepaid fund owner';end if;
end $$;
rollback;
select 'PASS: PaySME-owned supplier prepayments, no-email funding gate, independent Vendor sales, OTP, exact batch charge, no redemption double charge, prospective terms, reconciliation and notification leases. All fixtures rolled back.' as result;
