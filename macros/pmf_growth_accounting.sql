{% macro pmf_growth_accounting(metric_name, cfg, grain) %}

{%- set metric_label = cfg.grain_labels[grain] if cfg.grain_labels else metric_name -%}
{%- set trunc_map = {'daily': 'day', 'weekly': 'week', 'monthly': 'month', 'quarterly': 'quarter'} -%}
{%- set trunc_unit = trunc_map[grain] -%}
{%- set is_binary  = cfg.is_binary -%}

with

entity_period as (
    select
        {{ cfg.entity_id }}                                           as entity_id,
        date_trunc('{{ trunc_unit }}', cast({{ cfg.time_column }} as date)) as period,
        {% if is_binary %}
        1                                                             as value
        {% else %}
        {{ cfg.value_expr }}                                          as value
        {% endif %}
    from {{ cfg.source_table }}
    {% if cfg.row_filter %}
    where {{ cfg.row_filter }}
    {% endif %}
    group by 1, 2
),

period_pairs as (
    select
        coalesce(curr.entity_id, prev.entity_id)                     as entity_id,
        coalesce(curr.period,    prev.period + interval '1 {{ trunc_unit }}') as period,
        curr.value                                                    as curr_value,
        prev.value                                                    as prev_value
    from entity_period curr
    full outer join entity_period prev
        on  curr.entity_id = prev.entity_id
        and curr.period    = prev.period + interval '1 {{ trunc_unit }}'
),

first_seen as (
    select entity_id, min(period) as first_period
    from entity_period
    group by 1
),

classified as (
    select
        pp.entity_id,
        pp.period,
        pp.curr_value,
        pp.prev_value,

        case
            when pp.curr_value is not null and pp.prev_value is null then
                case
                    when fs.first_period = pp.period then 'new'
                    else 'resurrected'
                end
            when pp.curr_value is null and pp.prev_value is not null then 'churned'
            when pp.curr_value is not null and pp.prev_value is not null then
                {% if is_binary %}
                'retained'
                {% else %}
                case
                    when pp.curr_value > pp.prev_value then 'expansion'
                    when pp.curr_value < pp.prev_value then 'contraction'
                    else 'retained'
                end
                {% endif %}
        end as bucket,

        {% if not is_binary %}
        case
            when pp.curr_value is not null and pp.prev_value is not null
                 and pp.curr_value > pp.prev_value
            then pp.curr_value - pp.prev_value
        end as expansion_delta,
        case
            when pp.curr_value is not null and pp.prev_value is not null
                 and pp.curr_value < pp.prev_value
            then pp.prev_value - pp.curr_value
        end as contraction_delta,
        {% endif %}

        case
            when pp.curr_value is not null and pp.prev_value is not null
            then least(pp.curr_value, pp.prev_value)
        end as retained_value

    from period_pairs pp
    left join first_seen fs on pp.entity_id = fs.entity_id
),

period_agg as (
    select
        period,

        {% if is_binary %}
        count(distinct case when bucket = 'new'         then entity_id end) as new,
        count(distinct case when bucket = 'resurrected' then entity_id end) as resurrected,
        count(distinct case when bucket = 'churned'     then entity_id end) as churned,
        count(distinct case when bucket = 'retained'    then entity_id end) as retained,
        cast(null as bigint)                                                 as expansion,
        cast(null as bigint)                                                 as contraction,
        count(distinct case when curr_value is not null then entity_id end) as total
        {% else %}
        sum(case when bucket = 'new'         then curr_value     else 0 end) as new,
        sum(case when bucket = 'resurrected' then curr_value     else 0 end) as resurrected,
        sum(case when bucket = 'churned'     then prev_value     else 0 end) as churned,
        sum(case when bucket = 'retained'    then retained_value else 0 end) as retained,
        sum(coalesce(expansion_delta,  0))                                   as expansion,
        sum(coalesce(contraction_delta,0))                                   as contraction,
        sum(case when curr_value is not null then curr_value     else 0 end) as total
        {% endif %}

    from classified
    group by 1
)

select
    '{{ metric_label }}'                                                as metric_name,
    '{{ grain }}'                                                      as grain,
    period,
    new, churned, resurrected, retained, expansion, contraction, total,

    lag(total) over (order by period)                                  as prev_total,

    case
        when lag(total) over (order by period) > 0
        then cast(retained as float) / lag(total) over (order by period)
    end                                                                as gross_retention,

    case
        when lag(total) over (order by period) > 0
        then cast(
            coalesce(churned, 0) + coalesce(contraction, 0)
            - coalesce(resurrected, 0) - coalesce(expansion, 0)
        as float) / lag(total) over (order by period)
    end                                                                as net_churn,

    case
        when coalesce(churned, 0) + coalesce(contraction, 0) > 0
        then cast(
            coalesce(new, 0) + coalesce(resurrected, 0) + coalesce(expansion, 0)
        as float) / (coalesce(churned, 0) + coalesce(contraction, 0))
    end                                                                as quick_ratio,

    case
        when lag(total) over (order by period) > 0
        then cast(total - lag(total) over (order by period) as float)
             / lag(total) over (order by period)
    end                                                                as growth_rate

from period_agg
order by period

{% endmacro %}
