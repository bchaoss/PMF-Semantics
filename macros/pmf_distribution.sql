{% macro pmf_distribution(metric_name, cfg, grain) %}

{%- set metric_label = cfg.grain_labels[grain] if cfg.grain_labels else metric_name -%}
{%- set trunc_map = {'daily': 'day', 'weekly': 'week', 'monthly': 'month', 'quarterly': 'quarter'} -%}
{%- set trunc_unit = trunc_map[grain] -%}
{%- set is_binary  = cfg.is_binary -%}

{% if not is_binary %}
{# ── CDF for ordinal metrics (GMV, Revenue, …) ───────────────────────────── #}

with

entity_period_value as (
    select
        {{ cfg.entity_id }}                                                    as entity_id,
        date_trunc('{{ trunc_unit }}', cast({{ cfg.time_column }} as date))    as period,
        {{ cfg.value_expr }}                                                   as entity_value
    from {{ cfg.source_table }}
    {% if cfg.row_filter %}
    where {{ cfg.row_filter }}
    {% endif %}
    group by 1, 2
),

with_percentile as (
    select
        entity_id,
        period,
        entity_value,
        percent_rank() over (partition by period order by entity_value)        as value_percentile,
        sum(entity_value) over (
            partition by period
            order by entity_value
            rows between unbounded preceding and current row
        )                                                                      as cumulative_value,
        sum(entity_value) over (partition by period)                           as total_value,
        count(*)          over (partition by period)                           as total_entities,
        row_number()      over (partition by period order by entity_value)     as entity_rank
    from entity_period_value
)

select
    '{{ metric_label }}'                                                        as metric_name,
    '{{ grain }}'                                                              as grain,
    period,
    entity_id,
    entity_value,
    value_percentile,
    cast(entity_rank as float) / total_entities                                as pct_entities_at_or_below,
    case
        when total_value > 0
        then cast(cumulative_value as float) / total_value
    end                                                                        as pct_value_at_or_below,
    case when value_percentile >= 0.8  then 1 else 0 end                       as is_top_quintile,
    case when value_percentile >= 0.95 then 1 else 0 end                       as is_top_5pct
from with_percentile
order by period, entity_value

{% else %}
{# ── L-N distribution for binary / engagement metrics (MAU, DAU, …) ────── #}

with

entity_intensity as (
    select
        {{ cfg.entity_id }}                                                    as entity_id,
        date_trunc('{{ trunc_unit }}', cast({{ cfg.time_column }} as date))    as period,
        count(distinct date(cast({{ cfg.time_column }} as timestamp)))         as intensity_value
    from {{ cfg.source_table }}
    {% if cfg.row_filter %}
    where {{ cfg.row_filter }}
    {% endif %}
    group by 1, 2
),

intensity_distribution as (
    select
        period,
        intensity_value,
        count(distinct entity_id) as entity_count
    from entity_intensity
    group by 1, 2
),

with_totals as (
    select
        period,
        intensity_value,
        entity_count,
        sum(entity_count) over (partition by period)                           as total_active,
        sum(entity_count) over (
            partition by period
            order by intensity_value
            rows between unbounded preceding and current row
        )                                                                      as cumulative_count
    from intensity_distribution
)

select
    '{{ metric_label }}'                                                        as metric_name,
    '{{ grain }}'                                                              as grain,
    period,
    intensity_value,
    entity_count,
    cast(entity_count     as float) / total_active                             as pct_of_active_entities,
    cast(cumulative_count as float) / total_active                             as cumulative_pct,
    case
        when cast(cumulative_count as float) / total_active >= 0.5
         and lag(cast(cumulative_count as float) / total_active)
             over (partition by period order by intensity_value) < 0.5
        then 1 else 0
    end                                                                        as is_median_bucket
from with_totals
order by period, intensity_value

{% endif %}

{% endmacro %}
