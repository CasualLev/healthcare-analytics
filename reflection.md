# Reflection: OLTP vs. Star Schema

All numbers below were measured on the same machine (MySQL 8.4, 200,004 encounters), median of 5 warm runs, with identical results from both schemas.

## 1. Key Decisions and Why

| Decision | Choice | Why |
|---|---|---|
| Fact grain | One row per encounter | Billing, length of stay and readmission all live at this level. A diagnosis or procedure grain would double-count money, or drop the 25% of encounters with no procedure. |
| Specialty on the fact | `specialty_key` stored directly | 3 of 4 queries group by specialty. One hop instead of two, and it records the specialty at the time of the visit. |
| Pre-computed measures | Billing totals, counts, length of stay, readmission flag | Expensive work runs once at load time instead of on every report. |
| Many-to-many detail | Two integer-only bridge tables | Keeps the fact grain clean while still answering diagnosis/procedure questions (Q2). |
| Missing references | Key 0 "Unknown" member | Facts are never silently dropped by inner joins. |
| Dimension updates | SCD Type 1 (overwrite) | Simple, and history that matters (specialty, age at visit) already lives on the fact row. |
| Indexes | Covering indexes for Q1/Q4 and Q3 | Queries read the index only, never the full fact row. |
| Query style | Aggregate on keys first, join labels last | Dimensions are joined to 10-456 result rows, not to 200K fact rows. |
| Aggregate table for Q2 | Deliberately not built | Keeps the Q2 result an honest measure of the bridge design. |

## 2. Why Is the Star Schema Faster?

**Joins.** The total number of joins barely changed (11 in OLTP vs. 10 in the star schema). What changed is *where* they run:

| Query | OLTP joins over large row sets | Star joins over large  row sets |
|---|---|---|
| Q1 | 2 (providers, specialties per encounter) | 1 (dim_date → covering index) |
| Q2 | 3 (900K pair rows each looked up) | 1 (bridge ↔ bridge); labels joined to 10 rows |
| Q3 | 3 (incl. self-join on encounters) | 0, tiny dimensions filter first, then one index lookup |
| Q4 | 3 (billing → encounters → providers → specialties) | 0, dimensions joined to 7,310 pre-summed rows |

**Where data is pre-computed:**
- **ETL (once per load):** readmission flag, billing totals, diagnosis/procedure counts, length of stay, age at encounter.
- **dim_date:** month label, quarter, weekday. No `DATE_FORMAT()` per row.
- **Dimensions:** age group, ICD chapter, CPT category, provider full name.

**Why denormalization helps analytics:**
- 3NF optimises for writing a fact once and keeping it consistent. Analytics reads millions of rows and needs those facts together.
- The star schema stores them together, so the database stops re-assembling the same joins on every run.
- Grouping on integer keys is cheaper than grouping on text, and covering indexes avoid reading full rows.

## 3. Trade-offs: What We Gained and Lost

**Gained**
- **Speed:** 2.7x to 21.9x faster across the 4 queries (section 5).
- **Simpler SQL:** the readmission rate is a `SUM` of a 0/1 column instead of a self-join with `COUNT(DISTINCT)`.
- **One definition:** readmission is coded once in the ETL, so every report agrees.
- **Richer analysis:** age groups, ICD chapters and CPT categories come for free.

**Lost**
- **Storage:** the warehouse is a second copy (130 MB vs. 112 MB for OLTP). Indexes take 76 MB of it; the fact table alone has 50 MB of indexes on 20 MB of data.
- **Freshness:** data is only as current as the last load (daily in the proposed design).
- **ETL complexity:** a 41 s full load, reconciliation checks, and logic for late claims, late encounters (which can change an *older* stay's readmission flag) and late dimension members.
- **Flexibility:** pre-computed rules are fixed. Switching to the stricter "inpatient-only" readmission definition means changing the ETL and reloading, not just editing a query.
- **Write cost:** wide covering indexes slow down every insert and update during loads.

**Was it worth it?** Yes. The costs are paid once, at load time and on disk, while the speedup is paid back on every report by every analyst. The one caveat is that a star schema is not automatically fast: the first version of Q1 (1.05 s) was *slower* than OLTP until the query shape matched the indexes.

## 4. Bridge Tables: Worth It?

**Why bridges instead of denormalizing into the fact:**
- An encounter has 1-4 diagnoses and 0-3 procedures. Fixed columns (`diagnosis_1` … `diagnosis_4`) cap the count, leave NULLs, and turn "all encounters with I10" into a 4-column OR.
- Changing the grain to one row per diagnosis would double-count billing for Q1, Q3 and Q4.
- Most queries never touch the bridges: `primary_diagnosis_key` and the counts already sit on the fact.

**The trade-off:**
- Bridges made Q2 4.3x faster through integer keys, no `COUNT(DISTINCT)` and late label joins.
- They did *not* remove the 900K-row pair explosion; Q2 still reads ~2.8M rows and remains the slowest query (1.4 s).

**In production:** I would keep the bridges for ad-hoc diagnosis/procedure questions. If Q2 ran daily, I would also add an `agg_diagnosis_procedure_pairs` table built by the ETL, making Q2 a read of ~1,100 pre-counted rows.

## 5. Performance Quantification

| Query | Original | Optimized | Improvement | Main reason |
|---|---|---|---|---|
| Q3 Readmission rate | 0.706 s | 0.032 s | **21.9x** | Readmission flag pre-computed: no self-join, no full scan; reads 72K rows instead of 483K |
| Q4 Revenue by specialty | 1.544 s | 0.123 s | **12.5x** | Billing pre-aggregated on the fact; covering index; reads 222K rows instead of 780K |
| Q2 Diagnosis-procedure pairs | 5.971 s | 1.379 s | **4.3x** | Integer bridges and grouping on keys; same row explosion, cheaper rows |
| Q1 Monthly encounters | 0.736 s | 0.276 s | **2.7x** | Covering index and stored month label; same number of rows read |

**Pattern:** the biggest gains came where the ETL removed work entirely (Q3, Q4). Where the work is inherent to the question (Q1 counts every encounter, Q2 builds every pair), the star schema makes each row cheaper but cannot avoid touching it.
