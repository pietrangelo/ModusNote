-- The parts of Supabase the migration relies on, for testing on a plain
-- PostgreSQL: the API roles and auth.uid() as Supabase defines it, reading
-- the JWT subject that PostgREST exposes as a setting.
create role anon nologin;
create role authenticated nologin;
create schema auth;
grant usage on schema auth to anon, authenticated;
create function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;
grant usage on schema public to anon, authenticated;
-- The accounts table, reduced to what delete_account touches.
create table auth.users (id uuid primary key);
