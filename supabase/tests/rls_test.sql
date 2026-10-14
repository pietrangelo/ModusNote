-- Row Level Security tests, run as the API role with a JWT subject, the
-- way PostgREST runs every request. Any failed assertion aborts the run.
\set ON_ERROR_STOP on
\set alice '''00000000-0000-0000-0000-00000000000a'''
\set bob   '''00000000-0000-0000-0000-00000000000b'''
\set mallory '''00000000-0000-0000-0000-0000000000ee'''
\set ws    '''00112233445566778899aabbccddeeff'''
\set other '''ffeeddccbbaa99887766554433221100'''

create function pg_temp.act_as(account text) returns void
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', coalesce(account, ''), true);
end;
$$;

-- Runs a statement that must be refused (RLS or privileges).
create function pg_temp.refused(statement text) returns void
language plpgsql as $$
begin
  execute statement;
  raise exception 'expected refusal: %', statement;
exception
  when insufficient_privilege then null;
end;
$$;

create function pg_temp.check(condition boolean, label text) returns void
language plpgsql as $$
begin
  if not condition then raise exception 'FAILED: %', label; end if;
  raise notice 'ok - %', label;
end;
$$;


begin;
select pg_temp.act_as(:alice);
insert into public.workspaces (id) values (:ws);
select pg_temp.check(
  (select can_manage from public.workspace_accounts where user_id = :alice::uuid),
  'the founder becomes a managing account'
);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
values (:ws, repeat('1', 32), 0, decode(repeat('ab', 41), 'hex')),
       (:ws, repeat('2', 32), 0, decode(repeat('cd', 41), 'hex'));
insert into public.membership_records (workspace_id, sequence, record)
values (:ws, 0, '\x01');
insert into public.key_bundles (workspace_id, bundle) values (:ws, '\x01');
select pg_temp.check(
  (select array_agg(position order by position) from public.sync_rows) = '{1,2}',
  'positions are assigned per workspace, in order'
);
commit;

begin;
select pg_temp.act_as(:mallory);
select pg_temp.check(
  (select count(*) from public.workspaces) = 0
    and (select count(*) from public.sync_rows) = 0
    and (select count(*) from public.membership_records) = 0
    and (select count(*) from public.key_bundles) = 0
    and (select count(*) from public.workspace_accounts) = 0,
  'a non-member sees nothing of the workspace'
);
select pg_temp.refused($q$
  insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
  values ('00112233445566778899aabbccddeeff', repeat('3', 32), 0,
          decode(repeat('ab', 41), 'hex'))
$q$);
select pg_temp.refused($q$
  insert into public.membership_records (workspace_id, sequence, record)
  values ('00112233445566778899aabbccddeeff', 1, '\x01')
$q$);
select pg_temp.refused($q$
  insert into public.key_bundles (workspace_id, bundle)
  values ('00112233445566778899aabbccddeeff', '\x01')
$q$);
select pg_temp.refused($q$
  insert into public.workspace_accounts (workspace_id, user_id)
  values ('00112233445566778899aabbccddeeff', '00000000-0000-0000-0000-0000000000ee')
$q$);
select pg_temp.refused($q$
  insert into public.workspaces (id, created_by)
  values ('ffeeddccbbaa99887766554433221100', '00000000-0000-0000-0000-00000000000a')
$q$);
select pg_temp.check(true, 'a non-member cannot append, join, or found as someone else');
commit;

begin;
select pg_temp.act_as(:alice);
insert into public.workspace_accounts (workspace_id, user_id) values (:ws, :bob);
commit;

begin;
select pg_temp.act_as(:bob);
select pg_temp.check(
  (select count(*) from public.sync_rows) = 2,
  'an added account reads the workspace'
);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext, position)
values (:ws, repeat('4', 32), 0, decode(repeat('ef', 41), 'hex'), 999);
select pg_temp.check(
  (select max(position) from public.sync_rows) = 3,
  'clients cannot choose their own position'
);
select pg_temp.refused($q$
  update public.sync_rows set ciphertext = decode(repeat('00', 41), 'hex')
$q$);
select pg_temp.refused($q$ delete from public.sync_rows $q$);
select pg_temp.refused($q$ update public.membership_records set record = '\x02' $q$);
select pg_temp.refused($q$ delete from public.key_bundles $q$);
select pg_temp.check(true, 'streams are append-only, even for members');
select pg_temp.refused($q$
  insert into public.workspace_accounts (workspace_id, user_id)
  values ('00112233445566778899aabbccddeeff', '00000000-0000-0000-0000-0000000000ee')
$q$);
update public.workspace_accounts set can_manage = true where user_id = :bob::uuid;
select pg_temp.check(
  not (select can_manage from public.workspace_accounts where user_id = :bob::uuid),
  'a non-manager can neither add accounts nor promote itself'
);
commit;

