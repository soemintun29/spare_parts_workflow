begin;

create temp table if not exists phase5_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text not null
);

do $$
declare
  v_wh_id uuid := '22222222-0000-0000-0000-000000000501';
  v_tech_src uuid := '11111111-0000-0000-0000-000000000501';
  v_tech_dst uuid := '11111111-0000-0000-0000-000000000502';
  v_part_id uuid := 'aaaaaaaa-0000-0000-0000-000000000501';
  v_voucher_id uuid := gen_random_uuid();
  v_voucher_no text := 'SV-P5-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_register_id uuid;
  v_transfer_id uuid;
  v_err text;
  v_count integer;
  v_amount numeric;
  v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
begin
  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values
    (v_wh_id, 'authenticated', 'authenticated', 'phase5-wh@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_src, 'authenticated', 'authenticated', 'phase5-src@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_dst, 'authenticated', 'authenticated', 'phase5-dst@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
  on conflict (id) do nothing;

  insert into app.user_profiles(user_id, role, branch_code, region_code, is_active)
  values
    (v_wh_id, 'warehouse_controller', 'B1', 'R1', true),
    (v_tech_src, 'technician', 'B1', 'R1', true),
    (v_tech_dst, 'technician', 'B1', 'R1', true)
  on conflict (user_id) do update
  set role = excluded.role,
      branch_code = excluded.branch_code,
      region_code = excluded.region_code,
      is_active = excluded.is_active;

  insert into app.parts_master(id, part_no, part_description, product_category, default_selling_price)
  values (v_part_id, 'P-PHASE5-1000', 'Phase 5 Part', 'Testing', 50.00)
  on conflict (id) do nothing;

  insert into app.van_stock(technician_id, part_id, branch_code, region_code, quantity_held, quantity_consumed)
  values (v_tech_src, v_part_id, 'B1', 'R1', 10, 0)
  on conflict (technician_id, part_id) do update
  set quantity_held = 10,
      quantity_consumed = 0,
      updated_at = timezone('utc', now());

  -- Sales invariants
  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into app.sales_vouchers(id, voucher_no, branch_code, region_code, customer_name, status, created_by)
  values (v_voucher_id, v_voucher_no, 'B1', 'R1', 'Cash Customer', 'draft', v_wh_id)
  on conflict (id) do nothing;

  insert into app.sales_voucher_lines(voucher_id, part_id, quantity, unit_price)
  values (v_voucher_id, v_part_id, 2, 100);

  perform app.issue_sales_voucher(v_voucher_id, 'p5-issue-' || v_suffix);
  perform app.pay_sales_voucher(v_voucher_id, 200, 'PAY-REF', 'p5-pay-' || v_suffix);
  perform app.pay_sales_voucher(v_voucher_id, 200, 'PAY-REF', 'p5-pay-' || v_suffix);

  select paid_amount into v_amount
  from app.sales_vouchers
  where id = v_voucher_id;

  insert into phase5_test_results values (
    'sales_paid_amount_matches_total',
    v_amount = 200,
    'paid_amount=' || v_amount::text
  );

  begin
    perform app.void_sales_voucher(v_voucher_id, 'should fail', 'p5-void-' || v_suffix);
    insert into phase5_test_results values ('void_only_unpaid_issued', false, 'void unexpectedly succeeded on paid voucher');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase5_test_results values (
        'void_only_unpaid_issued',
        position('Void allowed only for unpaid issued vouchers' in v_err) > 0,
        v_err
      );
  end;

  perform app.refund_sales_voucher(v_voucher_id, 50, 'partial refund', 'p5-refund-' || v_suffix);
  perform app.refund_sales_voucher(v_voucher_id, 50, 'partial refund', 'p5-refund-' || v_suffix);

  begin
    perform app.refund_sales_voucher(v_voucher_id, 200, 'excess refund', 'p5-refund-over-' || v_suffix);
    insert into phase5_test_results values ('refund_not_exceed_paid', false, 'excess refund unexpectedly succeeded');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase5_test_results values (
        'refund_not_exceed_paid',
        position('Refund cannot exceed paid amount' in v_err) > 0,
        v_err
      );
  end;

  select id into v_register_id
  from app.daily_cash_register
  where register_date = current_date
    and branch_code = 'B1'
  limit 1;

  perform app.reconcile_daily_cash_register(v_register_id);

  select expected_cash into v_amount
  from app.daily_cash_register
  where id = v_register_id;

  insert into phase5_test_results values (
    'daily_cash_reconciliation_matches_entries',
    v_amount = 150,
    'expected_cash=' || v_amount::text
  );

  select count(*)
    into v_count
  from app.daily_cash_entries dce
  where dce.voucher_id = v_voucher_id
    and dce.entry_type in ('sale_payment', 'refund');

  insert into phase5_test_results values (
    'refund_linkage_traceable',
    v_count >= 2,
    'cash_entries=' || v_count::text
  );

  -- Transfer invariants
  select id
    into v_transfer_id
  from app.create_transfer(v_part_id, v_tech_src, v_tech_dst, 3, 'JOB_SUPPORT', 'phase5 transfer', 'p5-create-transfer-' || v_suffix);

  -- reuse same key should not duplicate transfer
  perform app.create_transfer(v_part_id, v_tech_src, v_tech_dst, 3, 'JOB_SUPPORT', 'phase5 transfer', 'p5-create-transfer-' || v_suffix);
  select count(*)
    into v_count
  from app.transfer_requests tr
  where tr.reason_code = 'JOB_SUPPORT'
    and tr.created_by = auth.uid();

  insert into phase5_test_results values (
    'transfer_create_idempotent',
    v_count = 1,
    'transfer_count=' || v_count::text
  );

  select id into v_transfer_id
  from app.transfer_requests tr
  where tr.reason_code = 'JOB_SUPPORT'
    and tr.created_by = auth.uid()
  limit 1;

  perform app.handover_transfer(v_transfer_id, 'p5-handover-' || v_suffix);
  perform app.handover_transfer(v_transfer_id, 'p5-handover-' || v_suffix);

  perform app.receive_transfer(v_transfer_id, 3, 'p5-receive-transfer-' || v_suffix);
  perform app.receive_transfer(v_transfer_id, 3, 'p5-receive-transfer-' || v_suffix);

  select count(*)
    into v_count
  from app.van_stock vs
  where vs.technician_id = v_tech_dst
    and vs.part_id = v_part_id
    and vs.quantity_held >= 3;

  insert into phase5_test_results values (
    'destination_stock_changes_only_on_receive',
    v_count = 1,
    'destination_holds_row=' || v_count::text
  );

  -- Expire/cancel unlock tests using fresh transfers
  perform app.create_transfer(v_part_id, v_tech_src, v_tech_dst, 1, 'JOB_SUPPORT', 'expire test', 'p5-create-expire-' || v_suffix);
  select id into v_transfer_id
  from app.transfer_requests
  where reason_comment = 'expire test'
  order by created_at desc
  limit 1;
  perform app.expire_transfer(v_transfer_id, 'SLA timeout', 'p5-expire-' || v_suffix);

  select count(*)
    into v_count
  from app.van_stock_locks
  where transfer_id = v_transfer_id
    and lock_status = 'released'
    and release_reason = 'expired';

  insert into phase5_test_results values (
    'source_lock_released_on_expire',
    v_count = 1,
    'released_lock_rows=' || v_count::text
  );

  begin
    perform app.create_transfer(v_part_id, v_tech_src, v_tech_dst, 999, 'JOB_SUPPORT', 'overflow', 'p5-transfer-overflow-' || v_suffix);
    insert into phase5_test_results values ('transfer_blocks_over_unlocked_qty', false, 'overflow transfer unexpectedly succeeded');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase5_test_results values (
        'transfer_blocks_over_unlocked_qty',
        position('exceeds available unlocked source qty' in v_err) > 0,
        v_err
      );
  end;
end;
$$;

select test_name, passed, detail
from phase5_test_results
order by test_name;

rollback;
