-- =====================================================================
-- 05 ADVANCED SQL ANALYSIS  (Ad-hoc-Abfragen auf Analytics-/Reporting-Layer)
-- CTEs, Window Functions, LAG, PARTITION BY, NTILE, Subqueries, CORR
-- =====================================================================

-- ---------------------------------------------------------------------
-- A1) Ranking der Produktvarianten nach Ausfallrate (CTE + RANK)
-- ---------------------------------------------------------------------
WITH variant_analysis AS (
    SELECT v.variant_code,
           COUNT(*)                                   AS total_records,
           SUM(f.machine_failure)                     AS failures,
           100.0 * SUM(f.machine_failure) / COUNT(*)  AS failure_rate
    FROM fact_production f
    JOIN dim_product_variant v ON v.product_variant_id = f.product_variant_id
    GROUP BY v.variant_code
)
SELECT variant_code, total_records, failures,
       ROUND(failure_rate, 2) AS failure_rate_pct,
       RANK() OVER (ORDER BY failure_rate DESC) AS failure_ranking
FROM variant_analysis;

-- ---------------------------------------------------------------------
-- A2) Sind die Unterschiede zwischen Varianten belastbar?
-- Näherungsintervall (Wald, 95 %) für die Ausfallrate. Bei H (n ~ 1.000)
-- ist das Intervall deutlich breiter als bei L (n = 6.000).
-- ---------------------------------------------------------------------
WITH v AS (
    SELECT d.variant_code,
           COUNT(*) AS n,
           1.0 * SUM(f.machine_failure) / COUNT(*) AS p
    FROM fact_production f
    JOIN dim_product_variant d ON d.product_variant_id = f.product_variant_id
    GROUP BY d.variant_code
)
SELECT variant_code, n,
       ROUND(100.0 * p, 2)                                         AS failure_rate_pct,
       ROUND(100.0 * (p - 1.96 * SQRT(p * (1 - p) / n)), 2)        AS ci95_lower_pct,
       ROUND(100.0 * (p + 1.96 * SQRT(p * (1 - p) / n)), 2)        AS ci95_upper_pct
FROM v
ORDER BY p DESC;

-- ---------------------------------------------------------------------
-- B) Failure Modes je Variante als Pivot (Conditional Aggregation)
-- ---------------------------------------------------------------------
SELECT v.variant_code,
       COUNT(*)                                                    AS records,
       SUM(f.twf) AS twf, SUM(f.hdf) AS hdf, SUM(f.pwf) AS pwf,
       SUM(f.osf) AS osf, SUM(f.rnf) AS rnf,
       ROUND(100.0 * SUM(f.osf) / COUNT(*), 2)                     AS osf_rate_pct
FROM fact_production f
JOIN dim_product_variant v ON v.product_variant_id = f.product_variant_id
GROUP BY v.variant_code
ORDER BY v.variant_code;

-- ---------------------------------------------------------------------
-- C) Werkzeugverschleiß in 25-Minuten-Stufen + LAG
-- LAG ist hier sinnvoll, weil die Stufen eine natürliche Reihenfolge haben.
-- NICHT sinnvoll wäre LAG über uid: Der Datensatz enthält keinen Zeitstempel
-- und keine Maschinen-ID, uid ist nur eine laufende Nummer.
-- ---------------------------------------------------------------------
WITH wear_steps AS (
    SELECT (tool_wear_min / 25) * 25 AS wear_from_min,
           COUNT(*)                  AS records,
           SUM(machine_failure)      AS failures
    FROM fact_production
    GROUP BY (tool_wear_min / 25) * 25
),
rates AS (
    SELECT wear_from_min, records, failures,
           100.0 * failures / records AS failure_rate_pct
    FROM wear_steps
)
SELECT wear_from_min,
       wear_from_min + 24                                   AS wear_to_min,
       records, failures,
       ROUND(failure_rate_pct, 2)                           AS failure_rate_pct,
       ROUND(failure_rate_pct
             - LAG(failure_rate_pct) OVER (ORDER BY wear_from_min), 2) AS change_vs_previous_step_pp
