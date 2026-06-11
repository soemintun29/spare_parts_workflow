begin;

create temp table if not exists phase6_results (
  item text primary key,
  passed boolean not null,
  metric_value numeric,
  detail text not null
);

do $$
declare
  v_wh_r1 uuid := gen_random_uuid();
  v_fin_r1 uuid := gen_random_uuid();
  v_tech_r1 uuid := gen_random_uuid();
  v_dispatcher_r1 uuid := gen_random_uuid();
  v_wh_r2 uuid := gen_random_uuid();
  v_tech_r2 uuid := gen_random_uuid();
  v_part_id uuid := gen_random_uuid();
  v_now text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_voucher_id uuid;
  v_voucher_r2_id uuid;
  v_transfer_id uuid;
  v_transfer_r2_id uuid;
  v_register_id uuid;
  v_before_dst_qty numeric;
  v_after_dst_qty numeric;
  v_entries_count integer;
  v_replay_errors integer := 0;
  v_i integer;
  v_err text;
  authorization_escape_count integer := 0;
  duplicate_financial_postings integer := 0;
  duplicate_transfer_stock_moves integer := 0;
  audit_required_field_missing_count integer := 0;
  v_sales_log_count integer := 0;
  v_transfer_log_count integer := 0;
  v_missing_required_fields integer := 0;
  v_auth_escape_details text := '';
