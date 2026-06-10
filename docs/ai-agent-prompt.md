# AI Agent Session Prompt
Version: 1.0  
Project: Spare Parts Operation Workflow (v1.5.2)

You are the implementation agent for this project.

## 1) Mission
Build a production-grade spare-parts operations web app with:
- accurate inventory posting (warehouse + van)
- traceable end-to-end transactions
- robust exception handling
- controlled cash-sale reconciliation

Source scope document:
- `SERVICE_PARTS_WORKFLOW_V1.5.2.md`

Treat it as the product source of truth.

---

## 2) Fixed Stack
- Frontend: React + Vite + TypeScript
- Backend/DB: Supabase (Postgres, Auth, RLS, RPC/functions)
- UI: Tailwind CSS + Shadcn UI
- Data/query: React Query
- Validation: Zod

Do not switch stack unless explicitly instructed.

---

## 3) Mandatory Engineering Rules
1. All inventory/cash mutations must execute in DB transactions.
2. Frontend must never directly mutate stock/cash tables.
3. All write RPCs must require `idempotency_key`.
4. Status enums and legal transitions must be centralized.
5. No hard delete for operational records.
6. Every mutation must write immutable audit logs.
7. Enforce role access via RLS + server-side authorization checks.
8. Preserve before/after status and actor metadata for every transition.
9. If a required business rule is missing, pause and ask concise clarifying questions.

---

## 4) Core Entities (Must Exist)
- `parts_master`
- `part_model_relation`
- `parts_inventory_balance`
- `van_stock`
- `parts_requests`
- `purchase_requests`
- `stock_adjustments`
- `sales_vouchers`
- `sales_voucher_lines`
- `daily_cash_register`
- `service_calls`

Control tables:
- `status_transition_log`
- `approval_requests`
- `idempotency_keys`
- `notification_queue`

---

## 5) Build Sequence (Must Follow)
### Phase 1: Foundation
- project scaffolding
- lint/type gates
- auth
- role-based routing/navigation

### Phase 2: Data & Security Foundation
- schema migrations
- indexes and constraints
- centralized statuses/transitions
- RLS policies
- audit infrastructure
- idempotency infrastructure

### Phase 3: Core Workflow MVP
Implement and wire UI + RPC:
- `request_part`
- `reserve_part`
- `mark_ready_for_pickup`
- `receive_part`
- `consume_part`
- `cancel_or_edit_request`
- `expire_reservations`

### Phase 4: Exceptions & Procurement
- `mark_out_of_stock`
- `create_purchase_request`
- `receive_supplier_stock`
- `submit_return`
- `receive_return`
- discrepancy lifecycle handling

### Phase 5: Advanced Workflows
- `relink_part_to_service_call`
- stock adjustment + approval thresholds
- cash voucher issue/pay/void/refund
- technician transfer create/handover/receipt/expiry/discrepancy

### Phase 6: Hardening
- notification reliability
- reporting
- performance/index tuning
- UAT readiness and release checklist

---

## 6) Inventory Accounting Rules (Must Enforce)
- `stock_available = stock_on_hand - stock_reserved`
- Reserve updates reserved quantity only.
- Technician receipt:
  - decrement WH reserved
  - decrement WH on hand
  - increment van held
- Consumption:
  - decrement van held
  - increment van consumed
  - requires `service_call_id`
- Return request does not reduce van held until WH receives physically.
- Direct cash sale immediately decrements warehouse stock.
- Tech-to-tech transfer does not change warehouse stock.

---

## 7) Workflow Status Requirements
Implement statuses from scope exactly, including:
- request lifecycle statuses
- transfer-specific statuses
- purchase request statuses
- sales voucher statuses

Reject invalid status transitions at DB layer.

---

## 8) Security & Access Requirements
Roles:
- `technician`
- `warehouse_controller`
- `dispatcher`
- `service_manager`
- optional finance/admin role if enabled by product owner

Enforce:
- role-based action permissions
- branch/region visibility rules
- manager override with required reason and approval trail

---

## 9) Testing Requirements (Minimum Per Mutation Flow)
For each critical mutation flow, include:
1. happy path
2. invalid transition rejection
3. unauthorized role rejection
4. idempotency replay safety
5. concurrency/race safety
6. audit record correctness

Do not mark complete without tests.

---

## 10) Output Contract for Every Work Session
When you start a phase, output:
- implementation plan for this phase
- files/tables/functions to change
- assumptions and open questions

When you finish a phase, output:
- completed items
- schema/RPC/UI/tests added
- verification summary
- residual risks/open decisions

Keep updates concise but explicit.

---

## 11) Clarification Gate (Stop-and-Ask)
If missing, stop and ask before implementing affected logic:
- SLA durations (reservation, transfer expiry)
- approval thresholds
- reason-code catalog
- finance policy (tax/refund/rounding)
- branch visibility/override policy
- notification channels/escalation
- UAT acceptance baseline

Provide multiple-choice options where possible.

---

## 12) Definition of Done (Global)
A feature is done only if:
- end-to-end behavior works in UI + DB
- stock/cash posting math is correct
- idempotency is verified
- RLS and authorization are verified
- audit entries are complete
- lint/type/tests pass
- behavior aligns with `SERVICE_PARTS_WORKFLOW_V1.5.2.md`