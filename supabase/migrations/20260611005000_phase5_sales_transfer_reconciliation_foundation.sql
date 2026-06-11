begin;

create type app.cash_entry_type as enum (
  'sale_payment',
  'refund',
  'void_reversal'
);

create type app.transfer_status as enum (
  'transfer_pending',
  'transfer_handed_over',
  'transfer_received',
  'transfer_discrepancy',
  'transfer_cancelled',
  'transfer_expired'
);

create table if not exists app.transfer_requests (
  id uuid primary key default gen_random_uuid(),
  transfer_no text not null unique,
  part_id uuid not null references app.parts_master(id),
  source_technician_id uuid not null references app.user_profiles(user_id),
  destination_technician_id uuid not null references app.user_profiles(user_id),
  source_branch_code text not null,
  source_region_code text not null,
  destination_branch_code text not null,
  destination_region_code text not null,
  quantity_requested numeric(14,3) not null check (quantity_requested > 0),
  quantity_locked numeric(14,3) not null default 0 check (quantity_locked >= 0),
  quantity_received numeric(14,3) not null default 0 check (quantity_received >= 0),
  status app.transfer_status not null,
  reason_code text not null,
  reason_comment text,
  lock_released_at timestamptz,
  lock_release_reason text,
  created_by uuid not null references app.user_profiles(user_id),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.van_stock_locks (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references app.transfer_requests(id),
  technician_id uuid not null references app.user_profiles(user_id),
  part_id uuid not null references app.parts_master(id),
  locked_quantity numeric(14,3) not null check (locked_quantity > 0),
  lock_status text not null check (lock_status in ('active', 'released')),
  released_at timestamptz,
  release_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  unique (transfer_id, technician_id, part_id)
);

create table if not exists app.daily_cash_entries (
  id uuid primary key default gen_random_uuid(),
  register_id uuid not null references app.daily_cash_register(id),
  voucher_id uuid not null references app.sales_vouchers(id),
  entry_type app.cash_entry_type not null,
  amount numeric(14,2) not null check (amount >= 0),
  linked_voucher_id uuid references app.sales_vouchers(id),
  created_at timestamptz not null default timezone('utc', now())
);

alter table app.sales_vouchers
  add column if not exists subtotal_amount numeric(14,2) not null default 0 check (subtotal_amount >= 0),
  add column if not exists tax_amount numeric(14,2) not null default 0 check (tax_amount >= 0),
  add column if not exists rounding_amount numeric(14,2) not null default 0,
  add column if not exists paid_amount numeric(14,2) not null default 0 check (paid_amount >= 0),
  add column if not exists refunded_amount numeric(14,2) not null default 0 check (refunded_amount >= 0),
  add column if not exists payment_reference text,
  add column if not exists original_voucher_id uuid references app.sales_vouchers(id),
  add column if not exists reversal_type text check (reversal_type in ('void', 'refund')),
  add column if not exists reversal_reason text;

create index if not exists idx_transfer_requests_status on app.transfer_requests(status, created_at);
create index if not exists idx_transfer_requests_source on app.transfer_requests(source_technician_id, part_id, status);
create index if not exists idx_van_stock_locks_active on app.van_stock_locks(technician_id, part_id, lock_status);
create index if not exists idx_daily_cash_entries_register on app.daily_cash_entries(register_id, entry_type);

insert into app.status_transition_policy (workflow_name, from_status, to_status, requires_reason, requires_approval)
values
  ('sales_vouchers', 'issued', 'cancelled', true, true),
  ('sales_vouchers', 'paid', 'refunded', true, true),
  ('transfer_requests', 'transfer_pending', 'transfer_handed_over', false, false),
  ('transfer_requests', 'transfer_pending', 'transfer_cancelled', true, false),
  ('transfer_requests', 'transfer_pending', 'transfer_expired', true, false),
  ('transfer_requests', 'transfer_handed_over', 'transfer_received', false, false),
  ('transfer_requests', 'transfer_handed_over', 'transfer_discrepancy', true, false),
  ('transfer_requests', 'transfer_handed_over', 'transfer_expired', true, false),
  ('transfer_requests', 'transfer_discrepancy', 'transfer_cancelled', true, true)
on conflict (workflow_name, from_status, to_status) do nothing;

create or replace function app.get_sales_voucher_expected_amount(
  p_voucher_id uuid
)
returns numeric
language sql
stable
as $$
  select coalesce(sv.subtotal_amount, 0) + coalesce(sv.tax_amount, 0) + coalesce(sv.rounding_amount, 0)
  from app.sales_vouchers sv
  where sv.id = p_voucher_id
$$;

create or replace function app.get_sales_voucher_line_total(
  p_voucher_id uuid
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(svl.line_total), 0)
  from app.sales_voucher_lines svl
  where svl.voucher_id = p_voucher_id
$$;

create or replace function app.ensure_sales_voucher_financial_invariants(
  p_voucher_id uuid
)
returns void
language plpgsql
as $$
declare
  v_line_total numeric;
  v_expected_total numeric;
  v_paid numeric;
  v_refunded numeric;
  v_status app.sales_voucher_status;
begin
  select
    app.get_sales_voucher_line_total(p_voucher_id),
    app.get_sales_voucher_expected_amount(p_voucher_id),
    sv.paid_amount,
    sv.refunded_amount,
    sv.status
  into
    v_line_total,
    v_expected_total,
    v_paid,
    v_refunded,
    v_status
  from app.sales_vouchers sv
  where sv.id = p_voucher_id;

  if v_line_total <> coalesce((select subtotal_amount from app.sales_vouchers where id = p_voucher_id), 0) then
    raise exception 'Voucher subtotal must equal line totals';
  end if;

  if v_status = 'paid' and v_paid <> v_expected_total then
    raise exception 'Paid amount must equal expected voucher total';
  end if;

  if v_refunded > v_paid then
    raise exception 'Refund cannot exceed paid amount';
  end if;
end;
$$;

create or replace function app.require_transfer_transition(
  p_from app.transfer_status,
  p_to app.transfer_status
)
returns void
language plpgsql
as $$
begin
  if not exists (
    select 1
    from app.status_transition_policy stp
    where stp.workflow_name = 'transfer_requests'
      and stp.from_status = p_from::text
      and stp.to_status = p_to::text
  ) then
    raise exception 'Illegal transfer transition: % -> %', p_from, p_to;
  end if;
end;
$$;

create or replace function app.transfer_available_unlocked_qty(
  p_technician_id uuid,
  p_part_id uuid
)
returns numeric
language sql
stable
as $$
  with held as (
    select coalesce(vs.quantity_held, 0) as qty
    from app.van_stock vs
    where vs.technician_id = p_technician_id
      and vs.part_id = p_part_id
  ),
  locked as (
    select coalesce(sum(vsl.locked_quantity), 0) as qty
    from app.van_stock_locks vsl
    where vsl.technician_id = p_technician_id
      and vsl.part_id = p_part_id
      and vsl.lock_status = 'active'
  )
  select greatest(0, (select qty from held) - (select qty from locked))
$$;

create or replace function app.ensure_transfer_qty_invariant(
  p_transfer_id uuid
)
returns void
language plpgsql
as $$
declare
  v_transfer app.transfer_requests;
  v_available numeric;
begin
  select * into v_transfer
  from app.transfer_requests tr
  where tr.id = p_transfer_id;

  if not found then
    raise exception 'transfer not found';
  end if;

  v_available := app.transfer_available_unlocked_qty(v_transfer.source_technician_id, v_transfer.part_id);
  if v_transfer.quantity_requested > v_available and v_transfer.status = 'transfer_pending' then
    raise exception 'Transfer quantity exceeds unlocked source quantity';
  end if;
end;
$$;

create or replace function app.issue_sales_voucher(
  p_voucher_id uuid,
  p_idempotency_key text
)
returns app.sales_vouchers
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_sv app.sales_vouchers;
  v_status text;
  v_total numeric;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  select * into v_sv
  from app.sales_vouchers
  where id = p_voucher_id
  for update;

  if not found then
    raise exception 'voucher not found';
  end if;

  if not app.can_access_region(v_sv.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'issue_sales_voucher',
    p_idempotency_key,
    md5(concat_ws('|', p_voucher_id::text, 'issue')),
    jsonb_build_object('voucher_id', p_voucher_id, 'to_status', 'issued')
  );

  if v_status = 'succeeded' then
    return v_sv;
  end if;

  perform app.require_legal_transition('sales_vouchers', v_sv.status::text, 'issued');

  v_total := app.get_sales_voucher_line_total(p_voucher_id);

  update app.sales_vouchers
  set subtotal_amount = v_total,
      total_amount = v_total + tax_amount + rounding_amount,
      status = 'issued',
      issued_at = timezone('utc', now()),
      updated_at = timezone('utc', now())
  where id = p_voucher_id
  returning * into v_sv;

  perform app.ensure_sales_voucher_financial_invariants(v_sv.id);

  perform app.complete_idempotent_operation(
    'issue_sales_voucher',
    p_idempotency_key,
    jsonb_build_object('voucher_id', v_sv.id, 'status', v_sv.status)
  );

  return v_sv;
exception
  when others then
    perform app.fail_idempotent_operation(
      'issue_sales_voucher',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.pay_sales_voucher(
  p_voucher_id uuid,
  p_paid_amount numeric,
  p_payment_reference text,
  p_idempotency_key text
)
returns app.sales_vouchers
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_sv app.sales_vouchers;
  v_status text;
  v_register app.daily_cash_register;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_paid_amount is null or p_paid_amount < 0 then
    raise exception 'paid amount must be non-negative';
  end if;

  select * into v_sv
  from app.sales_vouchers
  where id = p_voucher_id
  for update;

  if not found then
    raise exception 'voucher not found';
  end if;

  if not app.can_access_region(v_sv.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'pay_sales_voucher',
    p_idempotency_key,
    md5(concat_ws('|', p_voucher_id::text, p_paid_amount::text, coalesce(p_payment_reference, ''))),
    jsonb_build_object('voucher_id', p_voucher_id, 'paid_amount', p_paid_amount)
  );

  if v_status = 'succeeded' then
    return v_sv;
  end if;

  perform app.require_legal_transition('sales_vouchers', v_sv.status::text, 'paid');

  if p_paid_amount <> app.get_sales_voucher_expected_amount(p_voucher_id) then
    raise exception 'Paid amount must equal voucher expected amount';
  end if;

  update app.sales_vouchers
  set paid_amount = p_paid_amount,
      payment_reference = p_payment_reference,
      status = 'paid',
      paid_at = timezone('utc', now()),
      updated_at = timezone('utc', now())
  where id = p_voucher_id
  returning * into v_sv;

  perform app.ensure_sales_voucher_financial_invariants(v_sv.id);

  insert into app.daily_cash_register(register_date, branch_code, region_code, expected_cash, physical_cash, discrepancy_amount)
  values (current_date, v_sv.branch_code, v_sv.region_code, 0, null, null)
  on conflict (register_date, branch_code) do nothing;

  select * into v_register
  from app.daily_cash_register dcr
  where dcr.register_date = current_date
    and dcr.branch_code = v_sv.branch_code
  for update;

  update app.daily_cash_register
  set expected_cash = expected_cash + p_paid_amount,
      updated_at = timezone('utc', now())
  where id = v_register.id;

  insert into app.daily_cash_entries(register_id, voucher_id, entry_type, amount)
  values (v_register.id, v_sv.id, 'sale_payment', p_paid_amount);

  perform app.complete_idempotent_operation(
    'pay_sales_voucher',
    p_idempotency_key,
    jsonb_build_object('voucher_id', v_sv.id, 'status', v_sv.status)
  );

  return v_sv;
exception
  when others then
    perform app.fail_idempotent_operation(
      'pay_sales_voucher',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.void_sales_voucher(
  p_voucher_id uuid,
  p_reason text,
  p_idempotency_key text
)
returns app.sales_vouchers
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_sv app.sales_vouchers;
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  select * into v_sv
  from app.sales_vouchers
  where id = p_voucher_id
  for update;

  if not found then
    raise exception 'voucher not found';
  end if;

  if not app.can_access_region(v_sv.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'void_sales_voucher',
    p_idempotency_key,
    md5(concat_ws('|', p_voucher_id::text, coalesce(p_reason, ''))),
    jsonb_build_object('voucher_id', p_voucher_id, 'action', 'void')
  );

  if v_status = 'succeeded' then
    return v_sv;
  end if;

  if v_sv.status <> 'issued' or v_sv.paid_amount > 0 then
    raise exception 'Void allowed only for unpaid issued vouchers';
  end if;

  perform app.require_legal_transition('sales_vouchers', v_sv.status::text, 'cancelled');

  update app.sales_vouchers
  set status = 'cancelled',
      reversal_type = 'void',
      reversal_reason = p_reason,
      updated_at = timezone('utc', now())
  where id = p_voucher_id
  returning * into v_sv;

  perform app.complete_idempotent_operation(
    'void_sales_voucher',
    p_idempotency_key,
    jsonb_build_object('voucher_id', v_sv.id, 'status', v_sv.status)
  );

  return v_sv;
exception
  when others then
    perform app.fail_idempotent_operation(
      'void_sales_voucher',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.refund_sales_voucher(
  p_voucher_id uuid,
  p_refund_amount numeric,
  p_reason text,
  p_idempotency_key text
)
returns app.sales_vouchers
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_sv app.sales_vouchers;
  v_status text;
  v_register app.daily_cash_register;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_refund_amount is null or p_refund_amount <= 0 then
    raise exception 'refund amount must be > 0';
  end if;

  select * into v_sv
  from app.sales_vouchers
  where id = p_voucher_id
  for update;

  if not found then
    raise exception 'voucher not found';
  end if;
  if not app.can_access_region(v_sv.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'refund_sales_voucher',
    p_idempotency_key,
    md5(concat_ws('|', p_voucher_id::text, p_refund_amount::text, coalesce(p_reason, ''))),
    jsonb_build_object('voucher_id', p_voucher_id, 'refund_amount', p_refund_amount)
  );

  if v_status = 'succeeded' then
    return v_sv;
  end if;

  if v_sv.status <> 'paid' then
    raise exception 'Refund allowed only for paid vouchers';
  end if;
  if v_sv.refunded_amount + p_refund_amount > v_sv.paid_amount then
    raise exception 'Refund cannot exceed paid amount';
  end if;

  perform app.require_legal_transition('sales_vouchers', v_sv.status::text, 'refunded');

  update app.sales_vouchers
  set refunded_amount = refunded_amount + p_refund_amount,
      status = 'refunded',
      reversal_type = 'refund',
      reversal_reason = p_reason,
      updated_at = timezone('utc', now())
  where id = p_voucher_id
  returning * into v_sv;

  perform app.ensure_sales_voucher_financial_invariants(v_sv.id);

  select * into v_register
  from app.daily_cash_register dcr
  where dcr.register_date = current_date
    and dcr.branch_code = v_sv.branch_code
  for update;

  if not found then
    raise exception 'Daily cash register missing for refund date/branch';
  end if;

  update app.daily_cash_register
  set expected_cash = expected_cash - p_refund_amount,
      updated_at = timezone('utc', now())
  where id = v_register.id;

  insert into app.daily_cash_entries(register_id, voucher_id, entry_type, amount, linked_voucher_id)
  values (v_register.id, v_sv.id, 'refund', p_refund_amount, v_sv.id);

  perform app.complete_idempotent_operation(
    'refund_sales_voucher',
    p_idempotency_key,
    jsonb_build_object('voucher_id', v_sv.id, 'status', v_sv.status, 'refunded_amount', v_sv.refunded_amount)
  );

  return v_sv;
exception
  when others then
    perform app.fail_idempotent_operation(
      'refund_sales_voucher',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.create_transfer(
  p_part_id uuid,
  p_source_technician_id uuid,
  p_destination_technician_id uuid,
  p_quantity numeric,
  p_reason_code text,
  p_reason_comment text,
  p_idempotency_key text
)
returns app.transfer_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_status text;
  v_transfer app.transfer_requests;
  v_source app.user_profiles;
  v_destination app.user_profiles;
  v_transfer_no text;
  v_available numeric;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'transfer quantity must be > 0';
  end if;

  select * into v_source from app.user_profiles where user_id = p_source_technician_id and is_active = true;
  select * into v_destination from app.user_profiles where user_id = p_destination_technician_id and is_active = true;
  if not found then
    raise exception 'source/destination technician must be active';
  end if;

  if v_source.region_code <> v_destination.region_code then
    raise exception 'cross-region transfer requires override flow';
  end if;

  v_available := app.transfer_available_unlocked_qty(p_source_technician_id, p_part_id);
  if p_quantity > v_available then
    raise exception 'Transfer quantity exceeds available unlocked source qty';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'create_transfer',
    p_idempotency_key,
    md5(concat_ws('|', p_part_id::text, p_source_technician_id::text, p_destination_technician_id::text, p_quantity::text, coalesce(p_reason_code, ''), coalesce(p_reason_comment, ''))),
    jsonb_build_object('part_id', p_part_id, 'source', p_source_technician_id, 'destination', p_destination_technician_id, 'qty', p_quantity)
  );

  if v_status = 'succeeded' then
    select tr.* into v_transfer
    from app.transfer_requests tr
    where tr.created_by = auth.uid()
    order by tr.created_at desc
    limit 1;
    return v_transfer;
  end if;

  v_transfer_no := 'TR-' || to_char(timezone('utc', now()), 'YYYYMMDDHH24MISS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);

  insert into app.transfer_requests(
    transfer_no,
    part_id,
    source_technician_id,
    destination_technician_id,
    source_branch_code,
    source_region_code,
    destination_branch_code,
    destination_region_code,
    quantity_requested,
    quantity_locked,
    status,
    reason_code,
    reason_comment,
    created_by
  )
  values (
    v_transfer_no,
    p_part_id,
    p_source_technician_id,
    p_destination_technician_id,
    v_source.branch_code,
    v_source.region_code,
    v_destination.branch_code,
    v_destination.region_code,
    p_quantity,
    p_quantity,
    'transfer_pending',
    p_reason_code,
    p_reason_comment,
    auth.uid()
  )
  returning * into v_transfer;

  insert into app.van_stock_locks(transfer_id, technician_id, part_id, locked_quantity, lock_status)
  values (v_transfer.id, p_source_technician_id, p_part_id, p_quantity, 'active');

  perform app.complete_idempotent_operation(
    'create_transfer',
    p_idempotency_key,
    jsonb_build_object('transfer_id', v_transfer.id, 'status', v_transfer.status)
  );

  return v_transfer;
exception
  when others then
    perform app.fail_idempotent_operation(
      'create_transfer',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.handover_transfer(
  p_transfer_id uuid,
  p_idempotency_key text
)
returns app.transfer_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_status text;
  v_transfer app.transfer_requests;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  select * into v_transfer
  from app.transfer_requests
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'transfer not found';
  end if;

  if not app.can_access_region(v_transfer.source_region_code) then
    raise exception 'Unauthorized region access';
  end if;

  select status into v_status
  from app.begin_idempotent_operation(
    'handover_transfer',
    p_idempotency_key,
    md5(concat_ws('|', p_transfer_id::text, 'handover')),
    jsonb_build_object('transfer_id', p_transfer_id, 'to_status', 'transfer_handed_over')
  );

  if v_status = 'succeeded' then
    return v_transfer;
  end if;

  perform app.require_transfer_transition(v_transfer.status, 'transfer_handed_over');

  update app.transfer_requests
  set status = 'transfer_handed_over',
      updated_at = timezone('utc', now())
  where id = p_transfer_id
  returning * into v_transfer;

  perform app.complete_idempotent_operation(
    'handover_transfer',
    p_idempotency_key,
    jsonb_build_object('transfer_id', v_transfer.id, 'status', v_transfer.status)
  );

  return v_transfer;
exception
  when others then
    perform app.fail_idempotent_operation(
      'handover_transfer',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.receive_transfer(
  p_transfer_id uuid,
  p_received_quantity numeric,
  p_idempotency_key text
)
returns app.transfer_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_status text;
  v_transfer app.transfer_requests;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_received_quantity is null or p_received_quantity <= 0 then
    raise exception 'received quantity must be > 0';
  end if;

  select * into v_transfer
  from app.transfer_requests
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'transfer not found';
  end if;

  if p_received_quantity > v_transfer.quantity_locked then
    raise exception 'received quantity exceeds locked source quantity';
  end if;

  select status into v_status
  from app.begin_idempotent_operation(
    'receive_transfer',
    p_idempotency_key,
    md5(concat_ws('|', p_transfer_id::text, p_received_quantity::text)),
    jsonb_build_object('transfer_id', p_transfer_id, 'received_qty', p_received_quantity)
  );

  if v_status = 'succeeded' then
    return v_transfer;
  end if;

  perform app.require_transfer_transition(v_transfer.status, 'transfer_received');

  -- Destination stock changes only here.
  insert into app.van_stock(technician_id, part_id, branch_code, region_code, quantity_held, quantity_consumed)
  values (
    v_transfer.destination_technician_id,
    v_transfer.part_id,
    v_transfer.destination_branch_code,
    v_transfer.destination_region_code,
    p_received_quantity,
    0
  )
  on conflict (technician_id, part_id)
  do update set
    quantity_held = app.van_stock.quantity_held + excluded.quantity_held,
    updated_at = timezone('utc', now());

  update app.van_stock
  set quantity_held = quantity_held - p_received_quantity,
      updated_at = timezone('utc', now())
  where technician_id = v_transfer.source_technician_id
    and part_id = v_transfer.part_id
    and quantity_held >= p_received_quantity;

  if not found then
    raise exception 'Insufficient source van stock for transfer receipt';
  end if;

  update app.transfer_requests
  set quantity_received = p_received_quantity,
      status = 'transfer_received',
      lock_released_at = timezone('utc', now()),
      lock_release_reason = 'received',
      updated_at = timezone('utc', now())
  where id = p_transfer_id
  returning * into v_transfer;

  update app.van_stock_locks
  set lock_status = 'released',
      released_at = timezone('utc', now()),
      release_reason = 'received'
  where transfer_id = p_transfer_id
    and lock_status = 'active';

  perform app.complete_idempotent_operation(
    'receive_transfer',
    p_idempotency_key,
    jsonb_build_object('transfer_id', v_transfer.id, 'status', v_transfer.status)
  );

  return v_transfer;
exception
  when others then
    perform app.fail_idempotent_operation(
      'receive_transfer',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.expire_transfer(
  p_transfer_id uuid,
  p_reason text,
  p_idempotency_key text
)
returns app.transfer_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_transfer app.transfer_requests;
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  select * into v_transfer
  from app.transfer_requests
  where id = p_transfer_id
  for update;
  if not found then
    raise exception 'transfer not found';
  end if;

  select status into v_status
  from app.begin_idempotent_operation(
    'expire_transfer',
    p_idempotency_key,
    md5(concat_ws('|', p_transfer_id::text, coalesce(p_reason, ''))),
    jsonb_build_object('transfer_id', p_transfer_id, 'to_status', 'transfer_expired')
  );
  if v_status = 'succeeded' then
    return v_transfer;
  end if;

  perform app.require_transfer_transition(v_transfer.status, 'transfer_expired');

  update app.transfer_requests
  set status = 'transfer_expired',
      lock_released_at = timezone('utc', now()),
      lock_release_reason = coalesce(p_reason, 'expired'),
      updated_at = timezone('utc', now())
  where id = p_transfer_id
  returning * into v_transfer;

  update app.van_stock_locks
  set lock_status = 'released',
      released_at = timezone('utc', now()),
      release_reason = 'expired'
  where transfer_id = p_transfer_id
    and lock_status = 'active';

  perform app.complete_idempotent_operation(
    'expire_transfer',
    p_idempotency_key,
    jsonb_build_object('transfer_id', v_transfer.id, 'status', v_transfer.status)
  );

  return v_transfer;
exception
  when others then
    perform app.fail_idempotent_operation(
      'expire_transfer',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.cancel_transfer(
  p_transfer_id uuid,
  p_reason text,
  p_idempotency_key text
)
returns app.transfer_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_transfer app.transfer_requests;
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  select * into v_transfer
  from app.transfer_requests
  where id = p_transfer_id
  for update;
  if not found then
    raise exception 'transfer not found';
  end if;

  select status into v_status
  from app.begin_idempotent_operation(
    'cancel_transfer',
    p_idempotency_key,
    md5(concat_ws('|', p_transfer_id::text, coalesce(p_reason, ''))),
    jsonb_build_object('transfer_id', p_transfer_id, 'to_status', 'transfer_cancelled')
  );
  if v_status = 'succeeded' then
    return v_transfer;
  end if;

  perform app.require_transfer_transition(v_transfer.status, 'transfer_cancelled');

  update app.transfer_requests
  set status = 'transfer_cancelled',
      lock_released_at = timezone('utc', now()),
      lock_release_reason = coalesce(p_reason, 'cancelled'),
      updated_at = timezone('utc', now())
  where id = p_transfer_id
  returning * into v_transfer;

  update app.van_stock_locks
  set lock_status = 'released',
      released_at = timezone('utc', now()),
      release_reason = 'cancelled'
  where transfer_id = p_transfer_id
    and lock_status = 'active';

  perform app.complete_idempotent_operation(
    'cancel_transfer',
    p_idempotency_key,
    jsonb_build_object('transfer_id', v_transfer.id, 'status', v_transfer.status)
  );

  return v_transfer;
exception
  when others then
    perform app.fail_idempotent_operation(
      'cancel_transfer',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.reconcile_daily_cash_register(
  p_register_id uuid
)
returns app.daily_cash_register
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_register app.daily_cash_register;
  v_expected numeric;
begin
  select * into v_register
  from app.daily_cash_register
  where id = p_register_id
  for update;

  if not found then
    raise exception 'daily cash register not found';
  end if;

  select coalesce(sum(
    case
      when dce.entry_type = 'sale_payment' then dce.amount
      when dce.entry_type in ('refund', 'void_reversal') then -dce.amount
      else 0
    end
  ), 0)
  into v_expected
  from app.daily_cash_entries dce
  where dce.register_id = p_register_id;

  update app.daily_cash_register
  set expected_cash = v_expected,
      discrepancy_amount = case
        when physical_cash is null then null
        else physical_cash - v_expected
      end,
      updated_at = timezone('utc', now())
  where id = p_register_id
  returning * into v_register;

  return v_register;
end;
$$;

alter table app.transfer_requests enable row level security;
alter table app.van_stock_locks enable row level security;
alter table app.daily_cash_entries enable row level security;

create policy transfer_requests_region_read
on app.transfer_requests
for select
to authenticated
using (app.can_access_region(source_region_code) or app.can_access_region(destination_region_code));

create policy transfer_requests_region_write
on app.transfer_requests
for update
to authenticated
using (app.current_user_role() in ('technician', 'warehouse_controller', 'dispatcher', 'service_manager'))
with check (app.current_user_role() in ('technician', 'warehouse_controller', 'dispatcher', 'service_manager'));

create policy van_stock_locks_region_read
on app.van_stock_locks
for select
to authenticated
using (
  exists (
    select 1 from app.transfer_requests tr
    where tr.id = van_stock_locks.transfer_id
      and (app.can_access_region(tr.source_region_code) or app.can_access_region(tr.destination_region_code))
  )
);

create policy daily_cash_entries_region_read
on app.daily_cash_entries
for select
to authenticated
using (
  exists (
    select 1
    from app.daily_cash_register dcr
    where dcr.id = daily_cash_entries.register_id
      and app.can_access_region(dcr.region_code)
      and app.current_user_role() in ('warehouse_controller', 'service_manager', 'finance_admin')
  )
);

grant execute on function app.get_sales_voucher_expected_amount(uuid) to authenticated;
grant execute on function app.get_sales_voucher_line_total(uuid) to authenticated;
grant execute on function app.ensure_sales_voucher_financial_invariants(uuid) to authenticated;
grant execute on function app.require_transfer_transition(app.transfer_status, app.transfer_status) to authenticated;
grant execute on function app.transfer_available_unlocked_qty(uuid, uuid) to authenticated;
grant execute on function app.ensure_transfer_qty_invariant(uuid) to authenticated;
grant execute on function app.issue_sales_voucher(uuid, text) to authenticated;
grant execute on function app.pay_sales_voucher(uuid, numeric, text, text) to authenticated;
grant execute on function app.void_sales_voucher(uuid, text, text) to authenticated;
grant execute on function app.refund_sales_voucher(uuid, numeric, text, text) to authenticated;
grant execute on function app.create_transfer(uuid, uuid, uuid, numeric, text, text, text) to authenticated;
grant execute on function app.handover_transfer(uuid, text) to authenticated;
grant execute on function app.receive_transfer(uuid, numeric, text) to authenticated;
grant execute on function app.expire_transfer(uuid, text, text) to authenticated;
grant execute on function app.cancel_transfer(uuid, text, text) to authenticated;
grant execute on function app.reconcile_daily_cash_register(uuid) to authenticated;

commit;
