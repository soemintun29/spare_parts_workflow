# Spare Parts Operation Workflow (v1.5.2)

## 1. Overview
This document defines the end-to-end workflow for spare parts operations across:
- Warehouse to Technician fulfillment,
- Technician van stock usage and returns,
- Back-order procurement,
- Direct warehouse cash sales,
- Technician-to-technician transfers.

### Objectives
- Keep inventory accurate in warehouse and technician vans.
- Ensure traceable transactions for each movement and decision.
- Improve scheduling reliability when parts are constrained.
- Ensure daily cash sales are controlled and reconcilable.

---

## 2. Roles

- **Technician**
  - Request, receive, consume, return, relink, and transfer parts.
- **Warehouse Controller**
  - Manage warehouse stock, fulfill requests, process returns, manage back-orders, and run direct part sales.
- **Dispatcher**
  - Reschedule jobs impacted by stock-outs and coordinate urgent transfers.
- **Service Manager (Approver)**
  - Approve exceptions (high-value transfer, stock adjustment, voucher void/refund above threshold).

---

## 3. Core Data Entities

- **`parts_master`**
  - Part master and default commercial info.
- **`part_model_relation`**
  - Mapping table for part-to-model many-to-many relationships.
- **`parts_inventory_balance`**
  - Warehouse stock balances: `stock_on_hand`, `stock_reserved`, `stock_available`.
- **`van_stock`**
  - Technician-held inventory.
- **`parts_requests`**
  - Main transaction/audit table for requests, issue, receive, return, consume, relink, and transfer events.
- **`purchase_requests`**
  - Procurement/back-order process records.
- **`stock_adjustments`**
  - Inventory correction entries with reason and approvals.
- **`sales_vouchers`**
  - Direct warehouse sales header (cash sale).
- **`sales_voucher_lines`**
  - Direct warehouse sales line items.
- **`daily_cash_register`**
  - Daily cash summary and reconciliation record.
- **`service_calls`**
  - Job execution records, assignment, and back-order scheduling states.

---

## 4. Master Data and Required Fields

## 4.1 Part Master (Warehouse)
Required fields:
- Part No
- Part Description
- Product Category
- Selling Price
- Stock on hand
- Stock reserved
- Stock available

### Related model handling
- Use mapping table: **`part_model_relation(part_no, model_code)`**
- Recommended constraints:
  - Unique `(part_no, model_code)`
  - Index on `part_no`
  - Index on `model_code`

## 4.2 Technician Held Inventory (Tech View)
Required fields:
- Part No
- Part Description
- Quantity
- Status labels (Tech UI): `Requested`, `Reserved`, `To Return`

> Note: Backend can maintain richer internal statuses for control and audit while UI shows simplified labels.

---

## 5. Unified Status Model

## 5.1 `parts_requests` statuses
- `requested`
- `pending`
- `reserved`
- `partially_reserved`
- `ready_for_pickup`
- `partially_ready`
- `received`
- `partially_received`
- `to_return`
- `returned`
- `consumed`
- `out_of_stock`
- `back_ordered`
- `cancelled`
- `discrepancy`

### Transfer-specific statuses
- `transfer_pending`
- `transfer_handed_over`
- `transfer_received`
- `transfer_discrepancy`
- `transfer_cancelled`
- `transfer_expired`

## 5.2 `purchase_requests` statuses
- `created`
- `ordered`
- `partially_received`
- `received`
- `closed`
- `cancelled`

## 5.3 `sales_vouchers` statuses
- `draft`
- `issued`
- `paid`
- `cancelled`
- `refunded` (if refund process is enabled)

---

## 6. Inventory Accounting Rules

1. `stock_available = stock_on_hand - stock_reserved`.
2. Reserve operation updates `stock_reserved` only.
3. Technician receipt posts:
   - `stock_reserved` decrement,
   - `stock_on_hand` decrement,
   - `van_stock.quantity_held` increment.
4. Consumption posts:
   - `van_stock.quantity_held` decrement,
   - `van_stock.quantity_consumed` increment,
   - transaction linked to `service_call_id`.
5. Return request (`to_return`) does **not** reduce van stock until WH physically receives.
6. WH return receipt posts:
   - `van_stock.quantity_held` decrement,
   - warehouse stock increment (or quarantine bucket for defective items).
7. Direct warehouse cash sale posts immediate `stock_on_hand` decrement.
8. Technician-to-technician transfer does not change warehouse stock.

---

## 7. Workflows

## Workflow 1: Standard Part Request and Fulfillment

1. Technician requests part from service call context (filtered by `part_model_relation`).
2. System creates request: `requested` / `pending`.
3. WH issues:
   - Full: `reserved` → `ready_for_pickup`
   - Partial: `partially_reserved` → `partially_ready`
4. Technician receives:
   - `received` / `partially_received` and stock movement posted to van.
5. Technician consumes on job completion:
   - `consumed` movement posted.

---

## Workflow 2: Partial Fulfillment Decision

1. WH marks partial quantity ready.
2. Technician decides:
   - Accept partial now; remainder stays `back_ordered`, or
   - Wait full quantity.
3. If no decision in SLA window, apply configured default action.

---

## Workflow 3: Stock-Out / Rejection / Reschedule

1. WH sets request `out_of_stock`.
2. System updates service call:
   - `status = back_order`,
   - unassign technician when required,
   - set `reschedule_reason`.
3. Related technician activity is closed/removed.
4. Dispatcher notified and call returned to scheduling queue.
5. `purchase_requests` is created/linked for replenishment.

---

## Workflow 4: Back-Order Procurement and Replenishment

