-- What a member's account may append, as the server can tell it.
--
-- Until now every account of a workspace could append to all three
-- streams: the clients check signatures and roles, so a forged row was
-- ignored. Two things slipped past that, because the server acts on rows
-- before any client looks at them:
--
-- * membership_records takes the sequence from the client. Any account,
--   a person invited only to read included, could take the next number
--   (or one far ahead) with a record nobody can verify: every device then
--   refused the log, and no owner could ever append to it again, not even
--   to remove that account.
-- * sync_rows runs compaction on insert. A reader's row is discarded by
--   every client, yet its `supersedes` had already deleted the earlier
--   revisions of the record it named, on the server, for everyone.
--
-- So the server now keeps, next to can_manage, whether an account writes
-- (can_write: false only for an account admitted for readers alone), and:
-- only managing accounts append membership records and key bundles, in
-- sequence order without gaps; only writing accounts append rows or upload
-- and delete blobs. A managing account always writes.
--
-- Accounts already in a workspace keep writing: the server cannot tell
-- which of them were invited to read. An owner who invited someone to read
-- before this migration can set it with
--   update public.workspace_accounts set can_write = false
--   where workspace_id = '<workspace>' and user_id = '<account>';

alter table public.workspace_accounts
  add column can_write boolean not null default true;

create function public.writes_workspace(workspace text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.workspace_accounts
    where workspace_id = workspace and user_id = auth.uid()
      and (can_write or can_manage)
  );
$$;

drop policy "accounts append rows" on public.sync_rows;
create policy "writing accounts append rows" on public.sync_rows
  for insert to authenticated with check (public.writes_workspace(workspace_id));

drop policy "accounts append membership" on public.membership_records;
create policy "managers append membership" on public.membership_records
  for insert to authenticated with check (public.manages_workspace(workspace_id));

drop policy "accounts append bundles" on public.key_bundles;
create policy "managers append bundles" on public.key_bundles
  for insert to authenticated with check (public.manages_workspace(workspace_id));

-- The log is contiguous from 0: a record may only take the next sequence.
-- Two owners appending at once still meet on the primary key (409). An
-- account that may not append is left to the policy, so the answer tells it
-- nothing about the log.
create function public.next_membership_sequence()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.manages_workspace(new.workspace_id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('membership_records:' || new.workspace_id, 0));
  if new.sequence <> coalesce(
    (select max(sequence) + 1 from public.membership_records
     where workspace_id = new.workspace_id),
    0
  ) and not exists (
    select 1 from public.membership_records
    where workspace_id = new.workspace_id and sequence = new.sequence
  ) then
    raise exception 'membership sequence out of order' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger membership_records_sequence
before insert on public.membership_records
for each row execute function public.next_membership_sequence();

-- [write] is false for an account admitted for readers alone. An account
-- already in keeps what it had and gains what is asked: it may have
-- another device with a role that writes.
drop function public.admit_member(text, text, uuid, boolean);
create function public.admit_member(
  workspace text,
  member text,
  account uuid default null,
  manage boolean default false,
  write boolean default true
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  target uuid := coalesce(account, auth.uid());
begin
  if auth.uid() is null or not public.manages_workspace(workspace) then
    raise sqlstate '42501' using message = 'not a managing account';
  end if;
  if member !~ '^[0-9a-f]{64}$' then
    raise sqlstate '22023' using message = 'malformed member';
  end if;
  if exists (
    select 1 from public.workspace_accounts
    where workspace_id = workspace and user_id = target
  ) then
    update public.workspace_accounts
    set can_manage = can_manage or manage,
        can_write = can_write or write or manage
    where workspace_id = workspace and user_id = target
      and ((manage and not can_manage) or ((write or manage) and not can_write));
  else
    insert into public.workspace_accounts (workspace_id, user_id, can_manage, can_write)
    values (workspace, target, manage, write or manage);
  end if;
  insert into public.workspace_members (workspace_id, member, user_id)
  values (workspace, member, target)
  on conflict on constraint workspace_members_pkey do nothing;
end;
$$;

-- Uploads count against the uploader's budget, and only a writing account
-- uploads.
create or replace function public.reserve_blob_upload(workspace text, blob text, size bigint)
returns boolean
language plpgsql volatile security definer set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  spent bigint;
begin
  if caller is null or not public.writes_workspace(workspace) then
    raise exception 'not a writing account' using errcode = '42501';
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

revoke execute on function public.writes_workspace(text),
  public.next_membership_sequence(),
  public.admit_member(text, text, uuid, boolean, boolean)
  from public, anon;
revoke execute on function public.next_membership_sequence() from authenticated;
grant execute on function public.writes_workspace(text),
  public.admit_member(text, text, uuid, boolean, boolean)
  to authenticated;
