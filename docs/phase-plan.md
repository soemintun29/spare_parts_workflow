# Delivery Phase Plan

## Phase 0: Bootstrap (Day 1-2)
### Deliverables
- Vite React TS app setup
- Tailwind + Shadcn integrated
- Supabase client setup
- Auth + role route guard skeleton
- Strict lint/type gates in CI

### Exit Criteria
- App builds/runs
- Login and route guarding work
- CI passes lint and typecheck

---

## Phase 1: Data Foundation (Day 2-4)
### Deliverables
- Core tables and indexes
- Status enums + transition policy
- RLS policies by role
- Audit + idempotency + approval tables

### Exit Criteria
- Migrations apply cleanly
- RLS policy tests pass
- Audit writes verified

---

## Phase 2: Core Flow MVP (Week 1-2)
### Scope
- Request part
- Reserve full/partial
- Mark ready
- Receive to van
- Consume against service call
- Cancel/edit rules
- Reservation expiry release

### Exit Criteria
- Workflows 1,2,7,8 pass UAT scenarios
- Stock math and status transitions validated

---

## Phase 3: Exceptions + Procurement (Week 3)
### Scope
- Out-of-stock path
- Back-order purchase request lifecycle
- Supplier receipt + re-allocation
- Return submit/receive
- Discrepancy open/resolution

### Exit Criteria
- Workflows 3,4,5,9 operational with audit and notifications

---

## Phase 4: Advanced Operations (Week 4+)
### Scope
- Van relink flow
- Stock adjustments + approvals
- Cash voucher issue/pay/void/refund
- Tech transfer + handover/receipt/expiry/discrepancy

### Exit Criteria
- Workflows 6,10,11,12/12A complete and tested

---

## Phase 5: Hardening and Go-Live
### Scope
- Performance tuning
- Reports and exception dashboards
- UAT closure
- SOP/training and rollback readiness

### Exit Criteria
- Go-live checklist signed
- Pilot run successful