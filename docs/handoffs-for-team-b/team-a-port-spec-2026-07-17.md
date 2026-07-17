PROMPT FOR TEAM A — Replicate the 2026-07-14 → 2026-07-17 work in your repo

FROM: Repo B (MiniMax M3 / GLM 5.2) coding agent, working under owner-signed
blanket GO + the 2026-07-16 owner batch directive.

TO: Repo A (Fable 5 / ChatGPT 5.6 / Opus 4.8 / Sonnet 5) coding agent.

WHO READS THIS: any model starting work on Repo A's `feature/phase-0-foundation`
branch (or whatever your equivalent working branch is). This is a port spec — it
describes WHAT to build and WHY, not a "go copy these files" — because
**Repo A is read-only from our side per the 2026-07-08 boundary**. Build it
on your side with your own state hashes, your own branch, your own cloud project
(repo A's Supabase is `aqhxhamdwmhcwxmebqbo`; never point at our
`jabjyvdkadcbfocaerno` and never point yours at ours).

═══════════════════════════════════════════════════════════════════════════
0. SCOPE
═══════════════════════════════════════════════════════════════════════════

Four items, in order. Each item is independently shippable but they compound
(item 1's `void_requests` table is referenced in item 4's git log; items 2
and 3 are linked: the vendor picker in item 3 only works once item 2's
vendor master is in place):

  1. PERM item 6 — Void-sale approval workflow (money path; SPEC WAS P1C §2.3,
     file is `app/features/pos/voidRequests.ts` analogue; guard required).
  2. Tier 3 item 1 — Vendors + Cost Schedule + Vendor ledger (AP) (money
     path; spec is the cost-schedule + AP-locked batch design).
  3. Tier 3 item 2 — Vendor picker in Buy Stock (link Buy Stock to a
     registered vendor; non-money change to existing inventory write path).
  4. Inventory Usage Summary tab (read-only client feature; no new server
     surface — the data is already in `inventory_movements`).

Plus, in the SAME session:
  5. A DR restore-drill documented to `docs/dr-restore-drill-2026-07-17.md`
     that verifies the local Supabase stack is a faithful restore target
     for the linked cloud project.

Each item has the same shape: SPEC → MIGRATION (additive) → GUARD BATTERY
(happy path + sad path + wrong-role + non-zero asymmetric fixtures) →
`npx supabase db reset` + the guard → APP LAYER (three-way seam:
mock→Dexie | online→PostgREST/RPC | offline→outbox) → `npx tsc --noEmit`
· `npx vitest run` · `npx vite build` → COMMIT (with a flagfile via
`git commit -F <msgfile>`) → PUSH → CONFIRM CI ACTUALLY GREEN → STATUS.md
update + handoff note.

═══════════════════════════════════════════════════════════════════════════
1. BEFORE YOU TOUCH ANYTHING — read these in order
═══════════════════════════════════════════════════════════════════════════

   1. `CLAUDE.md` (repo root) — the operating contract for your repo. Your
      ADR/ODR → Enterprise Architecture → Stage A → B1–B8 → C1–C8 →
      CLAUDE.md → code chain is the same shape as ours; the content is
      yours. Don't touch ADRs without owner GO.
   2. `AGENTS.md` (repo root) — Repo A's mirror of Fable 5's onboarding
      contract. Every discipline rule applies to you the same way it
      applies to us. The Provenance header (2026-07-12, owner-authorized
      copy) explains the relationship.
   3. `STATUS.md` — your per-feature source of truth. **Rule: never round
      up.** "Done" = committed AND pushed AND that specific flow tested
      end-to-end. Update it before ending the session.
   4. The newest `docs/28_Enterprise_Architecture_Audit/Phase_2_Context_Reset_Handoff.md`
      §§ — where your work last stopped, and why.
   5. `docs/28_Enterprise_Architecture_Audit/Launch_Runbook.md` — the path
      to launch + post-launch ops for YOUR repo (owner copies may differ;
      cross-check what's true on Repo A vs the Repo B version).

   You will need to know the following things about your own repo before
   you start writing code. Don't trust my descriptions of file paths —
   they're Mine, not yours. Use what you find in your own tree.

═══════════════════════════════════════════════════════════════════════════
2. NON-NEGOTIABLES (each one exists because it caught or prevented a real
   incident in OUR work this week; the same rules apply to yours)
═══════════════════════════════════════════════════════════════════════════

   - **Evidence or it didn't happen.** Every "done" names the command run
     and its output. e.g. "guards 21 PASS / 0", "vitest 24-24-0", "invoice
     #1 ₱270 journal balanced". If you didn't run it, don't claim it.
   - **Migrations are immutable once committed.** Evolve schema via NEW
     additive migrations. Functions evolve via drop+recreate in a new file.
     Never edit an old migration. (We had to drop+recreate
     `inventory_record_purchase` this week — see item 3 — but the migration
     that did it is a new file, not an edit to the original M3A migration.)
   - **Money paths are gated.** Anything touching GL postings (sales, void,
     settle, cash entries, payroll, payments, transfers) needs: the owning
     spec read first → a behavioral guard battery → full-suite attack
     (`supabase db reset` + every battery) → cross-vendor review → owner
     sign-off IN THIS REPO. A reviewer's GO is NOT authorization; the
     owner's sign-off is. Verify decision PROVENANCE, not just a ticked
     checkbox.
   - **RLS is the security boundary.** Every table: RLS enabled AND
     forced, zero anon grants; governed domains are function-only writes
     (SECURITY DEFINER, `set search_path = ''`, actor + permission +
     branch-membership checks BEFORE any write). Money is `numeric`, never
     float. Balances are DERIVED, never stored. Corrections are reversal-
     by-addition, never UPDATE/DELETE of posted rows.
   - **Tests must never touch production.** vitest pins `VITE_USE_MOCK=true`
     (or your equivalent) in `vite.config.ts`. If yours doesn't, fix that
     first — a real `.env` once sent our unit suite against the live cloud.
   - **Secrets.** `.env` is gitignored; only `VITE_SUPABASE_URL` + the
     anon key belong there. The service_role key and DB password NEVER
     touch a file. Before every push:
     `git diff origin/<branch>..HEAD | grep -iE "key|token|secret|password"`
     and read every hit.
   - **Never `git add -A`.** Stage by explicit path. Deletions are never
     incidental. Run `git status --short` after ANY generator/scaffold
     tool and account for every line.
   - **Docs never reference their own commit's SHA** (creates an
     unresolvable placeholder → endless fix-commit spiral). Reference the
     previous commit or stable anchors.

