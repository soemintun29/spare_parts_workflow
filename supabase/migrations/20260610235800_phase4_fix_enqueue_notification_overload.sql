begin;

drop function if exists app.enqueue_notification(text, text, uuid, app.app_role, jsonb);

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

commit;
