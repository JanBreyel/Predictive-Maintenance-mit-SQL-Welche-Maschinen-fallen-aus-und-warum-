-- =====================================================================
-- 04 REPORTING LAYER  |  Business-Views (Power-BI-/Dashboard-ready)
-- Hinweis: Alle Auswertungen basieren auf fact_production (Analytics-Layer).
-- Ausfallraten werden immer relativ (in %) ausgewiesen, nicht nur absolut.
-- =====================================================================

DROP VIEW IF EXISTS vw_failure_overview;
DROP VIEW IF EXISTS vw_failure_by_variant;
DROP VIEW IF EXISTS vw_failure_modes;
DROP VIEW IF EXISTS vw_failure_modes_by_variant;
DROP VIEW IF EXISTS vw_operational_risk;
DROP VIEW IF EXISTS vw_maintenance_priority;

-- ---------------------------------------------------------------------
-- 1) Gesamtüberblick (eine Zeile = Management-KPIs)
-- ---------------------------------------------------------------------
CREATE VIEW vw_failure_overview AS
SELECT
    COUNT(*)                                                   AS total_records,
    SUM(machine_failure)                                       AS total_failures,
    ROUND(100.0 * SUM(machine_failure) / COUNT(*), 2)          AS failure_rate_pct,
    ROUND(100.0 * (COUNT(*) - SUM(machine_failure)) / COUNT(*), 2) AS failure_free_rate_pct,
    SUM(CASE WHEN failure_mode_count > 1 THEN 1 ELSE 0 END)    AS records_with_multiple_modes,
    SUM(CASE WHEN dq_flag IS NOT NULL THEN 1 ELSE 0 END)       AS records_with_dq_flag
FROM fact_production;

-- ---------------------------------------------------------------------
-- 2) Produktvarianten L / M / H
-- ---------------------------------------------------------------------
CREATE VIEW vw_failure_by_variant AS
WITH variant_stats AS (
    SELECT
        v.variant_code,
        v.variant_name,
        COUNT(*)                AS production_volume,
        SUM(f.machine_failure)  AS failures
    FROM fact_production f
    JOIN dim_product_variant v ON v.product_variant_id = f.product_variant_id
    GROUP BY v.variant_code, v.variant_name
),
totals AS (
    SELECT SUM(production_volume) AS total_volume,
           SUM(failures)          AS total_failures
    FROM variant_stats
)
SELECT
    s.variant_code,
    s.variant_name,
    s.production_volume,
    ROUND(100.0 * s.production_volume / t.total_volume, 1)  AS share_of_volume_pct,
    s.failures,
    ROUND(100.0 * s.failures / t.total_failures, 1)         AS share_of_failures_pct,
    ROUND(100.0 * s.failures / s.production_volume, 2)      AS failure_rate_pct,
    -- Index 1.00 = Gesamt-Ausfallrate; >1 = überdurchschnittlich
    ROUND((1.0 * s.failures / s.production_volume) / (1.0 * t.total_failures / t.total_volume), 2) AS risk_index,
    RANK() OVER (ORDER BY 1.0 * s.failures / s.production_volume DESC) AS failure_rate_rank
FROM variant_stats s
CROSS JOIN totals t;

-- ---------------------------------------------------------------------
-- 3) Failure Modes gesamt (Long-Format über fact_failure_mode)
-- Achtung: Ein Datensatz kann mehrere Modi haben -> Summe der Modi kann
-- größer sein als die Zahl der Ausfälle. RNF tritt fast nie zusammen mit
-- machine_failure = 1 auf (siehe Spalte machine_failures_with_mode).
-- ---------------------------------------------------------------------
CREATE VIEW vw_failure_modes AS
WITH mode_stats AS (
    SELECT
        d.failure_mode_code,
        d.failure_mode_name,
        COUNT(*)                AS records_with_mode,
        SUM(f.machine_failure)  AS machine_failures_with_mode
    FROM fact_failure_mode m
    JOIN dim_failure_mode d ON d.failure_mode_id = m.failure_mode_id
    JOIN fact_production  f ON f.uid = m.uid
    GROUP BY d.failure_mode_code, d.failure_mode_name
)
SELECT
    failure_mode_code,
    failure_mode_name,
    records_with_mode,
    ROUND(100.0 * records_with_mode / (SELECT COUNT(*) FROM fact_production), 2)           AS pct_of_all_records,
    ROUND(100.0 * records_with_mode / SUM(records_with_mode) OVER (), 1)                   AS share_of_all_mode_events_pct,
    machine_failures_with_mode,
    ROUND(100.0 * machine_failures_with_mode / (SELECT SUM(machine_failure) FROM fact_production), 1) AS pct_of_machine_failures,
    RANK() OVER (ORDER BY records_with_mode DESC)                                          AS frequency_rank
FROM mode_stats;

