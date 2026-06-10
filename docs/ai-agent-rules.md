# AI Agent Implementation Rules

## 1) Transaction and Posting Safety
- Use DB transactions for all multi-table movements.
- Lock rows where needed to prevent race conditions.
- Reject operations that would produce invalid stock states.
- Keep posting logic in RPC/functions, not in frontend.

## 2) Inventory Accounting Rules
- `stock_available = stock_on_hand - stock_reserved`
- Reserve only updates reserved quantity.
- Technician receipt decrements WH reserved/on-hand and increments van held.
- Consumption decrements van held and increments van consumed (with service call link).
- Return request does not reduce van held until warehouse physical receipt.
- Direct cash sale deducts warehouse stock immediately.
- Tech-to-tech transfer must not affect warehouse stock.

## 3) Status and Transition Rules
- Centralize status enums and transition matrix.
- Reject illegal transitions in DB layer.
- Preserve status-before and status-after in logs.
- Implement transfer-specific statuses separately.

## 4) Idempotency Rules
- Require `idempotency_key` on each mutation RPC.
- Store request fingerprint and result linkage.
- Repeat submission with same key must not double-post.

## 5) Audit and Compliance Rules
Each operational event must capture:
- transaction/voucher/reference ID
- part no / qty / unit price (where applicable)
- source and destination
- status before and after
- actor, role, timestamp
- reason/comment
- approval metadata (if required)

## 6) Access and Security Rules
- Enforce RLS by role and branch visibility.
- Recheck role permissions in server-side function layer.
- Never trust client role claims without validation.
- Restrict manager override actions with approval trail.

## 7) Testing Rules
Minimum tests per mutation flow:
- happy path
- invalid transition
- unauthorized access
- idempotency replay
- concurrency conflict
- audit log presence and correctness

## 8) Notification Rules
- Publish domain events from server after successful commits.
- Queue notifications with retry metadata.
- Avoid duplicate sends on retried requests.

## 9) Prohibited Practices
- No direct stock edits from UI.
- No hard deletion of operational records.
- No silent overrides without reason and approver metadata.
- No bypass of audit log writes.