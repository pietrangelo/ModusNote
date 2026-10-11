-- Modus Notes sync schema.
--
-- The server is zero-knowledge: it stores opaque ids, epochs, positions and
-- ciphertext produced by the client's domain envelopes. It never resolves
-- conflicts or interprets payloads, so every stream is append-only and the
-- clients decide what each row means. Row Level Security limits each
-- account to the workspaces it belongs to; the cryptographic membership
-- (signed log, GroupKeys) is enforced by the clients on top of it.

create table public.workspaces (
  id text primary key check (id ~ '^[0-9a-f]{32}$'),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);

-- Supabase accounts allowed to read and append a workspace's streams.
-- Distinct from the signed membership log: an owner removes an account
-- here as well as revoking its device, so the server stops serving it.
create table public.workspace_accounts (
  workspace_id text not null references public.workspaces (id) on delete cascade,
  user_id uuid not null,
  can_manage boolean not null default false,
  primary key (workspace_id, user_id)
);

create table public.sync_rows (
  workspace_id text not null references public.workspaces (id) on delete cascade,
  position bigint not null,
  record_id text not null check (record_id ~ '^[0-9a-f]{32}$'),
  epoch bigint not null check (epoch between 0 and 4294967295),
  ciphertext bytea not null check (octet_length(ciphertext) between 41 and 16777216),
  created_at timestamptz not null default now(),
  primary key (workspace_id, position)
);

create table public.membership_records (
  workspace_id text not null references public.workspaces (id) on delete cascade,
  sequence bigint not null check (sequence between 0 and 4294967295),
  record bytea not null check (octet_length(record) between 1 and 65536),
  created_at timestamptz not null default now(),
  primary key (workspace_id, sequence)
);

create table public.key_bundles (
  workspace_id text not null references public.workspaces (id) on delete cascade,
  position bigint not null,
  bundle bytea not null check (octet_length(bundle) between 1 and 16777216),
  created_at timestamptz not null default now(),
  primary key (workspace_id, position)
);

-- Membership checks run as definer so the policies below can consult
-- workspace_accounts without recursing into its own policies.
create function public.is_workspace_account(workspace text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.workspace_accounts
    where workspace_id = workspace and user_id = auth.uid()
  );
$$;

create function public.manages_workspace(workspace text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.workspace_accounts
    where workspace_id = workspace and user_id = auth.uid() and can_manage
  );
$$;

create function public.add_founding_account()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.workspace_accounts (workspace_id, user_id, can_manage)
  values (new.id, new.created_by, true);
  return new;
end;
$$;

create trigger workspaces_founding_account
after insert on public.workspaces
for each row execute function public.add_founding_account();

-- Positions are per workspace and assigned under a per-workspace lock held
-- until commit, so they increase in commit order: a client pulling
-- "position > cursor" can never skip a row that committed late with a lower
-- number. Clients cannot choose their own position.
create function public.assign_position()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(TG_TABLE_NAME || ':' || new.workspace_id, 0));
  execute format(
    'select coalesce(max(position), 0) + 1 from public.%I where workspace_id = $1',
    TG_TABLE_NAME
  ) into new.position using new.workspace_id;
  return new;
end;
$$;

create trigger sync_rows_position
before insert on public.sync_rows
for each row execute function public.assign_position();

create trigger key_bundles_position
before insert on public.key_bundles
for each row execute function public.assign_position();

alter table public.workspaces enable row level security;
alter table public.workspace_accounts enable row level security;
alter table public.sync_rows enable row level security;
alter table public.membership_records enable row level security;
alter table public.key_bundles enable row level security;

create policy "accounts see their workspaces" on public.workspaces
  for select to authenticated using (public.is_workspace_account(id));
create policy "accounts found workspaces as themselves" on public.workspaces
  for insert to authenticated with check (created_by = auth.uid());

create policy "accounts see co-members" on public.workspace_accounts
  for select to authenticated using (public.is_workspace_account(workspace_id));
create policy "managers add accounts" on public.workspace_accounts
  for insert to authenticated with check (public.manages_workspace(workspace_id));
create policy "managers change accounts" on public.workspace_accounts
  for update to authenticated
  using (public.manages_workspace(workspace_id))
  with check (public.manages_workspace(workspace_id));
create policy "managers remove accounts, anyone leaves" on public.workspace_accounts
  for delete to authenticated
  using (public.manages_workspace(workspace_id) or user_id = auth.uid());

create policy "accounts read rows" on public.sync_rows
  for select to authenticated using (public.is_workspace_account(workspace_id));
create policy "accounts append rows" on public.sync_rows
  for insert to authenticated with check (public.is_workspace_account(workspace_id));

create policy "accounts read membership" on public.membership_records
  for select to authenticated using (public.is_workspace_account(workspace_id));
create policy "accounts append membership" on public.membership_records
  for insert to authenticated with check (public.is_workspace_account(workspace_id));

create policy "accounts read bundles" on public.key_bundles
  for select to authenticated using (public.is_workspace_account(workspace_id));
create policy "accounts append bundles" on public.key_bundles
  for insert to authenticated with check (public.is_workspace_account(workspace_id));

-- Append-only by privilege, not only by policy: nobody but the table owner
-- can update or delete a stream row, whatever policies are added later.
revoke all on public.workspaces, public.workspace_accounts, public.sync_rows,
  public.membership_records, public.key_bundles from anon, authenticated;
grant select, insert on public.workspaces, public.sync_rows,
  public.membership_records, public.key_bundles to authenticated;
grant select, insert, update, delete on public.workspace_accounts to authenticated;
revoke execute on function public.is_workspace_account(text),
  public.manages_workspace(text), public.add_founding_account(),
  public.assign_position() from public, anon;
grant execute on function public.is_workspace_account(text),
  public.manages_workspace(text) to authenticated;
