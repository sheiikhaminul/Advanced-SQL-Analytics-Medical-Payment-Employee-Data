-- ============================================================
--  Advanced SQL Solutions — Medical Payment & Employee Data
--  Database  : PostgreSQL
--  Dataset   : Radiant Data System Ltd
-- ============================================================
--
--  TABLES USED:
--    employee  → Account Key, Designation, Department, Salary, Manager ID
--    payment   → Service Date, Posting Date, Account Key, Charge Key,
--                CPT Code, Transaction Amount, Allowed Amount,
--                Remit Class, CARC Code
--
--  BUSINESS RULE (applied in Q4 & Q5):
--    - Transaction Amount <= 0           → treat as 0
--    - Transaction Amount > Allowed Amount → use Allowed Amount * 0.8
--    - Otherwise                         → use Transaction Amount as-is
-- ============================================================


-- ============================================================
-- Q1: Most frequent CARC Code for Remit Class = 'Marker'
--     and which employee used it the most
-- ============================================================
--
--  APPROACH:
--    JOIN employee + payment on Account Key
--    Filter WHERE Remit Class = 'Marker'
--    GROUP BY all non-aggregate columns
--    ORDER BY COUNT DESC → LIMIT 1 picks the top row
--
--  TIP: LIMIT 1 after ORDER BY COUNT(*) DESC is the simplest
--       way to get the single "top" record without any window function.
--       Use this pattern whenever you only need ONE top result.

SELECT
    p."CARC Code",
    p."Account Key",
    e."Designation",
    e."Department",
    COUNT(*) AS count
FROM employee e
INNER JOIN payment p
    ON e."Account Key" = p."Account Key"
WHERE p."Remit Class" = 'Marker'
GROUP BY
    p."CARC Code",
    p."Account Key",
    e."Designation",
    e."Department"
ORDER BY count DESC
LIMIT 1;


-- ============================================================
-- Q2: Most frequent CARC Code for Remit Class = 'Denial'
--     and which employee used it the most
-- ============================================================
--
--  APPROACH: Identical to Q1 — only the WHERE filter changes.
--
--  TIP: Reusing the same query structure by changing only the
--       WHERE clause is a clean, interview-friendly pattern.
--       Avoid duplicating logic unnecessarily.

SELECT
    p."CARC Code",
    p."Account Key",
    e."Designation",
    e."Department",
    COUNT(*) AS count
FROM payment p
INNER JOIN employee e
    ON p."Account Key" = e."Account Key"
WHERE p."Remit Class" = 'Denial'
GROUP BY
    p."CARC Code",
    p."Account Key",
    e."Designation",
    e."Department"
ORDER BY count DESC
LIMIT 1;


-- ============================================================
-- Q3: Top 2 salaries within each Department
-- ============================================================
--
--  APPROACH:
--    Use ROW_NUMBER() partitioned by Department, ordered by Salary DESC
--    Wrap in CTE → filter ranks < 3 in outer query
--
--  TIP 1 (ROW_NUMBER vs RANK):
--    ROW_NUMBER() → always unique (1,2,3...) even if salaries are tied
--    RANK()       → tied salaries get the same rank (1,1,3...)
--    DENSE_RANK() → tied salaries get same rank, no gaps (1,1,2...)
--    Use ROW_NUMBER() when you strictly want exactly N rows per group.
--
--  TIP 2 (CTE + Window Filter):
--    You CANNOT use WHERE ranks < 3 directly in the same SELECT
--    where ROW_NUMBER() is computed — aliases aren't available yet.
--    Always wrap window functions in a CTE or subquery first.

WITH cte AS (
    SELECT
        e."Account Key",
        e."Designation",
        e."Department",
        e."Salary",
        e."Manager ID",
        ROW_NUMBER() OVER (
            PARTITION BY e."Department"   -- reset rank for each department
            ORDER BY e."Salary" DESC      -- highest salary gets rank 1
        ) AS ranks
    FROM employee e
)
SELECT *
FROM cte
WHERE ranks < 3;   -- ranks 1 and 2 only  (equivalent to ranks <= 2)


-- ============================================================
-- Q4: Month-over-Month % change in modified Transaction Amount
-- ============================================================
--
--  APPROACH:
--    Step 1 (CTE)  → apply business rule via CASE WHEN inside SUM(),
--                    group by year + month
--    Step 2 (Main) → use LAG() to fetch previous month's amount,
--                    compute % change
--
--  TIP 1 (ROUND + typecast):
--    PostgreSQL's ROUND() does NOT accept float8 (double precision).
--    SUM() on a numeric column returns float8 by default.
--    Always cast to ::NUMERIC before applying ROUND():
--      ROUND( SUM(...)::NUMERIC, 2 )   ✅
--      ROUND( SUM(...), 2 )            ❌ will throw a type error
--
--  TIP 2 (Date casting):
--    If the Posting Date column is stored as TEXT or VARCHAR,
--    cast it to DATE first: "Posting Date"::DATE
--    Then EXTRACT() works correctly on it.
--
--  TIP 3 (LAG default value):
--    LAG(col, 1, 0) → third argument is the default when no previous row exists.
--    Without it, the first row returns NULL, which breaks arithmetic.
--    Always supply a default for the first row.
--
--  TIP 4 (Division by zero):
--    Always guard division with CASE WHEN divisor = 0 THEN 0 (or NULL).
--    Skipping this causes a runtime error when previous month amount is 0.

