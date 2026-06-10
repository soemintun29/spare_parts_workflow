begin;

create temp table probe_result (
  observed_status text,
  submit_result text,
  error_text text
);

do $$
declare
  v_part_id uuid := 'aaaaaaaa-0000-0000-0000-000000000201';
  v_return_req_id uuid := 'bbbbbbbb-0000-0000-0000-000000000202';
  v_wh_id uuid := '22222222-0000-0000-0000-000000000201';
  v_tech_id uuid := '11111111-0000-0000-0000-000000000201';
  v_status app.parts_request_status;
  v_setup_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_err text;
begin
  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values
    (v_wh_id, 'authenticated', 'authenticated', 'phase4-probe-wh@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_id, 'authenticated', 'authenticated', 'phase4-probe-tech@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
  on conflict (id) do nothing;

  insert into app.user_profiles(user_id, role, branch_code, region_code, is_active)
  values
    (v_wh_id, 'warehouse_controller', 'B1', 'R1', true),
    (v_tech_id, 'technician', 'B1', 'R1', true)
  on conflict (user_id) do update
  set role = excluded.role, branch_code = excluded.branch_code, region_code = excluded.region_code, is_active = excluded.is_active;

  insert into app.parts_master(id, part_no, part_description, product_category, default_selling_price)
  values (v_part_id, 'P-PHASE4-PROBE', 'Phase 4 Probe Part', 'Testing', 40.00)
  on conflict (id) do nothing;

  insert into app.parts_requests (
    id, request_no, part_id, requester_id, technician_id, branch_code, region_code, quantity_requested, status
  )
  values (
    v_return_req_id, 'REQ-P4-RETURN-PROBE', v_part_id, v_tech_id, v_tech_id, 'B1', 'R1', 2, 'pending'
  )
  on conflict (id) do update
  set status = 'pending', quantity_reserved = 0, quantity_received = 0, return_quantity = 0, discrepancy_quantity = 0;

  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform app.update_parts_request_status(v_return_req_id, 'reserved', null, null, 'probe-ret-status-1-' || v_setup_suffix);
  perform app.update_parts_request_status(v_return_req_id, 'ready_for_pickup', null, null, 'probe-ret-status-2-' || v_setup_suffix);
  perform app.update_parts_request_status(v_return_req_id, 'received', null, null, 'probe-ret-status-3-' || v_setup_suffix);

  select status into v_status from app.parts_requests where id = v_return_req_id;

  perform set_config('request.jwt.claim.sub', v_tech_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform app.submit_return(v_return_req_id, 2, 'RETURN_UNUSED', 'probe', 'probe-submit-1-' || v_setup_suffix);
    insert into probe_result values (v_status::text, 'ok', null);
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into probe_result values (v_status::text, 'error', v_err);
  end;
end;
$$;

select * from probe_result;

rollback;
