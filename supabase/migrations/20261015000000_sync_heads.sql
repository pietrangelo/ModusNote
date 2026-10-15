-- One cheap request to learn whether a sync has anything to fetch.
--
-- A device polls its workspace every minute while the vault is open. Most
-- polls find nothing new, yet each one asked three questions (membership
-- log, key bundles, rows). sync_heads answers all three at once with the
-- newest position of each stream, read from the primary keys, and the
-- client skips the streams it is already caught up with.
--
-- Security invoker: Row Level Security applies as for the selects it
-- replaces, so an account that is not in the workspace sees zeros, the
-- same as a workspace with nothing in it. The positions are what those
-- selects already return; nothing new is revealed.

create function public.sync_heads(workspace text)
returns table (rows bigint, key_bundles bigint, membership bigint)
language sql stable security invoker set search_path = ''
as $$
  select
    coalesce((select max(position) from public.sync_rows
              where workspace_id = workspace), 0),
    coalesce((select max(position) from public.key_bundles
              where workspace_id = workspace), 0),
    coalesce((select max(sequence) + 1 from public.membership_records
              where workspace_id = workspace), 0);
$$;

revoke execute on function public.sync_heads(text) from public, anon;
grant execute on function public.sync_heads(text) to authenticated;
