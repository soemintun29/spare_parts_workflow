# Phase 3 Handover Notes (Current State)

## Applied Migrations (in order)
1. `20260610233000_phase3_exceptions_procurement_returns.sql`
2. `20260610233500_phase3_fix_purchase_status_cast.sql`

## RPCs Added
- `app.enqueue_notification(...)`
- `app.mark_out_of_stock(...)`
- `app.create_purchase_request(...)`
- `app.receive_supplier_stock(...)`
- `app.submit_return(...)`
- `app.receive_return(...)`
- `app.resolve_discrepancy(...)`

## Schema Changes Added
- `app.parts_requests.return_quantity` (numeric, default 0)
- `app.parts_requests.discrepancy_quantity` (numeric, default 0)
- `app.purchase_requests.source_request_id` (uuid -> `app.parts_requests.id`)
- extended transition policy for discrepancy resolution:
  - `discrepancy -> returned`
  - `discrepancy -> back_ordered`
  - `discrepancy -> cancelled`

## Verification Status
- Phase 3 verification script execution failed due to one transition-rule bug.
- No destructive command used.
- No reset/drop/recreate executed.

## Root Cause
`app.receive_supplier_stock(...)` updates `purchase_requests.status` directly from:
- `created -> received` (or `created -> partially_received`)

But legal transition matrix allows:
- `created -> ordered`
- `ordered -> partially_received | received`

So DB trigger `app.enforce_purchase_request_transition()` correctly rejects the invalid direct jump.

## Proposed Fix (Before Retry)
Add a forward migration that updates `app.receive_supplier_stock(...)` to:
1. if current status is `created`, first transition to `ordered`
2. then apply receipt transition to `partially_received` or `received`
3. keep idempotency and audit behavior unchanged

## Open Risks
- Until fix is applied, supplier-receipt flow is blocked for `created` purchase requests.
- Phase 3 verification suite remains partially blocked by this issue.
