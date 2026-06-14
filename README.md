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
> - **Phase 3 (this commit)** adds the **tamper-evident audit ledger and
>   information-flow control over the IBAN**: an HMAC-chained append-only
>   ledger (`ledger.capa`), constant-time chain verification, and the
>   `@secret` IBAN bridges (`mask.capa`) that mask and fingerprint the
>   account through audited declassifies. It pulls in its first external
>   dependency, the SLSA-verified `capa_hash`, and writes the ledger
>   through an attenuated `Fs`. See [Phase 3](#phase-3-the-tamper-evident-ledger-and-iban-information-flow).
>
> Later phases add the Db / Net / Proc adapters, a CLI, a test suite, and
> the governance / SBOM pack.

## Running the demo

From Phase 3 on, claimdesk has one external dependency (`capa_hash`).
Vendor and verify it once with the package manager, then run:

```sh
capa install                    # vendors + verifies capa_hash (GPG tag + SLSA)
capa --run main.capa
capa --wasm --run main.capa     # identical output, byte for byte
```

If claimdesk is checked out under a directory that is not on the default
module search path, point `CAPA_PATH` at the parent of the repo so the
`capa_claimdesk.*` modules resolve, e.g.
`CAPA_PATH=/path/to/repos capa --run main.capa`.

The run writes the audit ledger to `out/ledger.log` (gitignored). The
`Fs` capability is attenuated to `out/` before any write, so even a
mistargeted path could not escape that directory.

Expected output (the same on both backends):

```
claimdesk Phase 3 demo: tamper-evident ledger + IBAN information-flow
====================================================================

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

demo complete: one claim approved and paid, one rejected; ledger chained and verified.
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
| `main.capa`    | The deterministic demo: two claims run through the lifecycle, the engine's `Decision` choosing approve-and-pay vs reject, every event chained into the ledger, the IBAN masked/fingerprinted through audited declassifies, and the chain verified in constant time at the end. |

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
the output directory. `capa --manifest main.capa` reports
`declassification_sites: 2`, `mac_matches` constant-time, and no
`Unsafe` anywhere.

### Supply chain

`capa_hash` is pinned in `capa.toml` by git tag `v0.1.2` and the
publisher key `6C1D222D491FB88031E041A536CFB426101AA24B`. `capa install`
vendors it into `vendor/`, writes the resolved commit into `capa.lock`,
and verifies the GPG tag signature and SLSA provenance before any check.
`vendor/` and `capa.lock` are gitignored pre-publication.

## License

MIT. See [LICENSE](LICENSE).
