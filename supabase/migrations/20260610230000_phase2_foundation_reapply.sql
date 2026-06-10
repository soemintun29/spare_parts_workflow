begin;

create extension if not exists "pgcrypto";

create schema if not exists app;

create type app.app_role as enum (
  'technician',
  'warehouse_controller',
  'dispatcher',
  'service_manager',
  'finance_admin'
);

create type app.parts_request_status as enum (
  'requested',
  'pending',
  'reserved',
  'partially_reserved',
  'ready_for_pickup',
  'partially_ready',
  'received',
  'partially_received',
  'to_return',
  'returned',
  'consumed',
  'out_of_stock',
  'back_ordered',
  'cancelled',
  'discrepancy',
  'transfer_pending',
  'transfer_handed_over',
  'transfer_received',
  'transfer_discrepancy',
  'transfer_cancelled',
  'transfer_expired'
);

create type app.purchase_request_status as enum (
  'created',
  'ordered',
  'partially_received',
  'received',
  'closed',
  'cancelled'
);

create type app.sales_voucher_status as enum (
  'draft',
  'issued',
  'paid',
  'cancelled',
  'refunded'
);

create type app.approval_status as enum (
  'pending',
  'approved',
  'rejected',
  'expired',
  'cancelled'
);

create type app.notification_status as enum (
  'queued',
  'processing',
  'sent',
  'failed',
  'dead_letter'
);

