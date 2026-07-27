# `wms_wcs-sequential-dispatch` — E2E verification

Verification artifacts for the sequential-dispatch / intelligent-palletising
contract (`supabase/migrations/20260731_wcs_sequential_dispatch.sql`): the
minimal outbound unit, its sequence assignment inside a dispatch wave, the
`PALLETIZE`/`WRAP` command payload contract on top of area 1's generic command
envelope, and — the part that actually matters — the **per-item** completion
propagation that turns one command result into N individual assignment
outcomes.

No real robot arm, gripper or stretch wrapper is involved. The equipment side is
driven by the same software-simulator idea as areas 1–4: the scripts
authenticate as the seeded demo identities (`request.jwt.claims` +
`set role authenticated`) and call the contract's RPCs directly, which is
exactly what a real WCS/PLC gateway would do.

## Files

| File | What it is |
|---|---|
| `simulator.sql` | psql simulator + negative-path assertions across all 9 spec requirements |
| `simulator-run.txt` | captured output of a clean run against a freshly seeded DB |
| `mcp_roundtrip.py` | same contract driven through the MCP tool layer (in-process `fastmcp.Client`) |
| `mcp_roundtrip-run.txt` | captured output of a clean MCP round-trip |
| `playwright-run.txt` | captured output of the **full** browser E2E suite (11 tests, all specs) |
| `screenshots/` | 18 full-page screenshots captured during that run |

The browser spec itself lives with the app it drives, at
`frontend/playwright/e2e/wcs-sequential-dispatch-flow.spec.ts` (Playwright's
`testDir` is fixed by `frontend/playwright.config.ts`). Its screenshots and run
log land here.

## Running it

```bash
cd supabase && supabase start          # if not already running
supabase db reset                      # 6 migrations + seed
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -q < ../openspec/specs/wms_wcs-sequential-dispatch/e2e/simulator.sql

cd ../mcp && .venv/bin/python \
  ../openspec/specs/wms_wcs-sequential-dispatch/e2e/mcp_roundtrip.py

cd ../frontend && npx playwright test
```

`simulator.sql` truncates this contract's two tables, the WES tables, the
routing/sortation tables and the four WCS tables (plus their audit/idempotency
rows) at the top, so it is safely re-runnable without a full `db reset`. The
Playwright suite as a whole does need a fresh `supabase db reset` first —
`wms-flow.spec.ts` consumes the seeded `SKU-A-001` shortage, which is a
pre-existing property of that spec, not of this one. This contract's own spec is
independently re-runnable (unique `SEQ-E2E-*` / `ZONE-SEQ-E2E` namespace plus an
`afterAll` cleanup).

## What it covers

**Outbound unit registration** — `store_code` + `product_id` + `qty` with
optional declared weight/volume, created `OPEN` at `version=1`. Refused:
`qty <= 0`, blank `store_code`, a product from another tenant, a negative
declared weight, and a warehouse the caller has no scope for (`FORBIDDEN`).
`WCS_OPERATOR` and `QUALITY_INSPECTOR` both get `FORBIDDEN` — creating an
outbound unit is an upstream business decision. Replaying the same
`idempotency_key` returns the cached response and creates exactly one row.

