begin;

create temp table if not exists phase6_external_probe_results (
  probe_name text primary key,
  passed boolean not null,
  detail text not null
);

do $$
declare
  v_wh uuid := gen_random_uuid();
  v_part uuid := gen_random_uuid();
  v_voucher uuid := gen_random_uuid();
  v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_sale_entries integer;
  v_refund_entries integer;
begin
  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values (
    v_wh, 'authenticated', 'authenticated', 'phase6-probe-wh-' || v_suffix || '@test.local',
    '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K',
    now(), now(), now(), '{}'::jsonb, '{}'::jsonb
  )
  on conflict (id) do nothing;

  insert into app.user_profiles(user_id, role, branch_code, region_code, is_active)
  values (v_wh, 'warehouse_controller', 'B1', 'R1', true)
  on conflict (user_id) do update
  set role = excluded.role,
      branch_code = excluded.branch_code,
      region_code = excluded.region_code,
      is_active = excluded.is_active;

  insert into app.parts_master(id, part_no, part_description, product_category, default_selling_price)
  values (v_part, 'P-P6-EXT-' || substr(v_suffix, 1, 8), 'Phase 6 external probe part', 'Testing', 100.00)
  on conflict (id) do nothing;

  perform set_config('request.jwt.claim.sub', v_wh::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into app.sales_vouchers(id, voucher_no, branch_code, region_code, customer_name, status, created_by)
  values (v_voucher, 'SV-P6-EXT-' || v_suffix, 'B1', 'R1', 'External Probe', 'draft', v_wh);
  insert into app.sales_voucher_lines(voucher_id, part_id, quantity, unit_price)
  values (v_voucher, v_part, 1, 100);

  perform app.issue_sales_voucher(v_voucher, 'p6-ext-issue-' || v_suffix);

  -- Simulated external multi-session probe: same idempotency key replay race semantics.
  perform app.pay_sales_voucher(v_voucher, 100, 'EXT', 'p6-ext-pay-race-' || v_suffix);
  begin
    perform app.pay_sales_voucher(v_voucher, 100, 'EXT', 'p6-ext-pay-race-' || v_suffix);
  exception when others then
    null;
  end;

  perform app.refund_sales_voucher(v_voucher, 10, 'EXT', 'p6-ext-refund-race-' || v_suffix);
  begin
    perform app.refund_sales_voucher(v_voucher, 10, 'EXT', 'p6-ext-refund-race-' || v_suffix);
  exception when others then
    null;
  end;

  select count(*)
    into v_sale_entries
  from app.daily_cash_entries
  where voucher_id = v_voucher
    and entry_type = 'sale_payment';

  select count(*)
    into v_refund_entries
  from app.daily_cash_entries
  where voucher_id = v_voucher
    and entry_type = 'refund';

  insert into phase6_external_probe_results
  values (
    'sales_pay_refund_external_multisession_probe',
    v_sale_entries = 1 and v_refund_entries = 1,
    'simulated external multi-session: sale_entries=' || v_sale_entries::text || ', refund_entries=' || v_refund_entries::text
  );
end;
$$;

select probe_name, passed, detail
from phase6_external_probe_results;

rollback;
