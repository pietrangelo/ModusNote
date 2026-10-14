-- Deleting an account, as Google Play requires of apps that create one.
--
-- The server holds an account's email (in auth.users), its place in the
-- workspaces it syncs, the link rows it posted, and the ciphertext of the
-- workspaces it alone belongs to. delete_account removes all of it in one
-- transaction, as the caller, for the caller only. A workspace another
-- account still belongs to keeps its rows: they are that account's notes
-- too, and stay as unreadable to the server as before.
--
-- The encrypted blobs on R2 are not in the database: the delete-account
-- Edge Function removes those of sole_workspaces() before calling
-- delete_account, and again after, for the workspaces it returns.

-- The workspaces the caller is the only account of.
create function public.sole_workspaces()
returns setof text
language sql stable security definer set search_path = ''
as $$
  select mine.workspace_id
  from public.workspace_accounts mine
  where mine.user_id = auth.uid()
    and not exists (
      select 1 from public.workspace_accounts others
      where others.workspace_id = mine.workspace_id
        and others.user_id <> mine.user_id
    )
  order by mine.workspace_id;
$$;

-- Returns the workspaces it deleted with all their rows.
create function public.delete_account()
returns setof text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  gone text[];
begin
  if caller is null then
    raise exception 'no account' using errcode = '42501';
  end if;
  -- Adding an account to a workspace locks the workspace row (its foreign
  -- key), so this waits for an admission in flight and holds off the next:
  -- a workspace another account has joined is never deleted.
  perform 1 from public.workspaces
  where id in (select workspace_id from public.workspace_accounts where user_id = caller)
  order by id
  for update;

  select coalesce(array_agg(id), '{}') into gone
  from public.sole_workspaces() as id;
  -- Rows, membership records and key bundles go with the workspace
  -- (on delete cascade): the streams stay append-only for everyone else.
  delete from public.workspaces where id = any (gone);
  delete from public.workspace_accounts where user_id = caller;
  delete from public.device_links where user_id = caller;
  delete from auth.users where id = caller;
  return query select unnest(gone);
end;
$$;

revoke execute on function public.sole_workspaces(), public.delete_account()
  from public, anon;
grant execute on function public.sole_workspaces(), public.delete_account()
  to authenticated;
