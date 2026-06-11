begin;

create or replace function app.require_phase5_action_role(
  p_action text
)
returns void
language plpgsql
as $$
declare
  v_role app.app_role;
begin
  v_role := app.current_user_role();

  if v_role is null then
    raise exception 'Unauthorized: missing user role';
  end if;

  if p_action in (
    'issue_sales_voucher',
    'pay_sales_voucher',
    'void_sales_voucher',
    'refund_sales_voucher',
    'reconcile_daily_cash_register'
  ) then
    if v_role not in ('warehouse_controller', 'service_manager', 'finance_admin') then
      raise exception 'Unauthorized role for action %', p_action;
    end if;
    return;
  end if;

  if p_action in (
    'create_transfer',
    'handover_transfer',
    'receive_transfer',
    'expire_transfer',
    'cancel_transfer'
  ) then
    if v_role not in ('warehouse_controller', 'dispatcher', 'service_manager') then
      raise exception 'Unauthorized role for action %', p_action;
    end if;
    return;
  end if;

  raise exception 'Unknown phase5 action %', p_action;
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

  perform app.require_phase5_action_role('issue_sales_voucher');

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

  perform app.require_phase5_action_role('pay_sales_voucher');

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

  perform app.require_phase5_action_role('void_sales_voucher');

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

  perform app.require_phase5_action_role('refund_sales_voucher');

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

  if v_sv.status not in ('paid', 'refunded') then
    raise exception 'Refund allowed only for paid/refunded vouchers';
  end if;
  if v_sv.refunded_amount + p_refund_amount > v_sv.paid_amount then
    raise exception 'Refund cannot exceed paid amount';
  end if;

  if v_sv.status = 'paid' then
    perform app.require_legal_transition('sales_vouchers', v_sv.status::text, 'refunded');
  end if;

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

  perform app.require_phase5_action_role('create_transfer');

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

  perform app.require_phase5_action_role('handover_transfer');

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

  perform app.require_phase5_action_role('receive_transfer');

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

  perform app.require_phase5_action_role('expire_transfer');

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

  perform app.require_phase5_action_role('cancel_transfer');

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
  perform app.require_phase5_action_role('reconcile_daily_cash_register');

  select * into v_register
  from app.daily_cash_register
  where id = p_register_id
  for update;

  if not found then
    raise exception 'daily cash register not found';
  end if;

  if not app.can_access_region(v_register.region_code) then
    raise exception 'Unauthorized region access';
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

grant execute on function app.require_phase5_action_role(text) to authenticated;

commit;