begin;
select pg_temp.act_as(:bob);
do $$
begin
  insert into public.membership_records (workspace_id, sequence, record)
  values ('00112233445566778899aabbccddeeff', 0, '\x02');
  raise exception 'FAILED: a membership record was overwritten';
exception
  when unique_violation then raise notice 'ok - a membership record cannot be replaced';
end;
$$;
commit;

begin;
select pg_temp.act_as(:alice);
delete from public.workspace_accounts where user_id = :bob::uuid;
commit;

begin;
select pg_temp.act_as(:bob);
select pg_temp.check(
  (select count(*) from public.sync_rows) = 0
    and (select count(*) from public.key_bundles) = 0,
  'a removed account no longer reads anything'
);
select pg_temp.refused($q$
  insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
  values ('00112233445566778899aabbccddeeff', repeat('5', 32), 0,
          decode(repeat('ab', 41), 'hex'))
$q$);
select pg_temp.check(true, 'a removed account can no longer append');
commit;

begin;
set local role anon;
select pg_temp.refused($q$ select * from public.sync_rows $q$);
select pg_temp.refused($q$ select * from public.workspaces $q$);
select pg_temp.check(true, 'the anonymous role has no access at all');
commit;

begin;
select pg_temp.act_as(:alice);
do $$
begin
  insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
  values ('00112233445566778899aabbccddeeff', 'not-an-id', 0,
          decode(repeat('ab', 41), 'hex'));
  raise exception 'FAILED: malformed record id accepted';
exception
  when check_violation then raise notice 'ok - malformed ids and sizes are refused';
end;
$$;
commit;

begin;
select pg_temp.act_as(:alice);
delete from public.workspace_accounts where user_id = :alice::uuid;
select pg_temp.check(
  (select count(*) from public.workspaces) = 0,
  'an account can leave on its own'
);
commit;

-- Device links: one account's devices meet; nobody else sees them.
begin;
select pg_temp.act_as(:alice);
insert into public.device_links (link_id, kind, payload)
values (repeat('a', 32), 'offer', '\x01'), (repeat('a', 32), 'answer', '\x02');
select pg_temp.check(
  (select count(*) from public.device_links) = 2,
  'an account reads back its own link rows'
);
select pg_temp.check(
  (select bool_and(user_id = :alice::uuid) from public.device_links),
  'link rows belong to the account that posted them'
);
select pg_temp.refused($q$
  insert into public.device_links (link_id, kind, payload, user_id)
  values (repeat('b', 32), 'offer', '\x01', '00000000-0000-0000-0000-00000000000b')
$q$);
select pg_temp.refused($q$
  insert into public.device_links (link_id, kind, payload, created_at)
  values (repeat('b', 32), 'offer', '\x01', now() + interval '1 year')
$q$);
select pg_temp.check(true, 'an account posts neither as another nor into the future');
select pg_temp.refused($q$ update public.device_links set payload = '\x03' $q$);
select pg_temp.check(true, 'link rows are never rewritten');
commit;

begin;
select pg_temp.act_as(:mallory);
select pg_temp.check(
  (select count(*) from public.device_links) = 0,
  'another account sees no link rows'
);
delete from public.device_links;
commit;

begin;
select pg_temp.act_as(:alice);
select pg_temp.check(
  (select count(*) from public.device_links) = 2,
  'another account cannot delete them either'
);
commit;

begin;
-- A row from twenty minutes ago, as the clock would leave it.
update public.device_links set created_at = now() - interval '20 minutes'
where kind = 'offer';
select pg_temp.act_as(:alice);
select pg_temp.check(
  (select count(*) from public.device_links where kind = 'offer') = 0,
  'a link row is unreadable after a quarter of an hour'
);
delete from public.device_links where link_id = repeat('a', 32);
commit;

begin;
select pg_temp.check(
  (select count(*) from public.device_links where kind = 'answer') = 0,
  'an account deletes its own link rows'
);
commit;

begin;
set local role anon;
select pg_temp.refused($q$ select * from public.device_links $q$);
select pg_temp.check(true, 'the anonymous role cannot reach device links');
commit;

-- Deleting an account: everything of the caller goes, and nothing of a
-- workspace another account still belongs to.
\set carol '''00000000-0000-0000-0000-00000000000c'''
\set dave  '''00000000-0000-0000-0000-00000000000d'''
\set solo  '''0123456789abcdef0123456789abcdef'''
\set shared '''fedcba9876543210fedcba9876543210'''

