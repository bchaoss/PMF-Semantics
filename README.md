# PMF Semantic Layer

Semantic layer implementation of the quantitative [PMF framework from Tribe Capital](https://tribecap.co/essays/a-quantitative-approach-to-product-market-fit):
**Growth Accounting × Cohort Analysis × Distribution**

*Implemented as a dbt package, without dependency on dbt Cloud or any paid features.*

---

## Quickstart

```bash
# 1. Install dbt for your warehouse
pip install dbt-postgres      # or dbt-bigquery, dbt-snowflake, dbt-duckdb …

# 2. Configure your warehouse connection
#    Edit ~/.dbt/profiles.yml  (see profiles.yml.example in this repo)

# 3. Point the package at your tables
#    Edit dbt_project.yml → vars.metrics → source_table for each metric

# 4. Run
dbt run
```

dbt writes the output tables to your warehouse.

---

## Project structure

```
pmf_dbt/
├── dbt_project.yml          # metric definitions live here (vars.metrics)
├── macros/
│   ├── pmf_growth_accounting.sql   # core logic — shared across all metrics
│   ├── pmf_cohort.sql
│   └── pmf_distribution.sql
└── models/pmf/
    ├── gmv__growth_accounting__monthly.sql   # one-liner: calls the macro
    ├── gmv__cohort__monthly.sql
    ├── gmv__distribution__monthly.sql
    ├── gmv__growth_accounting__weekly.sql
    ├── gmv__cohort__weekly.sql
    ├── mau__growth_accounting__monthly.sql
    ├── mau__cohort__monthly.sql
    └── mau__distribution__monthly.sql
```

**The macros contain all the logic. The model files are one line each.**
You never need to edit the macros unless you want to extend the framework.

---

## Adding a new metric

**Step 1** — Add the metric definition to `dbt_project.yml` under `vars.metrics`:

```yaml
vars:
  metrics:
    revenue:                              # your metric name
      source_table: "your_schema.payments"
      entity_id:    "merchant_id"         # the "who"
      time_column:  "paid_at"
      value_expr:   "SUM(net_amount)"
      is_binary:    false                 # false = ordinal (has expansion/contraction)
      time_grains:  ["monthly", "weekly"]
      row_filter:   "status = 'settled'"  # optional
```

**Step 2** — Create model files (one per framework × grain):

```bash
# models/pmf/revenue__growth_accounting__monthly.sql
{{ pmf_growth_accounting('revenue', var('metrics')['revenue'], 'monthly') }}

# models/pmf/revenue__cohort__monthly.sql
{{ pmf_cohort('revenue', var('metrics')['revenue'], 'monthly') }}

# models/pmf/revenue__distribution__monthly.sql
{{ pmf_distribution('revenue', var('metrics')['revenue'], 'monthly') }}
```

**Step 3** — Run:

```bash
dbt run --select revenue__*
```

---

## Output tables

### growth_accounting
| column | description |
|--------|-------------|
| `metric_name` | e.g. `gmv` |
| `grain` | `monthly` / `weekly` |
| `period` | truncated date |
| `new` | value from new entities |
| `resurrected` | value from returned entities |
| `expansion` | incremental value from existing entities (null for binary) |
| `retained` | value from stable existing entities |
| `contraction` | lost value from existing entities (null for binary) |
| `churned` | value from lost entities |
| `total` | total this period |
| `gross_retention` | retained / prev_total |
| `net_churn` | (churned + contraction - resurrected - expansion) / prev_total |
| `quick_ratio` | (new + resurrected + expansion) / (churned + contraction) |
| `growth_rate` | (total - prev_total) / prev_total |

### cohort
| column | description |
|--------|-------------|
| `cohort_period` | first active period |
| `cohort_age` | periods since cohort birth |
| `logo_retention` | % of cohort still active |
| `revenue_retention` | period value / birth value (can exceed 1.0) |
| `ltv_per_entity` | cumulative value / cohort size |

### distribution
**Ordinal metrics**: CDF — `entity_value`, `pct_entities_at_or_below`, `pct_value_at_or_below`

**Binary metrics**: L-N — `intensity_value` (days active), `pct_of_active_entities`, `cumulative_pct`

---

## Viewing multiple metrics together

All tables share the same schema. Union them for cross-metric dashboards:

```sql
select * from gmv__growth_accounting__monthly
union all
select * from mau__growth_accounting__monthly
order by metric_name, period
```

---

## is_binary explained

| | `is_binary: false` (GMV, Revenue) | `is_binary: true` (MAU, DAU) |
|---|---|---|
| expansion / contraction | ✓ computed | null |
| growth accounting | full 6-bucket | 4-bucket |
| distribution | CDF of value | L-N intensity |
| revenue_retention | can exceed 1.0 | always ≤ 1.0 |
