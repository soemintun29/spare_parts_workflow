begin;

create temp table if not exists phase3_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text not null
);

do $$
declare
  v_part_id uuid := 'aaaaaaaa-0000-0000-0000-000000000101';
  v_wh_id uuid := '22222222-0000-0000-0000-000000000101';
  v_tech_id uuid := '11111111-0000-0000-0000-000000000101';
  v_req_id uuid := 'bbbbbbbb-0000-0000-0000-000000000101';
  v_return_req_id uuid := 'bbbbbbbb-0000-0000-0000-000000000102';
  v_van_id uuid := 'cccccccc-0000-0000-0000-000000000101';
  v_err text;
  v_pr app.purchase_requests;
  v_req app.parts_requests;
  v_count integer;
begin
  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values
    (v_tech_id, 'authenticated', 'authenticated', 'phase3-tech@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_wh_id, 'authenticated', 'authenticated', 'phase3-wh@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
  on conflict (id) do nothing;

  insert into app.user_profiles(user_id, role, branch_code, region_code, is_active)
  values
    (v_tech_id, 'technician', 'B1', 'R1', true),
    (v_wh_id, 'warehouse_controller', 'B1', 'R1', true)
  on conflict (user_id) do update
  set role = excluded.role, branch_code = excluded.branch_code, region_code = excluded.region_code, is_active = excluded.is_active;

  insert into app.parts_master(id, part_no, part_description, product_category, default_selling_price)
  values (v_part_id, 'P-PHASE3-1000', 'Phase 3 Part', 'Testing', 20.00)
  on conflict (id) do nothing;

  insert into app.parts_requests (
    id, request_no, part_id, requester_id, technician_id, branch_code, region_code, quantity_requested, status
  )
  values (
    v_req_id, 'REQ-P3-1000', v_part_id, v_tech_id, v_tech_id, 'B1', 'R1', 3, 'pending'
  )
  on conflict (id) do update set status = 'pending', reason_code = null, reason_comment = null;

  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  -- mark_out_of_stock
  v_req := app.mark_out_of_stock(v_req_id, 'NO_STOCK', 'stock unavailable', 'p3-oos-1');
  insert into phase3_test_results values (
    'mark_out_of_stock_sets_status',
    v_req.status = 'out_of_stock',
    'status=' || v_req.status::text
  );

  -- create_purchase_request + idempotent replay
  v_pr := app.create_purchase_request(v_req_id, 3, 'SUP-001', current_date + 3, 'p3-pr-1');
  perform app.create_purchase_request(v_req_id, 3, 'SUP-001', current_date + 3, 'p3-pr-1');
  select count(*)
    into v_count
  from app.purchase_requests
  where source_request_id = v_req_id;
  insert into phase3_test_results values (
    'create_purchase_request_idempotent',
    v_count = 1,
    'purchase_request_count=' || v_count::text
  );

  -- receive_supplier_stock transitions PR and allocates request
  v_pr := app.receive_supplier_stock(v_pr.id, 3, 'p3-recv-supplier-1');
  select *
    into v_req
  from app.parts_requests
  where id = v_req_id;

  insert into phase3_test_results values (
    'receive_supplier_stock_allocates_backorder',
    v_req.status = 'ready_for_pickup' and v_req.quantity_reserved = 3,
    'request_status=' || v_req.status::text || ', reserved=' || v_req.quantity_reserved::text
  );

  -- return flow setup
  insert into app.parts_requests (
    id, request_no, part_id, requester_id, technician_id, branch_code, region_code, quantity_requested, quantity_received, status
  )
  values (
    v_return_req_id, 'REQ-P3-RETURN-1', v_part_id, v_tech_id, v_tech_id, 'B1', 'R1', 2, 2, 'received'
  )
  on conflict (id) do update set status = 'received', quantity_received = 2, return_quantity = 0, discrepancy_quantity = 0;

  insert into app.van_stock(id, technician_id, part_id, branch_code, region_code, quantity_held, quantity_consumed)
  values (v_van_id, v_tech_id, v_part_id, 'B1', 'R1', 2, 0)
  on conflict (technician_id, part_id) do update set quantity_held = 2;

  -- technician submits return
  perform set_config('request.jwt.claim.sub', v_tech_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_req := app.submit_return(v_return_req_id, 2, 'RETURN_UNUSED', 'unused', 'p3-submit-return-1');
  insert into phase3_test_results values (
    'submit_return_sets_to_return',
    v_req.status = 'to_return' and v_req.return_quantity = 2,
    'status=' || v_req.status::text || ', return_qty=' || v_req.return_quantity::text
  );

  -- warehouse receives return with discrepancy
  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_req := app.receive_return(v_return_req_id, 1, 1, 'DAMAGED_FOUND', 'one damaged', 'p3-receive-return-1');
  insert into phase3_test_results values (
    'receive_return_discrepancy',
    v_req.status = 'discrepancy' and v_req.discrepancy_quantity >= 1,
    'status=' || v_req.status::text || ', discrepancy_qty=' || v_req.discrepancy_quantity::text
  );

  -- resolve discrepancy
  v_req := app.resolve_discrepancy(v_return_req_id, 'returned', 'RESOLVED', 'approved resolution', 'p3-resolve-disc-1');
  insert into phase3_test_results values (
    'resolve_discrepancy_to_returned',
    v_req.status = 'returned',
    'status=' || v_req.status::text
  );

  -- notification evidence
  select count(*)
    into v_count
  from app.notification_queue
  where entity_name in ('parts_requests', 'purchase_requests')
    and entity_id in (v_req_id, v_return_req_id, v_pr.id);
  insert into phase3_test_results values (
    'notifications_enqueued',
    v_count >= 3,
    'notification_count=' || v_count::text
  );
end;
$$;

select test_name, passed, detail
from phase3_test_results
order by test_name;

rollback;
