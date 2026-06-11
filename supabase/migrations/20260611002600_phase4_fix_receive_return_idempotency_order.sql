begin;

create or replace function app.receive_return(
  p_request_id uuid,
  p_good_quantity numeric,
  p_damaged_quantity numeric,
  p_reason_code text,
  p_reason_comment text,
  p_idempotency_key text
)
returns app.parts_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_req app.parts_requests;
  v_total numeric;
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  if coalesce(p_good_quantity, 0) < 0 or coalesce(p_damaged_quantity, 0) < 0 then
    raise exception 'quantities cannot be negative';
  end if;

  v_total := coalesce(p_good_quantity, 0) + coalesce(p_damaged_quantity, 0);
  if v_total <= 0 then
    raise exception 'total received return quantity must be > 0';
  end if;

  perform app.require_action_role('update_parts_request_status');

  select *
    into v_req
  from app.parts_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'parts_request not found';
  end if;

  if not app.can_access_region(v_req.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  -- Idempotency replay must short-circuit before status precondition.
  select status
    into v_status
  from app.begin_idempotent_operation(
    'receive_return',
    p_idempotency_key,
    md5(concat_ws('|', p_request_id::text, p_good_quantity::text, p_damaged_quantity::text, coalesce(p_reason_code, ''), coalesce(p_reason_comment, ''))),
    jsonb_build_object('request_id', p_request_id, 'good_quantity', p_good_quantity, 'damaged_quantity', p_damaged_quantity)
  );

  if v_status = 'succeeded' then
    return v_req;
  end if;

  if v_req.status <> 'to_return' then
    raise exception 'Request is not in to_return status';
  end if;

  if v_req.return_quantity < v_total then
    raise exception 'receive quantity exceeds pending return quantity';
  end if;

  update app.van_stock
  set quantity_held = quantity_held - v_total,
      updated_at = timezone('utc', now())
  where technician_id = v_req.technician_id
    and part_id = v_req.part_id
    and quantity_held >= v_total;

  if not found then
    raise exception 'Insufficient van stock for return receipt';
  end if;

  if p_good_quantity > 0 then
    insert into app.parts_inventory_balance (part_id, branch_code, region_code, stock_on_hand, stock_reserved)
    values (v_req.part_id, v_req.branch_code, v_req.region_code, p_good_quantity, 0)
    on conflict (part_id, branch_code)
    do update set
      stock_on_hand = app.parts_inventory_balance.stock_on_hand + excluded.stock_on_hand,
      updated_at = timezone('utc', now());
  end if;

  if p_damaged_quantity > 0 then
    perform app.require_legal_transition('parts_requests', v_req.status::text, 'discrepancy');
    update app.parts_requests
    set status = 'discrepancy',
        return_quantity = return_quantity - v_total,
        discrepancy_quantity = discrepancy_quantity + p_damaged_quantity,
        reason_code = p_reason_code,
        reason_comment = p_reason_comment,
        updated_at = timezone('utc', now())
    where id = p_request_id
    returning * into v_req;

    perform app.enqueue_notification(
      'return_discrepancy_opened',
      'parts_requests',
      v_req.id,
      'service_manager',
      jsonb_build_object('request_no', v_req.request_no, 'damaged_quantity', p_damaged_quantity)
    );
  else
    perform app.require_legal_transition('parts_requests', v_req.status::text, 'returned');
    update app.parts_requests
    set status = 'returned',
        return_quantity = return_quantity - v_total,
        reason_code = p_reason_code,
        reason_comment = p_reason_comment,
        updated_at = timezone('utc', now())
    where id = p_request_id
    returning * into v_req;
  end if;

  perform app.complete_idempotent_operation(
    'receive_return',
    p_idempotency_key,
    jsonb_build_object('request_id', v_req.id, 'status', v_req.status)
  );

  return v_req;
exception
  when others then
    perform app.fail_idempotent_operation(
      'receive_return',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

commit;
