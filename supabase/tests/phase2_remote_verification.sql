begin;

create temp table if not exists phase2_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text not null
);

do $$
declare
  v_part_id uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  v_request_id uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  v_tech_id uuid := '11111111-0000-0000-0000-000000000001';
  v_wh_id uuid := '22222222-0000-0000-0000-000000000001';
  v_mgr_id uuid := '33333333-0000-0000-0000-000000000001';
  v_err text;
  v_transition_count integer;
  v_audit_count integer;
begin
  insert into auth.users (
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at,
    raw_app_meta_data,
    raw_user_meta_data
  )
  values
    (v_tech_id, 'authenticated', 'authenticated', 'phase2-tech@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_wh_id, 'authenticated', 'authenticated', 'phase2-wh@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_mgr_id, 'authenticated', 'authenticated', 'phase2-mgr@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
  on conflict (id) do nothing;

  insert into app.user_profiles (user_id, role, branch_code, region_code, is_active)
  values
    (v_tech_id, 'technician', 'B1', 'R1', true),
    (v_wh_id, 'warehouse_controller', 'B1', 'R1', true),
    (v_mgr_id, 'service_manager', 'B1', 'R1', true)
  on conflict (user_id) do update
  set role = excluded.role,
      branch_code = excluded.branch_code,
      region_code = excluded.region_code,
      is_active = excluded.is_active;

  insert into app.parts_master (id, part_no, part_description, product_category, default_selling_price)
  values (v_part_id, 'P-REMOTE-1000', 'Remote Test Part', 'Testing', 10.00)
  on conflict (id) do nothing;

  insert into app.parts_requests (
    id,
    request_no,
    part_id,
    requester_id,
    technician_id,
    branch_code,
    region_code,
    quantity_requested,
    status
  )
  values (
    v_request_id,
    'REQ-REMOTE-1000',
    v_part_id,
    v_tech_id,
    v_tech_id,
    'B1',
    'R1',
    1,
    'pending'
  )
  on conflict (id) do update
  set status = 'pending',
      reason_code = null,
      reason_comment = null;

  -- Test 1: unauthorized access blocked (technician cannot execute status mutation RPC)
  perform set_config('request.jwt.claim.sub', v_tech_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.headers', '{"x-idempotency-key":"idem-unauth-remote"}', true);
  begin
    perform app.update_parts_request_status(
      v_request_id,
      'reserved',
      'TEST',
      'unauthorized role check',
      'idem-unauth-remote'
    );
    insert into phase2_test_results values ('unauthorized_access_blocked', false, 'No exception raised');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase2_test_results values (
        'unauthorized_access_blocked',
        position('Unauthorized role' in v_err) > 0,
        v_err
      );
  end;

  -- Test 2: invalid transition rejected (warehouse pending -> consumed should fail)
  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.headers', '{"x-idempotency-key":"idem-invalid-remote"}', true);
  begin
    perform app.update_parts_request_status(
      v_request_id,
      'consumed',
      'TEST',
      'invalid transition check',
      'idem-invalid-remote'
    );
    insert into phase2_test_results values ('invalid_transition_rejected', false, 'No exception raised');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase2_test_results values (
        'invalid_transition_rejected',
        position('Illegal status transition' in v_err) > 0,
        v_err
      );
  end;

  -- Test 3: idempotent replay no double-post
  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.headers', '{"x-idempotency-key":"idem-replay-remote"}', true);

  perform app.update_parts_request_status(
    v_request_id,
    'reserved',
    'TEST',
    'valid transition',
    'idem-replay-remote'
  );

  perform app.update_parts_request_status(
    v_request_id,
    'reserved',
    'TEST',
    'valid transition',
    'idem-replay-remote'
  );

  select count(*)
    into v_transition_count
  from app.status_transition_log stl
  where stl.table_name = 'parts_requests'
    and stl.record_id = v_request_id
    and stl.from_status = 'pending'
    and stl.to_status = 'reserved';

  insert into phase2_test_results values (
    'idempotent_replay_no_double_post',
    v_transition_count = 1,
    'transition_count=' || v_transition_count::text
  );

  -- Test 4: audit rows created
  select count(*)
    into v_audit_count
  from app.status_transition_log stl
  where stl.table_name = 'parts_requests'
    and stl.record_id = v_request_id;

  insert into phase2_test_results values (
    'audit_rows_created',
    v_audit_count >= 1,
    'audit_count=' || v_audit_count::text
  );
end;
$$;

select test_name, passed, detail
from phase2_test_results
order by test_name;

rollback;