FROM rates
ORDER BY wear_from_min;

-- ---------------------------------------------------------------------
-- D) Drehmoment-Dezile (NTILE): Wie konzentriert sind Ausfälle?
-- ---------------------------------------------------------------------
WITH deciles AS (
    SELECT machine_failure, torque_nm,
           NTILE(10) OVER (ORDER BY torque_nm) AS torque_decile
    FROM fact_production
)
SELECT torque_decile,
       MIN(torque_nm) AS torque_min,
       MAX(torque_nm) AS torque_max,
       COUNT(*)       AS records,
       SUM(machine_failure) AS failures,
       ROUND(100.0 * SUM(machine_failure) / COUNT(*), 2) AS failure_rate_pct
FROM deciles
GROUP BY torque_decile
ORDER BY torque_decile;

-- ---------------------------------------------------------------------
-- E) Variante x Verschleiß, Ranking je Variante (PARTITION BY)
-- ---------------------------------------------------------------------
SELECT product_variant, wear_band,
       COUNT(*)                                            AS records,
       SUM(machine_failure)                                AS failures,
       ROUND(100.0 * SUM(machine_failure) / COUNT(*), 2)   AS failure_rate_pct,
       RANK() OVER (PARTITION BY product_variant
                    ORDER BY 1.0 * SUM(machine_failure) / COUNT(*) DESC) AS rank_in_variant
FROM v_production_banded
GROUP BY product_variant, wear_band
ORDER BY product_variant, rank_in_variant;

-- ---------------------------------------------------------------------
-- F) Subquery: Segmente (Variante x Verschleiß x Drehmoment) mit
--    überdurchschnittlicher Ausfallrate und ausreichender Stichprobe
-- ---------------------------------------------------------------------
SELECT product_variant, wear_band, torque_band,
       COUNT(*) AS records,
       SUM(machine_failure) AS failures,
       ROUND(100.0 * SUM(machine_failure) / COUNT(*), 2) AS failure_rate_pct
FROM v_production_banded
GROUP BY product_variant, wear_band, torque_band
HAVING COUNT(*) >= 30
   AND 1.0 * SUM(machine_failure) / COUNT(*) >
       (SELECT 1.0 * SUM(machine_failure) / COUNT(*) FROM fact_production) * 3
ORDER BY failure_rate_pct DESC;

-- ---------------------------------------------------------------------
-- G) Welche Messgrößen hängen linear mit dem Ausfall zusammen?
-- Punktbiseriale Korrelation (PostgreSQL: CORR). Linear = unvollständig:
-- Drehzahl und Temperaturdifferenz wirken eher über Schwellenbereiche
-- (siehe vw_operational_risk), daher sind die Werte klein.
-- ---------------------------------------------------------------------
SELECT ROUND(CAST(CORR(torque_nm,            machine_failure) AS NUMERIC), 3) AS corr_torque,
       ROUND(CAST(CORR(tool_wear_min,        machine_failure) AS NUMERIC), 3) AS corr_tool_wear,
       ROUND(CAST(CORR(rotational_speed_rpm, machine_failure) AS NUMERIC), 3) AS corr_speed,
       ROUND(CAST(CORR(temp_diff_k,          machine_failure) AS NUMERIC), 3) AS corr_temp_diff,
       ROUND(CAST(CORR(air_temperature_k,    machine_failure) AS NUMERIC), 3) AS corr_air_temp,
       ROUND(CAST(CORR(power_w,              machine_failure) AS NUMERIC), 3) AS corr_power
FROM fact_production;

-- ---------------------------------------------------------------------
-- H) Pareto der Wartungspriorisierung (aus dem Reporting-Layer)
-- ---------------------------------------------------------------------
SELECT * FROM vw_maintenance_priority ORDER BY failures DESC;
