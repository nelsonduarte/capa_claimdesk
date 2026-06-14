# capa_claimdesk

An enterprise expense-reimbursement processing engine with an approval
workflow, written in [Capa](https://github.com/nelsonduarte/Capa_language).

claimdesk takes an employee's expense claim from draft to payout and
makes the hard parts of that process unrepresentable rather than merely
tested:

- The claim **lifecycle is a typestate**. A claim is a `Claim[Draft]`,
  `Claim[UnderReview]`, `Claim[Approved]`, and so on; the state lives in
  the type, so an illegal transition (approving a draft, settling a
  claim that is still under review) does not compile, and a claim that
  is abandoned mid-process is a linearity error.
- The **payment authorization is a linear type**. The token that
  authorizes paying out an approved claim is minted once and consumed
  exactly once. It cannot be duplicated (no double payment) and cannot
  be dropped (no silently-unpaid approval); both are machine-checked.
- **Money is integer cents**, never a float, with currency carried on
  every amount so a cross-currency mistake is a typed error instead of a
  meaningless number.
- The **policy rule engine is provably pure**. Each expense-policy rule
  is a concrete type implementing one `Rule` trait; the engine holds the
  policy as a `List<Rule>` and dispatches dynamically over the mix,
  folds the per-rule outcomes, and returns a `Decision`. `rules.capa`
  and `engine.capa` reach *zero* capabilities (no Fs / Net / Db / Clock /
  Random / Stdio) and use no `Unsafe`, which `capa --manifest` proves
  mechanically. The decision then drives the typestate transition:
  `Approved` is approved and paid, `Rejected` is rejected.
- The **audit ledger is tamper-evident, and the IBAN cannot leak**. Every
  lifecycle event is appended to an HMAC-chained, append-only ledger
  (altering any past event breaks every chain value after it), the chain
  is re-verified in **constant time**, and the regulated secret, the
  employee IBAN, is held under **information-flow control**: it reaches
  the ledger only as a masked suffix or a keyed one-way fingerprint, each
  through a single audited `declassify`. Remove a declassify and the
  build hard-fails. The integrity primitives come from the SLSA-verified
  `capa_hash` library; the ledger is written through an `Fs` capability
  attenuated to the output directory.

The whole engine is designed to run **byte-identically** under the
Python interpreter (`--run`) and the WebAssembly backend
(`--wasm --run`). It uses no `Unsafe` and no networking; the domain core
is capability-free.

> Status: this is a multi-phase build.
>
> - **Phase 1** landed the repository and the domain core: money, the
>   domain vocabulary, the claim-lifecycle typestate, and the linear
>   payment authorization, plus a deterministic demo.
> - **Phase 2** adds the **policy rule engine**: a `Rule` trait with
>   several concrete policy rules, a decision engine that dispatches
>   dynamically over a `List<Rule>` and aggregates the outcomes into a
>   `Decision`, and the integration that lets that decision drive the
>   `UnderReview -> Approved` / `-> Rejected` transition. The engine is
>   provably capability-free.
> - **Phase 3** adds the **tamper-evident audit ledger and
>   information-flow control over the IBAN**: an HMAC-chained append-only
>   ledger (`ledger.capa`), constant-time chain verification, and the
>   `@secret` IBAN bridges (`mask.capa`) that mask and fingerprint the
>   account through audited declassifies. It pulls in its first external
>   dependency, the SLSA-verified `capa_hash`, and writes the ledger
>   through an attenuated `Fs`. See [Phase 3](#phase-3-the-tamper-evident-ledger-and-iban-information-flow).
> - **Phase 4 (this commit)** adds the **IO adapter layer** that wires the
>   pure core to the world, each adapter holding ONE attenuated
>   capability: `config.capa` reads policy thresholds from the
>   environment (`Env`, `restrict_to_keys`), `intake.capa` imports a batch
>   of claims from CSV (`Fs`, via the `capa_csv` library), `store.capa`
>   persists claims, decisions, and ledger lines to SQLite and queries a
>   rollup (`Db`, `restrict_to`), and `report.capa` renders the summary
>   through a `Reporter` trait with Text / Csv / Json implementations
>   (dynamic dispatch). The two example claims now come from a CSV
>   fixture. See [Phase 4](#phase-4-the-io-adapter-layer).
>
> Later phases add a CLI, a test suite, and the governance / SBOM pack.

## Running the demo

From Phase 3 on, claimdesk has external dependencies (`capa_hash`, and
from Phase 4 also `capa_csv`). Vendor and verify them once with the
package manager, then run.

**Module search path.** The package's modules are imported as
`capa_claimdesk.*`, so the directory that *contains* this repository must
be on the module search path. The repo directory is itself named
`capa_claimdesk`, so the simplest invocation, from inside the repo, is to
point `CAPA_PATH` at the parent:

```sh
capa install                    # vendors + verifies capa_hash + capa_csv (GPG tag + SLSA)
CAPA_PATH=.. capa --check main.capa
CAPA_PATH=.. capa --run main.capa
CAPA_PATH=.. capa --wasm --run main.capa     # identical output, byte for byte
```

(More generally: `CAPA_PATH=/path/to/the/parent/of/this/repo`.) The
vendored dependencies under `vendor/` are resolved automatically by
`capa install`; only the `capa_claimdesk.*` package path needs
`CAPA_PATH`. Running `capa --check main.capa` with no `CAPA_PATH` is the
"cannot resolve import 'capa_claimdesk.money'" symptom: it means the
parent directory is not on the search path, not that anything is broken.

The run reads the claim batch from `data/claims.csv` (committed fixture),
writes the audit ledger to `out/ledger.log`, the SQLite store to
`out/claimdesk.db`, and the CSV report to `out/report.csv` (the whole
`out/` directory is gitignored). The `Fs` and `Db` capabilities are
attenuated to `out/` (and the intake `Fs` to `data/`) before any access,
so a mistargeted path could not escape those directories.

Expected output (the same on both backends, byte for byte):

```
claimdesk Phase 4 demo: IO adapter layer (Env config, CSV intake, Db store, Reporter)
==================================================================================

[config]      policy from Env: total<=1000.00 EUR, Meals<=75.00 EUR, receipt>=400.00 EUR
              Env attenuated; allows HOME outside config keys: no
[intake]      imported 2 claim(s) from data/claims.csv

[Draft]       claim C-2026-0007 opened for Alice Mendes (IBAN ************0154)
              3 lines, requested total 553.15 EUR
[Submitted]   submitted at tick 20260614
[UnderReview] picked up by R-3001 (Bruno Antunes)
              evaluating policy:
              - currency-consistency: pass
              - total-limit: pass
              - category-limit:Meals: pass
              - receipt-required: pass
              - duplicate-line: pass
              => APPROVED for 553.15 EUR
[Settled]     paid 553.15 EUR to Alice Mendes
              receipt: claim C-2026-0007, nonce 1

[Draft]       claim C-2026-0008 opened for Bruno Costa (IBAN ************0267)
              4 lines, requested total 153.00 EUR
[Submitted]   submitted at tick 20260614
[UnderReview] picked up by R-3001 (Bruno Antunes)
              evaluating policy:
              - currency-consistency: pass
              - total-limit: pass
              - category-limit:Meals: fail: Meals subtotal 108.00 EUR exceeds 75.00 EUR
              - receipt-required: pass
              - duplicate-line: fail: duplicate line: "Taxi to venue" appears twice
              => REJECTED: Meals subtotal 108.00 EUR exceeds 75.00 EUR; duplicate line: "Taxi to venue" appears twice
[Rejected]    by M-4002 (Carla Dias): Meals subtotal 108.00 EUR exceeds 75.00 EUR; duplicate line: "Taxi to venue" appears twice

ledger written to out/ledger.log (7 entries)
ledger verified: 7 entries, HMAC chain intact

[store]       Db attenuated to out/; allows data/secrets.db: no
              rollup from SQLite (parse_json of db.query):
                APPROVED: 1 claim(s), 553.15 EUR settled
                REJECTED: 1 claim(s), 0.00 EUR settled

[report]      CSV report written to out/report.csv

claimdesk processing summary
claims:
  C-2026-0007  APPROVED  553.15 EUR  payee ************0154
  C-2026-0008  REJECTED  0.00 EUR  payee ************0267
totals:
  APPROVED: 1 claim(s), 553.15 EUR settled
  REJECTED: 1 claim(s), 0.00 EUR settled

demo complete: claims imported from CSV, processed, persisted to SQLite, reported.
```

Each ledger line carries the masked IBAN suffix and the keyed
fingerprint, never the account, and a chain MAC over the previous line:

```
0|C-2026-0007|SUBMITTED|E-1001|fp=79d6...a789|payee=************0154|0||3 lines, requested 553.15 EUR|chain=425b...882f
1|C-2026-0007|UNDER_REVIEW|R-3001 (Bruno Antunes)|fp=79d6...a789|payee=************0154|0||picked up by reviewer|chain=b7c3...64ad
...
```

## Modules

| Module         | What it holds                                                        |
| -------------- | -------------------------------------------------------------------- |
| `money.capa`   | `Money` as integer cents, `Currency`, add/subtract/sum/compare/format; cross-currency operations are typed `Result` errors. |
| `domain.capa`  | `Employee` (with a `@secret` IBAN), `Category`, `ExpenseLine`, line totals. |
| `authz.capa`   | The `linear type DisbursementAuthorization` payment token and its one-shot consumption into a `DisbursementReceipt`. |
| `claim.capa`   | The `typestate Claim` lifecycle (`Draft -> Submitted -> UnderReview -> Approved -> Settled`, with `UnderReview -> Rejected`) and its transitions. |
| `rules.capa`   | The `Rule` trait, the `RuleOutcome` sum type, and the concrete expense-policy rules (currency consistency, total limit, per-category limit, receipt required, duplicate line). Provably capability-free. |
| `engine.capa`  | The `Decision` sum type and the decision engine: dispatches a `List<Rule>` dynamically, folds the outcomes (via a generic `Tally<T>` / `Evaluated<T>`), and returns a `Decision`. Provably capability-free. |
| `mask.capa`    | The audited `@secret`-to-public IBAN bridges: `mask_iban` (last-four display suffix) and `iban_fingerprint` (keyed one-way HMAC). Both keep their result `@secret`; the caller declassifies at the sink. Pure (zero capabilities). |
| `ledger.capa`  | The append-only, HMAC-chained tamper-evident ledger: event serialization, chaining (`chain_from` / `build_chain`), constant-time verification (`verify_chain`, `mac_matches`), and persistence. Pure except `write_ledger`, which holds only `Fs`. |
| `config.capa`  | **(Phase 4)** Loads the policy thresholds from the environment and builds the rule list. Holds **`Env` only**, attenuated with `restrict_to_keys` to the four `CLAIMDESK_*` config keys. Each numeric value is declassified once (an env value is `@secret` by default; a public config number is not). Fixed defaults keep the demo deterministic with no env var set. |
| `intake.capa`  | **(Phase 4)** Imports a batch of claims from a CSV file via the `capa_csv` library (`parse_headed`), grouping rows into domain `Employee` + `ExpenseLine` values. Holds **`Fs` only** (one attenuated read); parsing is pure. The IBAN column flows into the `@secret` field, so the imported account enters the secret domain at construction. Typed `Result` errors, never a crash. |
| `store.capa`   | **(Phase 4)** Persists claims, decisions, and ledger lines to a SQLite file and runs a per-verdict rollup query (decoded with `parse_json`). Holds **`Db` only**, attenuated with `restrict_to` to `out/`. Only the masked suffix and the keyed fingerprint are stored, never the IBAN. |
| `report.capa`  | **(Phase 4)** A `Reporter` trait with one `render` method and three implementations (`TextReporter`, `CsvReporter` via `capa_csv` `write`, `JsonReporter` via `to_json`), chosen by name and dispatched dynamically. **Pure** (no capability): main holds the `Fs` / `Stdio` that emits the rendered String. |
| `main.capa`    | The deterministic demo. **Phase 4 flow:** load config (`Env`) -> import claims from CSV (`Fs`) -> process each through the engine and the ledger -> persist to SQLite (`Db`) -> emit the report (`Fs` / `Stdio`). Two claims (one approved, one rejected) sourced from `data/claims.csv`; the IBAN masked/fingerprinted through audited declassifies; the chain verified in constant time. |

## The policy rule engine (Phase 2)

Behaviour is polymorphic through one trait. Each policy is a distinct
concrete type implementing `Rule`:

```capa
pub trait Rule
    fun name(self) -> String
    fun evaluate(self, lines: List<ExpenseLine>, total: Money) -> RuleOutcome
```

The shipped rules:

| Rule                       | Verdict on violation | Logic                                              |
| -------------------------- | -------------------- | -------------------------------------------------- |
| `CurrencyConsistencyRule`  | `Fail`               | every line must be in the claim's currency.        |
| `TotalLimitRule`           | `Fail` / `Warn`      | the claim total must not exceed a cap (a `Warn` when within a margin of it). |
| `CategoryLimitRule`        | `Fail`               | the subtotal of one `Category` must not exceed a per-category cap. |
| `ReceiptRequiredRule`      | `Warn`               | any line at or above a threshold needs a receipt.  |
| `DuplicateLineRule`        | `Fail`               | no two lines may share a category and an exact amount. |

The configurable rules take their thresholds as fields at construction,
so a deployment tunes policy by building a different `List<Rule>`, never
by editing a rule. The engine holds that heterogeneous list, calls
`evaluate` on each element (dynamic dispatch reaching the right impl),
and folds the outcomes into a `Decision`:

```
any Fail  -> Rejected  (with the failing reasons)
any Warn  -> NeedsInfo (with the warnings)
otherwise -> Approved  (with the validated total)
```

`main.capa` then drives the typestate transition from that `Decision`:
`Approved` runs `approve` and pays out, `Rejected` (and, in Phase 2,
`NeedsInfo`) runs `reject`. The rule engine and the lifecycle are
linked: a pure, machine-checkable decision chooses a compile-time-checked
state transition.

### Provably pure

`rules.capa` and `engine.capa` reach no capabilities at all. `capa
--manifest engine.capa` reports, for the engine entry point:

```json
{
  "name": "evaluate_claim",
  "declared_capabilities": [],
  "transitively_reachable_capabilities": [],
  "provably_excluded_capabilities": [
    "Clock", "Db", "Env", "Fs", "Net", "Proc", "Random", "Stdio", "Unsafe"
  ]
}
```

Only `main.capa` holds `Stdio`, and only to print the report. The
decision logic is pure data in, pure data out.

## The lifecycle

```
  Draft --submit--> Submitted --start_review--> UnderReview
      UnderReview --approve--> Approved --settle--> Settled
      UnderReview --reject---> Rejected
```

`settle` is the only transition into `Settled`, and it **consumes** a
`DisbursementAuthorization`: a claim can only be settled by spending a
freshly minted, not-yet-used payment authorization, and that token is
spent exactly there.

### What does not compile (by construction)

These are all compile-time errors, not runtime checks or tests:

```capa
approve(draft)                  // approve requires Claim[UnderReview]
settle(submitted, authz)        // settle requires Claim[Approved]

let s = submit(draft)
start_review(draft)             // draft was consumed by submit (linear)

let _ = submit(draft)           // result dropped: claim abandoned mid-protocol
```

and, for the authorization token:

```capa
let a = authorize(...)
settle(c, a)
settle(c2, a)                   // a was already consumed: cannot pay twice

let a = authorize(...)          // never consumed: a payout was authorized
                                // and then silently dropped -> compile error
```

## Money as integer cents

Capa has no implicit numeric coercion (`Float + Int` is a type error)
and binary floating point cannot represent most decimal amounts exactly,
so every amount is a whole number of minor units with its currency:

```capa
from_major(312, 40, EUR)        // 312.40 EUR  ==  Money { cents: 31240, currency: EUR }
format(money(-705, USD))        // "-7.05 USD"
add(money(100, EUR), money(50, USD))   // Err(CurrencyMismatch(EUR, USD))
```

## Phase 3: the tamper-evident ledger and IBAN information-flow

Phase 3 is the security core. It turns the lifecycle into an auditable
record and proves, at compile time, that the one regulated secret never
escapes.

### The HMAC-chained audit ledger

Every lifecycle event (submitted, under review, approved, rejected,
paid) becomes one append-only ledger entry. The entries are chained:

```
chain[i] = HMAC-SHA256(chain-key, chain[i-1] || "|" || serialized_event_i)
```

anchored to a fixed `GENESIS`. The serialization is the tamper surface:
change any field of any past event and its body bytes change, so every
downstream chain MAC fails to recompute. The HMAC is the real thing,
from the `capa_hash` library, so the chain is identical byte-for-byte on
both backends.

### Constant-time verification

`verify_chain` re-derives the whole chain and compares each stored MAC
against the recomputed one with `strings_equal` from `capa_hash`, a
**constant-time** comparison, not `==`. Comparing a MAC with `==`
short-circuits at the first differing byte (CWE-208), a timing oracle an
attacker can use to forge a tag byte by byte; the constant-time compare
looks at every byte with no early return. The MAC-equality wrapper
`mac_matches` carries the `@constant_time()` marker, which the analyzer
checks (`capa --manifest` reports `"constant_time": true` for it).

### The IBAN never leaks: information-flow control

`Employee.iban` is `@secret`. It reaches the ledger and the console only
in one of two minimised forms, each produced by `mask.capa` and disclosed
through a single audited `declassify` with a GDPR reason:

- **masked suffix** (`************0154`) for display, and
- **keyed fingerprint** (an HMAC under a managed key) to correlate an
  employee across entries without exposing the account.

`mask.capa` keeps *both* results `@secret`; the disclosure is taken at
the sink, in `run_claim`, which holds the `Stdio` draft line and the
ledger's `Fs.write`. A `declassify` only breaks the secret-to-sink chain
within its own function, so placing both at that one boundary is what
makes them load-bearing and keeps the SBOM's `declassification_sites`
count down to exactly two, both reviewable.

This is a **verifiable** property, not a convention. Delete either
declassify and `capa --check` hard-fails. Removing the fingerprint
declassify, for example:

```
error: information-flow: a @secret value is passed to 'write_ledger' as
events, which reaches a public sink inside 'write_ledger' (it sends data
out of the program). Route it through declassify(value, reason: "...")
if this disclosure is intended.
```

`run_claim` is marked `@strict_ifc()`, so these are hard errors, not
warnings.

> **A note on field-level `@secret` (compiler limitation found while
> building this).** Reading a `@secret` *struct field* (`employee.iban`)
> currently drops the field's secret label, both for a direct sink and
> across a function return. The IBAN is therefore re-bound into an
> explicitly `@secret` local (`let iban: @secret String = employee.iban`)
> at the top of `run_claim` before anything is derived from it; that
> annotation is what re-establishes the label and makes the sinks
> guarded and the declassifies load-bearing. The seam is one line and is
> commented in `main.capa`. This is reported upstream as a compiler bug;
> the workaround keeps the showcased property real and enforced.

### Capabilities stay least-privilege

Adding `capa_hash` does not widen the capability surface: it is pure,
zero-capability code. `mask.capa` is pure; in `ledger.capa` only
`write_ledger` holds `Fs` (and the verification, `verify_chain` /
`mac_matches`, is pure). The ledger is written through an `Fs` attenuated
with `fs.restrict_to("out/")`, so the persistence authority is bounded to
the output directory. At Phase 3 `capa --manifest main.capa` reported
exactly **2** `declassification_sites` (both IBAN), `mac_matches`
constant-time, and no `Unsafe` anywhere. (Phase 4 adds one more, for a
non-sensitive config value; see below.)

### Supply chain

`capa_hash` is pinned in `capa.toml` by git tag `v0.1.2` and the
publisher key `6C1D222D491FB88031E041A536CFB426101AA24B`. `capa install`
vendors it into `vendor/`, writes the resolved commit into `capa.lock`,
and verifies the GPG tag signature and SLSA provenance before any check.
`vendor/` and `capa.lock` are gitignored pre-publication.

## Phase 4: the IO adapter layer

Phase 4 connects the pure core (rules + engine) to the world through four
adapter modules, each holding **one** attenuated capability. The core
stays provably capability-free; the world is reached only through narrow,
audited seams. The whole flow stays deterministic and byte-identical on
both backends, generated SQLite database and CSV report included.

### One capability per adapter, each attenuated

`capa --manifest main.capa` (155 functions in the linked program)
reports each adapter's authority. The split is exact:

| Adapter            | Capability | Attenuation                                   |
| ------------------ | ---------- | --------------------------------------------- |
| `config.capa`      | `Env`      | `restrict_to_keys` to the `CLAIMDESK_*` keys  |
| `intake.capa`      | `Fs`       | `restrict_to("data/")` (one read)             |
| `store.capa`       | `Db`       | `restrict_to("out/")`                         |
| `report.capa`      | *(none)*   | pure; main holds the emitting `Fs` / `Stdio`  |
| `rules` / `engine` | *(none)*   | provably pure, unchanged from Phase 2         |

The demo prints each attenuation's effect: the config `Env` reports
`allows("HOME") = no` (a key outside the config set), and the store `Db`
reports `allows("data/secrets.db") = no` (a path outside `out/`). The
narrowing is monotonic and fail-closed; nothing downstream can widen it.

### The flow

```
load config (Env) -> import claims from CSV (Fs) -> process each through
the engine + ledger -> persist to SQLite (Db) -> emit report (Fs/Stdio)
```

The two example claims (one approved, one rejected) now come from the
committed `data/claims.csv` fixture, parsed by the SLSA-verified
`capa_csv` library. `store.capa` writes a `claims`, a `decisions`, and a
`ledger` table and runs a `GROUP BY verdict` rollup, decoding the
cross-backend JSON wire shape from `db.query` with `parse_json`.
`report.capa` renders the same summary through a `Reporter` trait
dispatched dynamically over the chosen implementation.

### Information flow holds across the new sources and sinks

The IBAN is `@secret`. Phase 4 adds a *source* (the CSV column) and two
*sinks* (the SQLite store and the CSV report), and the property survives
both:

- A public CSV string flowing **into** the `@secret` `Employee.iban`
  field is always allowed (a label only ever rises), so the imported
  account enters the secret domain at construction and cannot reach a
  sink without the same audited declassify the rest of the program uses.
- The store and the report persist only the already-public minimised
  forms (the masked suffix and the keyed fingerprint), produced by the
  two existing IBAN declassifies in `run_claim`. They add **no** new
  IBAN declassification site.

Phase 4 adds exactly **one** new declassification site, and it is not the
IBAN: `config.read_cents` declassifies each policy threshold read from
the environment, with the reason *"policy threshold from environment: a
public config number (a cents limit), not a deployment secret"*. This is
the honest face of `Env`'s secret-by-default rule: the environment is
where deployment secrets live, so every `env.get` is `@secret`, and a
value that genuinely is **not** sensitive (a public limit) is asserted so
at one auditable point. `capa --manifest main.capa` therefore reports
`declassification_sites: 3` (one config value + the two IBAN sites) and
still `functions_crossing_unsafe: 0`.

### Supply chain (Phase 4)

`capa_csv` is pinned in `capa.toml` by git tag `v0.1.1` and the same
publisher key, vendored and verified by `capa install` exactly like
`capa_hash`. It is pure, zero-capability code, so it does not widen the
program's capability surface.

### Two compiler gaps found while building Phase 4 (dogfooding)

Both are Wasm-backend codegen gaps: the program is `capa --check`-clean
and runs correctly under `--run`, but `--wasm --run` fails. Each was
worked around in **claimdesk** code (not the compiler) and reported
upstream with a minimal repro:

1. **Wildcard for-pattern.** `for _ in 0..n` passes `--check` and runs on
   Python, but `--wasm` fails with *"CIR lowering does not yet support:
   for-pattern WildcardPat"*. `intake.capa` binds the loop index name it
   needs anyway.

2. **Attenuation over a call result.** A capability attenuation whose
   argument is a function-call result, e.g.
   `env.restrict_to_keys(config_keys())`, makes `--wasm` emit a
   `local.tee $_alloc_tmp` referencing a local it never declares, so
   `wasm-tools parse` rejects the module (*"unknown local
   `$_alloc_tmp`"*). A direct list literal at the call site does not
   trip it, so `config.capa` passes the key list inline.

## License

MIT. See [LICENSE](LICENSE).
