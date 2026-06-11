begin;

create temp table if not exists phase4_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text not null
);

do $$
declare
  v_part_id uuid := 'aaaaaaaa-0000-0000-0000-000000000201';
  v_req_id uuid := 'bbbbbbbb-0000-0000-0000-000000000201';
  v_return_req_id uuid;
  v_return_request_no text;
  v_pr_id uuid;
  v_wh_id uuid := '22222222-0000-0000-0000-000000000201';
  v_tech_id uuid := '11111111-0000-0000-0000-000000000201';
  v_notif_id uuid := 'dddddddd-0000-0000-0000-000000000201';
  v_notif2_id uuid := 'dddddddd-0000-0000-0000-000000000202';
  v_notif3_id uuid := 'dddddddd-0000-0000-0000-000000000203';
  v_notif_deadletter_id uuid;
  v_count integer;
  v_err text;
  v_submit_err text;
  v_metrics record;
  v_return_status app.parts_request_status;
  v_receive_status app.parts_request_status;
  v_to_return_qty numeric;
  v_receive_err text;
  v_receive_ok boolean := false;
  v_setup_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_submit_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_receive_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_receive_idem_key text;
  v_submit_ok boolean := false;
begin
  v_return_req_id := gen_random_uuid();
  v_return_request_no := 'REQ-P4-RETURN-' || v_setup_suffix;
  v_notif_deadletter_id := gen_random_uuid();

  insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  )
  values
    (v_wh_id, 'authenticated', 'authenticated', 'phase4-wh@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb),
    (v_tech_id, 'authenticated', 'authenticated', 'phase4-tech@test.local', '$2a$10$7EqJtq98hPqEX7fNZaFWoOHi6V5Pj7o0M7Y5QZnQXtNCmieYw9e7K', now(), now(), now(), '{}'::jsonb, '{}'::jsonb)
  on conflict (id) do nothing;

  insert into app.user_profiles(user_id, role, branch_code, region_code, is_active)
  values
    (v_wh_id, 'warehouse_controller', 'B1', 'R1', true),
    (v_tech_id, 'technician', 'B1', 'R1', true)
  on conflict (user_id) do update
  set role = excluded.role, branch_code = excluded.branch_code, region_code = excluded.region_code, is_active = excluded.is_active;

  insert into app.parts_master(id, part_no, part_description, product_category, default_selling_price)
  values (v_part_id, 'P-PHASE4-1000', 'Phase 4 Part', 'Testing', 40.00)
  on conflict (id) do nothing;

  insert into app.parts_requests (
    id, request_no, part_id, requester_id, technician_id, branch_code, region_code, quantity_requested, status
  )
  values (
    v_req_id, 'REQ-P4-1000', v_part_id, v_tech_id, v_tech_id, 'B1', 'R1', 4, 'pending'
  )
  on conflict (id) do update set status = 'pending', quantity_reserved = 0, quantity_received = 0;

  -- Dedicated return/discrepancy fixture to keep flows independent.
  insert into app.parts_requests (
    id, request_no, part_id, requester_id, technician_id, branch_code, region_code, quantity_requested, status
  )
  values (
    v_return_req_id, v_return_request_no, v_part_id, v_tech_id, v_tech_id, 'B1', 'R1', 2, 'pending'
  )
  on conflict (id) do update
  set status = 'pending',
      quantity_reserved = 0,
      quantity_received = 0,
      return_quantity = 0,
      discrepancy_quantity = 0,
      reason_code = null,
      reason_comment = null;

  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  perform app.mark_out_of_stock(v_req_id, 'NO_STOCK', 'phase4 test', 'p4-oos-1');
  select id into v_pr_id
  from app.create_purchase_request(v_req_id, 4, 'SUP-P4', current_date + 1, 'p4-pr-1');

  -- Idempotent replay safety for supplier receipt
  perform app.receive_supplier_stock(v_pr_id, 4, 'p4-recv-1');
  perform app.receive_supplier_stock(v_pr_id, 4, 'p4-recv-1');

  select count(*)
    into v_count
  from app.status_transition_log stl
  where stl.table_name = 'purchase_requests'
    and stl.record_id = v_pr_id
    and stl.to_status = 'received';

  insert into phase4_test_results values (
    'supplier_receipt_idempotent_replay',
    v_count = 1,
    'received_transition_count=' || v_count::text
  );

  -- Return flow idempotency/concurrency-safe replay on dedicated fixture.
  -- Reach "received" through legal transitions only.
  perform app.update_parts_request_status(v_return_req_id, 'reserved', null, null, 'p4-ret-status-1-' || v_setup_suffix);
  perform app.update_parts_request_status(v_return_req_id, 'ready_for_pickup', null, null, 'p4-ret-status-2-' || v_setup_suffix);
  perform app.update_parts_request_status(v_return_req_id, 'received', null, null, 'p4-ret-status-3-' || v_setup_suffix);

  select status
    into v_return_status
  from app.parts_requests
  where id = v_return_req_id;

  insert into phase4_test_results values (
    'pre_submit_checkpoint_status',
    v_return_status in ('received', 'partially_received', 'transfer_received'),
    'status=' || coalesce(v_return_status::text, 'null')
  );

  if v_return_status not in ('received', 'partially_received', 'transfer_received') then
    insert into phase4_test_results values (
      'submit_return_idempotent_replay',
      false,
      'checkpoint blocked: status=' || coalesce(v_return_status::text, 'null')
    );
    insert into phase4_test_results values (
      'receive_return_idempotent_replay',
      false,
      'not run: pre-submit checkpoint failed'
    );
    insert into phase4_test_results values (
      'notification_dedupe_scope_enforced',
      false,
      'not run: pre-submit checkpoint failed'
    );
    insert into phase4_test_results values (
      'notification_transition_guard',
      false,
      'not run: pre-submit checkpoint failed'
    );
    insert into phase4_test_results values (
      'stale_lock_recovery',
      false,
      'not run: pre-submit checkpoint failed'
    );
    insert into phase4_test_results values (
      'dead_letter_threshold_enforced',
      false,
      'not run: pre-submit checkpoint failed'
    );
    insert into phase4_test_results values (
      'service_role_restriction',
      false,
      'not run: pre-submit checkpoint failed'
    );
    insert into phase4_test_results values (
      'operational_metrics_available',
      false,
      'not run: pre-submit checkpoint failed'
    );
  else

  insert into app.van_stock(technician_id, part_id, branch_code, region_code, quantity_held, quantity_consumed)
  values (v_tech_id, v_part_id, 'B1', 'R1', 2, 0)
  on conflict (technician_id, part_id) do update set quantity_held = 2;

  perform set_config('request.jwt.claim.sub', v_tech_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  begin
    perform app.submit_return(v_return_req_id, 2, 'RETURN_UNUSED', 'phase4 test', 'p4-submit-1-' || v_submit_suffix);
    perform app.submit_return(v_return_req_id, 2, 'RETURN_UNUSED', 'phase4 test', 'p4-submit-1-' || v_submit_suffix);
    v_submit_ok := true;
  exception
    when others then
      get stacked diagnostics v_submit_err = message_text;
      v_submit_ok := false;
  end;

  if not v_submit_ok then
    insert into phase4_test_results values (
      'submit_return_idempotent_replay',
      false,
      'submit_return_exception=' || coalesce(v_submit_err, 'unknown')
    );
    insert into phase4_test_results values (
      'submit_return_exception_detail',
      false,
      coalesce(v_submit_err, 'unknown')
    );
    insert into phase4_test_results values (
      'receive_return_idempotent_replay',
      false,
      'not run: submit_return failed'
    );
    insert into phase4_test_results values (
      'notification_dedupe_scope_enforced',
      false,
      'not run: submit_return failed'
    );
    insert into phase4_test_results values (
      'notification_transition_guard',
      false,
      'not run: submit_return failed'
    );
    insert into phase4_test_results values (
      'stale_lock_recovery',
      false,
      'not run: submit_return failed'
    );
    insert into phase4_test_results values (
      'dead_letter_threshold_enforced',
      false,
      'not run: submit_return failed'
    );
    insert into phase4_test_results values (
      'service_role_restriction',
      false,
      'not run: submit_return failed'
    );
    insert into phase4_test_results values (
      'operational_metrics_available',
      false,
      'not run: submit_return failed'
    );
  else

  select count(*)
    into v_count
  from app.status_transition_log stl
  where stl.table_name = 'parts_requests'
    and stl.record_id = v_return_req_id
    and stl.to_status = 'to_return';

  insert into phase4_test_results values (
    'submit_return_idempotent_replay',
    v_count = 1,
    'to_return_transition_count=' || v_count::text
  );

  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_receive_idem_key := 'p4-receive-return-1-' || v_receive_suffix;

  select status, return_quantity
    into v_receive_status, v_to_return_qty
  from app.parts_requests
  where id = v_return_req_id;

  insert into phase4_test_results values (
    'receive_return_checkpoint_status',
    true,
    'status=' || coalesce(v_receive_status::text, 'null')
  );
  insert into phase4_test_results values (
    'receive_return_checkpoint_to_return_qty',
    true,
    'to_return_qty=' || coalesce(v_to_return_qty::text, 'null')
  );
  insert into phase4_test_results values (
    'receive_return_checkpoint_idempotency_key',
    true,
    'idempotency_key=' || v_receive_idem_key
  );

  begin
    perform app.receive_return(v_return_req_id, 1, 1, 'DAMAGED', 'phase4 test', v_receive_idem_key);
    perform app.receive_return(v_return_req_id, 1, 1, 'DAMAGED', 'phase4 test', v_receive_idem_key);
    v_receive_ok := true;
  exception
    when others then
      get stacked diagnostics v_receive_err = message_text;
      v_receive_ok := false;
  end;

  if not v_receive_ok then
    insert into phase4_test_results values (
      'receive_return_idempotent_replay',
      false,
      'receive_return_exception=' || coalesce(v_receive_err, 'unknown')
    );
    insert into phase4_test_results values (
      'receive_return_exception_detail',
      false,
      coalesce(v_receive_err, 'unknown')
    );
  else

  select count(*)
    into v_count
  from app.status_transition_log stl
  where stl.table_name = 'parts_requests'
    and stl.record_id = v_return_req_id
    and stl.to_status = 'discrepancy';

  insert into phase4_test_results values (
    'receive_return_idempotent_replay',
    v_count = 1,
    'discrepancy_transition_count=' || v_count::text
  );
  end if;

  -- Notification dedupe scope test: channel + recipient + event + entity
  insert into app.notification_queue(id, event_name, entity_name, entity_id, recipient_role, recipient_user_id, payload, channel, status)
  values (
    v_notif_id, 'evt', 'parts_requests', v_req_id, 'technician', v_tech_id, '{}'::jsonb, 'in_app', 'queued'
  )
  on conflict do nothing;

  insert into app.notification_queue(id, event_name, entity_name, entity_id, recipient_role, recipient_user_id, payload, channel, status)
  values (
    v_notif2_id, 'evt', 'parts_requests', v_req_id, 'technician', v_tech_id, '{}'::jsonb, 'in_app', 'queued'
  )
  on conflict do nothing;

  select count(*)
    into v_count
  from app.notification_queue nq
  where nq.channel = 'in_app'
    and nq.event_name = 'evt'
    and nq.entity_name = 'parts_requests'
    and nq.entity_id = v_req_id
    and nq.recipient_user_id = v_tech_id;

  insert into phase4_test_results values (
    'notification_dedupe_scope_enforced',
    v_count = 1,
    'dedupe_row_count=' || v_count::text
  );

  -- Notification state transition enforcement
  insert into app.notification_queue(id, event_name, entity_name, entity_id, recipient_role, payload, channel, status)
  values (
    v_notif3_id, 'evt-2', 'parts_requests', v_req_id, 'dispatcher', '{}'::jsonb, 'in_app', 'queued'
  )
  on conflict do nothing;

  begin
    update app.notification_queue
    set status = 'sent'
    where id = v_notif3_id;
    insert into phase4_test_results values ('notification_transition_guard', false, 'queued->sent allowed unexpectedly');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase4_test_results values (
        'notification_transition_guard',
        position('Illegal notification transition' in v_err) > 0,
        v_err
      );
  end;

  -- Stale lock recovery: set processing row stale and claim
  update app.notification_queue
  set status = 'processing',
      locked_at = timezone('utc', now()) - interval '20 minutes',
      locked_by = 'worker-old',
      retries = 0,
      next_attempt_at = timezone('utc', now())
  where id = v_notif3_id;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000999', true);

  perform app.claim_notifications(10, 'worker-new');

  select count(*)
    into v_count
  from app.notification_delivery_attempts nda
  where nda.notification_id = v_notif3_id
    and nda.outcome in ('stale_recovered', 'dead_letter');

  insert into phase4_test_results values (
    'stale_lock_recovery',
    v_count >= 1,
    'stale_recovery_attempts=' || v_count::text
  );

  -- Dead-letter threshold via repeated failures
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000999', true);

  -- Use a fresh fixture row and deterministic legal transitions:
  -- processing -> failed via mark_notification_failed
  -- failed -> processing via legal update
  insert into app.notification_queue(
    id,
    event_name,
    entity_name,
    entity_id,
    recipient_role,
    payload,
    channel,
    status,
    retries,
    next_attempt_at
  )
  values (
    v_notif_deadletter_id,
    'evt-deadletter',
    'parts_requests',
    v_req_id,
    'dispatcher',
    '{}'::jsonb,
    'sms',
    'processing',
    0,
    timezone('utc', now())
  )
  on conflict do nothing;

  for v_count in 1..6 loop
    perform app.mark_notification_failed(v_notif_deadletter_id, 'worker-fail', 'forced failure');

    exit when exists (
      select 1
      from app.notification_queue nq
      where nq.id = v_notif_deadletter_id
        and nq.status = 'dead_letter'
    );

    update app.notification_queue
    set status = 'processing',
        locked_at = timezone('utc', now()),
        locked_by = 'worker-fail'
    where id = v_notif_deadletter_id
      and status = 'failed';
  end loop;

  select count(*)
    into v_count
  from app.notification_queue nq
  where nq.id = v_notif_deadletter_id
    and nq.status = 'dead_letter';

  insert into phase4_test_results values (
    'dead_letter_threshold_enforced',
    v_count = 1,
    'dead_letter_rows=' || v_count::text
  );

  -- Service-role restriction test
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_wh_id::text, true);
  begin
    perform app.claim_notifications(1, 'worker-auth');
    insert into phase4_test_results values ('service_role_restriction', false, 'claim allowed for non-service role');
  exception
    when others then
      get stacked diagnostics v_err = message_text;
      insert into phase4_test_results values (
        'service_role_restriction',
        position('Service role required' in v_err) > 0,
        v_err
      );
  end;

  -- Metrics check
  select *
    into v_metrics
  from app.get_notification_operational_metrics();

  insert into phase4_test_results values (
    'operational_metrics_available',
    v_metrics.sent_count is not null
      and v_metrics.retry_count is not null
      and v_metrics.dead_letter_count is not null,
    'sent=' || v_metrics.sent_count::text
      || ', retry=' || v_metrics.retry_count::text
      || ', dead=' || v_metrics.dead_letter_count::text
  );
  end if;
  end if;
end;
$$;

select test_name, passed, detail
from phase4_test_results
order by test_name;

rollback;
