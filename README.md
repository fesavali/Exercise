# Exercise
# Lender-Level Exceptions in IncentiveCalculator

Aceli Africa — Case Study Submission
Felix Nzioki Savali

## 1. Problem statement (as given)

Aceli partners with 50+ lenders and incentivizes lending through two mechanisms:

- **OI (Origination Incentive)** — based on loan characteristics (loan size, borrower revenue, impact points), with modest country/value-chain adjustments.
- **FLC (First-Loss Coverage)** — a coverage-style incentive influenced by loan size, borrower status (new vs. returning), and impact signals.

Some lenders have exceptions to these rules — they may not be eligible to earn OI/FLC, may be limited to one or the other, or may need different rates/thresholds. Today these exceptions live offline and must be manually remembered at two separate points: loan registration and quarterly incentive calculation. This is error-prone and has no enforcement mechanism.

**Task**: modify or extend the given `IncentiveCalculator` Apex class to support lender-level exceptions, configured in Salesforce and applied consistently at both points.

## 2. Gaps identified in the original code

Reviewing the original `IncentiveCalculator.cls` before making any changes:

| # | Gap | Why it matters |
|---|-----|-----------------|
| 1 | No eligibility concept at all | Every lender is treated identically — no way to exclude a lender from OI, FLC, or both |
| 2 | All rates/thresholds hardcoded inline | `15000` minimum loan, `0.0015` revenue rate, `0.005` impact uplift, `0.04` FLC base, `0.01` returning increment, country multiplier via `contains('Kenya')` — every exception requires a code change and deploy |
| 3 | No configuration layer | Nothing in Salesforce an admin can edit; exceptions can only live in someone's memory or an external spreadsheet |
| 4 | Two independent call sites, no shared source of truth | Registration and quarter-end each compute incentives from scratch — nothing structurally prevents them from drifting apart if one is updated and the other isn't |
| 5 | `upsert incentive Loan__c;` does not compile | Standard Lookup fields cannot be marked as External ID in Salesforce — found while implementing, not visible from reading the code alone |
| 6 | `calculateQuarterlyEarnings` sums *all* balances ever recorded for a loan | No date filtering — "quarterly" earnings would silently become "all-time" earnings once a loan has more than one quarter of balance history |

## 3. Design

**Configuration layer**: `Lender_Exception__mdt` (Custom Metadata Type)

Chosen over a Custom Object because:
- Admin-editable via standard Setup UI, no deployment needed — satisfies "admin-changeable" directly
- Deployable/packageable alongside the Apex
- No data storage consumption

Fields: `Eligible_For_OI__c`, `Eligible_For_FLC__c`, `Can_Register_SMEs__c` (independent booleans — a lender can be OI-only, FLC-only, both, or neither, and registration eligibility is tracked separately from earning eligibility), `Min_Loan_For_OI__c`, `Revenue_Rate__c`, `Impact_Uplift_Per_Point__c`, `FLC_Base_Rate__c`, `FLC_Returning_Increment__c` (per-lender overrides of every previously-hardcoded constant), `Country_Multiplier_JSON__c` / `Value_Chain_Multiplier_JSON__c` (JSON-encoded maps, so new countries/value chains don't require new fields), `Lender_Code__c` (matches the lender's key — see Known Limitation below).

**Shared resolution**: a `LenderConfig` wrapper class and a single `getLenderConfig(lenderId)` method. If no exception record exists for a lender, it returns the original hardcoded defaults — so the change is non-breaking for every lender that doesn't need an exception.

**Eligibility gate**: `calculateIncentives` checks `cfg.eligibleForOI` / `cfg.eligibleForFLC` *before* calling the calculation methods at all. An ineligible lender gets exactly `0`, regardless of the loan's other characteristics — enforced at the top of the flow, not buried inside the math.

**Single source of truth across both flows**: both `calculateIncentives()` (registration) and `QuarterlyIncentiveBatch` (quarter-end) call the same `getLenderConfig()` and pass the same config object into the same calculation methods. See diagram.

## 4. What changed, mapped to the gaps

| Gap | Fix |
|---|---|
| 1, 2, 3 | New `Lender_Exception__mdt` type + `LenderConfig`/`getLenderConfig()` |
| 4 | Both flows call the identical shared method — cannot structurally drift apart |
| 5 | Replaced `upsert incentive Loan__c;` with a query-then-set-Id-then-upsert pattern |
| 6 | Added `Month__c` to `Loan_Balance__c`; `calculateQuarterlyEarnings` now filters to the current calendar quarter |

## 5. Commands to run

**Single loan, registration flow** (Execute Anonymous):
```apex
IncentiveCalculator.calculateIncentives('<LOAN_RECORD_ID>');
```

**All loans, quarter-end batch** (Execute Anonymous):
```apex
Database.executeBatch(new QuarterlyIncentiveBatch(), 200);
```

## 6. Verified results (live dev org)

Test lender `LEND001`: `Eligible_For_FLC__c = false`, `Min_Loan_For_OI__c = 20000` (override).

- Registration against a $25,000 loan → `Max_FLC__c = 0` (eligibility gate confirmed working)
- Quarter-end batch against a $10,000 balance → `Quarterly_Earnings__c = 600` (10,000 × 0.06 OI rate; the 550 FLC portion is correctly excluded)

Both numbers match — confirming the same exception is enforced identically in both flows.

## 7. Test coverage

`IncentiveCalculatorTest.cls` — 9 test methods, 92% coverage (88/95 lines) on `IncentiveCalculator`. Covers: FLC exclusion, overridden-threshold enforcement (vs. platform default), default fallback for lenders with no exception record, upsert idempotency, the same FLC exclusion in the batch path, quarter-boundary filtering, and null-safety on `getLenderConfig`/`getBonusValue`.

Known gap: the `try/catch` around `JSON.deserialize(loan.Bonuses__c, ...)` — malformed-JSON handling — isn't explicitly exercised by a test.

## 8. Known limitations

- Custom Metadata Types can't hold a true relational lookup to a standard/custom record Id — exceptions are keyed to lenders via a matching `Lender_Code__c` text field rather than a native lookup. A Hierarchical Custom Setting or a Custom Object with row-level security would be the alternative if enforced referential integrity is needed.
- Quarter boundaries use calendar quarters based on `Date.today()` — doesn't yet handle a fiscal year that doesn't align to the calendar, if Aceli's does.

## 9. Possible extensions (open for discussion)

- A third incentive type, or a generic/extensible incentive-type model instead of hardcoded OI/FLC fields
- Per-country or per-value-chain *eligibility* (not just multipliers) — currently eligibility is lender-wide only
- An admin-facing Lightning page to manage exceptions without navigating raw Setup UI
- Bulkification/governor-limit review for the batch path at real production loan volumes (thousands of loans per run)
- Effective-dated exceptions (a rate change that only applies going forward, preserving historical incentive calculations as-is)