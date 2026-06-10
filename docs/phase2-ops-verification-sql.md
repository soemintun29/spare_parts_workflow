# Phase 2 Ops Verification SQL

Run against linked/disposable project after migrations are applied.

## 0) Baseline smoke checks

```sql
select to_regclass('app.parts_requests') as parts_requests,
       to_regclass('app.idempotency_keys') as idempotency_keys,
       to_regclass('app.status_transition_log') as transition_log;
```

## 1) Unauthorized blocked

```sql
-- Expect: "Unauthorized role for action update_parts_request_status"
select set_config('request.jwt.claim.sub', '11111111-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.headers', '{"x-idempotency-key":"ops-unauth-1"}', true);

select app.update_parts_request_status(
  'bbbbbbbb-0000-0000-0000-000000000001',
  'reserved',
  'OPS',
  'unauthorized-check',
  'ops-unauth-1'
);
```

## 2) Invalid transition rejected

```sql
-- Expect: "Illegal status transition for workflow parts_requests: pending -> consumed"
select set_config('request.jwt.claim.sub', '22222222-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.headers', '{"x-idempotency-key":"ops-invalid-1"}', true);

select app.update_parts_request_status(
  'bbbbbbbb-0000-0000-0000-000000000001',
  'consumed',
  'OPS',
  'invalid-transition-check',
  'ops-invalid-1'
);
```

## 3) Idempotency replay safe (no double-post)

```sql
-- First call
select set_config('request.jwt.claim.sub', '22222222-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.headers', '{"x-idempotency-key":"ops-replay-1"}', true);

select app.update_parts_request_status(
  'bbbbbbbb-0000-0000-0000-000000000001',
  'reserved',
  'OPS',
  'replay-check',
  'ops-replay-1'
);

-- Replay same payload+key
select app.update_parts_request_status(
  'bbbbbbbb-0000-0000-0000-000000000001',
  'reserved',
  'OPS',
  'replay-check',
  'ops-replay-1'
);

-- Evidence: should be 1 transition row only
select count(*) as transition_count
from app.status_transition_log
where table_name = 'parts_requests'
  and record_id = 'bbbbbbbb-0000-0000-0000-000000000001'
  and from_status = 'pending'
  and to_status = 'reserved';
```

## 4) Audit rows present

```sql
select count(*) as audit_count
from app.status_transition_log
where table_name = 'parts_requests'
  and record_id = 'bbbbbbbb-0000-0000-0000-000000000001';
```

## One-shot automated run

Use:
- `supabase/tests/phase2_remote_verification.sql`

Command:
```bash
npx supabase db query --linked --file "supabase/tests/phase2_remote_verification.sql" --output json
```