WITH cte AS (
    SELECT
        EXTRACT(YEAR  FROM p."Posting Date"::DATE) AS "posting year",
        EXTRACT(MONTH FROM p."Posting Date"::DATE) AS "posting month",

        -- Apply business rule, then SUM and ROUND
        -- MUST cast to ::NUMERIC — ROUND() rejects float8 in PostgreSQL
        ROUND(
            SUM(
                CASE
                    WHEN p."Transaction Amount" <= 0                       THEN 0
                    WHEN p."Transaction Amount" > p."Allowed Amount"       THEN p."Allowed Amount" * 0.8
                    ELSE p."Transaction Amount"
                END
            )::NUMERIC, 2
        ) AS mod_trans_amount

    FROM payment p
    GROUP BY "posting year", "posting month"
)
SELECT
    cte."posting year",
    cte."posting month",
    cte.mod_trans_amount,

    -- LAG(col, offset, default) — default=0 prevents NULL on first row
    LAG(cte.mod_trans_amount, 1, 0) OVER (
        ORDER BY cte."posting year", cte."posting month"
    ) AS prev_mod_trans_amount,

    -- % change: guard against division by zero when prev month = 0
    CASE
        WHEN LAG(cte.mod_trans_amount, 1, 0) OVER (
                ORDER BY cte."posting year", cte."posting month"
             ) = 0
        THEN 0
        ELSE ROUND(
            (
                (
                    cte.mod_trans_amount
                    - LAG(cte.mod_trans_amount, 1, 0) OVER (
                        ORDER BY cte."posting year", cte."posting month"
                      )
                )
                / LAG(cte.mod_trans_amount, 1, 0) OVER (
                    ORDER BY cte."posting year", cte."posting month"
                  )
                * 100
            )::NUMERIC, 2
        )
    END AS percent_increase

FROM cte;


-- ============================================================
-- Q5: Employee with highest modified payment each month
-- ============================================================
--
--  APPROACH:
--    JOIN payment + employee
--    Apply business rule inside SUM() → grouped by Account Key + year/month
--    RANK() partitioned by year+month → rank 1 = top payer that month
--    Filter rank <= 1 in outer query
--
--  TIP 1 (RANK vs ROW_NUMBER here):
--    Use RANK() (not ROW_NUMBER()) so that if two employees have
--    the exact same amount in a month, BOTH appear as rank 1.
--    ROW_NUMBER() would arbitrarily drop one of them.
--
--  TIP 2 (Repeating expression in RANK):
--    You cannot reference the alias "mod_trans_amount" inside the
--    RANK() OVER(...ORDER BY...) in the same SELECT level.
--    The full CASE WHEN / SUM expression must be repeated.
--    This is a PostgreSQL limitation — alias resolution happens
--    after window functions are evaluated.
--    Solution: move the aggregation to a CTE, then apply RANK() on the alias.
--    (That approach would require a nested CTE — kept flat here for clarity.)
--
--  TIP 3 (ROUND + ::NUMERIC):
--    Same as Q4 — always cast SUM result to ::NUMERIC before ROUND().

WITH cte AS (
    SELECT
        p."Account Key",
        EXTRACT(YEAR  FROM p."Posting Date"::DATE) AS "posting year",
        EXTRACT(MONTH FROM p."Posting Date"::DATE) AS "posting month",

        -- Modified Transaction Amount with business rule
        ROUND(
            SUM(
                CASE
                    WHEN p."Transaction Amount" <= 0                      THEN 0
                    WHEN p."Transaction Amount" > p."Allowed Amount"      THEN p."Allowed Amount" * 0.8
                    ELSE p."Transaction Amount"
                END
            )::NUMERIC, 2
        ) AS mod_trans_amount,

        -- Rank employees within each year-month by their total amount
        -- RANK() used so tied employees both appear as rank 1
        RANK() OVER (
            PARTITION BY
                EXTRACT(YEAR  FROM p."Posting Date"::DATE),
                EXTRACT(MONTH FROM p."Posting Date"::DATE)
            ORDER BY
                ROUND(
                    SUM(
                        CASE
                            WHEN p."Transaction Amount" <= 0                  THEN 0
                            WHEN p."Transaction Amount" > p."Allowed Amount"  THEN p."Allowed Amount" * 0.8
                            ELSE p."Transaction Amount"
                        END
                    )::NUMERIC, 2
                ) DESC
        ) AS rank,

        e."Designation",
        e."Department",
        e."Manager ID"

    FROM payment p
    INNER JOIN employee e
        ON p."Account Key" = e."Account Key"
    GROUP BY
        p."Account Key",
        e."Department",
        e."Designation",
        e."Manager ID",
        "posting year",
        "posting month"
)
SELECT *
FROM cte
WHERE rank <= 1
ORDER BY cte."posting year", cte."posting month";


-- ============================================================
-- END OF SCRIPT
-- ============================================================
