-- Where two devices of the same account meet to link into one workspace.
--
-- The device already in the workspace posts an offer (the workspace's
-- invitation, sealed under a key stretched from a one-time code shown on its
-- screen); the new device posts an answer (its public identity, sealed under
-- the same key). The server relays both and learns only their size, the
-- link's random id and which account posted them. Rows are readable by that
-- account alone, and only for a quarter of an hour; the clients delete them
-- once the link is done.

create table public.device_links (
  id bigint generated always as identity primary key,
  link_id text not null check (link_id ~ '^[0-9a-f]{32}$'),
  kind text not null check (kind in ('offer', 'answer')),
  user_id uuid not null default auth.uid(),
  payload bytea not null check (octet_length(payload) between 1 and 8192),
  created_at timestamptz not null default now()
);

create index device_links_by_account on public.device_links (user_id, kind, id);

alter table public.device_links enable row level security;

create policy "accounts read their recent links" on public.device_links
  for select to authenticated
  using (user_id = auth.uid() and created_at > now() - interval '15 minutes');
create policy "accounts post links as themselves" on public.device_links
  for insert to authenticated with check (user_id = auth.uid());
create policy "accounts remove their links" on public.device_links
  for delete to authenticated using (user_id = auth.uid());

-- Clients choose only what they post: the account, the time and the order
-- are the server's, so a row cannot be dated into the future to outlive its
-- quarter of an hour.
revoke all on public.device_links from anon, authenticated;
grant select, delete on public.device_links to authenticated;
grant insert (link_id, kind, payload) on public.device_links to authenticated;
