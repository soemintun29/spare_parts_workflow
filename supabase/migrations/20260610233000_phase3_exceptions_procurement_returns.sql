begin;

alter table app.parts_requests
  add column if not exists return_quantity numeric(14,3) not null default 0 check (return_quantity >= 0),
  add column if not exists discrepancy_quantity numeric(14,3) not null default 0 check (discrepancy_quantity >= 0);

insert into app.status_transition_policy (workflow_name, from_status, to_status, requires_reason, requires_approval)
values
  ('parts_requests', 'discrepancy', 'returned', true, false),
  ('parts_requests', 'discrepancy', 'back_ordered', true, false),
  ('parts_requests', 'discrepancy', 'cancelled', true, true)
on conflict (workflow_name, from_status, to_status) do nothing;

alter table app.purchase_requests
  add column if not exists source_request_id uuid references app.parts_requests(id);

create or replace function app.enqueue_notification(
  p_event_name text,
  p_entity_name text,
  p_entity_id uuid,
  p_recipient_role app.app_role,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  insert into app.notification_queue (
    event_name,
    entity_name,
    entity_id,
    recipient_role,
    payload
  )
  values (
    p_event_name,
    p_entity_name,
    p_entity_id,
    p_recipient_role,
    p_payload
  );
end;
$$;

create or replace function app.mark_out_of_stock(
  p_request_id uuid,
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
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_reason_code is null or length(trim(p_reason_code)) = 0 then
    raise exception 'reason_code is required';
  end if;

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

  perform app.require_action_role('update_parts_request_status');

  select status
    into v_status
  from app.begin_idempotent_operation(
    'mark_out_of_stock',
    p_idempotency_key,
    md5(concat_ws('|', p_request_id::text, p_reason_code, coalesce(p_reason_comment, ''))),
    jsonb_build_object('request_id', p_request_id, 'to_status', 'out_of_stock')
  );

  if v_status = 'succeeded' then
    return v_req;
  end if;

  perform app.require_legal_transition('parts_requests', v_req.status::text, 'out_of_stock');

  update app.parts_requests
  set status = 'out_of_stock',
      reason_code = p_reason_code,
      reason_comment = p_reason_comment,
      updated_at = timezone('utc', now())
  where id = p_request_id
  returning * into v_req;

  if v_req.service_call_id is not null then
    update app.service_calls
    set status = 'back_order',
        reschedule_reason = coalesce(p_reason_comment, p_reason_code),
        updated_at = timezone('utc', now())
    where id = v_req.service_call_id;
  end if;

  perform app.enqueue_notification(
    'out_of_stock',
    'parts_requests',
    v_req.id,
    'dispatcher',
    jsonb_build_object('request_no', v_req.request_no, 'reason_code', p_reason_code)
  );
  perform app.enqueue_notification(
    'out_of_stock',
    'parts_requests',
    v_req.id,
    'technician',
    jsonb_build_object('request_no', v_req.request_no, 'reason_code', p_reason_code)
  );

  perform app.complete_idempotent_operation(
    'mark_out_of_stock',
    p_idempotency_key,
    jsonb_build_object('request_id', v_req.id, 'status', v_req.status)
  );

  return v_req;
exception
  when others then
    perform app.fail_idempotent_operation(
      'mark_out_of_stock',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

create or replace function app.create_purchase_request(
  p_request_id uuid,
  p_quantity numeric,
  p_supplier_ref text,
  p_eta_date date,
  p_idempotency_key text
)
returns app.purchase_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_req app.parts_requests;
  v_pr app.purchase_requests;
  v_status text;
  v_response jsonb;
  v_existing_id uuid;
  v_pr_no text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'quantity must be > 0';
  end if;

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

  perform app.require_action_role('update_parts_request_status');

  select status, response_payload
    into v_status, v_response
  from app.begin_idempotent_operation(
    'create_purchase_request',
    p_idempotency_key,
    md5(concat_ws('|', p_request_id::text, p_quantity::text, coalesce(p_supplier_ref, ''), coalesce(p_eta_date::text, ''))),
    jsonb_build_object('request_id', p_request_id, 'quantity', p_quantity)
  );

  if v_status = 'succeeded' then
    v_existing_id := nullif(v_response ->> 'purchase_request_id', '')::uuid;
    if v_existing_id is not null then
      select * into v_pr from app.purchase_requests where id = v_existing_id;
      if found then
        return v_pr;
      end if;
    end if;
    select *
      into v_pr
    from app.purchase_requests
    where source_request_id = p_request_id
    order by created_at desc
    limit 1;
    return v_pr;
  end if;

  if v_req.status = 'out_of_stock' then
    perform app.require_legal_transition('parts_requests', v_req.status::text, 'back_ordered');
    update app.parts_requests
    set status = 'back_ordered',
        updated_at = timezone('utc', now())
    where id = v_req.id
    returning * into v_req;
  elsif v_req.status <> 'back_ordered' then
    raise exception 'Request must be out_of_stock or back_ordered for purchase request';
  end if;

  v_pr_no := 'PR-' || to_char(timezone('utc', now()), 'YYYYMMDDHH24MISS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);

  insert into app.purchase_requests (
    pr_no,
    part_id,
    requester_id,
    branch_code,
    region_code,
    quantity_requested,
    supplier_ref,
    eta_date,
    status,
    source_request_id
  )
  values (
    v_pr_no,
    v_req.part_id,
    auth.uid(),
    v_req.branch_code,
    v_req.region_code,
    p_quantity,
    p_supplier_ref,
    p_eta_date,
    'created',
    v_req.id
  )
  returning * into v_pr;

  perform app.enqueue_notification(
    'purchase_request_created',
    'purchase_requests',
    v_pr.id,
    'dispatcher',
    jsonb_build_object('pr_no', v_pr.pr_no, 'source_request_id', v_req.id)
  );

  perform app.complete_idempotent_operation(
    'create_purchase_request',
    p_idempotency_key,
    jsonb_build_object('purchase_request_id', v_pr.id, 'pr_no', v_pr.pr_no)
  );

  return v_pr;
exception
  when others then
    perform app.fail_idempotent_operation(
      'create_purchase_request',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

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
      status = case
        when quantity_received + p_received_quantity < quantity_requested then 'partially_received'
        else 'received'
      end,
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

create or replace function app.submit_return(
  p_request_id uuid,
  p_return_quantity numeric,
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
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;
  if p_return_quantity is null or p_return_quantity <= 0 then
    raise exception 'return quantity must be > 0';
  end if;

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

  if app.current_user_role() = 'technician' and v_req.technician_id <> auth.uid() then
    raise exception 'Technician can only submit returns for own requests';
  end if;

  if v_req.status not in ('received', 'partially_received', 'transfer_received') then
    raise exception 'Return can only be submitted from received states';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'submit_return',
    p_idempotency_key,
    md5(concat_ws('|', p_request_id::text, p_return_quantity::text, coalesce(p_reason_code, ''), coalesce(p_reason_comment, ''))),
    jsonb_build_object('request_id', p_request_id, 'return_quantity', p_return_quantity)
  );

  if v_status = 'succeeded' then
    return v_req;
  end if;

  perform app.require_legal_transition('parts_requests', v_req.status::text, 'to_return');

  update app.parts_requests
  set status = 'to_return',
      return_quantity = return_quantity + p_return_quantity,
      reason_code = p_reason_code,
      reason_comment = p_reason_comment,
      updated_at = timezone('utc', now())
  where id = p_request_id
  returning * into v_req;

  perform app.enqueue_notification(
    'return_submitted',
    'parts_requests',
    v_req.id,
    'warehouse_controller',
    jsonb_build_object('request_no', v_req.request_no, 'return_quantity', p_return_quantity)
  );

  perform app.complete_idempotent_operation(
    'submit_return',
    p_idempotency_key,
    jsonb_build_object('request_id', v_req.id, 'status', v_req.status)
  );

  return v_req;
exception
  when others then
    perform app.fail_idempotent_operation(
      'submit_return',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

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

  if v_req.status <> 'to_return' then
    raise exception 'Request is not in to_return status';
  end if;

  if v_req.return_quantity < v_total then
    raise exception 'receive quantity exceeds pending return quantity';
  end if;

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

create or replace function app.resolve_discrepancy(
  p_request_id uuid,
  p_resolution_status app.parts_request_status,
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
  v_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  if p_resolution_status not in ('returned', 'back_ordered', 'cancelled') then
    raise exception 'Unsupported discrepancy resolution status';
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
  if v_req.status <> 'discrepancy' then
    raise exception 'Request is not in discrepancy status';
  end if;

  if not app.can_access_region(v_req.region_code) then
    raise exception 'Unauthorized region access';
  end if;

  select status
    into v_status
  from app.begin_idempotent_operation(
    'resolve_discrepancy',
    p_idempotency_key,
    md5(concat_ws('|', p_request_id::text, p_resolution_status::text, coalesce(p_reason_code, ''), coalesce(p_reason_comment, ''))),
    jsonb_build_object('request_id', p_request_id, 'resolution_status', p_resolution_status)
  );

  if v_status = 'succeeded' then
    return v_req;
  end if;

  perform app.require_legal_transition('parts_requests', v_req.status::text, p_resolution_status::text);

  update app.parts_requests
  set status = p_resolution_status,
      reason_code = p_reason_code,
      reason_comment = p_reason_comment,
      updated_at = timezone('utc', now())
  where id = p_request_id
  returning * into v_req;

  perform app.enqueue_notification(
    'discrepancy_resolved',
    'parts_requests',
    v_req.id,
    'technician',
    jsonb_build_object('request_no', v_req.request_no, 'resolution_status', p_resolution_status)
  );
  perform app.enqueue_notification(
    'discrepancy_resolved',
    'parts_requests',
    v_req.id,
    'dispatcher',
    jsonb_build_object('request_no', v_req.request_no, 'resolution_status', p_resolution_status)
  );

  perform app.complete_idempotent_operation(
    'resolve_discrepancy',
    p_idempotency_key,
    jsonb_build_object('request_id', v_req.id, 'status', v_req.status)
  );

  return v_req;
exception
  when others then
    perform app.fail_idempotent_operation(
      'resolve_discrepancy',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

grant execute on function app.enqueue_notification(text, text, uuid, app.app_role, jsonb) to authenticated;
grant execute on function app.mark_out_of_stock(uuid, text, text, text) to authenticated;
grant execute on function app.create_purchase_request(uuid, numeric, text, date, text) to authenticated;
grant execute on function app.receive_supplier_stock(uuid, numeric, text) to authenticated;
grant execute on function app.submit_return(uuid, numeric, text, text, text) to authenticated;
grant execute on function app.receive_return(uuid, numeric, numeric, text, text, text) to authenticated;
grant execute on function app.resolve_discrepancy(uuid, app.parts_request_status, text, text, text) to authenticated;

commit;