-- ---------------------------------------------------------------------
-- 4) Failure Modes je Produktvariante
-- ---------------------------------------------------------------------
CREATE VIEW vw_failure_modes_by_variant AS
WITH variant_volume AS (
    SELECT product_variant_id, COUNT(*) AS variant_records
    FROM fact_production
    GROUP BY product_variant_id
),
mode_by_variant AS (
    SELECT f.product_variant_id, m.failure_mode_id, COUNT(*) AS records_with_mode
    FROM fact_failure_mode m
    JOIN fact_production f ON f.uid = m.uid
    GROUP BY f.product_variant_id, m.failure_mode_id
)
SELECT
    v.variant_code,
    d.failure_mode_code,
    d.failure_mode_name,
    mv.records_with_mode,
    vv.variant_records,
    ROUND(100.0 * mv.records_with_mode / vv.variant_records, 2) AS mode_rate_pct,
    RANK() OVER (PARTITION BY v.variant_code ORDER BY mv.records_with_mode DESC) AS rank_within_variant
FROM mode_by_variant mv
JOIN variant_volume       vv ON vv.product_variant_id = mv.product_variant_id
JOIN dim_product_variant  v  ON v.product_variant_id  = mv.product_variant_id
JOIN dim_failure_mode     d  ON d.failure_mode_id     = mv.failure_mode_id;

-- ---------------------------------------------------------------------
-- 5) Operational Risk: Ausfallrate je Betriebsbereich
-- risk_level: Index >= 3 -> High, >= 1.5 -> Elevated; < 30 Datensätze ->
-- 'Low sample' (zu klein für eine belastbare Aussage).
-- Explorativer Zusammenhang, KEINE nachgewiesene Kausalität.
-- ---------------------------------------------------------------------
CREATE VIEW vw_operational_risk AS
WITH banded AS (
              SELECT 'tool_wear'       AS risk_factor, wear_band       AS band, machine_failure FROM v_production_banded
    UNION ALL SELECT 'torque',           torque_band,    machine_failure FROM v_production_banded
    UNION ALL SELECT 'rotational_speed', speed_band,     machine_failure FROM v_production_banded
    UNION ALL SELECT 'temp_difference',  temp_diff_band, machine_failure FROM v_production_banded
    UNION ALL SELECT 'power',            power_band,     machine_failure FROM v_production_banded
),
agg AS (
    SELECT risk_factor, band, COUNT(*) AS records, SUM(machine_failure) AS failures
    FROM banded
    GROUP BY risk_factor, band
),
overall AS (
    SELECT 1.0 * SUM(machine_failure) / COUNT(*) AS overall_rate FROM fact_production
),
scored AS (
    SELECT a.*,
           (1.0 * a.failures / a.records)                 AS rate,
           (1.0 * a.failures / a.records) / o.overall_rate AS idx
    FROM agg a CROSS JOIN overall o
)
SELECT
    risk_factor,
    band,
    records,
    failures,
    ROUND(100.0 * rate, 2) AS failure_rate_pct,
    ROUND(idx, 2)          AS risk_index,
    CASE WHEN records < 30  THEN 'Low sample'
         WHEN idx >= 3      THEN 'High'
         WHEN idx >= 1.5    THEN 'Elevated'
         ELSE                    'Normal' END AS risk_level,
    RANK() OVER (PARTITION BY risk_factor ORDER BY rate DESC) AS rank_within_factor
FROM scored;

-- ---------------------------------------------------------------------
-- 6) Wartungspriorisierung: Segmente (Verschleiß x Drehmoment) mit
-- Pareto-Anteil. Priorität P1 = hohe Ausfallrate UND relevantes Volumen
-- an Ausfällen; sortiert nach Ausfallzahl (Pareto-Logik).
-- ---------------------------------------------------------------------
CREATE VIEW vw_maintenance_priority AS
WITH seg AS (
    SELECT wear_band, torque_band,
           COUNT(*)               AS records,
           SUM(machine_failure)   AS failures
    FROM v_production_banded
    GROUP BY wear_band, torque_band
),
scored AS (
    SELECT s.*,
           1.0 * failures / records AS rate,
           (1.0 * failures / records) / (SELECT 1.0 * SUM(machine_failure) / COUNT(*) FROM fact_production) AS idx
    FROM seg s
)
SELECT
    wear_band,
    torque_band,
    records,
    failures,
    ROUND(100.0 * rate, 2)                                              AS failure_rate_pct,
    ROUND(idx, 2)                                                       AS risk_index,
    ROUND(100.0 * failures / SUM(failures) OVER (), 1)                  AS share_of_all_failures_pct,
    ROUND(100.0 * SUM(failures) OVER (ORDER BY failures DESC, wear_band, torque_band)
          / SUM(failures) OVER (), 1)                                   AS cumulative_failure_share_pct,
    CASE WHEN idx >= 3   AND failures >= 20 THEN 'P1 - sofort prüfen'
         WHEN idx >= 1.5 AND failures >= 10 THEN 'P2 - zeitnah planen'
         ELSE                                    'P3 - Routine' END     AS maintenance_priority
FROM scored;
