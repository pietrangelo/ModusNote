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
