-- =====================================================================
-- 03 ANALYTICS LAYER  |  Sternschema
--   dim_product_variant, dim_failure_mode, fact_production,
--   fact_failure_mode (Zuordnung: ein Datensatz kann mehrere Modi haben)
--   v_production_banded (wiederverwendbare Kategorisierung)
-- Modellierungsentscheidung: Die fünf Failure-Modi bleiben als Flags in
-- fact_production erhalten UND werden zusätzlich in fact_failure_mode
-- (1 Zeile je Datensatz und Modus) abgebildet, ohne auf einen Fehler
-- pro Datensatz zu reduzieren.
-- =====================================================================

DROP VIEW  IF EXISTS v_production_banded;
DROP TABLE IF EXISTS fact_failure_mode;
DROP TABLE IF EXISTS fact_production;
DROP TABLE IF EXISTS dim_failure_mode;
DROP TABLE IF EXISTS dim_product_variant;

CREATE TABLE dim_product_variant (
    product_variant_id  SMALLINT    PRIMARY KEY,
    variant_code        CHAR(1)     NOT NULL UNIQUE,
    variant_name        VARCHAR(20) NOT NULL
);

INSERT INTO dim_product_variant VALUES
    (1, 'L', 'Low quality'),
    (2, 'M', 'Medium quality'),
    (3, 'H', 'High quality');

CREATE TABLE dim_failure_mode (
    failure_mode_id    SMALLINT    PRIMARY KEY,
    failure_mode_code  VARCHAR(3)  NOT NULL UNIQUE,
    failure_mode_name  VARCHAR(40) NOT NULL,
    description        VARCHAR(120)
);

INSERT INTO dim_failure_mode VALUES
    (1, 'TWF', 'Tool Wear Failure',        'Werkzeug verschlissen bzw. ausgetauscht'),
    (2, 'HDF', 'Heat Dissipation Failure', 'Unzureichende Wärmeabfuhr'),
    (3, 'PWF', 'Power Failure',            'Leistung außerhalb des zulässigen Bereichs'),
    (4, 'OSF', 'Overstrain Failure',       'Überlastung (Werkzeugverschleiß x Drehmoment)'),
    (5, 'RNF', 'Random Failure',           'Zufälliger Ausfall');

CREATE TABLE fact_production (
    uid                    INTEGER       PRIMARY KEY,
    product_id             VARCHAR(10)   NOT NULL,
    product_variant_id     SMALLINT      NOT NULL REFERENCES dim_product_variant (product_variant_id),
    air_temperature_k      NUMERIC(4,1)  NOT NULL,
    process_temperature_k  NUMERIC(4,1)  NOT NULL,
    temp_diff_k            NUMERIC(4,1)  NOT NULL,
    rotational_speed_rpm   INTEGER       NOT NULL,
    torque_nm              NUMERIC(4,1)  NOT NULL,
    power_w                NUMERIC(10,2) NOT NULL,
    tool_wear_min          INTEGER       NOT NULL,
    machine_failure        SMALLINT      NOT NULL,
    twf SMALLINT NOT NULL, hdf SMALLINT NOT NULL, pwf SMALLINT NOT NULL,
    osf SMALLINT NOT NULL, rnf SMALLINT NOT NULL,
    failure_mode_count     SMALLINT      NOT NULL,
    dq_flag                VARCHAR(30)
);

INSERT INTO fact_production
SELECT s.uid, s.product_id, d.product_variant_id,
       s.air_temperature_k, s.process_temperature_k, s.temp_diff_k,
       s.rotational_speed_rpm, s.torque_nm, s.power_w, s.tool_wear_min,
       s.machine_failure, s.twf, s.hdf, s.pwf, s.osf, s.rnf,
       s.failure_mode_count, s.dq_flag
FROM stg_machine_data s
JOIN dim_product_variant d ON d.variant_code = s.product_variant;

CREATE INDEX idx_fact_production_variant ON fact_production (product_variant_id);

CREATE TABLE fact_failure_mode (
    uid              INTEGER  NOT NULL REFERENCES fact_production (uid),
    failure_mode_id  SMALLINT NOT NULL REFERENCES dim_failure_mode (failure_mode_id),
    PRIMARY KEY (uid, failure_mode_id)
);

INSERT INTO fact_failure_mode (uid, failure_mode_id)
SELECT f.uid, d.failure_mode_id
FROM (
    SELECT uid, 'TWF' AS mode_code FROM fact_production WHERE twf = 1
    UNION ALL SELECT uid, 'HDF' FROM fact_production WHERE hdf = 1
    UNION ALL SELECT uid, 'PWF' FROM fact_production WHERE pwf = 1
    UNION ALL SELECT uid, 'OSF' FROM fact_production WHERE osf = 1
    UNION ALL SELECT uid, 'RNF' FROM fact_production WHERE rnf = 1
) f
JOIN dim_failure_mode d ON d.failure_mode_code = f.mode_code;

-- ---------------------------------------------------------------------
-- Betriebszustände in Kategorien einteilen (zentrale Business-Logik).
-- Die Präfixe 1:, 2:, ... sorgen für eine sinnvolle Sortierung im BI-Tool.
-- Grenzwerte sind explorativ gewählt; Wear-Schwellen stammen aus dem Plan.
-- ---------------------------------------------------------------------
CREATE VIEW v_production_banded AS
SELECT
    f.*,
    v.variant_code AS product_variant,
    CASE WHEN tool_wear_min >= 200 THEN '3: High (>=200 min)'
         WHEN tool_wear_min >= 150 THEN '2: Medium (150-199 min)'
         ELSE                           '1: Low (<150 min)' END AS wear_band,
    CASE WHEN torque_nm <  30 THEN '1: <30 Nm'
         WHEN torque_nm <  40 THEN '2: 30-39.9 Nm'
         WHEN torque_nm <  50 THEN '3: 40-49.9 Nm'
         WHEN torque_nm <  60 THEN '4: 50-59.9 Nm'
         ELSE                      '5: >=60 Nm' END AS torque_band,
    CASE WHEN rotational_speed_rpm < 1300 THEN '1: <1300 rpm'
         WHEN rotational_speed_rpm < 1400 THEN '2: 1300-1399 rpm'
         WHEN rotational_speed_rpm < 1500 THEN '3: 1400-1499 rpm'
         WHEN rotational_speed_rpm < 1700 THEN '4: 1500-1699 rpm'
         WHEN rotational_speed_rpm < 1900 THEN '5: 1700-1899 rpm'
         ELSE                                  '6: >=1900 rpm' END AS speed_band,
    CASE WHEN temp_diff_k <  8.6 THEN '1: <8.6 K'
         WHEN temp_diff_k <  9.5 THEN '2: 8.6-9.4 K'
         WHEN temp_diff_k < 10.5 THEN '3: 9.5-10.4 K'
         WHEN temp_diff_k < 11.5 THEN '4: 10.5-11.4 K'
         ELSE                         '5: >=11.5 K' END AS temp_diff_band,
    CASE WHEN power_w < 3500 THEN '1: <3500 W'
         WHEN power_w > 9000 THEN '3: >9000 W'
         ELSE                     '2: 3500-9000 W' END AS power_band
FROM fact_production f
JOIN dim_product_variant v ON v.product_variant_id = f.product_variant_id;
