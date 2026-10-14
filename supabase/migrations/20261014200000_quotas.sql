-- Quotas: how much one account can make the server hold.
--
-- Anyone can create an account and sync, so without limits one account
-- could fill the database or the R2 bucket for everyone. The server cannot
-- look inside what it stores, but it can count it: bytes in the
-- workspaces an account founded, workspaces per account, accounts per
-- workspace, link rows per account, and bytes per account uploaded to R2
-- each day. A refused write raises
-- SQLSTATE PT413 or PT429, which PostgREST turns into HTTP 413 (the client
-- shows "storage full") or 429 (the client retries later).
--
-- The limits live in a table, so they can be changed with one UPDATE run
-- by the project owner, without a new migration.

create table public.quotas (
  name text primary key,
  value bigint not null check (value > 0)
);

insert into public.quotas (name, value) values
  -- Ciphertext held in the three streams of all the workspaces an account
  -- founded: the devices it admits write against its budget.
  ('account_bytes', 100 * 1024 * 1024),
  -- Workspaces an account founds. Each new vault founds one and an
  -- abandoned one stays (a reinstall, a browser cleared), so this is a
  -- guard against spam, not a budget: the bytes are counted above.
  ('workspaces_per_account', 20),
  ('accounts_per_workspace', 10),
  -- Link rows an account posts in a quarter of an hour.
  ('links_per_quarter_hour', 20),
  -- One encrypted blob on R2: a 30-minute WAV recording from a browser
  -- without WebCodecs, with room to spare.
  ('blob_bytes', 512 * 1024 * 1024),
  -- Bytes an account may announce for upload to R2 in 24 hours.
  ('blob_bytes_per_day', 2 * 1024 * 1024 * 1024::bigint);

create function public.quota(quota_name text)
returns bigint
language sql stable security definer set search_path = ''
as $$
  select value from public.quotas where name = quota_name;
$$;

-- Bytes held per workspace, kept by triggers on the streams. Rows a
-- compaction drops are subtracted before the new row is counted, so an
-- edit that does not grow a note always fits.

create index workspaces_by_founder on public.workspaces (created_by);
create table public.workspace_usage (
  workspace_id text primary key references public.workspaces (id) on delete cascade,
  bytes bigint not null default 0
);

insert into public.workspace_usage (workspace_id, bytes)
select w.id,
  coalesce((select sum(octet_length(ciphertext)) from public.sync_rows s where s.workspace_id = w.id), 0)
  + coalesce((select sum(octet_length(record)) from public.membership_records m where m.workspace_id = w.id), 0)
  + coalesce((select sum(octet_length(bundle)) from public.key_bundles k where k.workspace_id = w.id), 0)
from public.workspaces w;

create function public.count_workspace_bytes()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  row_ record;
  size bigint;
  founder uuid;
begin
  if TG_OP = 'DELETE' then row_ := old; else row_ := new; end if;
  if TG_TABLE_NAME = 'sync_rows' then
    size := octet_length(row_.ciphertext);
  elsif TG_TABLE_NAME = 'membership_records' then
    size := octet_length(row_.record);
  else
    size := octet_length(row_.bundle);
  end if;
  if TG_OP = 'DELETE' then
    -- Also when the workspace itself is being deleted: then there is
    -- nothing left to update.
    update public.workspace_usage set bytes = bytes - size
    where workspace_id = row_.workspace_id;
    return null;
  end if;
  select created_by into founder from public.workspaces where id = row_.workspace_id;
  -- One write at a time per founder, so two workspaces of one account
  -- cannot both take the last free bytes.
  perform pg_advisory_xact_lock(hashtextextended('bytes:' || founder::text, 0));
  insert into public.workspace_usage as usage (workspace_id, bytes)
  values (row_.workspace_id, size)
  on conflict (workspace_id) do update set bytes = usage.bytes + excluded.bytes;
  if (select sum(u.bytes) from public.workspace_usage u
      join public.workspaces w on w.id = u.workspace_id
      where w.created_by = founder) > public.quota('account_bytes') then
    raise sqlstate 'PT413' using message = 'storage quota exceeded';
  end if;
  return null;
end;
$$;

-- After the compaction trigger (triggers fire in name order), so the
-- rows a new revision supersedes are already gone when it is counted.
create trigger sync_rows_usage
after insert or delete on public.sync_rows
for each row execute function public.count_workspace_bytes();

create trigger membership_records_usage
after insert or delete on public.membership_records
for each row execute function public.count_workspace_bytes();

create trigger key_bundles_usage
after insert or delete on public.key_bundles
for each row execute function public.count_workspace_bytes();