begin;
insert into auth.users (id) values (:carol), (:dave);
select pg_temp.act_as(:carol);
insert into public.workspaces (id) values (:solo), (:shared);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
values (:solo, repeat('3', 32), 0, decode(repeat('ab', 41), 'hex')),
       (:shared, repeat('4', 32), 0, decode(repeat('ab', 41), 'hex'));
insert into public.membership_records (workspace_id, sequence, record)
values (:solo, 0, '\x01'), (:shared, 0, '\x01');
insert into public.key_bundles (workspace_id, bundle) values (:solo, '\x01');
insert into public.workspace_accounts (workspace_id, user_id) values (:shared, :dave);
insert into public.device_links (link_id, kind, payload)
values (repeat('c', 32), 'offer', '\x01');
select pg_temp.check(
  (select array_agg(w) from public.sole_workspaces() w) = array[:solo],
  'sole_workspaces names only the workspaces nobody else belongs to'
);
commit;

begin;
select pg_temp.act_as(:dave);
select pg_temp.check(
  (select count(*) from public.sole_workspaces()) = 0,
  'a co-member alone in nothing has no sole workspaces'
);
commit;

begin;
select pg_temp.act_as(:carol);
select pg_temp.check(
  (select array_agg(w) from public.delete_account() w) = array[:solo],
  'delete_account returns the workspaces it deleted'
);
commit;

begin;
select pg_temp.check(
  not exists (select 1 from auth.users where id = :carol::uuid),
  'the account is gone'
);
select pg_temp.check(
  exists (select 1 from auth.users where id = :dave::uuid),
  'other accounts stay'
);
select pg_temp.check(
  not exists (select 1 from public.workspaces where id = :solo)
  and not exists (select 1 from public.sync_rows where workspace_id = :solo)
  and not exists (select 1 from public.membership_records where workspace_id = :solo)
  and not exists (select 1 from public.key_bundles where workspace_id = :solo),
  'a workspace of that account alone goes with all its rows'
);
select pg_temp.check(
  (select count(*) from public.sync_rows where workspace_id = :shared) = 1
  and (select count(*) from public.membership_records where workspace_id = :shared) = 1,
  'adversary: a workspace another account belongs to keeps its rows'
);
select pg_temp.check(
  not exists (select 1 from public.workspace_accounts where user_id = :carol::uuid),
  'the account leaves every workspace'
);
select pg_temp.check(
  not exists (select 1 from public.device_links where user_id = :carol::uuid),
  'its link rows go too'
);
commit;

begin;
select pg_temp.act_as(:dave);
select pg_temp.check(
  (select count(*) from public.sync_rows where workspace_id = :shared) = 1,
  'the remaining account still reads its workspace'
);
commit;

begin;
select pg_temp.act_as(null);
do $$
begin
  perform public.delete_account();
  raise exception 'expected refusal';
exception
  when insufficient_privilege then null;
end;
$$;
select pg_temp.check(true, 'adversary: no account, nothing to delete');
commit;

begin;
set local role anon;
select pg_temp.refused($q$ select public.delete_account() $q$);
select pg_temp.refused($q$ select public.sole_workspaces() $q$);
select pg_temp.check(true, 'the anonymous role cannot delete accounts');
commit;

-- Compaction: a pushed row drops the rows of its record it supersedes.
\set erin  '''00000000-0000-0000-0000-0000000000e1'''
\set frank '''00000000-0000-0000-0000-0000000000f1'''
\set packed '''c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0'''
\set aside  '''c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1'''
\set fenced '''c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2'''

begin;
select pg_temp.act_as(:frank);
insert into public.workspaces (id) values (:fenced);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
values (:fenced, repeat('a', 32), 0, decode(repeat('ab', 41), 'hex'));
commit;

