begin;

create or replace function app.update_parts_request_status(
  p_request_id uuid,
  p_to_status app.parts_request_status,
  p_reason_code text default null,
  p_reason_comment text default null,
  p_idempotency_key text default null
)
returns app.parts_requests
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_req app.parts_requests;
  v_idempotency_key text;
  v_fingerprint text;
  v_idem_status text;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key is required';
  end if;

  select * into v_req
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

  v_idempotency_key := p_idempotency_key;
  v_fingerprint := md5(
    concat_ws(
      '|',
      p_request_id::text,
      p_to_status::text,
      coalesce(p_reason_code, ''),
      coalesce(p_reason_comment, '')
    )
  );

  select status
  into v_idem_status
  from app.begin_idempotent_operation(
    'update_parts_request_status',
    v_idempotency_key,
    v_fingerprint,
    jsonb_build_object(
      'request_id', p_request_id,
      'from_status', v_req.status,
      'to_status', p_to_status
    )
  );

  if v_idem_status = 'succeeded' then
    return v_req;
  end if;

  update app.parts_requests
  set status = p_to_status,
      reason_code = coalesce(p_reason_code, reason_code),
      reason_comment = coalesce(p_reason_comment, reason_comment),
      updated_at = timezone('utc', now())
  where id = p_request_id
  returning * into v_req;

  perform app.complete_idempotent_operation(
    'update_parts_request_status',
    v_idempotency_key,
    jsonb_build_object(
      'request_id', v_req.id,
      'status', v_req.status
    )
  );

  return v_req;
exception
  when others then
    perform app.fail_idempotent_operation(
      'update_parts_request_status',
      coalesce(p_idempotency_key, 'missing'),
      jsonb_build_object('error', sqlerrm)
    );
    raise;
end;
$$;

commit;
