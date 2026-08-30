-- Ecommerce Analytics Portfolio Project
-- Consolidated PostgreSQL script for the Power BI dashboard
-- Generated as a cleaned, single-file version of the SQL used during the project.
--
-- Expected raw tables:
--   raw.website_sessions
--   raw.website_pageviews
--   raw.orders
--   raw.order_items
--   raw.order_item_refunds
--   raw.products
--
-- Main Power BI datasets produced:
--   analytics.session_performance
--   analytics.session_funnel
--   analytics.product_performance
--   public.analytics_funnel_performance
--
-- NOTE:
-- This is a consolidated/refactored project script rather than a byte-for-byte
-- transcript of every command entered interactively.

CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS analytics;


-- ============================================================
-- 1. CLEAN LAYER
-- ============================================================

CREATE OR REPLACE VIEW clean.website_sessions AS
SELECT
    website_session_id,
    created_at,
    created_at::date AS session_date,
    user_id,
    CASE
        WHEN is_repeat_session = 1 THEN TRUE
        ELSE FALSE
    END AS is_repeat_session,
    utm_source,
    utm_campaign,
    utm_content,
    device_type,
    http_referer,
    CASE
        WHEN utm_source IS NULL AND http_referer IS NULL
            THEN 'Direct'
        WHEN utm_source IS NULL AND http_referer IS NOT NULL
            THEN 'Organic Search'
        WHEN LOWER(COALESCE(utm_source, '')) LIKE '%social%'
            THEN 'Paid Social'
        WHEN LOWER(COALESCE(utm_campaign, '')) = 'brand'
            THEN 'Paid Search - Brand'
        WHEN LOWER(COALESCE(utm_campaign, '')) = 'nonbrand'
            THEN 'Paid Search - Nonbrand'
        ELSE COALESCE(utm_source, 'Other')
    END AS traffic_channel
FROM raw.website_sessions;


CREATE OR REPLACE VIEW clean.website_pageviews AS
SELECT
    website_pageview_id,
    created_at,
    website_session_id,
    pageview_url
FROM raw.website_pageviews;


CREATE OR REPLACE VIEW clean.products AS
SELECT
    product_id,
    created_at,
    product_name
FROM raw.products;


CREATE OR REPLACE VIEW clean.orders AS
SELECT
    order_id,
    created_at,
    created_at::date AS order_date,
    website_session_id,
    user_id,
    primary_product_id,
    items_purchased,
    price_usd,
    cogs_usd,
    price_usd - cogs_usd AS gross_profit_usd
FROM raw.orders;


-- Exact clean-order-items logic used in the project.
CREATE OR REPLACE VIEW clean.order_items AS
SELECT
    order_item_id,
    created_at,
    order_id,
    product_id,
    CASE
        WHEN is_primary_item = 1 THEN TRUE
        ELSE FALSE
    END AS is_primary_item,
    price_usd,
    cogs_usd,
    price_usd - cogs_usd AS gross_profit_usd
FROM raw.order_items;


CREATE OR REPLACE VIEW clean.order_item_refunds AS
SELECT
    order_item_refund_id,
    created_at,
    order_item_id,
    order_id,
    refund_amount_usd
FROM raw.order_item_refunds;


-- ============================================================
-- 2. BASIC RECONCILIATION / DATA-QUALITY CHECKS
-- ============================================================

-- Order-item reconciliation.
-- During the project this returned approximately:
-- 40,025 order items
-- $1,938,509.75 revenue
-- $722,370.25 COGS
-- $1,216,139.50 gross profit
SELECT
    COUNT(*) AS order_items,
    ROUND(SUM(price_usd)::numeric, 2) AS revenue,
    ROUND(SUM(cogs_usd)::numeric, 2) AS cogs,
    ROUND(SUM(gross_profit_usd)::numeric, 2) AS gross_profit
FROM clean.order_items;


-- Refund summary.
SELECT
    COUNT(*) AS refund_records,
    ROUND(SUM(refund_amount_usd)::numeric, 2) AS refunded_revenue,
    ROUND(AVG(refund_amount_usd)::numeric, 2) AS average_refund
FROM clean.order_item_refunds;


-- Refund integrity checks.
SELECT
    COUNT(*) AS total_refunds,
    COUNT(*) FILTER (
        WHERE r.refund_amount_usd > i.price_usd
    ) AS refunds_greater_than_item_price,
    COUNT(*) FILTER (
        WHERE r.order_id <> i.order_id
    ) AS order_id_mismatches