1. WH converts back-order demand into supplier order (`purchase_requests`).
2. ETA and supplier ref are captured.
3. On supplier receipt:
   - Update `stock_on_hand`,
   - Auto-allocate by priority rules.
4. Requests move to `ready_for_pickup` / `partially_ready`.
5. Dispatcher and technician notified for next action.

---

## Workflow 5: Technician Return to Warehouse

1. Technician submits return (`to_return`) with quantity.
2. WH receives and inspects:
   - Good → return to usable stock.
   - Damaged/defective → quarantine stock.
3. Set `returned` or `discrepancy` with reason.

---

## Workflow 6: Technician Re-link from Van Stock (No WH Movement)

1. Technician selects van item marked `to_return`.
2. Technician assigns new `service_call_id`.
3. System validates available quantity.
4. System closes/adjusts `to_return` quantity and creates relink transaction.
5. No warehouse stock movement.
6. Quantity is consumed later from van during job completion.

---

## Workflow 7: Request Cancellation / Quantity Change

1. Pre-reserve: technician can cancel/edit.
2. Post-reserve: WH approval needed and reserve adjusted.
3. Post-receipt: enforce return + new request flow.
4. Reason, actor, timestamp mandatory for all changes.

---

## Workflow 8: Reservation Expiry and Auto Release

1. `ready_for_pickup` has pickup SLA (e.g., 48h).
2. On expiry:
   - release reserved stock,
   - return request to WH queue,
   - notify technician + dispatcher.
3. Store expiry event in audit logs.

---

## Workflow 9: Discrepancy Handling

1. Qty/condition mismatch marks `discrepancy`.
2. Freeze disputed quantity posting.
3. WH investigates and resolves:
   - correction, reissue, cancellation, or adjustment.
4. Record root cause and approver (if needed).

---

## Workflow 10: Stock Adjustment and Cycle Count

1. Perform periodic cycle count.
2. Variance creates `stock_adjustments` with reason code.
3. Threshold-based approval required.
4. Approved posting updates inventory and reconciliation log.

---

## Workflow 11: Direct Warehouse Part Sales (Cash)

1. Create voucher (`draft`) with part, qty, price.
2. Validate stock availability.
3. Issue voucher (`issued`) and deduct `stock_on_hand`.
4. Receive cash and finalize voucher (`paid`).
5. Post to `daily_cash_register`.
6. End-of-day reconcile physical cash vs expected.
7. Controls:
   - `draft` cancel allowed,
   - `issued` unpaid can be voided with rollback,
   - `paid` requires refund transaction (no delete).

---

## Workflow 12: Technician-to-Technician Transfer

1. Source technician creates transfer for part + qty + reason.
2. System validates source van quantity and lock conditions.
3. Transfer record created with `transfer_pending`.
4. Source confirms handover (`transfer_handed_over`).
5. Destination confirms receipt:
   - source van decreases,
   - destination van increases,
   - status `transfer_received`.
6. Destination may relink received qty to a service call.
7. If mismatch/reject: `transfer_discrepancy`.

---

## Workflow 12A: Control Rules for Technician-to-Technician Transfer

1. **Eligibility**
   - Both technicians must be active.
   - Same branch/region required (manager override optional).
2. **Inventory locks**
   - Block transfer of qty already consumed, returned, adjusted, or in another active transfer.
3. **Approval and visibility**
   - Dispatcher + WH can view all transfers.
   - High qty/value transfer requires manager approval.
4. **Mandatory references**
   - Reason code required.
   - Target `service_call_id` recommended at create and required before final consumption.
5. **Two-step confirmation**
   - Source handover + destination receipt required.
   - No stock movement to destination until destination confirms.
6. **Expiry**
   - `transfer_pending` auto-expires (e.g., 24h) if unconfirmed.
7. **Cancellation/discrepancy**
   - Cancellation allowed before destination confirmation.
   - Discrepancy reasons required and routed to WH/manager.
8. **Financial control**
   - No cash posting and no sales voucher for transfer.
9. **Audit**
   - Keep non-deletable event log with actors, timestamps, quantities, reason, branch, approvals.
10. **Monitoring**
   - Daily transfer report + exception report for overdue/high-risk patterns.

---

## 8. Allocation and Prioritization Rules

When stock is constrained:
1. Emergency/SLA-critical jobs.
2. Oldest back-order demand.
3. Nearest planned schedule date.
4. Approved manager override (must be logged).

---

## 9. Notifications (Minimum Required)

- New request → Warehouse Controller
- Ready/partially ready → Technician
- Out-of-stock/back-order → Dispatcher + Technician
- Back-order replenished/ready → Dispatcher + Technician
- Reservation expiry reminder → Technician (+ optional Dispatcher)
- Discrepancy open/resolved → WH + Technician (+ Manager optional)
- Paid sales voucher (optional) → Finance/Admin
- Cash not reconciled EOD → WH + Manager
- Transfer pending/received/expired/discrepancy → Source + Destination + WH + Dispatcher (as configured)

---

## 10. Audit and Compliance Requirements

For each transaction/voucher, record:
- transaction ID / voucher no,
- part no, qty, unit price (if sales),
- source location and destination location,
- status before and after,
- actor, role, timestamp,
- reason/comment for reject/cancel/adjust/discrepancy/transfer,
- approval metadata where required.

Rules:
- No hard delete for operational records.
- Use status transitions and reversal transactions.

---

## 11. Integration and Technical Rules

- Keep status enums centralized across frontend, backend, DB constraints.
- Use atomic DB transactions for multi-table movement postings.
- API/RPC must be idempotent (retry-safe).
- Maintain transaction references for ERP/SAP reconciliation.
- Standardize naming