-- Inviting another person's account into a workspace, and shutting a removed
-- member out of the server.
--
-- workspace_members tells which account each member device signs in with.
-- The device that admits a member writes it, so that any owner who later
-- removes that member can also remove its account, once no other member uses
-- it. The server already sees the members' public keys in the signed log;
-- this only adds which account each one uses. A server that lies here can
-- keep an account in or lock one out, which it could do anyway.
--
-- workspace_invites relays an invitation between two accounts the way
-- device_links does within one: an offer (the workspace's invitation sealed
-- under a key stretched from a one-time code) and answers (the invitee's
-- identity and account, sealed under the same key). The code's first six
-- symbols are the offer's lookup and the only part the server learns; the
-- rest stays secret, so the server would have to guess 50 bits, one Argon2id
-- per guess, to pass off a device of its own.

create table public.workspace_members (
  workspace_id text not null references public.workspaces (id) on delete cascade,
  member text not null check (member ~ '^[0-9a-f]{64}$'),
  user_id uuid not null,
  primary key (workspace_id, member)
);

create index workspace_members_by_account on public.workspace_members (workspace_id, user_id);

alter table public.workspace_members enable row level security;
create policy "accounts see who signs in as whom" on public.workspace_members
  for select to authenticated using (public.is_workspace_account(workspace_id));
revoke all on public.workspace_members from anon, authenticated;
grant select on public.workspace_members to authenticated;

-- An account that leaves, or is removed, takes its members' rows with it.
create function public.forget_account_members()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.workspace_members
  where workspace_id = old.workspace_id and user_id = old.user_id;
  return old;
end;
$$;

create trigger workspace_accounts_forget_members
after delete on public.workspace_accounts
for each row execute function public.forget_account_members();

-- Lets [account] (the caller's own when null) read and append the workspace,
-- and records that [member] signs in with it. Only a managing account may
-- admit; an account already in keeps its rights, gaining management if asked.
create function public.admit_member(
  workspace text,
  member text,
  account uuid default null,
  manage boolean default false
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
    update public.workspace_accounts set can_manage = true
    where workspace_id = workspace and user_id = target and manage and not can_manage;
  else
    insert into public.workspace_accounts (workspace_id, user_id, can_manage)
    values (workspace, target, manage);
  end if;
  insert into public.workspace_members (workspace_id, member, user_id)
  values (workspace, member, target)
  on conflict on constraint workspace_members_pkey do nothing;
end;
$$;

-- Forgets which account [member] used and, if no other member uses that
-- account, removes it from the workspace. The caller's own account always
-- stays: removing one of one's own devices must not lock out the others.
create function public.remove_member(workspace text, member text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  removed uuid;
begin
  if auth.uid() is null or not public.manages_workspace(workspace) then
    raise sqlstate '42501' using message = 'not a managing account';
  end if;
  delete from public.workspace_members m
  where m.workspace_id = workspace and m.member = remove_member.member
  returning m.user_id into removed;
  if removed is not null and removed <> auth.uid() and not exists (
    select 1 from public.workspace_members
    where workspace_id = workspace and user_id = removed
  ) then
    delete from public.workspace_accounts
    where workspace_id = workspace and user_id = removed;
  end if;
end;
$$;

create table public.workspace_invites (
  id bigint generated always as identity primary key,
  lookup text not null check (lookup ~ '^[0-9A-HJKMNP-TV-Z]{6}$'),
  kind text not null check (kind in ('offer', 'answer')),
  user_id uuid not null default auth.uid(),
  payload bytea not null check (octet_length(payload) between 1 and 8192),
  created_at timestamptz not null default now()
);

create index workspace_invites_by_lookup on public.workspace_invites (lookup, kind, id);
create index workspace_invites_by_account on public.workspace_invites (user_id, id);

alter table public.workspace_invites enable row level security;

-- Whoever posted an offer reads its answers; everyone reads their own rows.
-- Offers are found by lookup through invite_offer, never listed.
create function public.posted_offer(code text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.workspace_invites
    where lookup = code and kind = 'offer' and user_id = auth.uid()
      and created_at > now() - interval '15 minutes'
  );
$$;

create policy "accounts read their rows and answers to their offers"
  on public.workspace_invites for select to authenticated
  using (
    created_at > now() - interval '15 minutes'
    and (user_id = auth.uid() or (kind = 'answer' and public.posted_offer(lookup)))
  );
create policy "accounts post invite rows as themselves" on public.workspace_invites
  for insert to authenticated with check (user_id = auth.uid());
create policy "accounts remove their rows and answers to their offers"
  on public.workspace_invites for delete to authenticated
  using (user_id = auth.uid() or (kind = 'answer' and public.posted_offer(lookup)));

revoke all on public.workspace_invites from anon, authenticated;
grant select, delete on public.workspace_invites to authenticated;
grant insert (lookup, kind, payload) on public.workspace_invites to authenticated;

-- The newest offer under [code] from the last quarter of an hour.
create function public.invite_offer(code text)
returns bytea
language sql stable security definer set search_path = ''
as $$
  select payload from public.workspace_invites
  where lookup = code and kind = 'offer'
    and created_at > now() - interval '15 minutes'
  order by id desc
  limit 1;
$$;

-- The same budget as device links, per account: expired rows go first.
create function public.limit_workspace_invites()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.workspace_invites
  where user_id = new.user_id and created_at <= now() - interval '15 minutes';
  if (select count(*) from public.workspace_invites where user_id = new.user_id)
      >= public.quota('links_per_quarter_hour') then
    raise sqlstate 'PT429' using message = 'too many invite rows';
  end if;
  return new;
end;
$$;

create trigger workspace_invites_quota
before insert on public.workspace_invites
for each row execute function public.limit_workspace_invites();

-- delete_account() removes the account's other rows; its invite rows go too.
create function public.forget_account_invites()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.workspace_invites where user_id = old.id;
  return old;
end;
$$;

create trigger users_forget_invites
after delete on auth.users
for each row execute function public.forget_account_invites();

revoke execute on function public.forget_account_members(),
  public.posted_offer(text), public.limit_workspace_invites(),
  public.forget_account_invites()
  from public, anon;
revoke execute on function public.admit_member(text, text, uuid, boolean),
  public.remove_member(text, text), public.invite_offer(text)
  from public, anon;
revoke execute on function public.forget_account_members(),
  public.limit_workspace_invites(), public.forget_account_invites()
  from authenticated;
grant execute on function public.posted_offer(text),
  public.admit_member(text, text, uuid, boolean),
  public.remove_member(text, text), public.invite_offer(text)
  to authenticated;