FROM clean.order_item_refunds r
JOIN clean.order_items i
    ON r.order_item_id = i.order_item_id;


-- Gross, refunded, and net revenue.
WITH refund_by_item AS (
    SELECT
        order_item_id,
        SUM(refund_amount_usd) AS refunded_revenue
    FROM clean.order_item_refunds
    GROUP BY order_item_id
)
SELECT
    ROUND(SUM(i.price_usd)::numeric, 2) AS gross_revenue,
    ROUND(SUM(COALESCE(r.refunded_revenue, 0))::numeric, 2) AS refunded_revenue,
    ROUND(
        (
            SUM(i.price_usd)
            - SUM(COALESCE(r.refunded_revenue, 0))
        )::numeric,
        2
    ) AS net_revenue,
    ROUND(
        (
            SUM(COALESCE(r.refunded_revenue, 0))
            / NULLIF(SUM(i.price_usd), 0)
            * 100
        )::numeric,
        2
    ) AS refund_revenue_rate_pct
FROM clean.order_items i
LEFT JOIN refund_by_item r
    ON i.order_item_id = r.order_item_id;


-- ============================================================
-- 3. PRODUCT PERFORMANCE
-- ============================================================

CREATE OR REPLACE VIEW analytics.product_performance AS
WITH refund_by_item AS (
    SELECT
        order_item_id,
        SUM(refund_amount_usd) AS refunded_revenue
    FROM clean.order_item_refunds
    GROUP BY order_item_id
)
SELECT
    i.order_item_id,
    i.created_at AS order_item_created_at,
    i.order_id,
    o.order_date,
    o.website_session_id,
    s.user_id,
    i.product_id,
    p.product_name,
    i.is_primary_item,
    i.price_usd AS gross_revenue,
    i.cogs_usd AS cogs,
    i.gross_profit_usd AS gross_profit,
    COALESCE(r.refunded_revenue, 0) AS refunded_revenue,
    i.price_usd - COALESCE(r.refunded_revenue, 0) AS net_revenue,
    CASE
        WHEN COALESCE(r.refunded_revenue, 0) > 0 THEN TRUE
        ELSE FALSE
    END AS was_refunded,
    s.traffic_channel,
    s.utm_source,
    s.utm_campaign,
    s.device_type
FROM clean.order_items i
JOIN clean.orders o
    ON i.order_id = o.order_id
JOIN clean.website_sessions s
    ON o.website_session_id = s.website_session_id
LEFT JOIN clean.products p
    ON i.product_id = p.product_id
LEFT JOIN refund_by_item r
    ON i.order_item_id = r.order_item_id;


-- Product-level QA / analysis query.
SELECT
    product_id,
    product_name,
    COUNT(*) AS units_sold,
    ROUND(SUM(gross_revenue)::numeric, 2) AS gross_revenue,
    ROUND(SUM(cogs)::numeric, 2) AS cogs,
    ROUND(SUM(gross_profit)::numeric, 2) AS gross_profit,
    ROUND(SUM(refunded_revenue)::numeric, 2) AS refunded_revenue,
    ROUND(SUM(net_revenue)::numeric, 2) AS net_revenue,
    ROUND(
        (
            COUNT(*) FILTER (WHERE was_refunded)::numeric
            / NULLIF(COUNT(*), 0)
            * 100
        ),
        2
    ) AS refund_rate_pct
FROM analytics.product_performance
GROUP BY product_id, product_name
ORDER BY gross_revenue DESC;


-- ============================================================
-- 4. SESSION PERFORMANCE
-- ============================================================

CREATE OR REPLACE VIEW analytics.session_performance AS
WITH order_item_rollup AS (
    SELECT
        o.website_session_id,
        MIN(o.order_id) AS order_id,
        COUNT(DISTINCT o.order_id) AS orders,
        COUNT(i.order_item_id) AS items_purchased,
        SUM(i.price_usd) AS gross_revenue,
        SUM(i.cogs_usd) AS cogs,
        SUM(i.gross_profit_usd) AS gross_profit
    FROM clean.orders o
    JOIN clean.order_items i
        ON o.order_id = i.order_id
    GROUP BY o.website_session_id
),
refund_rollup AS (
    SELECT
        o.website_session_id,
        SUM(r.refund_amount_usd) AS refunded_revenue
    FROM clean.orders o
    JOIN clean.order_items i
        ON o.order_id = i.order_id
    JOIN clean.order_item_refunds r
        ON i.order_item_id = r.order_item_id
    GROUP BY o.website_session_id
)
SELECT
    s.created_at AS session_created_at,
    s.session_date,
    s.website_session_id,
    s.user_id,
    s.is_repeat_session,
    CASE
        WHEN s.is_repeat_session THEN 'Repeat'
        ELSE 'New'
    END AS customer_type,
    s.device_type,
    s.utm_source,
    s.utm_campaign,
    s.utm_content,
    s.traffic_channel,
    o.order_id,
    COALESCE(o.orders, 0) AS orders,
    COALESCE(o.items_purchased, 0) AS items_purchased,
    CASE
        WHEN COALESCE(o.orders, 0) > 0 THEN TRUE
        ELSE FALSE
    END AS converted,
    COALESCE(o.gross_revenue, 0) AS gross_revenue,
    COALESCE(o.cogs, 0) AS cogs,
    COALESCE(o.gross_profit, 0) AS gross_profit,
    COALESCE(r.refunded_revenue, 0) AS refunded_revenue,
    COALESCE(o.gross_revenue, 0) - COALESCE(r.refunded_revenue, 0) AS net_revenue
