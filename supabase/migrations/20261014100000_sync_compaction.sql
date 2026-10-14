-- Compaction of superseded revisions.
--
-- sync_rows grows with every edit, while a device only ever needs the
-- revision that wins for each record. The server cannot tell which one
-- that is: versions and times are sealed. The writer can. A pushed row
-- names in `supersedes` the position up to which every row of its record
-- is superseded by it: its writer had merged them all into the version the
-- new revision builds on (stopping before any row it could not open), and
-- wrote it later than any of them, so no device would pick one of them
-- again. This trigger drops those rows in the same transaction.
--
-- Clients still cannot update or delete anything: only this trigger
-- removes rows, only of the new row's own workspace and record, and only
-- below its position. A member who lies about `supersedes` hides older
-- revisions of a record from devices that have not pulled them yet; it can
-- already make its own revision win with a later time or a deletion.

alter table public.sync_rows
  add column supersedes bigint not null default 0 check (supersedes >= 0);

create index sync_rows_record on public.sync_rows (workspace_id, record_id, position);

create function public.drop_superseded_rows()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.supersedes > 0 then
    delete from public.sync_rows
    where workspace_id = new.workspace_id
      and record_id = new.record_id
      and position <= new.supersedes
      and position < new.position;
  end if;
  return null;
end;
$$;

-- After insert: the position trigger has run, under the workspace lock
-- that is held until commit.
create trigger sync_rows_drop_superseded
after insert on public.sync_rows
for each row execute function public.drop_superseded_rows();

revoke execute on function public.drop_superseded_rows() from public, anon;
