-- =====================================================================
-- 02 STAGING LAYER  |  stg_machine_data + Data-Quality-Checks
-- Aufgaben: Spaltennamen vereinheitlichen, Datentypen setzen, Wertebereiche
-- und Konsistenz prüfen, abgeleitete Spalten ergänzen.
-- Entscheidung: Es werden KEINE Zeilen gelöscht. Auffällige Zeilen werden
-- markiert (dq_flag) und bleiben nachvollziehbar erhalten.
-- =====================================================================

DROP VIEW IF EXISTS vw_data_quality_checks;
DROP TABLE IF EXISTS stg_machine_data;

CREATE TABLE stg_machine_data (
    uid                    INTEGER       PRIMARY KEY,
    product_id             VARCHAR(10)   NOT NULL UNIQUE,
    product_variant        CHAR(1)       NOT NULL CHECK (product_variant IN ('L','M','H')),
    air_temperature_k      NUMERIC(4,1)  NOT NULL,
    process_temperature_k  NUMERIC(4,1)  NOT NULL,
    rotational_speed_rpm   INTEGER       NOT NULL,
    torque_nm              NUMERIC(4,1)  NOT NULL,
    tool_wear_min          INTEGER       NOT NULL,
    machine_failure        SMALLINT      NOT NULL CHECK (machine_failure IN (0,1)),
    twf                    SMALLINT      NOT NULL CHECK (twf IN (0,1)),
    hdf                    SMALLINT      NOT NULL CHECK (hdf IN (0,1)),
    pwf                    SMALLINT      NOT NULL CHECK (pwf IN (0,1)),
    osf                    SMALLINT      NOT NULL CHECK (osf IN (0,1)),
    rnf                    SMALLINT      NOT NULL CHECK (rnf IN (0,1)),
    -- abgeleitete Spalten
    temp_diff_k            NUMERIC(4,1)  NOT NULL,  -- Prozess- minus Lufttemperatur
    power_w                NUMERIC(10,2) NOT NULL,  -- Torque [Nm] * Winkelgeschw. [rad/s]
    failure_mode_count     SMALLINT      NOT NULL,  -- Anzahl gesetzter Failure-Flags
    dq_flag                VARCHAR(30)              -- NULL = unauffällig
);

INSERT INTO stg_machine_data
WITH typed AS (
    SELECT
        CAST("UDI" AS INTEGER)                          AS uid,
        TRIM("Product ID")                              AS product_id,
        UPPER(TRIM("Type"))                             AS product_variant,
        CAST("Air temperature [K]"     AS NUMERIC(4,1)) AS air_temperature_k,
        CAST("Process temperature [K]" AS NUMERIC(4,1)) AS process_temperature_k,
        CAST("Rotational speed [rpm]"  AS INTEGER)      AS rotational_speed_rpm,
        CAST("Torque [Nm]"             AS NUMERIC(4,1)) AS torque_nm,
        CAST("Tool wear [min]"         AS INTEGER)      AS tool_wear_min,
        CAST("Machine failure"         AS SMALLINT)     AS machine_failure,
        CAST("TWF" AS SMALLINT) AS twf,
        CAST("HDF" AS SMALLINT) AS hdf,
        CAST("PWF" AS SMALLINT) AS pwf,
        CAST("OSF" AS SMALLINT) AS osf,
        CAST("RNF" AS SMALLINT) AS rnf
    FROM raw_ai4i_data
),
derived AS (
    SELECT t.*,
           process_temperature_k - air_temperature_k AS temp_diff_k,
           -- 2*pi/60 = 0.10471975512  (rpm -> rad/s)
           ROUND(torque_nm * rotational_speed_rpm * 0.10471975512, 2) AS power_w,
           twf + hdf + pwf + osf + rnf AS failure_mode_count
    FROM typed t
)
SELECT
    uid, product_id, product_variant, air_temperature_k, process_temperature_k,
    rotational_speed_rpm, torque_nm, tool_wear_min,
    machine_failure, twf, hdf, pwf, osf, rnf,
    temp_diff_k, power_w, failure_mode_count,
    CASE
        WHEN machine_failure = 1 AND failure_mode_count = 0 THEN 'MF_WITHOUT_MODE'
        WHEN machine_failure = 0 AND failure_mode_count > 0 THEN 'MODE_WITHOUT_MF'
    END AS dq_flag
