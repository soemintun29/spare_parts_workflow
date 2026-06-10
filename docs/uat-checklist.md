# UAT Checklist (Workflow-Based)

## 1) Request & Fulfillment
- [ ] Technician can request valid part by model mapping
- [ ] Warehouse can reserve full quantity
- [ ] Warehouse can reserve partial quantity
- [ ] Technician can receive full/partial quantity
- [ ] Stock postings match accounting rules

## 2) Consumption & Cancellation
- [ ] Technician consumes against service call
- [ ] Pre-reserve edit/cancel works
- [ ] Post-reserve edit/cancel requires approval
- [ ] Post-receipt follows return + new request policy

## 3) Stock-Out & Back-Order
- [ ] Out-of-stock transition updates service call state
- [ ] Dispatcher receives notification
- [ ] Purchase request lifecycle works
- [ ] Supplier receipt triggers allocation

## 4) Returns, Relink, Discrepancy
- [ ] Return request does not reduce van stock immediately
- [ ] Warehouse receive posts good/defective correctly
- [ ] Relink creates no warehouse movement
- [ ] Discrepancy freeze and resolution path works

## 5) Reservation and Transfer Expiry
- [ ] Reservation auto-release after SLA
- [ ] Transfer auto-expiry after SLA
- [ ] Expiry events logged and notified

## 6) Cash Sales
- [ ] Draft voucher validates stock
- [ ] Issued voucher deducts stock
- [ ] Paid voucher posts to daily cash register
- [ ] Void unpaid rolls back correctly
- [ ] Refund paid uses reversal transaction

## 7) Access, Audit, and Reliability
- [ ] Role-based access enforced for all critical actions
- [ ] Audit logs contain required fields
- [ ] Retry with same idempotency key does not double-post
- [ ] No hard delete in operational data paths

## UAT Sign-off
- QA Lead:
- Warehouse Lead:
- Dispatcher Lead:
- Service Manager:
- Product Owner:
- Date: