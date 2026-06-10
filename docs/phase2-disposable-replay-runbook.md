# Phase 2 Disposable Replay Runbook

Use this only on a disposable Supabase project.

## Inputs needed
- disposable project ref (from you)
- login already authenticated for CLI

## Procedure (from repo root)

1. Link to disposable project:
```bash
npx supabase link --project-ref <DISPOSABLE_PROJECT_REF>
```

2. Replay all migrations from zero on disposable:
```bash
npx supabase db reset --linked --yes
```

3. Capture migration replay evidence:
```bash
npx supabase db query --linked "select version, name from supabase_migrations.schema_migrations order by version;" --output json
```

4. Validate schema objects exist after replay:
```bash
npx supabase db query --linked "select to_regclass('app.parts_requests') as parts_requests, to_regclass('app.idempotency_keys') as idempotency_keys, to_regclass('app.status_transition_log') as transition_log;" --output json
```

5. Run required verification suite:
```bash
npx supabase db query --linked --file \"supabase/tests/phase2_remote_verification.sql\" --output json
```

## Expected success criteria
- migration list query returns all phase-2 migration versions
- `to_regclass(...)` returns non-null table identifiers
- verification rows include:
  - `unauthorized_access_blocked = true`
  - `invalid_transition_rejected = true`
  - `idempotent_replay_no_double_post = true`
  - `audit_rows_created = true`
