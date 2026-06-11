# Phase 4 Final Handover

## Outcome
Phase 4 accepted with notification reliability hardening, service-role worker gating, stale-lock recovery, dedupe scope enforcement, transition guards, operational metrics, and stabilized verification harness.

## Migration List (Ordered) and Purpose
1. `20260610235500_phase4_notification_reliability_and_metrics.sql`
   - Added runtime notification policy config (`max_retries`, backoff base/multiplier, stale lock minutes).
   - Added `notification_delivery_attempts`, `notification_state_policy`.
   - Added notification transition guard trigger.
   - Added service-role worker functions and metrics function.
   - Added notification dedupe unique scope.
2. `20260610235800_phase4_fix_enqueue_notification_overload.sql`
   - Removed ambiguous overloaded enqueue signature and kept one canonical function.
3. `20260610235900_phase4_fix_submit_return_idempotency_order.sql`
   - Fixed idempotent replay order in `submit_return` (replay short-circuit before precondition gate).
4. `20260611000000_phase4_fix_claim_notifications_enum_cast.sql`
   - Fixed enum cast in `claim_notifications` stale-lock branch.
5. `20260611001800_phase4_fix_claim_notifications_service_role_gate.sql`
   - Enforced `service_role` claim gate in `claim_notifications` on all execution paths.
6. `20260611002600_phase4_fix_receive_return_idempotency_order.sql`
   - Fixed idempotent replay order in `receive_return` (replay short-circuit before `to_return` status gate).
7. `20260611003200_phase4_fix_mark_notification_failed_enum_cast.sql`
   - Fixed enum cast in `mark_notification_failed` status assignment branch.

## Final Verification Output Summary (All Checks)
Command:
- `npx supabase db query --linked --file "supabase/tests/phase4_verification.sql" --output json`

Final status:
- `supplier_receipt_idempotent_replay`: PASS
- `pre_submit_checkpoint_status`: PASS
- `submit_return_idempotent_replay`: PASS
- `receive_return_checkpoint_status`: PASS
- `receive_return_checkpoint_to_return_qty`: PASS
- `receive_return_checkpoint_idempotency_key`: PASS
- `receive_return_idempotent_replay`: PASS
- `notification_dedupe_scope_enforced`: PASS
- `notification_transition_guard`: PASS
- `stale_lock_recovery`: PASS
- `dead_letter_threshold_enforced`: PASS
- `service_role_restriction`: PASS
- `operational_metrics_available`: PASS

## Production Defects Fixed and Why
1. **Notification worker enum cast defects**
   - Affected: `claim_notifications`, `mark_notification_failed`
   - Cause: `CASE` text result assigned into enum `notification_status` column without explicit cast.
   - Fix: explicit `::app.notification_status` cast.
2. **Service-role enforcement gap**
   - Affected: `claim_notifications`
   - Cause: worker function path allowed non-service claims in test evidence path.
   - Fix: explicit `request.jwt.claim.role = 'service_role'` guard in function body.
3. **Idempotency replay precondition order defects**
   - Affected: `submit_return`, `receive_return`
   - Cause: precondition checks executed before idempotency short-circuit; replay failed after first successful state change.
   - Fix: run idempotency begin + replay return before precondition gating.

## Deferred Item
- **Zero-state replay proof is deferred** until a disposable Supabase environment is available.