create function public.limit_founded_workspaces()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- One founder at a time, so two inserts cannot both see room for one.
  perform pg_advisory_xact_lock(hashtextextended('found:' || new.created_by::text, 0));
  if (select count(*) from public.workspaces where created_by = new.created_by)
      >= public.quota('workspaces_per_account') then
    raise sqlstate 'PT413' using message = 'workspace quota exceeded';
  end if;
  return new;
end;
$$;

create trigger workspaces_quota
before insert on public.workspaces
for each row execute function public.limit_founded_workspaces();

create function public.limit_workspace_accounts()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- The founding account is added by the workspace's own insert.
  perform 1 from public.workspaces where id = new.workspace_id for update;
  if (select count(*) from public.workspace_accounts where workspace_id = new.workspace_id)
      >= public.quota('accounts_per_workspace') then
    raise sqlstate 'PT413' using message = 'account quota exceeded';
  end if;
  return new;
end;
$$;

create trigger workspace_accounts_quota
before insert on public.workspace_accounts
for each row execute function public.limit_workspace_accounts();

-- Link rows: the account's expired ones are dropped first (nobody can read
-- them any more), then at most so many in a quarter of an hour.
create function public.limit_device_links()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('link:' || new.user_id::text, 0));
  delete from public.device_links
  where user_id = new.user_id and created_at <= now() - interval '15 minutes';
  if (select count(*) from public.device_links where user_id = new.user_id)
      >= public.quota('links_per_quarter_hour') then
    raise sqlstate 'PT429' using message = 'too many link rows';
  end if;
  return new;
end;
$$;

create trigger device_links_quota
before insert on public.device_links
for each row execute function public.limit_device_links();

-- Uploads to R2. The server never sees the blobs, so the blob-url function
-- asks here before it signs an upload URL, and signs the announced size
-- into it: R2 then refuses a body of any other length. A blob announced
-- twice (an upload retried) counts once.
create table public.blob_uploads (
  user_id uuid not null references auth.users (id) on delete cascade,
  workspace_id text not null references public.workspaces (id) on delete cascade,
  blob_id text not null check (blob_id ~ '^[A-Za-z0-9_-]{1,128}$'),
  size bigint not null check (size > 0),
  created_at timestamptz not null default now(),
  primary key (user_id, workspace_id, blob_id)
);

create index blob_uploads_by_time on public.blob_uploads (created_at);

-- True when the caller may upload `size` bytes as `blob` into `workspace`.
-- Refuses with 403 for a non-member, 413 for a blob over the size limit and
-- 429 once the caller's uploads of the last 24 hours would pass the daily
-- budget. Calling it directly only spends the caller's own budget.
create function public.reserve_blob_upload(workspace text, blob text, size bigint)
returns boolean
language plpgsql volatile security definer set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  spent bigint;
begin
  if caller is null or not public.is_workspace_account(workspace) then
    raise exception 'not a workspace account' using errcode = '42501';
  end if;
  if size is null or size < 1 or size > public.quota('blob_bytes') then
    raise sqlstate 'PT413' using message = 'blob too large';
  end if;
  if blob is null or blob !~ '^[A-Za-z0-9_-]{1,128}$' then
    raise exception 'malformed blob id' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('blob:' || caller::text, 0));
  delete from public.blob_uploads where created_at <= now() - interval '1 day';
  if exists (
    select 1 from public.blob_uploads u
    where u.user_id = caller and u.workspace_id = workspace and u.blob_id = blob
      and u.size >= reserve_blob_upload.size
  ) then
    return true;
  end if;
  select coalesce(sum(u.size), 0) into spent
  from public.blob_uploads u
  where u.user_id = caller and not (u.workspace_id = workspace and u.blob_id = blob);
  if spent + size > public.quota('blob_bytes_per_day') then
    raise sqlstate 'PT429' using message = 'daily upload budget spent';
  end if;
  insert into public.blob_uploads as u (user_id, workspace_id, blob_id, size)
  values (caller, workspace, blob, size)
  on conflict (user_id, workspace_id, blob_id) do update set size = excluded.size;
  return true;
end;
$$;

alter table public.quotas enable row level security;
alter table public.workspace_usage enable row level security;
alter table public.blob_uploads enable row level security;

-- Nothing here is for clients to read or write: no policies, no grants.
revoke all on public.quotas, public.workspace_usage, public.blob_uploads
  from anon, authenticated;
revoke execute on function public.quota(text), public.count_workspace_bytes(),
  public.limit_founded_workspaces(), public.limit_workspace_accounts(),
  public.limit_device_links(), public.reserve_blob_upload(text, text, bigint)
  from public, anon;
revoke execute on function public.quota(text), public.count_workspace_bytes(),
  public.limit_founded_workspaces(), public.limit_workspace_accounts(),
  public.limit_device_links()
  from authenticated;
grant execute on function public.reserve_blob_upload(text, text, bigint) to authenticated;