**Sequence assignment** — `sequence_position` + `target_pallet_code` inside an
`OPEN` wave; the outbound unit transitions to `SEQUENCED`. Refused: a duplicate
position in the same wave, an already-sequenced unit, position `0`, a blank
pallet code, a stale `expected_version` (`CONFLICT`), an unknown wave, a
`RELEASED` wave (area 2's rule, reused verbatim), and a tenant-B admin reaching
into tenant A (`FORBIDDEN`).

**Palletising dispatch** — everything `QUEUED` on one `(wave, pallet)` goes out
as ONE `PALLETIZE` command with `payload.sequence_items` sorted by
`sequence_position`; all of those assignments flip to `DISPATCHED` sharing one
`equipment_command_id`. Refused: the declared weight/volume ceiling
(planning-time, see D7 below), an empty batch, a non-`ROBOT_CELL` target, a
stale equipment version, and a cell already `RUNNING` on a *different* pallet
(D4 — one pallet is built by one cell end to end).

**Payload shape** — the same refusals reproduce through the *generic*
`wms_dispatch_equipment_command`, which is the point: the guard is a
`BEFORE INSERT` trigger, not RPC-local logic. Missing/empty `sequence_items`,
missing `target_pallet_code`, items out of ascending order, `WRAP` without
`wrap_program`, an unknown `wrap_program`, and `WRAP` on an AGV are all
`INVALID:`.

**Per-item completion propagation** — one `COMPLETED` report with
`detail.loaded_items` moves each referenced assignment individually
(`LOADED` → `COMPLETED` with its `load_position`, `SKIPPED` → `FAILED` with its
reason), and each outbound unit follows its assignment. Consistency is enforced
first: `COMPLETED` + `outcome=OVERWEIGHT`, `SUCCESS` with a `SKIPPED` item, an
unknown outcome, an item that belongs to another command, and a `LOADED` item
without a `load_position` are each refused with a distinct `INVALID:`, and
nothing moves while they are refused.

**The two weight failures are genuinely different** (design.md D7) — the same
pallet concept fails in two observable ways: at planning time the declared total
against the stated ceiling produces `INVALID:` and no command row at all; at
measurement time the cell reports `outcome=OVERWEIGHT` and the command plus its
assignments end `FAILED`. `wms_get_pallet_manifest` prints
`declared_total_weight_kg` next to `total_actual_weight_kg` so the drift is
visible.

**`WRAP` stays thin** (D8) — outcome consistency is checked (`SUCCESS`↔
`COMPLETED`, `FAILED`↔`FAILED`) but no assignment state changes; the simulator
counts `COMPLETED` assignments before and after and asserts they are equal.

**Cancellation** — a `QUEUED` assignment cancels cleanly and returns its
outbound unit to `OPEN`, which is then re-sequenced onto the same position it
just freed. A `DISPATCHED` assignment additionally cancels the shared
`PALLETIZE` command and its sibling assignments (DEVIATION 4). Already-terminal
assignments and stale versions are refused.

**Read models** — `wms_get_dispatch_sequence_status` filtered by wave returns
only that wave's assignments in `sequence_position` order with the linked
command's status; another warehouse is `FORBIDDEN`. `wms_get_pallet_manifest`
returns an **empty** manifest (`reported=false`, `items=[]`, but
`planned_item_count` filled) for a command whose result has not been reported —
not an error.

**RLS / privilege surface** — `authenticated` holds `SELECT` and nothing else on
both new tables, RLS is enabled on both, direct `INSERT`/`UPDATE`/`DELETE` are
`permission denied` even for a fully-privileged demo role, tenant B sees zero
rows, and all nine new functions are `SECURITY DEFINER`.

**Audit trail** — `wms_create_outbound_order`, `wms_assign_dispatch_sequence`,
`wms_cancel_dispatch_sequence`, `wms_dispatch_palletize_command` and the
automatic `wms_propagate_palletize_result` all write to `wms.audit_events`; the
propagation rows carry the per-item `DISPATCHED->COMPLETED` /
`DISPATCHED->FAILED` transitions nobody clicked.

## Deviations from design.md found while implementing

**1. `command_type` is hard-coded inside the dispatch RPC — again.**
design.md assumes relaxing `wms.equipment_commands`' `CHECK` constraint is
enough to make `PALLETIZE`/`WRAP` dispatchable. It is not:
`wms_dispatch_equipment_command` also hard-codes the accepted list in its own
guard, so the command is refused before the relaxed constraint is ever reached
— relaxing the constraint alone is a **no-op**. This is exactly the trap
`add-wcs-sortation-logic` documented for `DIVERT`/`SET_SPEED`, and it recurred
verbatim. The fix is the same: `create or replace` that function with the two
new values added to that one list and nothing else changed. Note the baseline:
the live body is **area 3's** replacement (`20260729`), not area 1's original —
area 4 replaced `_wms_pick_equipment_for_work_order` instead and left the
dispatch RPC alone. The replacement here is rebased on area 3's body.

**2. `WMS_ADMIN` cannot dispatch, so this contract refuses it up front.**
design.md's role table lists `WMS_ADMIN` as an allowed caller of
`wms_dispatch_palletize_command`. But that RPC calls
`wms_dispatch_equipment_command`, whose shipped role set is
`WAREHOUSE_MANAGER` / `WCS_OPERATOR` / `PROCESS_AGENT` and — alone among area 1's
RPCs — *not* `WMS_ADMIN`. Honouring design.md literally would let an admin pass
this contract's own guard, have the batch read and the payload built, and then
hit `FORBIDDEN` from the inner call. So `wms_dispatch_palletize_command` uses
the dispatch-capable set. The other three write RPCs never dispatch anything, so
they keep design.md's list (`WMS_ADMIN` included). This is the same mismatch
area 2 documented, reproduced in `simulator.sql` §4 and surfaced in the UI
rather than hidden.

**3. The two uniqueness rules are PARTIAL indexes, not plain UNIQUE.**
tasks.md 1.6 asks for `unique (outbound_order_id)` and
`unique (wave_id, sequence_position)`. Taken literally, a cancelled assignment
would permanently poison both the outbound unit and the position — you could
never re-sequence an order after cancelling it, which is precisely what the
"서열 배정 취소" requirement exists to enable. design.md's own wording is
"출고 단위당 **활성** 서열 배정 1건만", so `CANCELLED` rows are excluded from both
indexes and a cancelled assignment returns its outbound unit to `OPEN`. The
simulator and the browser spec both re-sequence a cancelled unit onto the
position it just freed.

**4. Cancelling one `DISPATCHED` assignment cancels its siblings.**
spec.md's "디스패치된 서열 배정을 취소하면 연결된 설비 명령도 취소된다" was written
as if an assignment owned its command 1:1. It does not — D3 makes `PALLETIZE`
deliberately N:1. Cancelling the command therefore also invalidates every
sibling riding it; leaving them `DISPATCHED` against a `CANCELLED` command would
be a lie. The cancel RPC moves the siblings to `CANCELLED` too, audits each one,
lists them in `cancelled_sibling_sequence_ids` and raises a
`SIBLING_SEQUENCES_CANCELLED` warning. Only the *addressed* assignment's
`expected_version` is checked — the caller cannot know its siblings' versions.

## Bugs found and fixed during verification

**A NULL-comparison hole in the payload/outcome validators.** The first draft
wrote `jsonb_typeof(item->'load_position') <> 'number'` and
`v_item_outcome not in ('LOADED','SKIPPED')`. When the key is **missing**,
`jsonb_typeof()` returns SQL `NULL`, and `null <> 'number'` is `null`, which
plpgsql's `if` treats as false — so a `LOADED` item with no `load_position`
silently passed validation and propagated a `COMPLETED` assignment with a null
load position. The simulator's `loaded_without_position` probe caught it (the
call that should have failed succeeded, which then made the *next*, legitimate
report fail with "command is already terminal"). Fixed by using
`is distinct from` and `coalesce(..., '')` for every such check, with a comment
explaining why. The same class of bug was checked for and fixed in the
`sequence_position` validator.

**A racy Playwright assertion that silently corrupted fixture data.** The
browser spec originally waited on the notice banner (`toContainText('출고 단위')`)
after clicking "Create Outbound Order". Because the banner still held the
*previous* unit's message, the assertion resolved immediately and the next
`fill()` raced the in-flight RPC's form reset — the third unit was created with
its order number wiped, and the test then could not find it in the dropdown. The
spec now waits on the form reset itself (`order number` input becomes empty),
which is specific to the create that was just issued.
