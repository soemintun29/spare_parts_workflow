begin;

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

commit;
