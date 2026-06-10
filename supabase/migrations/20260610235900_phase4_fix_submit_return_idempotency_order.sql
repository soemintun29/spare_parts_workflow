begin;

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

  -- Idempotency must be checked before status precondition so replay does not
  -- fail after first success moved the row out of "received" states.
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

  if v_req.status not in ('received', 'partially_received', 'transfer_received') then
    raise exception 'Return can only be submitted from received states';
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

commit;