═══════════════════════════════════════════════════════════════════════════
3. ITEM 1 — PERM 6 (Void-sale approval workflow)
═══════════════════════════════════════════════════════════════════════════

**SPEC source:** P1C §2.3 + your owner's standing 2026-07-16 batch directive
"PERM item 6: Void request → Admin+ approve/reject + journal history. New
table + RPC + guard + Approvals tab. Touches money paths." The intent is
separation of duties: an operator/cashier FILES a void request; an admin+
APPROVES or REJECTS. The instant-void path is removed entirely — even
admins must wait for another admin's approval.

**Schema (additive migration):**
  - `void_requests` table with columns: id (uuid pk), company_id (fk),
    invoice_id (fk to your POS invoices), requested_by (fk to user),
    requested_at (timestamptz), reason (text not null), status
    ('Pending' | 'Approved' | 'Rejected'), decision_by (fk nullable),
    decision_at (timestamptz nullable), decision_reason (text nullable),
    journal_entry_id (fk nullable to your journal_entries — the reversal
    post), idempotency_key (text unique where not null).
  - Partial unique index: `(company_id, invoice_id) WHERE status = 'Pending'`
    so one-Pending-per-invoice is guaranteed at the DB level.
  - RLS enabled + forced. All writes function-only.

**RPCs (all SECURITY DEFINER, set search_path = '', actor + permission +
branch-membership checks BEFORE any write):**
  - `request_void(p_invoice_id, p_reason)` — caller must be the invoice's
    branch member with `pos.sell`. Validates: reason non-empty, invoice
    exists and not already voided, no Pending request exists for this
    invoice, caller is not the same user who recorded the sale (separation
    of duties — applied at the request side too, so a cashier can't file
    and immediately self-approve is impossible because the
    `approve_void_request` side has a different gate). Returns request id.
  - `list_void_requests(p_company)` — gated on `pos.void`. Returns
    Pending requests across the company.
  - `approve_void_request(p_request_id, p_decision_reason)` — gated on
    `pos.void`. MUST verify: request is Pending, actor is not the
    requester (separation of duties), actor is in the same company.
    Inlines the reversal math: (a) reverse the original sales journal
    entry (debit Sales / credit COGS flipped; debit AR / credit Cash
    flipped; etc — copy the structure from your existing
    `pos_void_sale` and invert it). (b) Return the inventory movements
    (FIFO drain) — same as the original void. (c) Audit the chain
    (audit_events row with `event_type='void_approved'` +
    `source_document_id=request_id`). (d) Update the void_requests row
    (status, decision_by, decision_at, decision_reason,
    journal_entry_id). Returns the request id.
  - `reject_void_request(p_request_id, p_reason)` — gated on `pos.void`.
    Validates Pending + same-company. Updates the row. NO reversal math
    (the sale stands).

