-- The parts of Supabase the migration relies on, for testing on a plain
-- PostgreSQL: the API roles and auth.uid() reading the JWT subject that
-- PostgREST puts in request.jwt.claim.sub.
create role anon nologin;
create role authenticated nologin;
create schema auth;
grant usage on schema auth to anon, authenticated;
create function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema public to anon, authenticated;
