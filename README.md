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

The whole engine is designed to run **byte-identically** under the
Python interpreter (`--run`) and the WebAssembly backend
(`--wasm --run`). It uses no `Unsafe` and no networking; the domain core
is capability-free.

> Status: this is a multi-phase build.
>
> - **Phase 1** landed the repository and the domain core: money, the
>   domain vocabulary, the claim-lifecycle typestate, and the linear
>   payment authorization, plus a deterministic demo.
> - **Phase 2 (this commit)** adds the **policy rule engine**: a `Rule`
>   trait with several concrete policy rules, a decision engine that
>   dispatches dynamically over a `List<Rule>` and aggregates the
>   outcomes into a `Decision`, and the integration that lets that
>   decision drive the `UnderReview -> Approved` / `-> Rejected`
>   transition. The engine is provably capability-free.
>
> Later phases add an append-only ledger with information-flow control,
> the Db / Net / Proc / Fs adapters, a CLI, a test suite, and the
> governance / SBOM pack.

## Running the demo

From the repository root:

```sh
capa --run main.capa
capa --wasm --run main.capa     # identical output
```

If claimdesk is checked out under a directory that is not on the default
module search path, point `CAPA_PATH` at the parent of the repo so the
`capa_claimdesk.*` modules resolve, e.g.
`CAPA_PATH=/path/to/repos capa --run main.capa`.

Expected output (the same on both backends):

```
claimdesk Phase 2 demo: policy rule engine -> decision
======================================================

[Draft]       claim C-2026-0007 opened for Alice Mendes
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

[Draft]       claim C-2026-0008 opened for Bruno Costa
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

demo complete: one claim approved and paid, one rejected.
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
| `main.capa`    | The deterministic demo: two claims run through the lifecycle, the engine's `Decision` choosing approve-and-pay vs reject. |

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

## Information-flow intent

`Employee.iban` is marked `@secret` at its definition. That single
annotation is the seed for the information-flow-control phase: the
compiler will propagate a secret label through every value derived from
the IBAN, and the payout code will have to route it through an audited
declassify before it can reach a public sink (a log line, a CSV export,
a network call). Marking it in Phase 1 means the IFC phase tightens an
existing surface rather than retrofitting annotations later.

## License

MIT. See [LICENSE](LICENSE).