FROM clean.website_sessions s
LEFT JOIN order_item_rollup o
    ON s.website_session_id = o.website_session_id
LEFT JOIN refund_rollup r
    ON s.website_session_id = r.website_session_id;


-- Session KPI reconciliation.
SELECT
    COUNT(*) AS sessions,
    SUM(orders) AS orders,
    ROUND(
        (
            SUM(orders)::numeric
            / NULLIF(COUNT(*), 0)
            * 100
        ),
        2
    ) AS conversion_rate_pct,
    ROUND(SUM(gross_revenue)::numeric, 2) AS gross_revenue,
    ROUND(SUM(net_revenue)::numeric, 2) AS net_revenue,
    ROUND(SUM(gross_profit)::numeric, 2) AS gross_profit,
    ROUND(
        (
            SUM(gross_revenue)
            / NULLIF(SUM(orders), 0)
        )::numeric,
        2
    ) AS average_order_value,
    ROUND(
        (
            SUM(refunded_revenue)
            / NULLIF(SUM(gross_revenue), 0)
            * 100
        )::numeric,
        2
    ) AS refund_revenue_rate_pct,
    ROUND(
        (
            SUM(gross_revenue)
            / NULLIF(COUNT(*), 0)
        )::numeric,
        2
    ) AS revenue_per_session
FROM analytics.session_performance;


-- Traffic-channel analysis.
SELECT
    traffic_channel,
    COUNT(*) AS sessions,
    SUM(orders) AS orders,
    ROUND(
        (
            SUM(orders)::numeric
            / NULLIF(COUNT(*), 0)
            * 100
        ),
        2
    ) AS conversion_rate_pct,
    ROUND(SUM(gross_revenue)::numeric, 2) AS gross_revenue
FROM analytics.session_performance
GROUP BY traffic_channel
ORDER BY sessions DESC;


-- Device mix.
SELECT
    device_type,
    COUNT(*) AS sessions,
    ROUND(
        (
            COUNT(*)::numeric
            / SUM(COUNT(*)) OVER ()
            * 100
        ),
        2
    ) AS session_share_pct
FROM analytics.session_performance
GROUP BY device_type
ORDER BY sessions DESC;


-- ============================================================
-- 5. SESSION FUNNEL
-- ============================================================

CREATE OR REPLACE VIEW analytics.session_funnel AS
SELECT
    s.website_session_id,
    s.session_date,
    s.user_id,
    CASE
        WHEN s.is_repeat_session THEN 'Repeat'
        ELSE 'New'
    END AS customer_type,
    s.device_type,

    MAX(
        CASE
            WHEN p.pageview_url = '/products' THEN 1
            ELSE 0
        END
    ) AS reached_products,

    MAX(
        CASE
            WHEN p.pageview_url IN (
                '/the-original-mr-fuzzy',
                '/the-forever-love-bear',
                '/the-birthday-sugar-panda',
                '/the-hudson-river-mini-bear'
            ) THEN 1
            ELSE 0
        END
    ) AS reached_product_detail,

    MAX(
        CASE
            WHEN p.pageview_url = '/cart' THEN 1
            ELSE 0
        END
    ) AS reached_cart,

    MAX(
        CASE
            WHEN p.pageview_url = '/shipping' THEN 1
            ELSE 0
        END
    ) AS reached_shipping,

    MAX(
        CASE
            WHEN p.pageview_url IN ('/billing', '/billing-2') THEN 1
            ELSE 0
        END
    ) AS reached_billing,

    MAX(
        CASE
            WHEN p.pageview_url = '/thank-you-for-your-order' THEN 1
            ELSE 0
        END
    ) AS reached_order