**Guard battery (wrap in `begin; ... rollback;`):**
  - World bootstrap: 1 company, 1 branch, 1 admin (with pos.void), 1
    clerk (with pos.sell only), 1 employee (no relevant permission).
    1 invoice (created via your pos_record_sale so the original journal
    is in place).
  - HAPPY1: clerk files a void request on the invoice → admin+ approves
    → verify: invoice status = Voided, void_requests.status = Approved,
    reversal journal entry is balanced per line (sum debit = sum credit
    for each entry), inventory movement is the inverse of the original
    sale, audit_events has a void_approved row.
  - HAPPY2: clerk files on a SECOND invoice → admin+ rejects with
    reason → verify: invoice status unchanged, void_requests.status =
    Rejected, no reversal journal entry written, paid_amount unchanged.
  - SAD1: employee with no pos.sell tries to file → raises
    insufficient_privilege.
  - SAD2: admin who is the REQUESTER tries to approve their own request
    → raises insufficient_privilege (separation of duties).
  - SAD3: clerk files a SECOND request on the same invoice while the
    first is still Pending → raises (the partial unique index enforces
    this; the function should also check + raise a friendlier error
    before the INSERT).
  - SAD4: admin double-approves (the function is called twice in
    sequence) → second call raises because status is no longer Pending,
    AND verify: no double-reversal, no double-journal, no double-audit.
  - Assert 6/6 PASS, log each as `NOTICE: HAPPY1 PASS: ...` /
    `SAD1 PASS: ...`. The rollback at end-of-file un-does all writes.

**App layer:**
  - `app/features/pos/voidRequests.ts` (NEW): thin RPC client. Types
    `VoidRequest` (matching the table), `voidRequestsApi` with
    `request`, `list`, `approve`, `reject` methods. Mock-mode returns
    no-ops so the demo build stays navigable.
  - `app/features/pos/PosScreen.tsx` (MODIFIED): the existing "Void slip"
    button now calls `voidRequestsApi.request` instead of
    `posApi.voidSale`. Change the label to "Request Void" and add copy
    explaining the approval flow. The button gate should be `pos.sell`
    (not `pos.void` — anyone with `pos.sell` can file; `pos.void`
    becomes the admin-only approve permission). The `status: 'PendingVoid'`
    literal needs to be added to your PosInvoice status union if you
    don't have it.
  - `app/features/organization/approvals/ApprovalsScreen.tsx` (MODIFIED):
    add a "Pending Voids" card alongside the existing "Pending Crop
    Price Changes" and "Pending Revoke Approvals" cards. Pattern: load
    via `voidRequestsApi.list()`, show a table of (invoice #, requester,
    reason, requested_at, [Approve] [Reject] buttons). Approve opens a
    confirmation dialog. Reject opens a dialog asking for the rejection
    reason. On success, reload + toast.
  - `app/types/db.ts` (MODIFIED): add `vendor.read`, `vendor.manage`,
    and (if not already there) `'PendingVoid'` to your PosInvoice
    status union.

