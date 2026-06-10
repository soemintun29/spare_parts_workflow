-- Phase 2 verification script
-- Run after applying 20260610225000_phase2_foundation.sql
-- Assumes auth.uid() can be set in your SQL runner/session context.

begin;

-- Seed helper rows (service role context recommended for seeding)
insert into app.user_profiles (user_id, role, branch_code, region_code, is_active)
values
  ('11111111-1111-1111-1111-111111111111', 'technician', 'B1', 'R1', true),
  ('22222222-2222-2222-2222-222222222222', 'warehouse_controller', 'B1', 'R1', true),
  ('33333333-3333-3333-3333-333333333333', 'service_manager', 'B1', 'R1', true),
  ('44444444-4444-4444-4444-444444444444', 'finance_admin', 'B1', 'R1', true)
on conflict (user_id) do nothing;

insert into app.parts_master (id, part_no, part_description, product_category, default_selling_price)
values (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'P-1000',
  'Compressor Motor',
  'Cooling',
  100.00
)
on conflict (part_no) do nothing;

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
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'REQ-1000',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111',
  'B1',
  'R1',
  1,
  'pending'
)
on conflict (request_no) do nothing;

-- TEST 1: Unauthorized access blocked
-- Expect: exception "Unauthorized role for action..."
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select app.update_parts_request_status(
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'reserved',
  'TEST',
  'technician should be blocked',
  'idem-unauth-1'
);

-- TEST 2: Invalid transitions rejected
-- Expect: exception "Illegal status transition..."
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select app.update_parts_request_status(
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'consumed',
  'TEST',
  'invalid jump pending->consumed',
  'idem-invalid-1'
);

-- TEST 3: Idempotent replay no double-post
-- First call: pending -> reserved succeeds
select app.update_parts_request_status(
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'reserved',
  'TEST',
  'first valid update',
  'idem-replay-1'
);
-- Replay call with same key/payload should not create second transition
select app.update_parts_request_status(
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'reserved',
  'TEST',
  'first valid update',
  'idem-replay-1'
);

-- Evidence query: should return 1 row for this idempotency_key in transition log
select
  count(*) as transition_rows_for_replay_key
from app.status_transition_log stl
where stl.idempotency_key = 'idem-replay-1'
  and stl.table_name = 'parts_requests'
  and stl.record_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

-- TEST 4: Audit rows created
-- Evidence query: must be >= 1 for this request record
select
  count(*) as audit_rows_for_request
from app.status_transition_log stl
where stl.table_name = 'parts_requests'
  and stl.record_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

rollback;
