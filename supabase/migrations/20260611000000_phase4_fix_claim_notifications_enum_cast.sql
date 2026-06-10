begin;

create or replace function app.claim_notifications(
  p_batch_size integer default 20,
  p_worker_id text default 'worker-unknown'
)
returns table (
  id uuid,
  event_name text,
  entity_name text,
  entity_id uuid,
  channel text,
  payload jsonb,
  retries integer
)
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_max_retries integer;
  v_stale_minutes integer;
  v_base_backoff integer;
  v_multiplier integer;
begin
  perform app.require_service_role();

  v_max_retries := app.get_runtime_config_int('notification_max_retries', 5);
  v_stale_minutes := app.get_runtime_config_int('notification_stale_lock_minutes', 15);
  v_base_backoff := app.get_runtime_config_int('notification_backoff_base_seconds', 30);
  v_multiplier := app.get_runtime_config_int('notification_backoff_multiplier', 2);

  with stale_rows as (
    select nq.id, nq.retries
    from app.notification_queue nq
    where nq.status = 'processing'
      and nq.locked_at is not null
      and nq.locked_at < timezone('utc', now()) - make_interval(mins => v_stale_minutes)
    for update skip locked
  ),
  stale_update as (
    update app.notification_queue nq
    set status = (
      case
        when nq.retries + 1 >= v_max_retries then 'dead_letter'
        else 'failed'
      end
    )::app.notification_status,
    retries = nq.retries + 1,
    next_attempt_at = case
      when nq.retries + 1 >= v_max_retries then nq.next_attempt_at
      else timezone('utc', now()) + make_interval(
        secs => greatest(
          0,
          (v_base_backoff * (v_multiplier ^ greatest(0, nq.retries)))::integer
        )
      )
    end,
    last_error = 'stale lock recovered',
    locked_at = null,
    locked_by = null
    from stale_rows sr
    where nq.id = sr.id
    returning nq.id, nq.retries, nq.status
  )
  insert into app.notification_delivery_attempts (
    notification_id,
    worker_id,
    attempt_no,
    outcome,
    error_text,
    finished_at
  )
  select
    su.id,
    p_worker_id,
    su.retries,
    case when su.status = 'dead_letter' then 'dead_letter' else 'stale_recovered' end,
    'stale lock recovered',
    timezone('utc', now())
  from stale_update su;

  return query
  with candidates as (
    select nq.id
    from app.notification_queue nq
    where nq.status in ('queued', 'failed')
      and nq.next_attempt_at <= timezone('utc', now())
      and nq.retries < v_max_retries
    order by nq.next_attempt_at, nq.created_at
    for update skip locked
    limit greatest(1, p_batch_size)
  )
  update app.notification_queue nq
  set status = 'processing',
      locked_at = timezone('utc', now()),
      locked_by = p_worker_id,
      last_attempt_at = timezone('utc', now())
  from candidates c
  where nq.id = c.id
  returning
    nq.id,
    nq.event_name,
    nq.entity_name,
    nq.entity_id,
    nq.channel,
    nq.payload,
    nq.retries;
end;
$$;

commit;
