begin;

create or replace function app.receive_supplier_stock(
  p_purchase_request_id uuid,
  p_received_quantity numeric,
  p_idempotency_key text
)
returns app.purchase_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_pr app.purchase_requests;
  v_status text;
  v_remaining numeric;
  v_backorder app.parts_requests;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_received_quantity is null or p_received_quantity <= 0 then
    raise exception 'received quantity must be > 0';
  end if;

  select *
    into v_pr
  from app.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'purchase_request not found';
  end if;

  if not app.can_access_region(v_pr.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  perform app.require_action_role('update_parts_request_status');

  select status
    into v_status
  from app.begin_idempotent_operation(
    'receive_supplier_stock',
    p_idempotency_key,
    md5(concat_ws('|', p_purchase_request_id::text, p_received_quantity::text)),
    jsonb_build_object('purchase_request_id', p_purchase_request_id, 'received_quantity', p_received_quantity)
  );

  if v_status = 'succeeded' then
    return v_pr;
  end if;

  insert into app.parts_inventory_balance (part_id, branch_code, region_code, stock_on_hand, stock_reserved)
  values (v_pr.part_id, v_pr.branch_code, v_pr.region_code, p_received_quantity, 0)
  on conflict (part_id, branch_code)
  do update set
    stock_on_hand = app.parts_inventory_balance.stock_on_hand + excluded.stock_on_hand,
    updated_at = timezone('utc', now());

  update app.purchase_requests
  set quantity_received = quantity_received + p_received_quantity,
      status = (
        case
          when quantity_received + p_received_quantity < quantity_requested then 'partially_received'
          else 'received'
        end
      )::app.purchase_request_status,
      updated_at = timezone('utc', now())
  where id = v_pr.id
  returning * into v_pr;

  v_remaining := p_received_quantity;

  for v_backorder in
    select *
    from app.parts_requests
    where part_id = v_pr.part_id
      and branch_code = v_pr.branch_code
      and region_code = v_pr.region_code
      and status = 'back_ordered'
    order by created_at
  loop
    exit when v_remaining <= 0;
    if v_backorder.quantity_requested <= v_remaining then
      perform app.require_legal_transition('parts_requests', v_backorder.status::text, 'ready_for_pickup');
      update app.parts_requests
      set status = 'ready_for_pickup',
          quantity_reserved = quantity_requested,
          updated_at = timezone('utc', now())
      where id = v_backorder.id;

      update app.parts_inventory_balance
      set stock_reserved = stock_reserved + v_backorder.quantity_requested,
          updated_at = timezone('utc', now())
      where part_id = v_pr.part_id
        and branch_code = v_pr.branch_code;

      v_remaining := v_remaining - v_backorder.quantity_requested;

      perform app.enqueue_notification(
        'back_order_ready_for_pickup',
        'parts_requests',
        v_backorder.id,
        'technician',
        jsonb_build_object('request_no', v_backorder.request_no)
      );
      perform app.enqueue_notification(
        'back_order_ready_for_pickup',
        'parts_requests',
        v_backorder.id,
        'dispatcher',
        jsonb_build_object('request_no', v_backorder.request_no)
      );
    end if;
  end loop;

  perform app.complete_idempotent_operation(
    'receive_supplier_stock',
    p_idempotency_key,
    jsonb_build_object('purchase_request_id', v_pr.id, 'status', v_pr.status)
  );

  return v_pr;
exception
  when others then
    perform app.fail_idempotent_operation(
      'receive_supplier_stock',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

commit;
