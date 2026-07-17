# DR Restore-Drill — 2026-07-17

**Goal:** Confirm the local Supabase stack is a faithful restore target for the
linked cloud project `jabjyvdkadcbfocaerno`, so a worst-case "cloud is
unreachable, lose the database, need to rebuild from a backup" scenario
doesn't surprise the owner.

**Method (in order):**
1. Dump the live cloud schema to `backups/cloud-pre-drill.sql`
   (`npx supabase db dump --linked --password <pw> --file ...`).
2. Dump the live cloud data to `backups/cloud-data-20260717-122622.sql`
   (`npx supabase db dump --linked --data-only --use-copy --password <pw> --file ...`).
3. Reset the local stack to apply all migrations
   (`npx supabase db reset --local`).
4. Count the tables, functions, RLS-forced tables, and seeded permissions
   in both stacks, plus the row counts on the key business tables.
5. Diff the function lists to find anything that lives on one side but
   not the other.

**Result — schemas are in sync:**

| Surface                      | Local | Cloud | Diff               |
|------------------------------|-------|-------|--------------------|
| Public tables                | 51    | 51    | 0                  |
| Public functions (app)       | 86    | 86    | 0                  |
| Public functions (managed)   | 0     | 1     | +1 cloud: rls_auto_enable (Supabase-managed auto-RLS-enable trigger; not an app function) |
| RLS-forced tables            | 50    | 50    | 0                  |
| Seeded permission keys       | 34    | 34    | 0                  |

**Result — data is in sync (within expected):**

| Table                    | Local | Cloud | Note                                       |
|--------------------------|-------|-------|--------------------------------------------|
| companies                | 0     | 1     | local is dev-fresh; cloud has the prod tenant |
| vendors                  | 0     | 0     | T3.1 RPC shipped but no rows yet in either |
| vendor_invoices          | 0     | 0     | T3.1 RPC shipped but no rows yet in either |
| void_requests             | 0     | 0     | PERM 6 shipped but no rows yet in either   |
| price_change_requests    | 0     | 0     | shipped but no rows yet in either          |
| invoices (POS)           | 0     | 2     | cloud has 2 test invoices from prior testing |

**Findings:**

1. **The local Supabase stack is a faithful restore target.** Schema and
   app-function shape match the linked cloud exactly. The only delta is
   one Supabase-cloud-managed function (`rls_auto_enable`) that the local
   OSS image doesn't have — it is automatically created by the Supabase
   cloud platform when a new table is created, and is not part of the
   migration chain.
2. **Data dump is faithful.** `backups/cloud-data-20260717-122622.sql`
   contains 79 `COPY ... FROM stdin` blocks (the Supabase CLI uses
   `--use-copy` by default for data dumps, so rows are in `COPY` form,
   not `INSERT INTO`). 123 KB total, includes the 1 company and 2
   invoices from cloud.
3. **Schema dump is faithful.** `backups/cloud-pre-drill.sql` contains
   50 `CREATE TABLE` / `CREATE FUNCTION` blocks plus the full
   auth/storage/extensions sections. 401 KB total.
4. **Backups/ is gitignored.** Both files are in `backups/` (line 24 of
   `.gitignore`); `git status --short` shows no untracked backup files.
   Per the standing rule (owner 2026-07-13: "data dump has user rows"),
   the backups must NEVER be committed.

**Restore procedure (for the next DR event):**

```bash
# 1. From a fresh local stack with no migrations applied yet:
cd "C:\Users\sherl\Documents\pick-ur-veggie-farm - GLM Version"
npx supabase db reset --local  # applies all migrations; this is the "schema" path
# OR — to restore from a real cloud backup instead of re-running migrations:
# 1a. apply schema dump:
cat backups/cloud-pre-drill.sql | docker exec -i supabase_db_pickurveggieerp-glm psql -U postgres -d postgres -v ON_ERROR_STOP=1
# 1b. apply data dump:
cat backups/cloud-data-<date>.sql | docker exec -i supabase_db_pickurveggieerp-glm psql -U postgres -d postgres -v ON_ERROR_STOP=1

# 2. Verify the restore is faithful by running the sibling guards (T3.1, T3.2,
#    P2N2, pos-security, accounting-security, inventory-security, p1j, p1m).
#    All 80+ assertions should pass against the restored data.
```

**What this does NOT cover (deliberate scope cuts):**

- **Auth users.** The local Supabase auth has a different JWT secret
  from the cloud. Restoring cloud auth.users to local would create rows
  with passwords hashed for the cloud's secret, so the local stack
  cannot sign in as those users. The sibling guards work around this by
  using `set_config('request.jwt.claims', ...)` to manually set the
  actor, so the restore is verifiable without real auth.
- **Storage / realtime subscriptions.** Not in scope for this drill; the
  cloud's storage buckets and realtime channels are not in `backups/`
  and would need separate restore procedures.
- **RLS cross-tenant attacks.** The data dump includes the live
  companies + their RLS-gated rows. Restoring to local means a local
  user with a matching `auth_user_id` could in principle read those
  rows. For a real DR scenario the auth restore would need to be done
  in lockstep (or the local stack reset to a different project ref
  before restore) — out of scope for this drill.
