-- =====================================================================
-- 01 SOURCE LAYER  |  raw_ai4i_data
-- Quelle: ai4i2020.csv (UCI "AI4I 2020 Predictive Maintenance Dataset")
-- Regel: Rohdaten unverändert laden. Keine Bereinigung, keine Business-Logik.
-- Alle Spalten bleiben TEXT mit den originalen CSV-Spaltennamen, damit jede
-- spätere Typumwandlung in der Staging-Schicht nachvollziehbar bleibt.
-- =====================================================================

DROP TABLE IF EXISTS raw_ai4i_data;

CREATE TABLE raw_ai4i_data (
    "UDI"                     TEXT,
    "Product ID"              TEXT,
    "Type"                    TEXT,
    "Air temperature [K]"     TEXT,
    "Process temperature [K]" TEXT,
    "Rotational speed [rpm]"  TEXT,
    "Torque [Nm]"             TEXT,
    "Tool wear [min]"         TEXT,
    "Machine failure"         TEXT,
    "TWF"                     TEXT,
    "HDF"                     TEXT,
    "PWF"                     TEXT,
    "OSF"                     TEXT,
    "RNF"                     TEXT
);

copy raw_ai4i_data FROM 'C:\Users\ADMIN\Desktop\SQL Projekt\ai4i2020.csv' WITH (FORMAT csv, HEADER true);

-- Dokumentation des Imports: erwartet 10.000 Zeilen
SELECT COUNT(*) AS imported_rows FROM raw_ai4i_data;
