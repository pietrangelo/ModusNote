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
