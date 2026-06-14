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

The whole engine is designed to run **byte-identically** under the
Python interpreter (`--run`) and the WebAssembly backend
(`--wasm --run`). It uses no `Unsafe` and no networking; the domain core
is capability-free.

> Status: this is a multi-phase build. **Phase 1 (this commit) lands the
> repository and the domain core**: money, the domain vocabulary, the
> claim-lifecycle typestate, and the linear payment authorization, plus
> a deterministic demo. Later phases add the rules engine, an
> append-only ledger with information-flow control, the Db / Net / Proc
> / Fs adapters, a CLI, a test suite, and the governance / SBOM pack.

## Running the Phase 1 demo

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
claimdesk Phase 1 demo: expense claim lifecycle
================================================

[Draft]       claim C-2026-0007 opened for Alice Mendes
              3 lines, requested total 553.15 EUR
[Submitted]   submitted at tick 20260614
[UnderReview] picked up by R-3001 (Bruno Antunes)
[Approved]    approved by M-4002 (Carla Dias)
              approved total 553.15 EUR
              minted disbursement authorization (nonce 1)
[Settled]     paid 553.15 EUR to Alice Mendes
              receipt: claim C-2026-0007, nonce 1

lifecycle complete: claim approved, authorization spent once.
```

## Modules (Phase 1)

| Module        | What it holds                                                        |
| ------------- | -------------------------------------------------------------------- |
| `money.capa`  | `Money` as integer cents, `Currency`, add/subtract/sum/compare/format; cross-currency operations are typed `Result` errors. |
| `domain.capa` | `Employee` (with a `@secret` IBAN), `Category`, `ExpenseLine`, line totals. |
| `authz.capa`  | The `linear type DisbursementAuthorization` payment token and its one-shot consumption into a `DisbursementReceipt`. |
| `claim.capa`  | The `typestate Claim` lifecycle (`Draft -> Submitted -> UnderReview -> Approved -> Settled`, with `UnderReview -> Rejected`) and its transitions. |
| `main.capa`   | The deterministic Phase 1 demo walking the happy path.               |

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
