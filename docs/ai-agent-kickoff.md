# AI Agent Kickoff Contract
Version: 1.0  
Project: Spare Parts Operation Workflow (v1.5.2)

## 1) Objective
Build a production-ready web app for spare-parts operations covering:
- Warehouse to technician fulfillment
- Van stock usage and returns
- Back-order procurement
- Direct warehouse cash sales
- Technician-to-technician transfers

Primary goals:
- Accurate warehouse and van inventory
- Full traceability/auditability
- Reliable scheduling under stock constraints
- Controlled and reconcilable cash transactions

## 2) Fixed Tech Stack
- Frontend: React + Vite + TypeScript
- Backend/DB: Supabase (Postgres, Auth, RLS, RPC/Functions)
- UI: Tailwind CSS + Shadcn UI
- Data fetching/state: React Query
- Validation: Zod

## 3) Scope Reference
Source document:
- `SERVICE_PARTS_WORKFLOW_V1.5.2.md`

Use this document as source of truth for:
- statuses
- workflows
- accounting rules
- audit/compliance rules

## 4) Non-Negotiable Engineering Rules
1. All inventory and cash postings must be transactional in DB.
2. UI must never directly mutate stock/cash tables.
3. All write operations must be idempotent (require `idempotency_key`).
4. Status transitions must be centralized and validated.
5. No hard delete for operational records.
6. All mutation events must write immutable audit logs.
7. Enforce role-based access with RLS + server checks.
8. Preserve full before/after status trace for each transition.

## 5) Mandatory Data Entities
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

Plus control tables:
- `status_transition_log`
- `approval_requests`
- `idempotency_keys`
- `notification_queue`

## 6) Build Order (Must Follow)
1. Foundation (project setup, auth, role routing, lint/type gates)
2. DB schema + constraints + indexes + RLS + audit framework
3. Core inventory workflows (request/reserve/receive/consume/cancel/expiry)
4. Exceptions and procurement (stock-out, back-order, return, discrepancy)
5. Advanced modules (relink, adjustments, cash sales, transfers)
6. Reporting, notifications, hardening, UAT readiness

## 7) Done Criteria (Global)
A task is complete only when:
- behavior works end-to-end in UI + DB
- stock math is correct
- idempotency test passes
- authorization/RLS test passes
- audit record exists and is complete
- lint/type/tests pass

## 8) Clarification Protocol
If any required business parameter is missing (SLA, thresholds, reason codes, branch rules, tax/refund policy), stop and ask concise questions before implementation.

## 9) Output Format per Phase
For each phase, provide:
- planned tasks
- implemented changes
- migration/RPC/UI list
- tests executed and result
- open decisions/blockers