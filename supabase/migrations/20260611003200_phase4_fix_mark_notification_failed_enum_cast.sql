begin;

create or replace function app.mark_notification_failed(
  p_notification_id uuid,
  p_worker_id text default 'worker-unknown',
  p_error_text text default 'delivery failed'
)
returns app.notification_queue
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_row app.notification_queue;
  v_max_retries integer;
  v_base_backoff integer;
  v_multiplier integer;
  v_attempt_no integer;
begin
  perform app.require_service_role();

  v_max_retries := app.get_runtime_config_int('notification_max_retries', 5);
  v_base_backoff := app.get_runtime_config_int('notification_backoff_base_seconds', 30);
  v_multiplier := app.get_runtime_config_int('notification_backoff_multiplier', 2);

  select *
    into v_row
  from app.notification_queue nq
  where nq.id = p_notification_id
    and nq.status = 'processing'
  for update;

  if not found then
    raise exception 'Notification % is not in processing state', p_notification_id;
  end if;

  v_attempt_no := v_row.retries + 1;

  update app.notification_queue
  set retries = retries + 1,
      status = (
        case
          when retries + 1 >= v_max_retries then 'dead_letter'
          else 'failed'
        end
      )::app.notification_status,
      next_attempt_at = case
        when retries + 1 >= v_max_retries then next_attempt_at
        else timezone('utc', now()) + make_interval(
          secs => greatest(
            0,
            (v_base_backoff * (v_multiplier ^ greatest(0, retries)))::integer
          )
        )
      end,
      last_error = p_error_text,
      locked_at = null,
      locked_by = null,
      processed_at = case when retries + 1 >= v_max_retries then timezone('utc', now()) else processed_at end
  where id = p_notification_id
  returning * into v_row;

  insert into app.notification_delivery_attempts (
    notification_id,
    worker_id,
    attempt_no,
    outcome,
    error_text,
    finished_at
  )
  values (
    p_notification_id,
    p_worker_id,
    v_attempt_no,
    case when v_row.status = 'dead_letter' then 'dead_letter' else 'failed' end,
    p_error_text,
    timezone('utc', now())
  );

  return v_row;
end;
$$;

commit;