create table if not exists app.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role app.app_role not null,
  branch_code text not null,
  region_code text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.parts_master (
  id uuid primary key default gen_random_uuid(),
  part_no text not null unique,
  part_description text not null,
  product_category text not null,
  default_selling_price numeric(14,2) not null check (default_selling_price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.part_model_relation (
  id uuid primary key default gen_random_uuid(),
  part_id uuid not null references app.parts_master(id),
  model_code text not null,
  created_at timestamptz not null default timezone('utc', now()),
  unique (part_id, model_code)
);

create table if not exists app.parts_inventory_balance (
  id uuid primary key default gen_random_uuid(),
  part_id uuid not null references app.parts_master(id),
  branch_code text not null,
  region_code text not null,
  stock_on_hand numeric(14,3) not null default 0 check (stock_on_hand >= 0),
  stock_reserved numeric(14,3) not null default 0 check (stock_reserved >= 0),
  stock_available numeric(14,3) generated always as (stock_on_hand - stock_reserved) stored,
  check (stock_on_hand >= stock_reserved),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (part_id, branch_code)
);

create table if not exists app.van_stock (
  id uuid primary key default gen_random_uuid(),
  technician_id uuid not null references app.user_profiles(user_id),
  part_id uuid not null references app.parts_master(id),
  branch_code text not null,
  region_code text not null,
  quantity_held numeric(14,3) not null default 0 check (quantity_held >= 0),
  quantity_consumed numeric(14,3) not null default 0 check (quantity_consumed >= 0),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (technician_id, part_id)
);

create table if not exists app.service_calls (
  id uuid primary key default gen_random_uuid(),
  external_ref text unique,
  branch_code text not null,
  region_code text not null,
  status text not null,
  assigned_technician_id uuid references app.user_profiles(user_id),
  reschedule_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.parts_requests (
  id uuid primary key default gen_random_uuid(),
  request_no text not null unique,
  service_call_id uuid references app.service_calls(id),
  part_id uuid not null references app.parts_master(id),
  requester_id uuid not null references app.user_profiles(user_id),
  technician_id uuid references app.user_profiles(user_id),
  branch_code text not null,
  region_code text not null,
  quantity_requested numeric(14,3) not null check (quantity_requested > 0),
  quantity_reserved numeric(14,3) not null default 0 check (quantity_reserved >= 0),
  quantity_received numeric(14,3) not null default 0 check (quantity_received >= 0),
  status app.parts_request_status not null,
  reason_code text,
  reason_comment text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  pr_no text not null unique,
  part_id uuid not null references app.parts_master(id),
  requester_id uuid not null references app.user_profiles(user_id),
  branch_code text not null,
  region_code text not null,
  quantity_requested numeric(14,3) not null check (quantity_requested > 0),
  quantity_received numeric(14,3) not null default 0 check (quantity_received >= 0),
  supplier_ref text,
  eta_date date,
  status app.purchase_request_status not null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.stock_adjustments (
  id uuid primary key default gen_random_uuid(),
  adjustment_no text not null unique,
  part_id uuid not null references app.parts_master(id),
  branch_code text not null,
  region_code text not null,
  quantity_delta numeric(14,3) not null check (quantity_delta <> 0),
  reason_code text not null,
  reason_comment text not null,
  threshold_value numeric(14,3),
  created_by uuid not null references app.user_profiles(user_id),
  approved_by uuid references app.user_profiles(user_id),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.sales_vouchers (
  id uuid primary key default gen_random_uuid(),
  voucher_no text not null unique,
  branch_code text not null,
  region_code text not null,
  customer_name text,
  total_amount numeric(14,2) not null default 0 check (total_amount >= 0),
  status app.sales_voucher_status not null,
  issued_at timestamptz,
  paid_at timestamptz,
  created_by uuid not null references app.user_profiles(user_id),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.sales_voucher_lines (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references app.sales_vouchers(id),
  part_id uuid not null references app.parts_master(id),
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_total numeric(14,2) generated always as (quantity * unit_price) stored,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.daily_cash_register (
  id uuid primary key default gen_random_uuid(),
  register_date date not null,
  branch_code text not null,
  region_code text not null,
  expected_cash numeric(14,2) not null default 0,
  physical_cash numeric(14,2),
  discrepancy_amount numeric(14,2),
  reconciled_by uuid references app.user_profiles(user_id),
  reconciled_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (register_date, branch_code)
);

create table if not exists app.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references app.user_profiles(user_id),
  actor_role app.app_role not null,
  action_name text not null,
  idempotency_key text not null,
  request_fingerprint text not null,
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb,
  status text not null check (status in ('processing', 'succeeded', 'failed')),
  first_seen_at timestamptz not null default timezone('utc', now()),
  last_seen_at timestamptz not null default timezone('utc', now()),
  completed_at timestamptz,
  unique (actor_id, action_name, idempotency_key)
);

create table if not exists app.status_transition_policy (
  id uuid primary key default gen_random_uuid(),
  workflow_name text not null,
  from_status text not null,
  to_status text not null,
  requires_reason boolean not null default false,
  requires_approval boolean not null default false,
  unique (workflow_name, from_status, to_status)
);

create table if not exists app.approval_requests (
  id uuid primary key default gen_random_uuid(),
  entity_name text not null,
  entity_id uuid not null,
  override_scope text not null,
  approval_status app.approval_status not null default 'pending',
  requester_id uuid not null references app.user_profiles(user_id),
  approver_id uuid references app.user_profiles(user_id),
  reason_code text not null check (length(trim(reason_code)) > 0),
  reason_comment text not null check (length(trim(reason_comment)) > 0),
  region_code text not null,
  branch_code text not null,
  created_at timestamptz not null default timezone('utc', now()),
  decided_at timestamptz
);

create table if not exists app.status_transition_log (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  record_id uuid not null,
  from_status text not null,
  to_status text not null,
  actor_id uuid not null references app.user_profiles(user_id),
  actor_role app.app_role not null,
  idempotency_key text not null,
  reason_code text,
  reason_comment text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.notification_queue (
  id uuid primary key default gen_random_uuid(),
  event_name text not null,
  entity_name text not null,
  entity_id uuid not null,
  recipient_role app.app_role,
  recipient_user_id uuid references app.user_profiles(user_id),
  payload jsonb not null default '{}'::jsonb,
  status app.notification_status not null default 'queued',
  retries integer not null default 0 check (retries >= 0),
  next_attempt_at timestamptz not null default timezone('utc', now()),
  last_error text,
  created_at timestamptz not null default timezone('utc', now()),
  processed_at timestamptz
);

create index if not exists idx_part_model_relation_part_id on app.part_model_relation(part_id);
create index if not exists idx_part_model_relation_model_code on app.part_model_relation(model_code);
create index if not exists idx_inventory_branch_region on app.parts_inventory_balance(branch_code, region_code);
create index if not exists idx_van_stock_technician on app.van_stock(technician_id);
create index if not exists idx_parts_requests_status on app.parts_requests(status);
create index if not exists idx_parts_requests_region on app.parts_requests(region_code, branch_code);
create index if not exists idx_purchase_requests_status on app.purchase_requests(status);
create index if not exists idx_sales_voucher_status on app.sales_vouchers(status);
create index if not exists idx_transition_log_record on app.status_transition_log(table_name, record_id, created_at desc);
create index if not exists idx_approval_entity on app.approval_requests(entity_name, entity_id, approval_status);
create index if not exists idx_notification_queue_status on app.notification_queue(status, next_attempt_at);

create or replace function app.current_user_profile()
returns app.user_profiles
language sql
stable
as $$
  select up.*
  from app.user_profiles up
  where up.user_id = auth.uid()
$$;

create or replace function app.is_same_region(target_region text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from app.user_profiles up
    where up.user_id = auth.uid()
      and up.region_code = target_region
      and up.is_active = true
  );
$$;

create or replace function app.has_approved_cross_region_override(target_region text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from app.user_profiles up
    join app.approval_requests ar
      on ar.requester_id = up.user_id
    where up.user_id = auth.uid()
      and up.role = 'service_manager'
      and up.is_active = true
      and ar.override_scope = 'cross_region_access'
      and ar.approval_status = 'approved'
      and ar.region_code = target_region
      and ar.reason_code <> ''
      and ar.reason_comment <> ''
  );
$$;

create or replace function app.can_access_region(target_region text)
returns boolean
language sql
stable
as $$
  select app.is_same_region(target_region) or app.has_approved_cross_region_override(target_region);
$$;

create or replace function app.current_user_role()
returns app.app_role
language sql
stable
as $$
  select up.role
  from app.user_profiles up
  where up.user_id = auth.uid()
$$;

create or replace function app.require_legal_transition(
  p_workflow text,
  p_from_status text,
  p_to_status text
)
returns void
language plpgsql
as $$
begin
  if not exists (
    select 1
    from app.status_transition_policy stp
    where stp.workflow_name = p_workflow
      and stp.from_status = p_from_status
      and stp.to_status = p_to_status
  ) then
    raise exception 'Illegal status transition for workflow %: % -> %', p_workflow, p_from_status, p_to_status;
  end if;
end;
$$;

create or replace function app.prevent_hard_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Hard delete is not allowed on %', tg_table_name;
end;
$$;

create or replace function app.prevent_update_delete_transition_log()
returns trigger
language plpgsql
as $$
begin
  raise exception 'status_transition_log is immutable';
end;
$$;

create or replace function app.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create or replace function app.enforce_parts_request_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status <> new.status then
    perform app.require_legal_transition('parts_requests', old.status::text, new.status::text);
  end if;
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create or replace function app.enforce_purchase_request_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status <> new.status then
    perform app.require_legal_transition('purchase_requests', old.status::text, new.status::text);
  end if;
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create or replace function app.enforce_sales_voucher_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status <> new.status then
    perform app.require_legal_transition('sales_vouchers', old.status::text, new.status::text);
  end if;
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create or replace function app.log_status_transition()
returns trigger
language plpgsql
as $$
declare
  v_actor_role app.app_role;
  v_actor_id uuid;
begin
  if auth.uid() is null then
    return new;
  end if;

  if old.status is distinct from new.status then
    v_actor_id := auth.uid();

    select up.role
      into v_actor_role
    from app.user_profiles up
    where up.user_id = v_actor_id;

    insert into app.status_transition_log (
      table_name,
      record_id,
      from_status,
      to_status,
      actor_id,
      actor_role,
      idempotency_key,
      reason_code,
      reason_comment,
      metadata
    )
    values (
      tg_table_name,
      new.id,
      old.status::text,
      new.status::text,
      v_actor_id,
      coalesce(v_actor_role, app.current_user_role()),
      coalesce(current_setting('request.headers', true)::jsonb ->> 'x-idempotency-key', 'missing'),
      (to_jsonb(new) ->> 'reason_code'),
      (to_jsonb(new) ->> 'reason_comment'),
      jsonb_build_object('source', 'trigger')
    );
  end if;

  return new;
end;
$$;

create or replace function app.require_action_role(
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

  if p_action = 'update_parts_request_status'
     and v_role not in ('warehouse_controller', 'service_manager') then
    raise exception 'Unauthorized role for action %', p_action;
  end if;
end;
$$;

create or replace function app.begin_idempotent_operation(
  p_action_name text,
  p_idempotency_key text,
  p_request_fingerprint text,
  p_payload jsonb default '{}'::jsonb
)
returns table (
  id uuid,
  status text,
  response_payload jsonb
)
language plpgsql
as $$
declare
  v_actor_id uuid;
  v_actor_role app.app_role;
  v_row app.idempotency_keys;
begin
  select up.user_id, up.role
    into v_actor_id, v_actor_role
  from app.user_profiles up
  where up.user_id = auth.uid()
    and up.is_active = true;

  if v_actor_id is null then
    raise exception 'No active user profile for current user';
  end if;

  insert into app.idempotency_keys (
    actor_id,
    actor_role,
    action_name,
    idempotency_key,
    request_fingerprint,
    request_payload,
    status
  )
  values (
    v_actor_id,
    v_actor_role,
    p_action_name,
    p_idempotency_key,
    p_request_fingerprint,
    p_payload,
    'processing'
  )
  on conflict (actor_id, action_name, idempotency_key)
  do update
    set last_seen_at = timezone('utc', now())
  returning * into v_row;

  if v_row.request_fingerprint <> p_request_fingerprint then
    raise exception 'Idempotency key reuse with different payload';
  end if;

  if v_row.status = 'succeeded' then
    return query
    select v_row.id, v_row.status, v_row.response_payload;
    return;
  end if;

  if v_row.status = 'processing' and v_row.first_seen_at <> v_row.last_seen_at then
    raise exception 'Idempotent request already in progress';
  end if;

  return query
  select v_row.id, v_row.status, v_row.response_payload;
end;
$$;

create or replace function app.complete_idempotent_operation(
  p_action_name text,
  p_idempotency_key text,
  p_response_payload jsonb
)
returns void
language plpgsql
as $$
declare
  v_actor_id uuid;
begin
  select up.user_id into v_actor_id
  from app.user_profiles up
  where up.user_id = auth.uid()
    and up.is_active = true;

  if v_actor_id is null then
    raise exception 'No active user profile for current user';
  end if;

  update app.idempotency_keys ik
  set status = 'succeeded',
      response_payload = p_response_payload,
      completed_at = timezone('utc', now()),
      last_seen_at = timezone('utc', now())
  where ik.actor_id = v_actor_id
    and ik.action_name = p_action_name
    and ik.idempotency_key = p_idempotency_key;
end;
$$;

create or replace function app.fail_idempotent_operation(
  p_action_name text,
  p_idempotency_key text,
  p_error_payload jsonb
)
returns void
language plpgsql
as $$
declare
  v_actor_id uuid;
begin
  select up.user_id into v_actor_id
  from app.user_profiles up
  where up.user_id = auth.uid()
    and up.is_active = true;

  if v_actor_id is null then
    raise exception 'No active user profile for current user';
  end if;

  update app.idempotency_keys ik
  set status = 'failed',
      response_payload = p_error_payload,
      completed_at = timezone('utc', now()),
      last_seen_at = timezone('utc', now())
  where ik.actor_id = v_actor_id
    and ik.action_name = p_action_name
    and ik.idempotency_key = p_idempotency_key;
end;
$$;

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
  v_fingerprint := encode(
    digest(
      concat_ws(
        '|',
        p_request_id::text,
        p_to_status::text,
        coalesce(p_reason_code, ''),
        coalesce(p_reason_comment, '')
      ),
      'sha256'
    ),
    'hex'
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

create or replace function app.seed_status_transition_policy()
returns void
language plpgsql
as $$
begin
  insert into app.status_transition_policy (workflow_name, from_status, to_status, requires_reason, requires_approval)
  values
    ('parts_requests', 'requested', 'pending', false, false),
    ('parts_requests', 'requested', 'cancelled', true, false),
    ('parts_requests', 'pending', 'reserved', false, false),
    ('parts_requests', 'pending', 'partially_reserved', false, false),
    ('parts_requests', 'pending', 'out_of_stock', true, false),
    ('parts_requests', 'pending', 'cancelled', true, false),
    ('parts_requests', 'reserved', 'ready_for_pickup', false, false),
    ('parts_requests', 'reserved', 'partially_ready', false, false),
    ('parts_requests', 'reserved', 'cancelled', true, true),
    ('parts_requests', 'partially_reserved', 'partially_ready', false, false),
    ('parts_requests', 'partially_reserved', 'back_ordered', true, false),
    ('parts_requests', 'partially_reserved', 'cancelled', true, true),
    ('parts_requests', 'ready_for_pickup', 'received', false, false),
    ('parts_requests', 'ready_for_pickup', 'transfer_pending', true, false),
    ('parts_requests', 'ready_for_pickup', 'cancelled', true, true),
    ('parts_requests', 'partially_ready', 'partially_received', false, false),
    ('parts_requests', 'partially_ready', 'back_ordered', true, false),
    ('parts_requests', 'partially_ready', 'cancelled', true, true),
    ('parts_requests', 'received', 'consumed', false, false),
    ('parts_requests', 'received', 'to_return', true, false),
    ('parts_requests', 'received', 'transfer_pending', true, false),
    ('parts_requests', 'partially_received', 'consumed', false, false),
    ('parts_requests', 'partially_received', 'to_return', true, false),
    ('parts_requests', 'partially_received', 'back_ordered', true, false),
    ('parts_requests', 'to_return', 'returned', false, false),
    ('parts_requests', 'to_return', 'discrepancy', true, false),
    ('parts_requests', 'out_of_stock', 'back_ordered', false, false),
    ('parts_requests', 'out_of_stock', 'cancelled', true, false),
    ('parts_requests', 'back_ordered', 'reserved', false, false),
    ('parts_requests', 'back_ordered', 'partially_reserved', false, false),
    ('parts_requests', 'back_ordered', 'ready_for_pickup', false, false),
    ('parts_requests', 'back_ordered', 'cancelled', true, false),
    ('parts_requests', 'transfer_pending', 'transfer_handed_over', false, false),
    ('parts_requests', 'transfer_pending', 'transfer_cancelled', true, false),
    ('parts_requests', 'transfer_pending', 'transfer_expired', true, false),
    ('parts_requests', 'transfer_handed_over', 'transfer_received', false, false),
    ('parts_requests', 'transfer_handed_over', 'transfer_discrepancy', true, false),
    ('parts_requests', 'transfer_handed_over', 'transfer_expired', true, false),
    ('parts_requests', 'transfer_received', 'consumed', false, false),
    ('parts_requests', 'transfer_received', 'to_return', true, false),
    ('parts_requests', 'transfer_discrepancy', 'transfer_cancelled', true, true),
    ('purchase_requests', 'created', 'ordered', false, false),
    ('purchase_requests', 'created', 'cancelled', true, false),
    ('purchase_requests', 'ordered', 'partially_received', false, false),
    ('purchase_requests', 'ordered', 'received', false, false),
    ('purchase_requests', 'ordered', 'cancelled', true, false),
    ('purchase_requests', 'partially_received', 'received', false, false),
    ('purchase_requests', 'partially_received', 'closed', false, false),
    ('purchase_requests', 'partially_received', 'cancelled', true, false),
    ('purchase_requests', 'received', 'closed', false, false),
    ('sales_vouchers', 'draft', 'issued', false, false),
    ('sales_vouchers', 'draft', 'cancelled', true, false),
    ('sales_vouchers', 'issued', 'paid', false, false),
    ('sales_vouchers', 'issued', 'cancelled', true, true),
    ('sales_vouchers', 'paid', 'refunded', true, true)
  on conflict (workflow_name, from_status, to_status) do nothing;
end;
$$;

select app.seed_status_transition_policy();

drop trigger if exists trg_user_profiles_updated_at on app.user_profiles;
create trigger trg_user_profiles_updated_at
before update on app.user_profiles
for each row
execute function app.set_updated_at();

drop trigger if exists trg_parts_master_updated_at on app.parts_master;
create trigger trg_parts_master_updated_at
before update on app.parts_master
for each row
execute function app.set_updated_at();

drop trigger if exists trg_service_calls_updated_at on app.service_calls;
create trigger trg_service_calls_updated_at
before update on app.service_calls
for each row
execute function app.set_updated_at();

drop trigger if exists trg_purchase_requests_transition on app.purchase_requests;
create trigger trg_purchase_requests_transition
before update on app.purchase_requests
for each row
execute function app.enforce_purchase_request_transition();

drop trigger if exists trg_sales_vouchers_transition on app.sales_vouchers;
create trigger trg_sales_vouchers_transition
before update on app.sales_vouchers
for each row
execute function app.enforce_sales_voucher_transition();

drop trigger if exists trg_parts_requests_transition on app.parts_requests;
create trigger trg_parts_requests_transition
before update on app.parts_requests
for each row
execute function app.enforce_parts_request_transition();

drop trigger if exists trg_parts_requests_status_log on app.parts_requests;
create trigger trg_parts_requests_status_log
after update on app.parts_requests
for each row
execute function app.log_status_transition();

drop trigger if exists trg_purchase_requests_status_log on app.purchase_requests;
create trigger trg_purchase_requests_status_log
after update on app.purchase_requests
for each row
execute function app.log_status_transition();

drop trigger if exists trg_sales_vouchers_status_log on app.sales_vouchers;
create trigger trg_sales_vouchers_status_log
after update on app.sales_vouchers
for each row
execute function app.log_status_transition();

drop trigger if exists trg_transition_log_immutable on app.status_transition_log;
create trigger trg_transition_log_immutable
before update or delete on app.status_transition_log
for each row
execute function app.prevent_update_delete_transition_log();

drop trigger if exists trg_parts_master_no_delete on app.parts_master;
create trigger trg_parts_master_no_delete
before delete on app.parts_master
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_parts_requests_no_delete on app.parts_requests;
create trigger trg_parts_requests_no_delete
before delete on app.parts_requests
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_purchase_requests_no_delete on app.purchase_requests;
create trigger trg_purchase_requests_no_delete
before delete on app.purchase_requests
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_stock_adjustments_no_delete on app.stock_adjustments;
create trigger trg_stock_adjustments_no_delete
before delete on app.stock_adjustments
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_sales_vouchers_no_delete on app.sales_vouchers;
create trigger trg_sales_vouchers_no_delete
before delete on app.sales_vouchers
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_sales_voucher_lines_no_delete on app.sales_voucher_lines;
create trigger trg_sales_voucher_lines_no_delete
before delete on app.sales_voucher_lines
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_daily_cash_register_no_delete on app.daily_cash_register;
create trigger trg_daily_cash_register_no_delete
before delete on app.daily_cash_register
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_service_calls_no_delete on app.service_calls;
create trigger trg_service_calls_no_delete
before delete on app.service_calls
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_approval_requests_no_delete on app.approval_requests;
create trigger trg_approval_requests_no_delete
before delete on app.approval_requests
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_idempotency_keys_no_delete on app.idempotency_keys;
create trigger trg_idempotency_keys_no_delete
before delete on app.idempotency_keys
for each row
execute function app.prevent_hard_delete();

drop trigger if exists trg_notification_queue_no_delete on app.notification_queue;
create trigger trg_notification_queue_no_delete
before delete on app.notification_queue
for each row
execute function app.prevent_hard_delete();

alter table app.user_profiles enable row level security;
alter table app.parts_master enable row level security;
alter table app.part_model_relation enable row level security;
alter table app.parts_inventory_balance enable row level security;
alter table app.van_stock enable row level security;
alter table app.parts_requests enable row level security;
alter table app.purchase_requests enable row level security;
alter table app.stock_adjustments enable row level security;
alter table app.sales_vouchers enable row level security;
alter table app.sales_voucher_lines enable row level security;
alter table app.daily_cash_register enable row level security;
alter table app.service_calls enable row level security;
alter table app.status_transition_log enable row level security;
alter table app.approval_requests enable row level security;
alter table app.idempotency_keys enable row level security;
alter table app.notification_queue enable row level security;
alter table app.status_transition_policy enable row level security;

revoke insert, update, delete on app.parts_inventory_balance from authenticated;
revoke insert, update, delete on app.van_stock from authenticated;
revoke insert, update, delete on app.daily_cash_register from authenticated;
revoke insert, update, delete on app.sales_vouchers from authenticated;
revoke insert, update, delete on app.sales_voucher_lines from authenticated;

create policy user_profiles_self_read
on app.user_profiles
for select
to authenticated
using (user_id = auth.uid());

create policy user_profiles_service_manager_update
on app.user_profiles
for update
to authenticated
using (app.current_user_role() = 'service_manager')
with check (app.current_user_role() = 'service_manager');

create policy parts_master_region_read
on app.parts_master
for select
to authenticated
using (true);

create policy part_model_relation_region_read
on app.part_model_relation
for select
to authenticated
using (true);

create policy inventory_region_read
on app.parts_inventory_balance
for select
to authenticated
using (app.can_access_region(region_code));

create policy van_stock_region_read
on app.van_stock
for select
to authenticated
using (
  app.can_access_region(region_code)
  and (
    app.current_user_role() <> 'technician'
    or technician_id = auth.uid()
  )
);

create policy parts_requests_region_read
on app.parts_requests
for select
to authenticated
using (app.can_access_region(region_code));

create policy purchase_requests_region_read
on app.purchase_requests
for select
to authenticated
using (app.can_access_region(region_code));

create policy stock_adjustments_region_read
on app.stock_adjustments
for select
to authenticated
using (app.can_access_region(region_code));

create policy sales_vouchers_region_read
on app.sales_vouchers
for select
to authenticated
using (
  app.can_access_region(region_code)
  and (
    app.current_user_role() in ('warehouse_controller', 'service_manager', 'finance_admin')
  )
);

create policy sales_voucher_lines_region_read
on app.sales_voucher_lines
for select
to authenticated
using (
  exists (
    select 1
    from app.sales_vouchers sv
    where sv.id = sales_voucher_lines.voucher_id
      and app.can_access_region(sv.region_code)
      and app.current_user_role() in ('warehouse_controller', 'service_manager', 'finance_admin')
  )
);

create policy daily_cash_register_region_read
on app.daily_cash_register
for select
to authenticated
using (
  app.can_access_region(region_code)
  and app.current_user_role() in ('warehouse_controller', 'service_manager', 'finance_admin')
);

create policy service_calls_region_read
on app.service_calls
for select
to authenticated
using (app.can_access_region(region_code));

create policy transition_log_region_read
on app.status_transition_log
for select
to authenticated
using (
  exists (
    select 1
    from app.parts_requests pr
    where status_transition_log.table_name = 'parts_requests'
      and status_transition_log.record_id = pr.id
      and app.can_access_region(pr.region_code)
  )
  or exists (
    select 1
    from app.purchase_requests ppr
    where status_transition_log.table_name = 'purchase_requests'
      and status_transition_log.record_id = ppr.id
      and app.can_access_region(ppr.region_code)
  )
  or exists (
    select 1
    from app.sales_vouchers sv
    where status_transition_log.table_name = 'sales_vouchers'
      and status_transition_log.record_id = sv.id
      and app.can_access_region(sv.region_code)
  )
);

create policy approval_requests_region_read
on app.approval_requests
for select
to authenticated
using (app.can_access_region(region_code));

create policy approval_requests_insert
on app.approval_requests
for insert
to authenticated
with check (
  requester_id = auth.uid()
  and app.can_access_region(region_code)
);

create policy approval_requests_service_manager_update
on app.approval_requests
for update
to authenticated
using (app.current_user_role() = 'service_manager')
with check (app.current_user_role() = 'service_manager');

create policy idempotency_keys_self_read
on app.idempotency_keys
for select
to authenticated
using (actor_id = auth.uid());

create policy idempotency_keys_self_insert
on app.idempotency_keys
for insert
to authenticated
with check (actor_id = auth.uid());

create policy idempotency_keys_self_update
on app.idempotency_keys
for update
to authenticated
using (actor_id = auth.uid())
with check (actor_id = auth.uid());

create policy notification_queue_region_read
on app.notification_queue
for select
to authenticated
using (
  exists (
    select 1
    from app.user_profiles up
    where up.user_id = auth.uid()
      and (
        notification_queue.recipient_user_id = up.user_id
        or notification_queue.recipient_role = up.role
      )
  )
);

create policy status_transition_policy_read
on app.status_transition_policy
for select
to authenticated
using (true);

grant usage on schema app to authenticated, anon;
grant execute on function app.current_user_profile() to authenticated;
grant execute on function app.current_user_role() to authenticated;
grant execute on function app.can_access_region(text) to authenticated;
grant execute on function app.require_action_role(text) to authenticated;
grant execute on function app.begin_idempotent_operation(text, text, text, jsonb) to authenticated;
grant execute on function app.complete_idempotent_operation(text, text, jsonb) to authenticated;
grant execute on function app.fail_idempotent_operation(text, text, jsonb) to authenticated;
grant execute on function app.update_parts_request_status(uuid, app.parts_request_status, text, text, text) to authenticated;

commit;