begin;
select pg_temp.act_as(:erin);
insert into public.workspaces (id) values (:packed), (:aside);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
values (:packed, repeat('a', 32), 0, decode(repeat('ab', 41), 'hex')),
       (:packed, repeat('b', 32), 0, decode(repeat('ab', 41), 'hex')),
       (:packed, repeat('a', 32), 0, decode(repeat('ab', 41), 'hex')),
       (:aside, repeat('a', 32), 0, decode(repeat('ab', 41), 'hex'));
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext, supersedes)
values (:packed, repeat('a', 32), 0, decode(repeat('ab', 41), 'hex'), 3);
select pg_temp.check(
  (select array_agg(position order by position) from public.sync_rows
   where workspace_id = :packed) = '{2,4}',
  'a row drops the earlier rows of its record up to what it supersedes'
);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext, supersedes)
values (:packed, repeat('b', 32), 0, decode(repeat('ab', 41), 'hex'), 1000);
select pg_temp.check(
  (select array_agg(position order by position) from public.sync_rows
   where workspace_id = :packed) = '{4,5}',
  'adversary: supersedes past the end drops only older rows of that record'
);
select pg_temp.check(
  (select count(*) from public.sync_rows where workspace_id = :aside) = 1,
  'adversary: the same record in another workspace is untouched'
);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
values (:packed, repeat('a', 32), 0, decode(repeat('ab', 41), 'hex'));
select pg_temp.check(
  (select array_agg(position order by position) from public.sync_rows
   where workspace_id = :packed) = '{4,5,6}',
  'a row superseding nothing drops nothing, and positions keep growing'
);
select pg_temp.refused($q$ delete from public.sync_rows $q$);
select pg_temp.refused($q$ select public.drop_superseded_rows() $q$);
select pg_temp.check(true, 'clients still cannot delete rows themselves');
do $$
begin
  insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext, supersedes)
  values ('c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0', repeat('a', 32), 0,
          decode(repeat('ab', 41), 'hex'), -1);
  raise exception 'FAILED: negative supersedes accepted';
exception
  when check_violation then raise notice 'ok - supersedes cannot be negative';
end;
$$;
commit;

begin;
select pg_temp.act_as(:frank);
select pg_temp.check(
  (select count(*) from public.sync_rows where workspace_id = :fenced) = 1,
  'adversary: another account''s workspace is untouched'
);
commit;

-- Quotas: what one account can make the server hold. Small limits here so
-- the tests stay small; the migration sets the real ones.
\set gus   '''00000000-0000-0000-0000-0000000000a1'''
\set hana  '''00000000-0000-0000-0000-0000000000a2'''
\set full_ '''d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0'''
\set spare '''d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1'''

-- Raises unless the statement is refused with the given SQLSTATE.
create function pg_temp.refused_with(code text, statement text) returns void
language plpgsql as $$
begin
  execute statement;
  raise exception 'expected refusal %: %', code, statement;
exception
  when others then
    if sqlstate <> code then raise; end if;
end;
$$;

begin;
insert into auth.users (id) values (:gus), (:hana);
update public.quotas set value = 200 where name = 'account_bytes';
update public.quotas set value = 3 where name = 'workspaces_per_account';
update public.quotas set value = 2 where name = 'accounts_per_workspace';
update public.quotas set value = 2 where name = 'links_per_quarter_hour';
update public.quotas set value = 100 where name = 'blob_bytes';
update public.quotas set value = 250 where name = 'blob_bytes_per_day';
commit;

begin;
select pg_temp.act_as(:gus);
insert into public.workspaces (id) values (:full_), (:spare), ('d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3');
select pg_temp.refused_with('PT413', $q$
  insert into public.workspaces (id) values ('d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2')
$q$);
select pg_temp.check(true, 'an account founds only so many workspaces');
delete from public.workspace_accounts where workspace_id = 'd3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3';
select pg_temp.refused_with('PT413', $q$
  insert into public.workspaces (id) values ('d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2')
$q$);
select pg_temp.check(true, 'adversary: leaving a workspace does not give back its slot');
commit;

begin;
select pg_temp.act_as(:gus);
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
values (:full_, repeat('1', 32), 0, decode(repeat('ab', 150), 'hex'));
insert into public.membership_records (workspace_id, sequence, record)
values (:full_, 0, decode(repeat('ab', 40), 'hex'));
commit;

begin;
select pg_temp.act_as(:gus);
select pg_temp.refused_with('PT413', $q$
  insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
  values ('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', repeat('2', 32), 0, decode(repeat('ab', 61), 'hex'))
$q$);
select pg_temp.refused_with('PT413', $q$
  insert into public.key_bundles (workspace_id, bundle)
  values ('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', decode(repeat('ab', 61), 'hex'))
$q$);
select pg_temp.refused_with('PT413', $q$
  insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext)
  values ('d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1', repeat('2', 32), 0, decode(repeat('ab', 61), 'hex'))
$q$);
select pg_temp.check(true, 'the workspaces an account founded cannot grow past its bytes');
insert into public.sync_rows (workspace_id, record_id, epoch, ciphertext, supersedes)
values (:full_, repeat('1', 32), 0, decode(repeat('ab', 155), 'hex'), 1);
select pg_temp.check(
  (select count(*) from public.sync_rows where workspace_id = :full_) = 1,
  'an edit that supersedes its old revision fits in a full workspace'
);
commit;

