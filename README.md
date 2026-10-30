# Healthcare Analytics: OLTP to Star Schema

Data engineering mini project: measure the cost of running analytics on a normalized (3NF) clinical database, then design, build and load a star schema that answers the same questions faster.

**Stack:** MySQL 8.4, MySQL Workbench, Git Bash

## Results

Same machine, same data (200,004 encounters), median of 5 warm runs. Both schemas return identical results.

| Business question | OLTP (3NF) | Star schema | Speedup |
|---|---|---|---|
| Q1 Monthly encounters by specialty | 0.736 s | 0.276 s | 2.7x |
| Q2 Top diagnosis-procedure pairs | 5.971 s | 1.379 s | 4.3x |
| Q3 30-day readmission rate | 0.706 s | 0.032 s | 21.9x |
| Q4 Revenue by specialty & month | 1.544 s | 0.123 s | 12.5x |

## Architecture

- **`healthcare_oltp`** (source): 10 normalized tables, as given in the brief.
- **`healthcare_dw`** (warehouse): a separate database, mirroring production vs. analytics.
  - `fact_encounters`: one row per encounter, with pre-computed billing totals, counts, length of stay and a 30-day readmission flag.
  - 8 dimensions: date, patient, provider, specialty, department, encounter type, diagnosis, procedure. Each has surrogate keys and a key 0 "Unknown" member.
  - 2 bridge tables for the many-to-many diagnoses and procedures per encounter.

## Repository Layout

```
healthcare-analytics/
├── setup/
│   ├── oltp_schema.sql          # creates healthcare_oltp (rerunnable)
│   ├── oltp_sample_data.sql     # sample data from the brief
│   ├── generated_data.sql       # deterministic volume data (200K encounters)
│   ├── star_schema.sql          # star schema DDL (creates healthcare_dw)
│   └── etl_load.sql             # loads healthcare_dw + reconciliation checks
├── queries/
│   ├── oltp_queries.sql         # the 4 questions on the 3NF schema
│   └── star_schema_queries.sql  # the same 4 questions on the star schema
├── docs/
│   ├── query_analysis.txt       # Part 2: OLTP queries + bottlenecks
│   ├── design_decisions.txt     # Part 3.1: grain, dimensions, metrics, bridges
│   ├── star_schema_queries.txt  # Part 3.3: optimized queries + speedups
│   └── etl_design.txt           # Part 3.4: ETL logic and refresh strategy
└── reflection.md                # Part 4: analysis, trade-offs, numbers
```

## How to Rebuild

Run the scripts in this order, from MySQL Workbench or the command line:

```bash
mysql -u root -p < setup/oltp_schema.sql
mysql -u root -p < setup/oltp_sample_data.sql
mysql -u root -p < setup/generated_data.sql
mysql -u root -p < setup/star_schema.sql
mysql -u root -p < setup/etl_load.sql          # ~45 s, ends with a check table (all rows should say OK)
```

- `generated_data.sql` only adds rows. To rerun it, first rerun the two OLTP scripts.
- It uses `CRC32` instead of `RAND()`, so every rebuild produces exactly the same data.
- Use the command line for long scripts if Workbench times out.

## Key Findings

- **The biggest gains come from removing work, not just joins.** The readmission self-join (Q3) and the billing join (Q4) moved into the ETL, giving 12-22x speedups.
- **Some work is inherent.** Q2 still builds ~900K diagnosis-procedure pairs. The bridges make each row cheaper (4.3x) but cannot avoid the explosion; an aggregate table would be the next step.
- **Query shape matters.** The first star version of Q1 was *slower* than OLTP. Grouping on integer keys first and joining labels last, with a covering index, fixed it.
- **The cost:** a second copy of the data (130 MB vs. 112 MB), a daily ETL, and handling of late-arriving claims and encounters.

## Notes

- The brief's sample data inserts `billing` before `encounters`, which fails the foreign key. `oltp_sample_data.sql` inserts billing last.
- `YEAR_MONTH` is a reserved word in MySQL, so the date column is `year_month_label`.
- Patient names and MRN are PHI. They are kept because the brief lists them; production would mask them.
