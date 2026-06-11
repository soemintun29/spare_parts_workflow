begin;

create temp table if not exists phase6_auth_probe_results (
  check_name text primary key,
  passed boolean not null,
  detail text not null
);

do $$
declare
  v_wh_r1 uuid := '22222222-0000-0000-0000-000000000611';
  v_fin_r1 uuid := '33333333-0000-0000-0000-000000000611';
  v_tech_r1 uuid := '11111111-0000-0000-0000-000000000611';
  v_dispatcher_r1 uuid := '44444444-0000-0000-0000-000000000611';
  v_wh_r2 uuid := '22222222-0000-0000-0000-000000000612';
  v_tech_r2 uuid := '11111111-0000-0000-0000-000000000612';
  v_part_id uuid := 'aaaaaaaa-0000-0000-0000-000000000611';
  v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_voucher_r1_id uuid := gen_random_uuid();
  v_voucher_r2_id uuid := gen_random_uuid();
  v_transfer_r1_id uuid;
  v_transfer_r2_id uuid;
  v_register_id uuid;
begin
  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values
    (v_wh_r1, 'authenticated', 'authenticated', 'phase6-auth-wh-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_fin_r1, 'authenticated', 'authenticated', 'phase6-auth-fin-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_r1, 'authenticated', 'authenticated', 'phase6-auth-tech-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_dispatcher_r1, 'authenticated', 'authenticated', 'phase6-auth-dsp-r1@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_wh_r2, 'authenticated', 'authenticated', 'phase6-auth-wh-r2@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_r2, 'authenticated', 'authenticated', 'phase6-auth-tech-r2@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
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
  values (v_part_id, 'P-PHASE6-AUTH-1000', 'Phase 6 Auth Part', 'Testing', 100.00)
  on conflict (id) do nothing;

  insert into app.van_stock(technician_id, part_id, branch_code, region_code, quantity_held, quantity_consumed)
  values
    (v_tech_r1, v_part_id, 'B1', 'R1', 50, 0),
    (v_tech_r2, v_part_id, 'B2', 'R2', 50, 0)
  on conflict (technician_id, part_id) do update
  set quantity_held = excluded.quantity_held,
      quantity_consumed = 0,
      updated_at = timezone('utc', now());

  -- Setup fixtures
  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  insert into app.sales_vouchers(id, voucher_no, branch_code, region_code, customer_name, status, created_by)
  values (v_voucher_r1_id, 'SV-P6-AUTH-R1-' || v_suffix, 'B1', 'R1', 'Auth R1', 'draft', v_wh_r1);
  insert into app.sales_voucher_lines(voucher_id, part_id, quantity, unit_price)
  values (v_voucher_r1_id, v_part_id, 1, 100);

  perform set_config('request.jwt.claim.sub', v_wh_r2::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  insert into app.sales_vouchers(id, voucher_no, branch_code, region_code, customer_name, status, created_by)
  values (v_voucher_r2_id, 'SV-P6-AUTH-R2-' || v_suffix, 'B2', 'R2', 'Auth R2', 'draft', v_wh_r2);
  insert into app.sales_voucher_lines(voucher_id, part_id, quantity, unit_price)
  values (v_voucher_r2_id, v_part_id, 1, 100);

  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select id into v_transfer_r1_id
  from app.create_transfer(v_part_id, v_tech_r1, v_tech_r1, 5, 'AUTH_BASE_R1', 'auth r1 transfer', 'p6-auth-tr-r1-' || v_suffix);

  perform set_config('request.jwt.claim.sub', v_wh_r2::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select id into v_transfer_r2_id
  from app.create_transfer(v_part_id, v_tech_r2, v_tech_r2, 5, 'AUTH_BASE_R2', 'auth r2 transfer', 'p6-auth-tr-r2-' || v_suffix);

  -- technician denied on sales actions
  perform set_config('request.jwt.claim.sub', v_tech_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform app.issue_sales_voucher(v_voucher_r1_id, 'p6-auth-neg-issue-' || v_suffix);
    insert into phase6_auth_probe_results values ('issue_sales_voucher__technician_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('issue_sales_voucher__technician_denied', true, sqlerrm);
  end;

  begin
    perform app.pay_sales_voucher(v_voucher_r1_id, 100, 'AUTHNEG', 'p6-auth-neg-pay-' || v_suffix);
    insert into phase6_auth_probe_results values ('pay_sales_voucher__technician_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('pay_sales_voucher__technician_denied', true, sqlerrm);
  end;

  begin
    perform app.void_sales_voucher(v_voucher_r1_id, 'AUTHNEG', 'p6-auth-neg-void-' || v_suffix);
    insert into phase6_auth_probe_results values ('void_sales_voucher__technician_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('void_sales_voucher__technician_denied', true, sqlerrm);
  end;

  begin
    perform app.refund_sales_voucher(v_voucher_r1_id, 10, 'AUTHNEG', 'p6-auth-neg-refund-' || v_suffix);
    insert into phase6_auth_probe_results values ('refund_sales_voucher__technician_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('refund_sales_voucher__technician_denied', true, sqlerrm);
  end;

  -- finance_admin denied on transfer actions
  perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform app.create_transfer(v_part_id, v_tech_r1, v_tech_r1, 1, 'AUTH_NEG_FIN', 'fin create transfer', 'p6-auth-neg-create-transfer-' || v_suffix);
    insert into phase6_auth_probe_results values ('create_transfer__finance_admin_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('create_transfer__finance_admin_denied', true, sqlerrm);
  end;

  begin
    perform app.handover_transfer(v_transfer_r1_id, 'p6-auth-neg-handover-' || v_suffix);
    insert into phase6_auth_probe_results values ('handover_transfer__finance_admin_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('handover_transfer__finance_admin_denied', true, sqlerrm);
  end;

  begin
    perform app.receive_transfer(v_transfer_r1_id, 1, 'p6-auth-neg-receive-' || v_suffix);
    insert into phase6_auth_probe_results values ('receive_transfer__finance_admin_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('receive_transfer__finance_admin_denied', true, sqlerrm);
  end;

  begin
    perform app.expire_transfer(v_transfer_r1_id, 'AUTHNEG', 'p6-auth-neg-expire-' || v_suffix);
    insert into phase6_auth_probe_results values ('expire_transfer__finance_admin_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('expire_transfer__finance_admin_denied', true, sqlerrm);
  end;

  begin
    perform app.cancel_transfer(v_transfer_r1_id, 'AUTHNEG', 'p6-auth-neg-cancel-' || v_suffix);
    insert into phase6_auth_probe_results values ('cancel_transfer__finance_admin_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('cancel_transfer__finance_admin_denied', true, sqlerrm);
  end;

  -- finance_admin allowed on reconcile
  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform app.issue_sales_voucher(v_voucher_r1_id, 'p6-auth-issue-ok-' || v_suffix);
  perform app.pay_sales_voucher(v_voucher_r1_id, 100, 'AUTHOK', 'p6-auth-pay-ok-' || v_suffix);
  select id into v_register_id
  from app.daily_cash_register
  where register_date = current_date and branch_code = 'B1'
  limit 1;
  perform set_config('request.jwt.claim.sub', v_fin_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform app.reconcile_daily_cash_register(v_register_id);
    insert into phase6_auth_probe_results values ('reconcile_daily_cash_register__finance_admin_allowed', true, 'success as expected');
  exception when others then
    insert into phase6_auth_probe_results values ('reconcile_daily_cash_register__finance_admin_allowed', false, sqlerrm);
  end;

  -- Cross-region denials (mode A strict)
  perform set_config('request.jwt.claim.sub', v_wh_r1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform app.issue_sales_voucher(v_voucher_r2_id, 'p6-auth-xreg-issue-' || v_suffix);
    insert into phase6_auth_probe_results values ('issue_sales_voucher__cross_region_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('issue_sales_voucher__cross_region_denied', true, sqlerrm);
  end;

  begin
    perform app.pay_sales_voucher(v_voucher_r2_id, 100, 'XREGNEG', 'p6-auth-xreg-pay-' || v_suffix);
    insert into phase6_auth_probe_results values ('pay_sales_voucher__cross_region_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('pay_sales_voucher__cross_region_denied', true, sqlerrm);
  end;

  begin
    perform app.create_transfer(v_part_id, v_tech_r1, v_tech_r2, 1, 'AUTH_XREG', 'cross region deny', 'p6-auth-xreg-create-transfer-' || v_suffix);
    insert into phase6_auth_probe_results values ('create_transfer__cross_region_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('create_transfer__cross_region_denied', true, sqlerrm);
  end;

  begin
    perform app.handover_transfer(v_transfer_r2_id, 'p6-auth-xreg-handover-' || v_suffix);
    insert into phase6_auth_probe_results values ('handover_transfer__cross_region_denied', false, 'unexpected success');
  exception when others then
    insert into phase6_auth_probe_results values ('handover_transfer__cross_region_denied', true, sqlerrm);
  end;
end;
$$;

select check_name, passed, detail
from phase6_auth_probe_results
order by check_name;

rollback;
