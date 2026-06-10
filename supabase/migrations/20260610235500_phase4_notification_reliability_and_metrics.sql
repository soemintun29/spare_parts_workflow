begin;

create table if not exists app.system_runtime_config (
  config_key text primary key,
  config_value jsonb not null,
  description text,
  updated_at timestamptz not null default timezone('utc', now())
);

insert into app.system_runtime_config (config_key, config_value, description)
values
  ('notification_max_retries', '{"value": 5}'::jsonb, 'Maximum delivery retries before dead-letter.'),
  ('notification_backoff_base_seconds', '{"value": 30}'::jsonb, 'Base backoff seconds for retry scheduling.'),
  ('notification_backoff_multiplier', '{"value": 2}'::jsonb, 'Exponential multiplier for retry backoff.'),
  ('notification_stale_lock_minutes', '{"value": 15}'::jsonb, 'Stale processing lock threshold in minutes.')
on conflict (config_key) do nothing;

create or replace function app.get_runtime_config_int(
  p_key text,
  p_default integer
)
returns integer
language sql
stable
as $$
  select coalesce((src.config_value ->> 'value')::integer, p_default)
  from app.system_runtime_config src
  where src.config_key = p_key
  union all
  select p_default
  where not exists (select 1 from app.system_runtime_config src2 where src2.config_key = p_key)
  limit 1
$$;

alter table app.notification_queue
  add column if not exists channel text not null default 'in_app',
  add column if not exists locked_at timestamptz,
  add column if not exists locked_by text,
  add column if not exists last_attempt_at timestamptz;

create unique index if not exists uq_notification_dedupe_scope
on app.notification_queue (
  channel,
  recipient_user_id,
  recipient_role,
  event_name,
  entity_name,
  entity_id
)
nulls not distinct;

create table if not exists app.notification_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references app.notification_queue(id),
  worker_id text not null,
  attempt_no integer not null check (attempt_no > 0),
  outcome text not null check (outcome in ('sent', 'failed', 'dead_letter', 'stale_recovered')),
  error_text text,
  started_at timestamptz not null default timezone('utc', now()),
  finished_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists idx_notification_attempts_notification_id on app.notification_delivery_attempts(notification_id, created_at desc);
create index if not exists idx_notification_queue_retry_poll on app.notification_queue(status, next_attempt_at);

create table if not exists app.notification_state_policy (
  id uuid primary key default gen_random_uuid(),
  from_status app.notification_status not null,
  to_status app.notification_status not null,
  unique (from_status, to_status)
);

insert into app.notification_state_policy (from_status, to_status)
values
  ('queued', 'processing'),
  ('failed', 'processing'),
  ('processing', 'sent'),
  ('processing', 'failed'),
  ('processing', 'dead_letter')
on conflict (from_status, to_status) do nothing;

create or replace function app.require_notification_transition(
  p_from_status app.notification_status,
  p_to_status app.notification_status
)
returns void
language plpgsql
as $$
begin
  if p_from_status = p_to_status then
    return;
  end if;

  if not exists (
    select 1
    from app.notification_state_policy nsp
    where nsp.from_status = p_from_status
      and nsp.to_status = p_to_status
  ) then
    raise exception 'Illegal notification transition: % -> %', p_from_status, p_to_status;
  end if;
end;
$$;

create or replace function app.enforce_notification_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status is distinct from new.status then
    perform app.require_notification_transition(old.status, new.status);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notification_queue_transition on app.notification_queue;
create trigger trg_notification_queue_transition
before update on app.notification_queue
for each row
execute function app.enforce_notification_transition();

create or replace function app.require_service_role()
returns void
language plpgsql
as $$
declare
  v_claim_role text;
begin
  v_claim_role := coalesce(current_setting('request.jwt.claim.role', true), '');
  if v_claim_role = 'service_role' then
    return;
  end if;

  if current_user in ('postgres', 'service_role') then
    return;
  end if;

  raise exception 'Service role required';
end;
$$;