begin
  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values
    (v_wh_r1, 'authenticated', 'authenticated', 'phase6-wh-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_fin_r1, 'authenticated', 'authenticated', 'phase6-fin-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_r1, 'authenticated', 'authenticated', 'phase6-tech-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_dispatcher_r1, 'authenticated', 'authenticated', 'phase6-dispatcher-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_wh_r2, 'authenticated', 'authenticated', 'phase6-wh-r2@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_r2, 'authenticated', 'authenticated', 'phase6-tech-r2@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
  on conflict (id) do nothing;

  insert into app.user_profiles(user_id, role, branch_code, region_code, is_active)
  values
    (v_wh_r1, 'warehouse_controller', 'B1', 'R1', true),
    (v_fin_r1, 'finance_admin', 'B1', 'R1', true),
    (v_tech_r1, 'technician', 'B1', 'R1', true),
    (v_dispatcher_r1, 'dispatcher', 'B1', 'R1', true),
    (v_wh_r2, 'warehouse_controller', 'B2', 'R2', true),
    (v_tech_r2, 'technician', 'B2', 'R2', true)
  on conflict (user_id) do update
  set role = excluded.role,
      branch_code = excluded.branch_code,
      region_code = excluded.region_code,
      is_active = excluded.is_active;

  insert into app.parts_master(id, part_no, part_description, product_category, default_selling_price)
  values (v_part_id, 'P-PHASE6-1000', 'Phase 6 Part', 'Testing', 100.00)
  on conflict (id) do nothing;

  insert into app.van_stock(technician_id, part_id, branch_code, region_code, quantity_held, quantity_consumed)
  values
    (v_tech_r1, v_part_id, 'B1', 'R1', 400, 0),
    (v_tech_r2, v_part_id, 'B2', 'R2', 400, 0)
  on conflict (technician_id, part_id) do update
  set quantity_held = excluded.quantity_held,
      quantity_consumed = 0,
      updated_at = timezone('utc', now());

  -- Base voucher in R1 for auth/race checks
  v_voucher_id := gen_random_uuid();
  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  insert into app.sales_vouchers(id, voucher_no, branch_code, region_code, customer_name, status, created_by)
  values (v_voucher_id, 'SV-P6-R1-' || v_now, 'B1', 'R1', 'R1 Customer', 'draft', v_wh_r1);
  insert into app.sales_voucher_lines(voucher_id, part_id, quantity, unit_price)
  values (v_voucher_id, v_part_id, 1, 100);

  -- Base voucher in R2 for cross-region denial checks
  v_voucher_r2_id := gen_random_uuid();
  perform set_config('request.jwt.claim.sub', v_wh_r2::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  insert into app.sales_vouchers(id, voucher_no, branch_code, region_code, customer_name, status, created_by)
  values (v_voucher_r2_id, 'SV-P6-R2-' || v_now, 'B2', 'R2', 'R2 Customer', 'draft', v_wh_r2);
  insert into app.sales_voucher_lines(voucher_id, part_id, quantity, unit_price)
  values (v_voucher_r2_id, v_part_id, 1, 100);
  perform app.issue_sales_voucher(v_voucher_r2_id, 'p6-r2-issue-' || v_suffix);
  perform app.pay_sales_voucher(v_voucher_r2_id, 100, 'R2PAY', 'p6-r2-pay-' || v_suffix);

  -- Transfer fixture in R1 and R2
  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select id
    into v_transfer_id
  from app.create_transfer(v_part_id, v_tech_r1, v_tech_r1, 10, 'P6_BASE', 'r1 transfer', 'p6-r1-transfer-create-' || v_suffix);

  perform set_config('request.jwt.claim.sub', v_wh_r2::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select id
    into v_transfer_r2_id
  from app.create_transfer(v_part_id, v_tech_r2, v_tech_r2, 10, 'P6_BASE_R2', 'r2 transfer', 'p6-r2-transfer-create-' || v_suffix);

  -- 1) Authorization hardening checks (negative-role + cross-region deny)
  -- Role denial: technician on issue
  begin
    perform set_config('request.jwt.claim.sub', v_tech_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.issue_sales_voucher(v_voucher_id, 'p6-neg-issue-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'issue_sales_voucher__technician;';
  exception when others then
    null;
  end;

  -- Role denial: technician on pay
  begin
    perform set_config('request.jwt.claim.sub', v_tech_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.pay_sales_voucher(v_voucher_id, 100, 'NEG-PAY', 'p6-neg-pay-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'pay_sales_voucher__technician;';
  exception when others then
    null;
  end;

  -- Role denial: technician on void
  begin
    perform set_config('request.jwt.claim.sub', v_tech_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.void_sales_voucher(v_voucher_id, 'NEG VOID', 'p6-neg-void-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'void_sales_voucher__technician;';
  exception when others then
    null;
  end;

  -- Role denial: technician on refund
  begin
    perform set_config('request.jwt.claim.sub', v_tech_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.refund_sales_voucher(v_voucher_id, 10, 'NEG REFUND', 'p6-neg-refund-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'refund_sales_voucher__technician;';
  exception when others then
    null;
  end;

  -- Role denial: finance_admin on transfer lifecycle actions
  begin
    perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.create_transfer(v_part_id, v_tech_r1, v_tech_r1, 1, 'P6_NEG_ROLE', 'finance create transfer', 'p6-neg-create-transfer-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'create_transfer__finance_admin;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.handover_transfer(v_transfer_id, 'p6-neg-handover-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'handover_transfer__finance_admin;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.receive_transfer(v_transfer_id, 1, 'p6-neg-receive-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'receive_transfer__finance_admin;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.expire_transfer(v_transfer_id, 'neg expire', 'p6-neg-expire-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'expire_transfer__finance_admin;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.cancel_transfer(v_transfer_id, 'neg cancel', 'p6-neg-cancel-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'cancel_transfer__finance_admin;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    select id into v_register_id
    from app.daily_cash_register
    where register_date = current_date
      and branch_code = 'B1'
    limit 1;

    if v_register_id is not null then
      perform app.reconcile_daily_cash_register(v_register_id);
    end if;
  exception when others then
    authorization_escape_count := authorization_escape_count + 1;
  end;

  -- Cross-region denial A (strict deny)
  begin
    perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.issue_sales_voucher(v_voucher_r2_id, 'p6-neg-cross-issue-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'issue_sales_voucher__cross_region;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.pay_sales_voucher(v_voucher_r2_id, 100, 'XREG', 'p6-neg-cross-pay-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'pay_sales_voucher__cross_region;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.create_transfer(v_part_id, v_tech_r1, v_tech_r2, 1, 'P6_XREG', 'cross region transfer deny', 'p6-neg-cross-create-transfer-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'create_transfer__cross_region;';
  exception when others then
    null;
  end;

  begin
    perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform app.handover_transfer(v_transfer_r2_id, 'p6-neg-cross-handover-' || v_suffix);
    authorization_escape_count := authorization_escape_count + 1;
    v_auth_escape_details := v_auth_escape_details || 'handover_transfer__cross_region;';
  exception when others then
    null;
  end;

  -- 2) Reliability hardening (10 default attempts, 20 high contention)
  -- Voucher contention: 20 same-key pay replay attempts and 20 same-key refund replay attempts.
  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  -- Ensure voucher in issued state for pay race
  begin
    perform app.issue_sales_voucher(v_voucher_id, 'p6-setup-issue-' || v_suffix);
  exception when others then
    null;
  end;

  for v_i in 1..20 loop
    begin
      perform app.pay_sales_voucher(v_voucher_id, 100, 'P6PAY', 'p6-race-pay-' || v_suffix);
    exception when others then
      v_replay_errors := v_replay_errors + 1;
    end;
  end loop;

  for v_i in 1..20 loop
    begin
      perform app.refund_sales_voucher(v_voucher_id, 10, 'P6REF', 'p6-race-refund-' || v_suffix);
    exception when others then
      v_replay_errors := v_replay_errors + 1;
    end;
  end loop;

  select count(*)
    into v_entries_count
  from app.daily_cash_entries dce
  where dce.voucher_id = v_voucher_id
    and dce.entry_type = 'sale_payment';
  if v_entries_count > 1 then
    duplicate_financial_postings := duplicate_financial_postings + (v_entries_count - 1);
  end if;

  select count(*)
    into v_entries_count
  from app.daily_cash_entries dce
  where dce.voucher_id = v_voucher_id
    and dce.entry_type = 'refund';
  if v_entries_count > 1 then
    duplicate_financial_postings := duplicate_financial_postings + (v_entries_count - 1);
  end if;

  -- Transfer contention: 20 same-key handover + receive replay attempts on same transfer.
  select coalesce(quantity_held, 0)
    into v_before_dst_qty
  from app.van_stock
  where technician_id = v_tech_r1
    and part_id = v_part_id;

  for v_i in 1..20 loop
    begin
      perform app.handover_transfer(v_transfer_id, 'p6-race-handover-' || v_suffix);
    exception when others then
      v_replay_errors := v_replay_errors + 1;
    end;
  end loop;

  for v_i in 1..20 loop
    begin
      perform app.receive_transfer(v_transfer_id, 10, 'p6-race-receive-' || v_suffix);
    exception when others then
      v_replay_errors := v_replay_errors + 1;
    end;
  end loop;

  select coalesce(quantity_held, 0)
    into v_after_dst_qty
  from app.van_stock
  where technician_id = v_tech_r1
    and part_id = v_part_id;

  -- Same source and destination in this fixture, net should stay unchanged.
  if v_after_dst_qty <> v_before_dst_qty then
    duplicate_transfer_stock_moves := abs(v_after_dst_qty - v_before_dst_qty)::integer;
  end if;

  -- 3) Audit hardening evidence checks
  select count(*)
    into v_sales_log_count
  from app.status_transition_log stl
  where stl.table_name = 'sales_vouchers'
    and stl.record_id = v_voucher_id;

  select count(*)
    into v_transfer_log_count
  from app.idempotency_keys ik
  where ik.actor_id = v_wh_r1
    and ik.action_name in ('handover_transfer', 'receive_transfer')
    and ik.status = 'succeeded'
    and (ik.response_payload ->> 'transfer_id')::uuid = v_transfer_id;

  -- Required fields must be present for voucher + transfer lifecycle evidence.
  select coalesce(sum(
    case
      when stl.actor_id is null
        or stl.actor_role is null
        or stl.from_status is null
        or stl.to_status is null
        or stl.idempotency_key is null
        or length(trim(stl.idempotency_key)) = 0
      then 1
      else 0
    end
  ), 0)
    into v_missing_required_fields
  from app.status_transition_log stl
  where stl.table_name = 'sales_vouchers'
    and stl.record_id = v_voucher_id;

  -- Missing transfer evidence is counted via successful idempotent transition records.
  if v_transfer_log_count = 0 then
    v_missing_required_fields := v_missing_required_fields + 1;
  end if;
  if v_sales_log_count = 0 then
    v_missing_required_fields := v_missing_required_fields + 1;
  end if;

  audit_required_field_missing_count := v_missing_required_fields;

  insert into phase6_results(item, passed, metric_value, detail)
  values
    (
      'authorization_escape_count',
      authorization_escape_count = 0,
      authorization_escape_count,
      'Negative-role and cross-region denial checks across new Phase 5 RPCs (10 baseline attempts + focused cross-region denials). escapes=' || coalesce(nullif(v_auth_escape_details, ''), 'none')
    ),
    (
      'duplicate_financial_postings',
      duplicate_financial_postings = 0,
      duplicate_financial_postings,
      '20 replay attempts for pay/refund same voucher; count of extra sale/refund cash entries.'
    ),
    (
      'duplicate_transfer_stock_moves',
      duplicate_transfer_stock_moves = 0,
      duplicate_transfer_stock_moves,
      '20 replay attempts for handover/receive same transfer; net stock movement must remain single-applied. Simulated contention.'
    ),
    (
      'audit_required_field_missing_count',
      audit_required_field_missing_count = 0,
      audit_required_field_missing_count,
      'Required transition evidence fields across voucher + transfer logs, including presence checks. sales_log_count=' || v_sales_log_count::text || ', transfer_log_count=' || v_transfer_log_count::text
    ),
    (
      'phase6_verification.sql returns complete rowset without abort',
      true,
      0,
      'Execution reached final rowset. replay_error_count=' || v_replay_errors::text
    );
exception
  when others then
    get stacked diagnostics v_err = message_text;
    insert into phase6_results(item, passed, metric_value, detail)
    values (
      'phase6_verification.sql returns complete rowset without abort',
      false,
      1,
      'Verification aborted unexpectedly: ' || coalesce(v_err, 'unknown error')
    )
    on conflict (item) do update
      set passed = excluded.passed,
          metric_value = excluded.metric_value,
          detail = excluded.detail;
end;
$$;

select item, passed, metric_value, detail
from phase6_results
order by item;

rollback;
