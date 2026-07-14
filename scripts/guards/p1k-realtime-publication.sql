-- P1K realtime-publication guard (Tier-2 BEHAVIORAL). Proves the 3 scoped tables are members of the
-- supabase_realtime publication (they must be, or no events get shipped to subscribers; a missing
-- membership is a silent failure — the app's realtime subscription succeeds but never fires).
-- Also confirms publication membership is NARROW (3 tables only — not a firehose; a future accidental
-- `alter publication supabase_realtime add table <x>` would show up here as a DEFECT).
-- Per AGENTS §2: BEGIN/ROLLBACK self-contained; any DEFECT raises under ON_ERROR_STOP.
\set ON_ERROR_STOP on
begin;

do $$
declare n int; members text[];
begin
  -- the 3 P1K-scoped tables must be members
  select array_agg(tablename order by tablename) into members
    from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public';
  if members is null then
    raise exception 'DEFECT p1k: supabase_realtime publication has NO tables — P1K not applied or publication dropped';
  end if;
  if not (members @> array['invoices','user_branch_roles','users']::text[]) then
    raise exception 'DEFECT p1k: P1K-scoped tables missing from supabase_realtime — actual members: %', members;
  end if;

  -- scope check — exactly 3 tables, not a firehose
  select count(*) into n
    from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public';
  if n <> 3 then
    raise exception 'DEFECT p1k: supabase_realtime publication should have exactly 3 tables (narrow P1K scope), found % — actual: %', n, members;
  end if;

  -- wal_level must be logical for Realtime to ship events at all (a misconfigured DB silently never fires)
  if (select setting from pg_settings where name = 'wal_level') <> 'logical' then
    raise exception 'DEFECT p1k: wal_level is not logical — Realtime events will never ship';
  end if;

  raise notice 'PASS p1k: 3 scoped tables (invoices, user_branch_roles, users) in supabase_realtime; wal_level=logical';
end $$;

rollback;
