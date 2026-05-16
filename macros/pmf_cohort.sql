{% macro pmf_cohort(metric_name, cfg, grain) %}

{%- set metric_label = cfg.grain_labels[grain] if cfg.grain_labels else metric_name -%}
{%- set trunc_map = {'daily': 'day', 'weekly': 'week', 'monthly': 'month', 'quarterly': 'quarter'} -%}
{%- set trunc_unit = trunc_map[grain] -%}
{%- set is_binary  = cfg.is_binary -%}

with

entity_period as (
    select
        {{ cfg.entity_id }}                                                    as entity_id,
        date_trunc('{{ trunc_unit }}', cast({{ cfg.time_column }} as date))    as period,
        {% if is_binary %}
        1                                                                      as value
        {% else %}
        {{ cfg.value_expr }}                                                   as value
        {% endif %}
    from {{ cfg.source_table }}
    {% if cfg.row_filter %}
    where {{ cfg.row_filter }}
    {% endif %}
    group by 1, 2
),

entity_cohort as (
    select entity_id, min(period) as cohort_period
    from entity_period
    group by 1
),

cohort_activity as (
    select
        ep.entity_id,
        ec.cohort_period,
        ep.period as activity_period,
        {% if grain == 'weekly' %}
        cast((cast(ep.period as date) - cast(ec.cohort_period as date)) / 7 as integer) as cohort_age,
        {% else %}
        cast((
            extract(year from ep.period) * 12 + extract(month from ep.period)
          - extract(year from ec.cohort_period) * 12 - extract(month from ec.cohort_period)
        ) as integer) as cohort_age,
        {% endif %}
        ep.value
    from entity_period ep
    join entity_cohort ec on ep.entity_id = ec.entity_id
),

cohort_birth as (
    select
        cohort_period,
        count(distinct entity_id)    as cohort_size,
        {% if is_binary %}
        count(distinct entity_id)    as cohort_value_at_birth
        {% else %}
        sum(value)                   as cohort_value_at_birth
        {% endif %}
    from cohort_activity
    where cohort_age = 0
    group by 1
),

cohort_age_agg as (
    select
        cohort_period,
        cohort_age,
        count(distinct entity_id)    as active_entities,
        {% if is_binary %}
        count(distinct entity_id)    as period_value
        {% else %}
        sum(value)                   as period_value
        {% endif %}
    from cohort_activity
    group by 1, 2
),

cohort_ltv as (
    select
        cohort_period,
        cohort_age,
        active_entities,
        period_value,
        sum(period_value) over (
            partition by cohort_period
            order by cohort_age
            rows between unbounded preceding and current row
        ) as cumulative_value
    from cohort_age_agg
)

select
    '{{ metric_label }}'                                                        as metric_name,
    '{{ grain }}'                                                              as grain,
    cl.cohort_period,
    cl.cohort_age,
    cb.cohort_size,
    cl.active_entities,
    cl.period_value,
    cl.cumulative_value,
    cb.cohort_value_at_birth,

    case
        when cb.cohort_size > 0
        then cast(cl.active_entities as float) / cb.cohort_size
    end as logo_retention,

    case
        when cb.cohort_value_at_birth > 0
        then cast(cl.period_value as float) / cb.cohort_value_at_birth
    end as revenue_retention,

    case
        when cb.cohort_size > 0
        then cast(cl.cumulative_value as float) / cb.cohort_size
    end as ltv_per_entity

from cohort_ltv cl
join cohort_birth cb on cl.cohort_period = cb.cohort_period
order by cohort_period, cohort_age

{% endmacro %}