**Three-up on the committed tree:** `npx tsc --noEmit` clean, `npx vitest run`
green, `npx vite build` green. Then `npx supabase db push --linked` +
`npx vercel deploy --prod` (per your launch runbook; the Repo B path is
`vcp_...` but you'll use your own token).

**Cloud verification post-deploy:** query the linked cloud (your project
id, not ours) to confirm: the table exists, all 4 RPCs exist, RLS is
enabled + forced on the table.

═══════════════════════════════════════════════════════════════════════════
4. ITEM 2 — TIER 3 ITEM 1 (Vendors + Cost Schedule + AP Ledger)
═══════════════════════════════════════════════════════════════════════════

**SPEC source:** Owner 2026-07-16 batch: "Tier 3 — item 1: Cost Schedule +
Vendor master + Vendor/Customer ledger." Mirrors the customer-side P2-M9A
architecture in your repo (find it; it's the customer master +
`customer_ar_standing` derived view; you build the vendor-side mirror).

**Schema (additive migration):**
  - 6 new tables (RLS enabled + forced, all writes function-only):
    - `vendors` (master; id, company_id, vendor_code unique per company,
      name, contact, address, tax_id, payment_terms, default_account_id
      nullable FK, notes, status 'Active'|'Archived', created_by,
      created_at, updated_at).
    - `cost_schedule` (per vendor × product × effective date range;
      id, company_id, vendor_id, product_id, unit_cost numeric, effective_from
      date, effective_to date nullable, notes, created_at). The unique
      index is `(vendor_id, product_id, effective_from)`.
    - `vendor_invoices` (header; id, company_id, branch_id, vendor_id,
      invoice_number, invoice_date, due_date, total numeric, paid_amount
      numeric default 0, status 'Draft'|'Approved'|'Partial'|'Paid'|
      'Cancelled', notes, created_by, created_at, updated_at, journal_entry_id
      FK nullable).
    - `vendor_invoice_lines` (lines; id, vendor_invoice_id FK, product_id
      FK nullable, description text, quantity numeric, unit_cost numeric,
      line_total numeric generated, expense_account_id FK, cost_schedule_id
      FK nullable).
    - `vendor_payments` (header; id, company_id, branch_id, vendor_id,
      payment_date, amount numeric, method text, reference text nullable,
      notes, created_by, created_at, journal_entry_id FK nullable).
    - `vendor_payment_allocations` (links; id, vendor_payment_id FK,
      vendor_invoice_id FK, amount numeric, unique on
      (vendor_payment_id, vendor_invoice_id)).
  - 2 new permissions seeded (via your standard permission-seed
    pattern): `vendor.read` and `vendor.manage` (module='Vendors').
  - View: `vendor_ap_standing` is a FUNCTION, not a table/view
    (because it's parameterized by `(p_company, p_vendor_id default
    null)`). The body is a UNION ALL over per-vendor aggregates: total
    invoiced = sum(vendor_invoices.total WHERE status in
    ('Approved','Partial')), total paid = sum(payments that allocated
    to that vendor's invoices — but simplest is to sum the
    allocation rows), outstanding_ap = total_invoiced - total_paid.
    Read the customer-side `customer_ar_standing` function in your
    repo and mirror its shape.
  - Idempotency: vendor_invoices has a unique partial index
    `(company_id, vendor_id, invoice_number) WHERE status <> 'Cancelled'`.
    vendor_payments has a unique partial index `(company_id, vendor_id,
    idempotency_key) WHERE idempotency_key IS NOT NULL`.

**RPCs (all SECURITY DEFINER, set search_path = '', actor + permission +
branch-membership checks):**
  - `vendor_ensure_accounts(p_company)` — idempotent seed of the
    'AP' (Accounts Payable) chart-of-accounts row. vendor.manage-gated.
    Called automatically from `vendor_invoice_record` and
    `vendor_payment_record` so the first call self-heals.
  - `vendor_upsert(p_company, p_id, p_code, p_name, p_contact, p_address,
    p_tax_id, p_payment_terms, p_notes)` — create or edit. vendor.manage.
  - `cost_schedule_upsert(p_company, p_id, p_vendor_id, p_product_id,
    p_unit_cost, p_effective_from, p_effective_to, p_notes)` —
    auto-closes the prior active row for the same (vendor, product) by
    setting its `effective_to` to (new `effective_from`) - 1 day.
    vendor.manage. Idempotent.
  - `cost_schedule_lookup(p_company, p_vendor_id, p_product_id, p_on_date)`
    — returns (unit_cost, schedule_id) for the effective rate on a
    date. Read-only, gated on vendor.read.
  - `vendor_invoice_record(p_company, p_branch_id, p_vendor_id,
    p_invoice_number, p_invoice_date, p_due_date, p_lines jsonb, p_notes)`
    — records the invoice, writes ONE balanced journal entry
    (per-line debit on the chosen expense account + 1 credit row on
    AP for the total). Idempotent on (company, vendor, invoice_number).
    vendor.manage. Server validates each expense account belongs to
    the same company and is Asset/Expense type (defense against
    cross-tenant account hijack + against crediting revenue via a
    vendor bill).
  - `vendor_payment_record(p_company, p_branch_id, p_vendor_id,
    p_payment_date, p_amount, p_allocations jsonb, p_method, p_reference,
    p_notes)` — records a payment, allocates across one or more
    invoices (sum must equal amount, asserted in the function body
    with a check_violation). Writes ONE balanced journal entry
    (debit AP, credit CASH). Locks each invoice row FOR UPDATE to
    serialize concurrent payments; per-invoice status auto-advances
    to Paid/Partial based on paid_amount. vendor.manage.
  - `vendor_ap_standing(p_company, p_vendor_id default null)` — derived
    per-vendor outstanding AP. vendor.read.

**Guard battery (wrap in `begin; ... rollback;`):**
  - World bootstrap: 1 company, 1 branch, 1 admin (with vendor.manage),
    1 employee (no vendor.manage), full chart of accounts seeded
    (CASH / SALES / COGS / FG_INVENTORY / AR / AP / OPERATING_EXPENSES
    — AP needs to be present in the seed; otherwise the
    vendor_ensure_accounts call inside the guards becomes an unwanted
    coupling). 1 product, 2 vendors, 1 cost-schedule row.
  - HAPPY1: admin creates vendor + cost-schedule row + records a
    2-line invoice (1 stock line to FG_INVENTORY, 1 utility line to
    OPERATING_EXPENSES). Verifies: total=312.50, status=Approved,
    paid_amount=0, 3 journal lines (2 debits + 1 AP credit), per-entry
    balance OK, AP standing=312.50.
  - HAPPY2: full payment. Verifies: invoice status→Paid,
    paid_amount=312.50, 2 journal lines (1 AP debit + 1 CASH credit),
    per-entry balance OK, AP standing back to 0.
  - HAPPY3: partial payment on a SECOND invoice. Verifies:
    status=Partial, total=500, paid=200, AP standing=300.
  - HAPPY4: cost-schedule auto-close on new rate. Verifies: prior
    effective_to set to (new effective_from) - 1 day; lookup on
    current_date returns old rate (22.50); lookup on
    current_date+60 returns new rate (25.00).
  - SAD1: employee with no vendor.manage cannot record an invoice
    (insufficient_privilege).
  - SAD2: allocations sum (199) != payment amount (200) raises
    (check_violation).
  - SAD3: allocation (500) exceeding outstanding (300) raises
    (check_violation).
  - SAD4: re-record same (company, vendor, invoice_number) returns
    the existing id; only 1 row exists; total unchanged (₱999 attempt
    was not applied).
  - Assert 8/8 PASS.

**GOTCHA we hit and you will too:** the function signature. We originally
tried adding `p_vendor_id` at position 11 (after `p_idempotency_key`),
but the function previously took 9 args and the new arg collided with
the position. Postgres treats different arg counts as different
overloads, not as a replacement, so the OLD function still existed
and the client kept calling the 9-arg version. The fix was to APPEND
the new arg at the END (so all existing call sites resolve identically
to the new function via named-arg matching). **Whatever your
existing function signature looks like, APPEND the new args, do not
insert them in the middle.**

**App layer:**
  - `app/features/vendors/api.ts` (NEW): thin RPC client wrapping the
    8 server functions. Types: Vendor, VendorAPStanding,
    CostScheduleRow, plus the invoice-line + payment-allocation input
    shapes. Mock-mode returns [] / 'mock-id' / no-op so the demo
    build stays navigable.
  - `app/features/vendors/VendorsScreen.tsx` (NEW): vendor master data
    table (code, name, contact, terms, invoiced, paid, outstanding AP,
    status) + per-row action buttons (Edit / Record Invoice / Record
    Payment) + New Vendor button. Three Radix dialogs: VendorEditDialog
    (code, name, contact, address, tax id, terms, notes),
    InvoiceDialog (invoice #, date, due date, multi-line editor with
    description / qty / unit cost / expense account code; submit
    fetches chart_of_accounts to translate codes→ids), PaymentDialog
    (amount defaulted to outstanding AP, method, reference, notes;
    submit allocates oldest-invoice-first).
  - `app/core/routing/router.tsx` (MODIFIED): lazy import +
    `/vendors` route.
  - `app/components/layout/AppShell.tsx` (MODIFIED): new nav item
    "Vendors & AP" with an appropriate icon (Truck is what we used),
    gated on vendor.read.
  - `app/types/db.ts` (MODIFIED): PermissionKey union extended with
    'vendor.read' + 'vendor.manage'.

**Three-up + deploy + cloud verify** as in item 1.

═══════════════════════════════════════════════════════════════════════════
5. ITEM 3 — TIER 3 ITEM 2 (Vendor picker in Buy Stock)
═══════════════════════════════════════════════════════════════════════════

**SPEC source:** Owner 2026-07-16 batch: "Tier 3 — vendor picker in POS +
Customers & Credit Vendor tab (after item 1)." The "vendor picker in POS"
is implemented in the Buy Stock modal (the inventory purchase flow), not
in the sale flow (sales attribute to customers; buys attribute to vendors).

**Schema (additive migration):**
  - Add nullable `vendor_id` column to `purchase_receivings` with FK to
    `vendors(id)` on delete restrict (a receiving with a linked vendor
    cannot be silently re-linked to nothing; archiving a vendor with
    active receivings is blocked at the FK). Index `WHERE vendor_id IS
    NOT NULL`.
  - Expand the `purchase_receivings.source_type` CHECK constraint from
    `('online', 'physical')` to `('online', 'physical', 'vendor')`.
  - Drop + re-create your `inventory_record_purchase` (or equivalent)
    to accept an additional `p_vendor_id uuid default null` arg
    **APPENDED at the end** (not inserted in the middle — see the
    gotcha below).

**Validation inside the function:**
  - If `p_vendor_id` is provided: validate the vendor exists in the
    same company AND has status='Active' AND `source_type` is 'vendor'.
  - Snapshot semantics: when p_vendor_id is provided, copy the vendor's
    `name` and `contact` into the receiving's `source_name` and
    `source_contact` at insert time. Later vendor renames do NOT
    propagate. This mirrors the customer/branch snapshot pattern.

**GOTCHA we hit and you will too (twice):**
  1. The signature gotcha. We first tried inserting `p_vendor_id` in
     the middle of the signature. That made Postgres treat it as a
     new overload AND the old function kept existing, so the existing
     11-arg callers (our inventory client + the inventory-security +
     accounting-security guards) all hit the OLD function. The new
     function's arg list became a 12-arg variant; the old 11-arg
     variant kept working in parallel. We fixed this by:
       - drop function public.inventory_record_purchase(<old 11-arg sig>);
       - create or replace function public.inventory_record_purchase(<new
         12-arg sig>);
     Then all callers resolve to the same function via named-arg
     matching.
  2. We also accidentally dropped the `if p_is_equipment then insert
     into public.equipment_assets ...` block when rewriting the
     function. The inventory-security guard caught it: "DEFECT inv:
     equipment asset not registered Good". When you re-create the
     function, preserve that block verbatim from the original. Don't
     trust your rewrite to be lossless.

**Guard battery (wrap in `begin; ... rollback;`):**
  - World bootstrap: 2 companies (cross-company test), 2 branches,
    1 admin, 2 vendors (1 Active, 1 in a different company, 1
    Archived later), chart of accounts seeded.
  - HAPPY1: admin records a Buy Stock with source_type='vendor' + the
    Active vendor id → source_name + source_contact are snapshotted
    from the vendor master, vendor_id is set on the receiving row.
  - HAPPY2: source_type='vendor' WITHOUT a vendor_id (typed-in
    supplier). Function still works, vendor_id is NULL, source_name
    falls back to the caller's value.
  - HAPPY3: source_type='online' WITH a vendor_id (mismatch). Function
    raises check_violation.
  - SAD1: vendor_id pointing to a vendor in a different company →
    foreign_key_violation.
  - SAD2: vendor_id pointing to an Archived vendor → check_violation.
  - SAD3: CHECK constraint on `purchase_receivings.source_type` denies
    unknown values at the table level.
  - SAD4: Existing 11-arg call (no vendor_id) still resolves and
    produces a receiving — backward compatibility proof.
  - **Use a DIFFERENT category_key for each HAPPY/SAD block that
    creates a new item** (e.g. substrate, utilities, transport). The
    function's find-or-create generates `category_key-uuidv7_first8`
    codes; if two calls collide on the 8-char prefix (rare but it
    happens — we hit it twice) the UNIQUE(company_id, item_code)
    constraint will reject the second insert. Different categories
    guarantee different code prefixes.
  - Assert 7/7 PASS.

**Sibling-guard regression after the migration:** re-run your
existing `inventory-security` + `accounting-security` + your
item-2 (T3.1) guard. They all call the `inventory_record_purchase`
function; the 11-arg positional calls must still resolve and pass.

**App layer:**
  - `app/types/db.ts` (MODIFIED): `PurchaseReceiving.source_type` now
    `'online' | 'physical' | 'vendor'`; add optional `vendor_id` column.
  - `app/features/inventory/api.ts` (MODIFIED): `PurchaseInput` extended
    with optional `vendorId`; both the offline (Dexie) write and the
    online RPC payload now carry `vendor_id` (default null when not
    applicable).
  - `app/features/inventory/InventoryScreen.tsx` (MODIFIED): Buy Stock
    modal adds a "Registered Vendor (linked to AP)" option to the
    Purchase Location dropdown. When chosen, the Source/Platform Name
    field renders a SelectField of active vendors. Picking a vendor
    auto-fills source_name + source_contact. The submit passes
    vendorId only when the source type is 'vendor'. The receivings
    card badge shows "Vendor (Name)" alongside the existing "Online
    (...)" and "Supplier (...)" badges.
  - `app/features/customers/CustomersScreen.tsx` (MODIFIED): add a
    small "Open Vendors & AP" sibling link (gated on vendor.read)
    so the customer-side AR and vendor-side AP screens are
    discoverable from each other.

**Three-up + deploy + cloud verify** as in items 1 and 2.

═══════════════════════════════════════════════════════════════════════════
6. ITEM 4 — INVENTORY USAGE SUMMARY TAB
═══════════════════════════════════════════════════════════════════════════

**SPEC source:** Owner 2026-07-16 batch: "Inventory Usage Summary tab in
Stock Inventory." The "Log Stock Usage" flow already exists in your
inventory module (the audited negative adjustment with a "Used: ..."
reason). This is a pure read-only client feature that aggregates
those movements into a summary view.

**No server migration.** The data is already in `inventory_movements`;
the `inventory_adjust_material` write path is unchanged. The only
server work is a read-side helper on the client.

**App layer (no new guard needed):**
  - `app/types/db.ts` (MODIFIED): add a `UsageMovement` interface —
    one row from the "Log Stock Usage" flow. Fields: id, company_id,
    branch_id, item_id, material_batch_id, movement_type
    ('AdjustmentDecrease'), quantity, unit_cost, total_cost, reason,
    created_at, actor_user_id.
  - `app/features/inventory/api.ts` (MODIFIED): add
    `inventoryApi.fetchUsageMovements(companyId, branchId, fromIso?, toIso?)`.
    Filters server-side on `movement_type='AdjustmentDecrease' AND
    reason LIKE 'Used:%'`; sorted newest-first; cap 500 rows per
    query. Date bounds are optional; empty strings mean "no bound on
    that side". RLS-gated. Mock-mode returns [] (the usage flow is
    not modelled in the demo).
  - `app/features/inventory/usageSummary.ts` (NEW): pure aggregator.
    Inputs: `UsageMovement[]` + item/category maps. Outputs:
    `byCategory` rows (qty + cost + count + pct-share), top-10
    `byItem` rows, and 8-event `recent` feed (date, item, category,
    qty, cost, purpose — purpose strips the "Used:" prefix).
    `filterUsageByPeriod` helper for the date range. Mirror the
    existing `purchaseSummary.ts` shape.
  - `app/features/inventory/InventoryScreen.tsx` (MODIFIED): add a
    4th tab "Usage Summary" alongside your existing consumables /
    equipment / purchases tabs. Tab content has the same period
    filter (from/to dates + "All time" reset), three summary cards
    (Total units used, Consumed value at FIFO cost, Log events), a
    2-column "By Category" + "Top Items" section, and a "Recent
    Activity" table showing the 8 most-recent Usage events with
    their purpose. Lazy load: the Usage movements are fetched only
    when the user opens the Usage tab (useEffect gated on
    `tab==='usage'`), not on initial page load.

**Three-up on the committed tree:** `tsc --noEmit` clean, `vitest
run` green, `vite build` green. No cloud migration, no guard.
The underlying `inventory_movements` data + the
`inventory_adjust_material` write path are already covered by your
existing inventory-security guard (re-run it post-deploy to confirm
no regression — we re-ran and it stayed 10/10 green).

═══════════════════════════════════════════════════════════════════════════
7. ITEM 5 — DR RESTORE-DRILL (docs-only commit)
═══════════════════════════════════════════════════════════════════════════

**SPEC source:** Owner 2026-07-16 batch: "DR restore-drill against
owner's chosen target DB."

**Methodology:**
  1. Dump the live cloud schema to
     `backups/cloud-pre-drill.sql`:
     `npx supabase db dump --linked --password <pw> --file backups/cloud-pre-drill.sql`
  2. Dump the live cloud data to
     `backups/cloud-data-YYYYMMDD-HHMMSS.sql`:
     `npx supabase db dump --linked --data-only --use-copy --password <pw> --file backups/cloud-data-$(date +%Y%m%d-%H%M%S).sql`
     (the `--use-copy` flag is what makes the rows appear in
     `COPY ... FROM stdin` blocks instead of `INSERT INTO` — much
     faster for big dumps and easier to diff/grep).
  3. Reset the local stack to apply all migrations:
     `npx supabase db reset --local`
  4. Count tables, functions, RLS-forced tables, seeded permissions
     in both stacks. Diff the function lists.
  5. Read back the row counts on the key business tables (companies,
     invoices, vendor_invoices, void_requests, etc.) to confirm the
     data shape is consistent with the live cloud.

**Expected result:** schemas in sync modulo 1 cloud-managed function
(`rls_auto_enable` on our cloud; equivalent on yours will be whatever
Supabase adds automatically — it's a Supabase-platform trigger, not
in your migration chain). 51=51 tables, 50=50 RLS-forced, ~85=~85 app
functions, 34=34 seeded permissions.

**Document to commit:** `docs/dr-restore-drill-2026-07-17.md` (we put
our date in the filename; use yours). Include: the methodology, the
table of counts, the conclusion ("local Supabase stack is a faithful
restore target"), the restore procedure for the next DR event
(`npx supabase db reset --local` OR restore from schema dump, then
apply data dump, then run all sibling guards), and the deliberate
scope cuts (auth users, storage/realtime, cross-tenant RLS attacks
after restore).

**CRITICAL:** `backups/` MUST be in your `.gitignore` (it should
already be — line 24 of ours is `backups/`). Run
`git check-ignore -v backups/*.sql` to confirm. NEVER commit a
backup file — they contain user rows.

═══════════════════════════════════════════════════════════════════════════
8. POST-SHIP CHECKLIST (per item)
═══════════════════════════════════════════════════════════════════════════

  - [ ] Spec read first (your repo's version, not ours — paths differ)
  - [ ] Migration is ADDITIVE (no edits to old migration files)
  - [ ] New RPCs are SECURITY DEFINER, set search_path = '', with
        actor + permission + branch-membership checks BEFORE any write
  - [ ] Guard battery written (happy + sad + role + non-zero asymmetric
        fixtures), wrapped in begin; ... rollback;
  - [ ] All guard assertions PASS (`raise notice 'PASS'`)
  - [ ] Sibling guards re-run green (no regression)
  - [ ] App layer (mock + online + offline) for the new surface
  - [ ] Three-up: `npx tsc --noEmit` clean · `npx vitest run` green ·
        `npx vite build` green
  - [ ] Stage by EXPLICIT path (no `git add -A`)
  - [ ] Secret sweep clean
        (`git diff --cached | grep -iE "key|token|secret|password"`)
  - [ ] Commit via flagfile (`git commit -F <msgfile>`) — never
        reference your own commit's SHA in the message
  - [ ] Push to your working branch (not main, not develop)
  - [ ] `npx supabase db push --linked` (or your equivalent)
  - [ ] `npx vercel deploy --prod` (or your equivalent) — use YOUR
        token, YOUR project
  - [ ] Cloud verify: query the linked cloud to confirm tables +
        RPCs + permissions + functions are live
  - [ ] Prod health: `curl -sI https://<your-domain>/` returns 200
  - [ ] STATUS.md row added (or updated) in §2 with explicit
        verification evidence
  - [ ] Maintenance log §4 appended with the session narrative
  - [ ] Backup files (if any) confirmed gitignored
        (`git check-ignore -v backups/*.sql`)

═══════════════════════════════════════════════════════════════════════════
9. GOTCHAS WE HIT THIS WEEK (so you don't have to)
═══════════════════════════════════════════════════════════════════════════

  1. **Signature-order gotcha** (hit twice — T3.1 and T3.2): adding a
     new arg to a SECURITY DEFINER function in the middle of the
     signature doesn't replace the function; it creates a new
     overload, so all existing callers keep hitting the old one.
     FIX: append the new arg at the end with a default value. Then
     `drop function <old sig>; create or replace function <new sig>;`.
  2. **Lost code block during function rewrite** (T3.2): when we
     re-created `inventory_record_purchase` to add the vendor_id
     arg, we accidentally dropped the
     `if p_is_equipment then insert into equipment_assets ...` block.
     The inventory-security guard caught it ("DEFECT inv: equipment
     asset not registered Good"). FIX: when rewriting a function,
     diff the new body against the old line-by-line; don't trust
     the rewrite to be lossless. The block was preserved verbatim
     from the original M3A function.
  3. **Manual UPDATE as authenticated** (P2N2 development): the
     guard tried to do `update public.void_requests set status =
     'Rejected' ...` after the EXCEPTION handler, but the role
     context was still `authenticated` (no UPDATE grant on
     void_requests). FIX: don't do manual cleanup of approval-queue
     rows in the guard — the outer transaction's `rollback;` at
     end-of-file undoes all SAD writes anyway. If you DO need a
     cleanup, set `set local role postgres;` immediately before the
     UPDATE.
  4. **Dead reference to a non-existent column** (P2N2): a guard
     block had `select void_status into v_void_status` referencing
     a column that didn't exist. Caused a "column does not exist"
     error and obscured the actual assertion. FIX: trust the
     function's own output (it returns the id) instead of post-
     asserting via a separate SELECT.
  5. **`raise exception '...%'` without a parameter** (T3.2
     development): `raise exception 'vendor not found %' using
     errcode = '...';` — the `%` is a placeholder for a parameter
     that wasn't passed. FIX: either pass the parameter or remove
     the `%`.
  6. **JSX attribute strings with inner double-quotes** (T3.3
     development): `<EmptyState hint="Use the "Log Stock Usage"
     button..." />` — the inner `"` broke the attribute. FIX: use
     single-quoted attribute strings for hints/copy that contain
     double-quoted terms (`hint='Use the "Log Stock Usage" button...'`).
  7. **Mock mode DBs that haven't been hydrated** (T3.2
     development): `vendorsApi.list()` is called in a useEffect
     that runs on mount, but the user might be in mock mode where
     the suppliers list is empty. The Buy Stock modal must handle
     the empty state gracefully (show a "No active vendors yet"
     message with a link to /vendors) instead of crashing on
     `vendors.map(...)`.
  8. **Unique-constraint collisions on item_code** (T3.2 guard
     development): the `inventory_record_purchase` function
     generates `category_key-uuidv7_first8` codes. If two calls in
     the same guard run happen to collide on the 8-char prefix
     (rare but possible), the UNIQUE(company_id, item_code)
     constraint rejects the second insert. FIX: use a different
     category_key for each HAPPY/SAD block in the guard that
     creates a new item (e.g. substrate, utilities, transport).
  9. **`<Skeleton className="..." />` is not allowed** (T3.1
     development): the existing `Skeleton` component takes
     `rows?: number` only — it does not accept className. FIX: use
     `<Skeleton rows={N} />` or wrap in a div. Check the
     CustomersScreen for the correct pattern.

═══════════════════════════════════════════════════════════════════════════
10. EVIDENCE THE WORK IS REAL
═══════════════════════════════════════════════════════════════════════════

The full Repo B session record (with all the evidence: commit SHAs,
guard output, three-up output, cloud-verification queries, prod
health) is in our `STATUS.md` §4 maintenance log entry titled
"2026-07-17 (overnight autonomous session, owner batch GO)" and
the per-item rows in §2. You can use those as a reference for what
the final state should look like — but again, YOUR paths, YOUR
SHAs, YOUR cloud project, YOUR status. Replicate the shape, not
the bytes.

═══════════════════════════════════════════════════════════════════════════
11. WHAT YOU PROBABLY DON'T NEED TO DO
═══════════════════════════════════════════════════════════════════════════

  - Re-read the cross-repo handoff docs in
    `docs/28_Enterprise_Architecture_Audit/` unless you're unsure
    about the spec lineage. They're authoritative for us; for you,
    your own ADRs are.
  - Port the STATUS.md text verbatim. The facts are common; the
    file paths and SHAs are not.
  - Re-derive the AGENTS.md / CLAUDE.md rules. They were
    byte-for-byte shared between repos at the 2026-07-12
    copy event; if you see drift, flag it to the owner, don't
    unilaterally reconcile.

═══════════════════════════════════════════════════════════════════════════
12. SIGN-OFF
═══════════════════════════════════════════════════════════════════════════

Each of the 4 items above carries its own money-path gate. The owner
batch GO covers all four. The behavioral guard batteries (6+8+7=21
new assertions for items 1+2+3; items 4 and 5 don't need new guards)
are the SQL proof; the cloud-verification queries are the deploy
proof; the prod-health curl is the live proof. If you follow this
spec and your guards show 21 PASS / 0 FAIL on items 1+2+3 + the
inventory-security sibling still 10/10 green, you're at parity.

Good luck. Don't round up. When you're done, update your STATUS.md
and your §4 maintenance log; the owner will read those before
deciding what to review next.

— MiniMax M3 (Repo B), 2026-07-17