begin;
select pg_temp.check(
  (select bytes from public.workspace_usage where workspace_id = :full_) = 155 + 40,
  'usage counts every stream, minus the rows a compaction dropped'
);
commit;

begin;
select pg_temp.act_as(:gus);
insert into public.workspace_accounts (workspace_id, user_id) values (:full_, :hana);
select pg_temp.refused_with('PT413', $q$
  insert into public.workspace_accounts (workspace_id, user_id)
  values ('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', '00000000-0000-0000-0000-0000000000a3')
$q$);
select pg_temp.check(true, 'a workspace admits only so many accounts');
commit;

begin;
select pg_temp.act_as(:gus);
insert into public.device_links (link_id, kind, payload)
values (repeat('e', 32), 'offer', '\x01'), (repeat('e', 32), 'answer', '\x01');
select pg_temp.refused_with('PT429', $q$
  insert into public.device_links (link_id, kind, payload)
  values (repeat('e', 32), 'offer', '\x01')
$q$);
select pg_temp.check(true, 'an account posts only so many link rows at a time');
commit;

begin;
update public.device_links set created_at = now() - interval '16 minutes'
where user_id = :gus::uuid;
commit;

begin;
select pg_temp.act_as(:gus);
insert into public.device_links (link_id, kind, payload)
values (repeat('e', 32), 'offer', '\x01');
commit;

begin;
select pg_temp.check(
  (select count(*) from public.device_links where user_id = :gus::uuid) = 1,
  'expired link rows are dropped and free their slots'
);
commit;

-- Uploads to R2: the blob-url function reserves before it signs.
begin;
select pg_temp.act_as(:gus);
select pg_temp.check(
  public.reserve_blob_upload(:full_, 'blob-a', 100),
  'a member reserves an upload'
);
select pg_temp.check(
  public.reserve_blob_upload(:full_, 'blob-a', 100),
  'an upload retried counts once'
);
select pg_temp.refused_with('PT413', $q$
  select public.reserve_blob_upload('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', 'blob-b', 101)
$q$);
select pg_temp.refused_with('PT413', $q$
  select public.reserve_blob_upload('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', 'blob-b', 0)
$q$);
select pg_temp.check(true, 'a blob is refused over the size limit or empty');
select public.reserve_blob_upload(:full_, 'blob-b', 100);
select pg_temp.refused_with('PT429', $q$
  select public.reserve_blob_upload('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', 'blob-c', 51)
$q$);
select pg_temp.check(true, 'the uploads of a day stay within the budget');
select pg_temp.refused_with('22023', $q$
  select public.reserve_blob_upload('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', '../x', 1)
$q$);
select pg_temp.check(true, 'adversary: a blob id outside the alphabet is refused');
commit;

begin;
select pg_temp.act_as(:hana);
select pg_temp.check(
  public.reserve_blob_upload(:full_, 'blob-c', 100),
  'the budget is per account, not per workspace'
);
commit;

begin;
select pg_temp.act_as(:mallory);
select pg_temp.refused($q$
  select public.reserve_blob_upload('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', 'blob-d', 1)
$q$);
select pg_temp.check(true, 'adversary: a non-member reserves nothing');
commit;

begin;
update public.blob_uploads set created_at = now() - interval '25 hours'
where user_id = :gus::uuid;
commit;

begin;
select pg_temp.act_as(:gus);
select pg_temp.check(
  public.reserve_blob_upload(:full_, 'blob-e', 100),
  'the budget renews after a day'
);
select pg_temp.refused($q$ select * from public.blob_uploads $q$);
select pg_temp.refused($q$ select * from public.workspace_usage $q$);
select pg_temp.refused($q$ update public.quotas set value = 1 $q$);
select pg_temp.refused($q$ select public.quota('blob_bytes') $q$);
select pg_temp.check(true, 'adversary: clients neither read nor change quotas and usage');
commit;

begin;
set local role anon;
select pg_temp.refused($q$
  select public.reserve_blob_upload('d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0', 'blob-f', 1)
$q$);
select pg_temp.check(true, 'the anonymous role reserves nothing');
commit;

begin;
select pg_temp.act_as(:gus);
select public.delete_account();
commit;

begin;
select pg_temp.check(
  not exists (select 1 from public.blob_uploads where user_id = :gus::uuid),
  'a deleted account leaves no upload records'
);
commit;