create or replace function app.enqueue_notification(
  p_event_name text,
  p_entity_name text,
  p_entity_id uuid,
  p_recipient_role app.app_role,
  p_payload jsonb default '{}'::jsonb,
  p_channel text default 'in_app',
  p_recipient_user_id uuid default null
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
    recipient_user_id,
    payload,
    channel
  )
  values (
    p_event_name,
    p_entity_name,
    p_entity_id,
    p_recipient_role,
    p_recipient_user_id,
    p_payload,
    p_channel
  )
  on conflict (channel, recipient_user_id, recipient_role, event_name, entity_name, entity_id)
  do nothing;
end;
$$;

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
    set status = case
      when nq.retries + 1 >= v_max_retries then 'dead_letter'
      else 'failed'
    end,
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

create or replace function app.mark_notification_sent(
  p_notification_id uuid,
  p_worker_id text default 'worker-unknown'
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_retries integer;
begin
  perform app.require_service_role();

  update app.notification_queue nq
  set status = 'sent',
      processed_at = timezone('utc', now()),
      locked_at = null,
      locked_by = null,
      last_error = null
  where nq.id = p_notification_id
    and nq.status = 'processing'
  returning nq.retries into v_retries;

  if not found then
    raise exception 'Notification % is not in processing state', p_notification_id;
  end if;

  insert into app.notification_delivery_attempts (
    notification_id,
    worker_id,
    attempt_no,
    outcome,
    finished_at
  )
  values (
    p_notification_id,
    p_worker_id,
    v_retries + 1,
    'sent',
    timezone('utc', now())
  );
end;
$$;

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
      status = case
        when retries + 1 >= v_max_retries then 'dead_letter'
        else 'failed'
      end,
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

create or replace function app.get_notification_operational_metrics()
returns table (
  sent_count bigint,
  retry_count bigint,
  dead_letter_count bigint,
  queued_count bigint,
  processing_count bigint
)
language sql
stable
security definer
set search_path = app, public
as $$
  select
    count(*) filter (where nq.status = 'sent') as sent_count,
    count(*) filter (where nq.status = 'failed') as retry_count,
    count(*) filter (where nq.status = 'dead_letter') as dead_letter_count,
    count(*) filter (where nq.status = 'queued') as queued_count,
    count(*) filter (where nq.status = 'processing') as processing_count
  from app.notification_queue nq
$$;

alter table app.notification_delivery_attempts enable row level security;
alter table app.system_runtime_config enable row level security;
alter table app.notification_state_policy enable row level security;

create policy notification_attempts_ops_read
on app.notification_delivery_attempts
for select
to authenticated
using (app.current_user_role() in ('warehouse_controller', 'dispatcher', 'service_manager', 'finance_admin'));

create policy system_runtime_config_ops_read
on app.system_runtime_config
for select
to authenticated
using (app.current_user_role() in ('warehouse_controller', 'dispatcher', 'service_manager', 'finance_admin'));

create policy system_runtime_config_service_manager_update
on app.system_runtime_config
for update
to authenticated
using (app.current_user_role() = 'service_manager')
with check (app.current_user_role() = 'service_manager');

create policy notification_state_policy_read
on app.notification_state_policy
for select
to authenticated
using (true);

create policy notification_queue_ops_read
on app.notification_queue
for select
to authenticated
using (
  app.current_user_role() in ('warehouse_controller', 'dispatcher', 'service_manager', 'finance_admin')
  or exists (
    select 1
    from app.user_profiles up
    where up.user_id = auth.uid()
      and (
        notification_queue.recipient_user_id = up.user_id
        or notification_queue.recipient_role = up.role
      )
  )
);

revoke execute on function app.require_service_role() from public, anon, authenticated;
revoke execute on function app.claim_notifications(integer, text) from public, anon, authenticated;
revoke execute on function app.mark_notification_sent(uuid, text) from public, anon, authenticated;
revoke execute on function app.mark_notification_failed(uuid, text, text) from public, anon, authenticated;

grant execute on function app.require_service_role() to service_role, postgres;
grant execute on function app.claim_notifications(integer, text) to service_role, postgres;
grant execute on function app.mark_notification_sent(uuid, text) to service_role, postgres;
grant execute on function app.mark_notification_failed(uuid, text, text) to service_role, postgres;
grant execute on function app.get_notification_operational_metrics() to authenticated, service_role, postgres;
grant execute on function app.get_runtime_config_int(text, integer) to authenticated, service_role, postgres;

commit;
