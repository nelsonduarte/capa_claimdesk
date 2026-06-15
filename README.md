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
> - **Phase 4** adds the **IO adapter layer** that wires the
>   pure core to the world, each adapter holding ONE attenuated
>   capability: `config.capa` reads policy thresholds from the
>   environment (`Env`, `restrict_to_keys`), `intake.capa` imports a batch
>   of claims from CSV (`Fs`), `store.capa`
>   persists claims, decisions, and ledger lines to SQLite and queries a
>   rollup (`Db`, `restrict_to`), and `report.capa` renders the summary
>   through a `Reporter` trait with Text / Csv / Json implementations
>   (dynamic dispatch). The two example claims now come from a CSV
>   fixture. See [Phase 4](#phase-4-the-io-adapter-layer).
> - **Phase 5** completes the program **end-to-end** and
>   exercises **all eight** built-in capabilities, a **user-defined
>   capability**, and three more seed libraries. `main` now acquires
>   `Stdio`, `Fs`, `Db`, `Env`, `Net`, `Proc`, `Clock`, and `Random` and
>   **attenuates each one** before handing it to its adapter. New
>   capabilities: `fx.capa` holds an attenuated `Net` (currency
>   conversion), `scan.capa` an attenuated `Proc` (receipt verification),
>   `main` a `Random` (seeded, for deterministic transaction ids) and a
>   `Clock` (`restrict_to_after` an SLA cutoff). `notify.capa` declares a
>   **user-defined `Notifier` capability**. The command line is driven by
>   **capa_cli**, the pipeline is logged through **capa_log**, and a fixed
>   submission instant is formatted by **capa_datetime**. The default run
>   stays deterministic and byte-identical on both backends; a `--live`
>   flag switches `fx`/`scan` onto their real network/subprocess calls.
>   See [Phase 5](#phase-5-the-complete-pipeline).
>
> Phase 6 then adds the test suite (a positive `capa_test` suite for the
> pure core plus the `negative/` proofs), and Phase 7 the governance /
> SBOM pack that the program self-audits.

## Running the demo

claimdesk has external dependencies (`capa_hash`, `capa_csv`, and from
Phase 5 also `capa_cli`, `capa_log`, and `capa_datetime`). Vendor and
verify them once with the package manager, then run.

**Module search path.** The package's modules are imported as
`capa_claimdesk.*`, so the directory that *contains* this repository must
be on the module search path. The repo directory is itself named
`capa_claimdesk`, so the simplest invocation, from inside the repo, is to
point `CAPA_PATH` at the parent:

```sh
capa install                    # vendors + verifies every dependency (GPG tag + SLSA)
CAPA_PATH=.. capa --check main.capa
CAPA_PATH=.. capa --run main.capa
CAPA_PATH=.. capa --wasm --run main.capa     # identical output, byte for byte
```

The command line is parsed by `capa_cli` over `env.args()`; arguments are
forwarded after `--`:

```sh
CAPA_PATH=.. capa --run main.capa -- --help
CAPA_PATH=.. capa --run main.capa -- --reporter json
CAPA_PATH=.. capa --run main.capa -- --reporter csv
CAPA_PATH=.. capa --run main.capa -- --input data/claims.csv
CAPA_PATH=.. capa --run main.capa -- --live    # real Net/Proc calls (non-deterministic)
```

With no forwarded arguments the parse yields the deterministic defaults
(`--reporter text`, no `--live`), so the plain `--run` / `--wasm --run`
invocations above are byte-identical.

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

Expected output of the default run (the same on both backends, byte for
byte):

```
claimdesk Phase 5: full pipeline (8 capabilities, user-defined Notifier, CLI)
==============================================================================
[INFO] claimdesk start: reporter=text, live=no, input=data/claims.csv

[clock]       submission instant 2026-06-14T09:00:00Z, SLA cutoff 2026-06-16T09:00:00Z
              Clock attenuated to not-before the SLA cutoff; sleep gated until then

[config]      policy from Env: total<=1000.00 EUR, Meals<=75.00 EUR, receipt>=400.00 EUR
              Env attenuated; allows HOME outside config keys: no

[fx]          Net attenuated to api.frankfurter.app; allows evil.example.com: no
              conversion via fixed rate table (live net.get only under --live)
[scan]        Proc attenuated to python; allows rm: no
              receipt scan verdict: clean (live net.get/proc.exec only under --live)

[intake]      imported 2 claim(s) from data/claims.csv
[INFO] intake: 2 claim(s) loaded

[Draft]       claim C-2026-0007 opened for Alice Mendes (IBAN ************0154, submitted 2026-06-14T09:00:00Z)
[INFO] intake: claim C-2026-0007 opened for Alice Mendes, txn TX-989803
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
[Settled]     paid 553.15 EUR to Alice Mendes (txn TX-989803, receipt scan: clean)
              receipt: claim C-2026-0007, nonce 1
[INFO] claim C-2026-0007 approved for 553.15 EUR (txn TX-989803)
[notify:audit] C-2026-0007 APPROVED -- 553.15 EUR settled, txn TX-989803

[Draft]       claim C-2026-0008 opened for Bruno Costa (IBAN ************0267, submitted 2026-06-14T09:00:00Z)
[INFO] intake: claim C-2026-0008 opened for Bruno Costa, txn TX-484297
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
[WARN] claim C-2026-0008 rejected: Meals subtotal 108.00 EUR exceeds 75.00 EUR; duplicate line: "Taxi to venue" appears twice
[notify:audit] C-2026-0008 REJECTED -- Meals subtotal 108.00 EUR exceeds 75.00 EUR; duplicate line: "Taxi to venue" appears twice

ledger written to out/ledger.log (7 entries)
ledger verified: 7 entries, HMAC chain intact
[INFO] ledger verified: 7 entries, chain intact

[store]       Db attenuated to out/; allows data/secrets.db: no
              rollup from SQLite (parse_json of db.query):
                APPROVED: 1 claim(s), 553.15 EUR settled
                REJECTED: 1 claim(s), 0.00 EUR settled

[report]      CSV report written to out/report.csv

[report]      rendering 'text' report:
claimdesk processing summary
claims:
  C-2026-0007  APPROVED  553.15 EUR  payee ************0154
  C-2026-0008  REJECTED  0.00 EUR  payee ************0267
totals:
  APPROVED: 1 claim(s), 553.15 EUR settled
  REJECTED: 1 claim(s), 0.00 EUR settled
[INFO] claimdesk done: 2 claim(s) processed

demo complete: parsed CLI, processed batch end-to-end, all 8 capabilities exercised under least privilege.
```

The `[INFO]` / `[WARN]` lines come from a `capa_log` `Logger` threaded
through the pipeline; the `[notify:audit]` lines from the user-defined
`Notifier`; the ISO 8601 instants from `capa_datetime` (formatting a
fixed submission time, never wall-clock); and the `TX-` transaction ids
from a seeded `Random` (so they are reproducible across runs and
backends).

Each ledger line carries the masked IBAN suffix and the keyed
fingerprint, never the account, and a chain MAC over the previous line:

```
0|C-2026-0007|SUBMITTED|E-1001|fp=79d6...a789|payee=************0154|0||3 lines, requested 553.15 EUR|chain=425b...882f
1|C-2026-0007|UNDER_REVIEW|R-3001 (Bruno Antunes)|fp=79d6...a789|payee=************0154|0||picked up by reviewer|chain=b7c3...64ad
...
```

## Tests and proofs

The suite has two halves: positive tests that pin the business
behaviour, and negative cases that make the security guarantees
**executable** rather than prose.

### Positive tests (`capa test --both`)

`tests/test_*.capa` are ordinary Capa programs built on the
[`capa_test`](https://github.com/nelsonduarte/capa_test)
dev-dependency (a `Tester` with `check` / `eq_*` / `finish`
assertions). They cover the pure core, which is deterministic and so
byte-identical on both backends:

| Suite                       | Covers                                                                              |
| --------------------------- | ----------------------------------------------------------------------------------- |
| `test_money.capa`           | cent arithmetic, the currency-mismatch `Result`, list `sum` (identity + abort), `compare`, formatting of positive / negative / zero / sub-euro amounts. |
| `test_rules.capa`           | every policy rule across `Pass` / `Warn` / `Fail`, with the exact reason text.       |
| `test_engine.capa`          | decision aggregation: all-pass `Approved`, one-fail `Rejected`, warn-only `NeedsInfo`, fail-outranks-warn, joined reasons. |
| `test_mask.capa`            | IBAN suffix masking and the keyed HMAC fingerprint, pinned to a known cross-backend vector. |
| `test_ledger.capa`          | the HMAC chain, a known chain-MAC vector, `verify_chain` accepting an intact chain and **rejecting** any tampered body or MAC, the constant-time comparator. |
| `test_claim_lifecycle.capa` | the happy typestate path `Draft -> ... -> Settled` (spending a one-shot authorization) and the rejection path. |

```sh
capa test --both        # both backends + a byte-for-byte stdout diff
```

`capa test` discovers `tests/test_*.capa` under the project root and
runs each as a fresh `capa --run`; it prepends the project root and its
parent to `CAPA_PATH` itself, so the `capa_claimdesk.*` imports resolve
with no environment setup. `--both` additionally requires that the two
backends print identical stdout.

### Negative cases: the guarantees, made executable

The README claims the typestate protocol, linearity, information flow,
and constant-time discipline are enforced *by the compiler*. The
programs under [`negative/`](negative/) prove it: each one deliberately
violates exactly one guarantee and **must not compile**.

| Case                            | Guarantee forced                                          | Rejected because                                  |
| ------------------------------- | --------------------------------------------------------- | ------------------------------------------------- |
| `typestate_skip_state.capa`     | typestate protocol (no skipping states)                   | `approve` expects `Claim[UnderReview]`, got `Claim[Draft]` |
| `typestate_use_after.capa`      | linearity of the claim value                              | the claim was consumed earlier and cannot be reused |
| `linear_double_spend.capa`      | a payment authorization is one-shot                       | the authorization was consumed earlier (cannot pay twice) |
| `linear_drop.capa`              | a payment authorization cannot be silently dropped        | the authorization is dropped without being consumed |
| `ifc_leak_field.capa`           | confidentiality of the `@secret` IBAN                     | a `@secret` value reaches a public sink (no declassify) |
| `ifc_leak_destructure.capa`     | destructuring does not launder a secret label             | the destructured `@secret` IBAN reaches a public sink |
| `ct_secret_branch.capa`         | constant-time discipline (CWE-208)                        | a `@constant_time` function branches on `@secret` data |

The runner compiles each case and asserts a **non-zero** exit *and*
that the rejection names the expected reason. A case that compiled
would be a soundness hole and the runner fails loudly:

```sh
bash negative/run_negative.sh
```

```
ok   typestate_skip_state.capa  (rejected: "expects Claim[UnderReview], got Claim[Draft]")
ok   typestate_use_after.capa  (rejected: "consumed earlier and cannot be used again")
ok   linear_double_spend.capa  (rejected: "consumed earlier and cannot be used again")
ok   linear_drop.capa  (rejected: "dropped without being consumed")
ok   ifc_leak_field.capa  (rejected: "a @secret value reaches Stdio.println")
ok   ifc_leak_destructure.capa  (rejected: "a @secret value reaches Stdio.println")
ok   ct_secret_branch.capa  (rejected: "constant-time violation")
------------------------------------------------------------
negative cases: 7 rejected as expected, 0 unexpected
PASSED: every guarantee is enforced by the compiler.
```

The IFC cases use `@strict_ifc()` so a leak is a hard error rather than
the default warning; that is the only difference from the production
code, which routes every disclosure through an audited `declassify`.

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
| `intake.capa`  | **(Phase 4/5)** Imports a batch of claims from a CSV file, grouping rows into domain `Employee` + `ExpenseLine` values. Holds **`Fs` only** (one attenuated read); parsing is pure. The IBAN column flows into the `@secret` field, so the imported account enters the secret domain at construction. Parses the CSV through the real `capa_csv` library (`parse_headed` + the typed `HeaderTable` / `CsvError` model), brought in by **selective import** so it coexists with `capa_cli`'s `parse`; see the dogfooding note below. Typed `Result` errors, never a crash. |
| `store.capa`   | **(Phase 4)** Persists claims, decisions, and ledger lines to a SQLite file and runs a per-verdict rollup query (decoded with `parse_json`). Holds **`Db` only**, attenuated with `restrict_to` to `out/`. Only the masked suffix and the keyed fingerprint are stored, never the IBAN. |
| `report.capa`  | **(Phase 4)** A `Reporter` trait with one `render` method and three implementations (`TextReporter`, `CsvReporter` via `capa_csv` `write`, `JsonReporter` via `to_json`), chosen by name and dispatched dynamically. **Pure** (no capability): main holds the `Fs` / `Stdio` that emits the rendered String. The CLI's `--reporter` selects the format. |
| `fx.capa`      | **(Phase 5)** Foreign-exchange conversion of a claim amount into the settlement currency. Holds **`Net` only**, attenuated to the rate host. The default path converts with a fixed integer rate table (pure, deterministic); `fetch_rate_to_eur` does a real `net.get` to the attenuated host under `--live`. |
| `scan.capa`    | **(Phase 5)** Receipt-attachment verification. Holds **`Proc` only**, attenuated to the scanner command. The default path returns a fixed `Clean` verdict (pure, deterministic); `run_scan` does a real `proc.exec` of the attenuated command under `--live`. |
| `notify.capa`  | **(Phase 5)** A **user-defined `Notifier` capability** and a `StdioNotifier` implementor + factory (a cap-bearing struct wrapping `Stdio`). Announces each claim decision. The pipeline holds only a `Notifier`, so its whole authority there is "notify". |
| `cli.capa`     | **(Phase 5)** The command-line front end, built on the **`capa_cli`** library (`ArgSchema` / `parse` / `format_help`). Pure: turns `env.args()` into a typed `RunConfig` (`--input` / `--reporter` / `--live` / `--help`) or a help / error outcome. |
| `main.capa`    | The deterministic demo, now end-to-end. **Phase 5 flow:** parse the CLI (`capa_cli`) -> load config (`Env`) -> import the batch (`Fs`) -> for each claim mint a transaction id (`Random`, seeded), evaluate (engine), convert currency (`fx`/`Net`), scan the receipt (`scan`/`Proc`), decide + drive the typestate, settle (linear), append to the HMAC ledger, notify (`Notifier`), persist (`Db`) -> rollup + report (the CLI-chosen `Reporter`) -> verify the chain in constant time. `main` acquires **all eight** capabilities and attenuates each before handing it on; a `capa_log` `Logger` records each step and `capa_datetime` stamps a fixed instant. |

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

These are not just claims in prose. Each one is a real program under
[`negative/`](negative/) that the test runner compiles and asserts is
**rejected** by `capa --check`, for the expected reason. See
[Tests and proofs](#tests-and-proofs).

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

> **A note on field-level `@secret` (a compiler bug this showcase found,
> now fixed).** While building this, reading a `@secret` *struct field*
> (`employee.iban`) dropped the field's secret label, both for a direct
> sink and across a function return, and the same for a `let`
> destructuring of the field. That would have let the raw IBAN reach a
> sink unguarded, so an early version re-bound it into an explicitly
> `@secret` local to re-establish the label. The hole was reported
> upstream and **fixed in Capa v1.2.0** (commits `a9b4905` and
> `d2e5db5`): a `@secret` field read and destructure now carry the label.
> The workaround was therefore removed: `run_claim` derives the masked
> suffix and the fingerprint straight from `employee.iban`, the label
> rides through `mask.*`, and the two `declassify` calls are what let the
> public forms reach a sink. The `negative/ifc_leak_field.capa` and
> `negative/ifc_leak_destructure.capa` cases pin both halves of the fix:
> each sends the field (or its destructured binding) to a public sink
> with no declassify, and the compiler rejects them. This is the
> dogfooding loop the showcase is meant to exercise: build a real
> program, find a soundness gap, fix the compiler, keep the guarantee.

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

`capa --manifest main.capa` (155 functions in the linked program at this
phase; the finished Phase 5 program links 213) reports each adapter's
authority. The split is exact:

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

Both were Wasm-backend codegen gaps: the program was `capa --check`-clean
and ran correctly under `--run`, but `--wasm --run` failed. Both were
reported upstream with a minimal repro; one is now fixed in the compiler,
the other is still worked around in claimdesk code:

1. **Wildcard for-pattern (FIXED in v1.2.0).** `for _ in 0..n` was
   `--check`-clean and ran on Python, but `--wasm` failed with *"CIR
   lowering does not yet support: for-pattern WildcardPat"*. v1.2.0 lowers
   the wildcard for-pattern, so `for _ in ...` now works on both backends.

2. **Attenuation over a call result (STILL OPEN).** A capability
   attenuation whose argument is a function-call result, e.g.
   `env.restrict_to_keys(config_keys())`, makes `--wasm` emit a
   `local.tee $_alloc_tmp` referencing a local it never declares, so
   `wasm-tools parse` rejects the module (*"unknown local
   `$_alloc_tmp`"*). A direct list literal at the call site does not
   trip it, so `config.capa` passes the key list inline.

## Phase 5: the complete pipeline

Phase 5 finishes the program. `main` now acquires **all eight** built-in
capabilities and **attenuates each one** before handing it to the single
adapter that uses it, so `capa --manifest` reads as a least-privilege map
of the whole system. It also adds a **user-defined capability**, a real
command line, structured logging, and date formatting, all
cross-backend.

### All eight capabilities, each attenuated at the point of use

`capa --manifest main.capa` (213 functions in the linked program) reports
the split exactly:

| Capability | Held by                        | Attenuation                                   |
| ---------- | ------------------------------ | --------------------------------------------- |
| `Stdio`    | `main`, `report`, `Notifier`   | the console sink                              |
| `Fs`       | `intake` / `ledger` / `report` | `restrict_to("data/")` (read), `restrict_to("out/")` (writes) |
| `Db`       | `store`                        | `restrict_to("out/")`                         |
| `Env`      | `config`                       | `restrict_to_keys` to the `CLAIMDESK_*` keys  |
| `Net`      | `fx`                           | `restrict_to("api.frankfurter.app")`          |
| `Proc`     | `scan`                         | `restrict_to("python")` (the scanner command) |
| `Clock`    | `main`                         | `restrict_to_after` the SLA cutoff            |
| `Random`   | `main`                         | `with_seed(20260614)` (deterministic ids)     |

The demo prints each attenuation's effect (`allows("evil.example.com") =
no` for the fx `Net`, `allows("rm") = no` for the scan `Proc`, and so on):
the narrowing is monotonic and fail-closed. The pure core is unchanged:
`evaluate_claim` still excludes every capability.

```json
{
  "summary": {
    "total_functions": 213,
    "functions_crossing_unsafe": 0,
    "declassification_sites": 3
  },
  "user_defined_capabilities": [
    { "name": "Notifier", "methods": ["notify"], "implementors": ["StdioNotifier"] },
    { "name": "Logger",   "methods": ["log","debug","info","warn","error"], "implementors": ["StdioLogger"] }
  ]
}
```

```
evaluate_claim  -> provably excludes Clock Db Env Fs Logger Net Notifier Proc Random Stdio Unsafe
mac_matches     -> constant_time: true
run_claim       -> @strict_ifc, holds exactly Fs Notifier Logger Stdio
main            -> holds Stdio Fs Db Env Net Proc Clock Random
```

`declassification_sites` is still **3** (one config value plus the two
IBAN sites), `functions_crossing_unsafe` is **0**, the ledger's
`mac_matches` is still **constant-time**, and the claim lifecycle is one
**protocol state** machine.

### A user-defined capability

`notify.capa` declares `capability Notifier` with a single `notify`
method, and `StdioNotifier` implements it over a wrapped `Stdio` (the
cap-bearing-struct relaxation). `make_stdio_notifier` is the factory that
hands the `Stdio` authority over once; downstream the pipeline holds only
a `Notifier`, so the decision-notification step cannot print anything,
anywhere, or reach any other capability. A real deployment swaps in an
`EmailNotifier` (wrapping `Net`) without touching the pipeline.

### Exercising non-deterministic capabilities deterministically

`Net` and `Proc` are real, non-deterministic capabilities; the demo keeps
the default flow deterministic without giving up least-privilege:

- **`Random`** is exercised deterministically by construction:
  `with_seed(20260614)` produces a byte-identical sequence on both
  backends, so the per-claim `TX-` transaction ids are reproducible.
- **`Clock`** is attenuated (`restrict_to_after` the SLA cutoff) to show
  the gating, but wall-clock time is never printed; `capa_datetime`
  formats a **fixed** submission instant instead, so the output does not
  drift over time or between backends.
- **`Net`** (`fx`) and **`Proc`** (`scan`) hold their capability
  attenuated and contain the real `net.get` / `proc.exec` calls, but the
  default flow uses fixed data (a fixed rate table, a fixed `Clean`
  verdict) and makes **no** network or subprocess call. A `--live` flag
  switches them onto the real calls; that path is documented as
  non-deterministic and is deliberately **not** part of the compared,
  byte-identical flow. The manifest still proves that `fx` holds a `Net`
  attenuated to the rate host and `scan` a `Proc` attenuated to the
  scanner command, and that the real calls exist.

This is the honest trade: the manifest shows the full least-privilege
surface and the real capability-bearing code, while the default demo
stays reproducible cross-backend.

### Three more seed libraries

| Library         | Tag      | Used for                                                      |
| --------------- | -------- | ------------------------------------------------------------ |
| `capa_cli`      | `v0.1.2` | the command line (`ArgSchema` / `parse` / `format_help`)     |
| `capa_log`      | `v0.1.2` | a `Logger` capability threaded through the pipeline          |
| `capa_datetime` | `v0.1.2` | ISO 8601 formatting of the fixed submission/decision instant |

All three are pinned by git tag and the same publisher key, vendored and
verified by `capa install`. `capa_cli` and `capa_datetime` are
zero-capability; `capa_log`'s `Logger` is a user-defined capability over
`Stdio`, so it does not widen the built-in surface.

### Compiler findings while building Phase 5 (dogfooding)

Building this showcase surfaced several compiler gaps, all reported
upstream with a minimal repro. Most have since been **fixed in the
compiler** (the dogfooding paid off); one remains and is still worked
around in claimdesk code:

1. **Two dependencies both exporting a top-level name (FIXED in v1.2.0).**
   `capa_cli` and `capa_csv` both declare a `pub fun parse`. In v1.1.0 the
   loader linked every imported module's `pub` items into one flat global
   namespace with no escape hatch, so the two libraries could not coexist:
   linking `capa_cli.parser` with `capa_csv.parse` was a hard
   *"name conflict: 'parse'"*. v1.2.0 adds **selective import with
   renaming** (`import capa_csv.header (parse_headed as csv_parse_headed,
   HeaderTable)`), which brings in only the listed `pub` symbols under
   explicit names and keeps the rest hidden. `intake.capa` now parses the
   batch CSV through the **real `capa_csv`** (`parse_headed` + the typed
   `HeaderTable` / `CsvError` model), while `cli.capa` brings in
   `capa_cli`'s `parse` as `cli_parse`; the two registry dependencies
   coexist in one program with the collision resolved at the import line.
   (The same flat namespace still means **sum-type variant names are
   global**: a local `Fail` variant once collided with the rule engine's
   `Fail`, so the CLI's outcome type uses `ArgsError`; variant renaming in
   a selective import is not yet supported.)

2. **Wildcard for-pattern on Wasm (FIXED in v1.2.0).** `for _ in 0..n`
   was `--check`-clean and ran on Python but failed on `--wasm` with
   *"CIR lowering does not yet support: for-pattern WildcardPat"*. v1.2.0
   lowers it; the wildcard form is available on both backends now.

3. **Wasm attenuation requires a literal-string argument (STILL OPEN).**
   On the Wasm backend, `net.restrict_to(host)` / `proc.restrict_to(cmd)`
   with a *let-bound* host or command name are rejected at emit time with
   *"--wasm: Wasm attenuation check requires a literal-string arg"*. The
   string-prefix attenuations therefore take an inline string literal at
   the call site (`net.restrict_to("api.frankfurter.app")`); a helper
   names the same value for display. (A `Float` argument to
   `clock.restrict_to_after` is unaffected.) This is the one gap still
   worked around in claimdesk.

## Phase 7: governance and SBOM by construction

The program is **complete**. The final phase turns every guarantee the
earlier phases made into **machine-readable, byte-reproducible evidence**
and a document that maps each claim to it.

Everything lives under [`governance/`](governance/):

- [`GOVERNANCE.md`](governance/GOVERNANCE.md) maps each guarantee
  (typestate, linearity, IFC, constant-time, least-privilege,
  tamper-evident integrity) to the exact place it shows up in the
  manifest / SBOM and to the command that re-proves it, plus an honest,
  non-exhaustive CRA Annex I and GDPR data-minimisation mapping.
- [`generate.sh`](governance/generate.sh) emits the five artefacts
  (`manifest.json`, `sbom.cyclonedx.json`, `sbom.spdx.json`,
  `vex.cyclonedx.json`, `provenance.slsa.json`) from `main.capa`. It
  pins `SOURCE_DATE_EPOCH` from the versioned
  [`governance/SOURCE_DATE_EPOCH`](governance/SOURCE_DATE_EPOCH) file, so
  running it twice produces **byte-identical** output, build timestamps
  included. The five artefacts are **committed** (this is a showcase: the
  SBOM in the tree is part of the demo), with the standing promise that a
  re-run leaves `git status` clean.

### Self-governance: the program audits its own SBOM

[`governance/audit.capa`](governance/audit.capa) closes the loop. It is a
standalone Capa program that reads the committed CycloneDX SBOM back in
with the [`capa_sbom`](https://github.com/nelsonduarte/capa_sbom) library
(the seventh seed library this showcase exercises: `capa_hash`,
`capa_csv`, `capa_cli`, `capa_log`, `capa_datetime`, `capa_test`, and
`capa_sbom`) and checks a governance
policy against it, printing PASS/FAIL:

- **Policy 1**: the pure core (`rules` / `engine` / `mask` / `report` /
  `money` / `claim` / `domain`) declares **zero** capabilities.
- **Policy 2**: only the FX egress (`fx`, `main`) reaches the `Net`
  capability.

```sh
CAPA_PATH=.. capa --run       governance/audit.capa   # AUDIT PASSED
CAPA_PATH=.. capa --wasm --run governance/audit.capa   # identical PASS
```

It is **deliberately standalone**: it imports only `capa_sbom` (plus the
`Fs` / `Stdio` it needs), never a `capa_claimdesk` module. Capa links all
`pub` items into one flat global namespace, so a program pulling in both
`capa_sbom` and the full claimdesk module graph could hit a name clash
(now resolvable with the v1.2.0 selective import, the Phase 5 finding
above). Reading only the JSON the compiler emitted keeps the auditor
fully decoupled: it never sees the claimdesk source at all.

### What the showcase demonstrates

Across seven phases, capa_claimdesk exercises, end to end and on both the
Python and Wasm backends:

| Language feature | Guarantee it makes unrepresentable | Proof |
|---|---|---|
| Typestate (`Claim[State]`) | out-of-order lifecycle transitions | `typestate_*` negative cases; `typestates` in the manifest |
| Linear types (payment token) | double payment / silently-unpaid approval | `linear_*` negative cases; `linear_obligations` in the manifest |
| Information-flow control (`@secret` IBAN) | the IBAN leaking to a public sink unmasked | `ifc_leak_*` negative cases; 3 `declassifications` in the manifest |
| Constant-time (`@constant_time`) | timing-leaking the ledger MAC check | `ct_secret_branch` negative case; `constant_time:true` on `mac_matches` |
| Capabilities + least privilege | a pure function reaching the outside world | `provably_excluded_capabilities`; `functions_crossing_unsafe:0`; `audit.capa` |
| HMAC chain (`capa_hash`) | tampering with a past ledger entry undetectably | `verify_chain`; the chained `out/ledger.log` |
| Verified dependencies | an unpinned / unsigned supply-chain edit | `capa install` (lockfile SHA + GPG tag + SLSA provenance) |

The point is the same throughout: the hard parts are not merely tested,
they are **made unrepresentable**, and the compiler emits the evidence.

## License

MIT. See [LICENSE](LICENSE).