FROM derived;

-- ---------------------------------------------------------------------
-- Data-Quality-Checks als View (wiederholbar nach jedem Neuladen)
-- severity: FAIL = Daten unbrauchbar, WARN = dokumentierte Auffälligkeit
-- ---------------------------------------------------------------------

CREATE VIEW vw_data_quality_checks AS
SELECT 'Row count raw = staging' AS check_name, 'FAIL' AS severity,
       ABS((SELECT COUNT(*) FROM raw_ai4i_data) - (SELECT COUNT(*) FROM stg_machine_data)) AS failed_rows
UNION ALL
SELECT 'Duplicate UID', 'FAIL',
       COUNT(*) - COUNT(DISTINCT uid) FROM stg_machine_data
UNION ALL
SELECT 'Duplicate Product ID', 'FAIL',
       COUNT(*) - COUNT(DISTINCT product_id) FROM stg_machine_data
UNION ALL
SELECT 'Product ID prefix <> variant', 'FAIL',
       COUNT(*) FROM stg_machine_data WHERE SUBSTR(product_id, 1, 1) <> product_variant
UNION ALL
SELECT 'Non-positive temperature (K)', 'FAIL',
       COUNT(*) FROM stg_machine_data WHERE air_temperature_k <= 0 OR process_temperature_k <= 0
UNION ALL
SELECT 'Process temp <= air temp', 'FAIL',
       COUNT(*) FROM stg_machine_data WHERE temp_diff_k <= 0
UNION ALL
SELECT 'Rotational speed <= 0', 'FAIL',
       COUNT(*) FROM stg_machine_data WHERE rotational_speed_rpm <= 0
UNION ALL
SELECT 'Torque <= 0', 'FAIL',
       COUNT(*) FROM stg_machine_data WHERE torque_nm <= 0
UNION ALL
SELECT 'Tool wear < 0', 'FAIL',
       COUNT(*) FROM stg_machine_data WHERE tool_wear_min < 0
UNION ALL
-- Missing Values: laut UCI-Doku keine erwartet -> trotzdem explizit geprüft
SELECT 'Empty values in raw table', 'FAIL',
       COUNT(*) FROM raw_ai4i_data
       WHERE COALESCE(TRIM("UDI"),'') = '' OR COALESCE(TRIM("Product ID"),'') = ''
          OR COALESCE(TRIM("Type"),'') = '' OR COALESCE(TRIM("Air temperature [K]"),'') = ''
          OR COALESCE(TRIM("Process temperature [K]"),'') = '' OR COALESCE(TRIM("Rotational speed [rpm]"),'') = ''
          OR COALESCE(TRIM("Torque [Nm]"),'') = '' OR COALESCE(TRIM("Tool wear [min]"),'') = ''
          OR COALESCE(TRIM("Machine failure"),'') = '' OR COALESCE(TRIM("TWF"),'') = ''
          OR COALESCE(TRIM("HDF"),'') = '' OR COALESCE(TRIM("PWF"),'') = ''
          OR COALESCE(TRIM("OSF"),'') = '' OR COALESCE(TRIM("RNF"),'') = ''
UNION ALL
-- Konsistenz Machine failure <-> Failure-Modi
SELECT 'Machine failure = 1 without any failure mode', 'WARN',
       COUNT(*) FROM stg_machine_data WHERE dq_flag = 'MF_WITHOUT_MODE'
UNION ALL
SELECT 'Failure mode set but machine failure = 0', 'WARN',
       COUNT(*) FROM stg_machine_data WHERE dq_flag = 'MODE_WITHOUT_MF'
UNION ALL
SELECT 'Records with more than one failure mode', 'INFO',
       COUNT(*) FROM stg_machine_data WHERE failure_mode_count > 1;

-- Schnellprüfungen aus dem Projektplan
-- SELECT machine_failure, COUNT(*) FROM stg_machine_data GROUP BY machine_failure;
-- SELECT * FROM vw_data_quality_checks;