FROM clean.website_sessions s
LEFT JOIN clean.website_pageviews p
    ON s.website_session_id = p.website_session_id
GROUP BY
    s.website_session_id,
    s.session_date,
    s.user_id,
    s.is_repeat_session,
    s.device_type;


-- Funnel counts.
WITH counts AS (
    SELECT
        COUNT(*) AS all_sessions,
        SUM(reached_products) AS products,
        SUM(reached_product_detail) AS product_detail,
        SUM(reached_cart) AS cart,
        SUM(reached_shipping) AS shipping,
        SUM(reached_billing) AS billing,
        SUM(reached_order) AS order_complete
    FROM analytics.session_funnel
)
SELECT *
FROM counts;


-- ============================================================
-- 6. POWER BI FUNNEL PERFORMANCE TABLE
-- ============================================================

-- The Power BI report used a compact table with:
--   stage
--   stage_order
--   users
--   pct_of_previous_stage
--
-- Creating it in public preserves the simple table name:
-- analytics_funnel_performance

CREATE OR REPLACE VIEW public.analytics_funnel_performance AS
WITH counts AS (
    SELECT
        COUNT(*)::numeric AS all_sessions,
        SUM(reached_products)::numeric AS products,
        SUM(reached_product_detail)::numeric AS product_detail,
        SUM(reached_cart)::numeric AS cart,
        SUM(reached_shipping)::numeric AS shipping,
        SUM(reached_billing)::numeric AS billing,
        SUM(reached_order)::numeric AS order_complete
    FROM analytics.session_funnel
),
stages AS (
    SELECT 1 AS stage_order, 'All Sessions'::text AS stage, all_sessions AS users, NULL::numeric AS previous_users
    FROM counts

    UNION ALL
    SELECT 2, 'Products', products, all_sessions
    FROM counts

    UNION ALL
    SELECT 3, 'Product Detail', product_detail, products
    FROM counts

    UNION ALL
    SELECT 4, 'Cart', cart, product_detail
    FROM counts

    UNION ALL
    SELECT 5, 'Shipping', shipping, cart
    FROM counts

    UNION ALL
    SELECT 6, 'Billing', billing, shipping
    FROM counts

    UNION ALL
    SELECT 7, 'Order Complete', order_complete, billing
    FROM counts
)
SELECT
    stage,
    stage_order,
    users::bigint AS users,
    CASE
        WHEN stage_order = 1 THEN 100.00
        ELSE ROUND((users / NULLIF(previous_users, 0) * 100)::numeric, 2)
    END AS pct_of_previous_stage
FROM stages
ORDER BY stage_order;


-- ============================================================
-- 7. PAGEVIEW QA
-- ============================================================

SELECT
    pageview_url,
    COUNT(*) AS pageviews,
    COUNT(DISTINCT website_session_id) AS unique_sessions
FROM clean.website_pageviews
GROUP BY pageview_url
ORDER BY pageviews DESC;


-- ============================================================
-- 8. FINAL DASHBOARD TOTALS CHECK
-- ============================================================

-- The completed dashboard showed approximately:
-- Sessions:             473K
-- Orders:               32K
-- Conversion Rate:      6.83%
-- Gross Revenue:        $1.94M
-- Net Revenue:          $1.85M
-- Gross Profit:         $1.22M
-- Average Order Value:  $59.99
-- Refund Rate:          4.40%
-- Revenue per Session:  $4.10
--
-- Run this before refreshing Power BI to catch accidental upstream changes.

SELECT
    COUNT(*) AS sessions,
    SUM(orders) AS orders,
    ROUND((SUM(orders)::numeric / NULLIF(COUNT(*), 0) * 100), 2) AS conversion_rate_pct,
    ROUND(SUM(gross_revenue)::numeric, 2) AS gross_revenue,
    ROUND(SUM(net_revenue)::numeric, 2) AS net_revenue,
    ROUND(SUM(gross_profit)::numeric, 2) AS gross_profit,
    ROUND((SUM(gross_revenue) / NULLIF(SUM(orders), 0))::numeric, 2) AS average_order_value,
    ROUND((SUM(refunded_revenue) / NULLIF(SUM(gross_revenue), 0) * 100)::numeric, 2) AS refund_revenue_rate_pct,
    ROUND((SUM(gross_revenue) / NULLIF(COUNT(*), 0))::numeric, 2) AS revenue_per_session
FROM analytics.session_performance;
