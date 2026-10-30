-- =====================================================================
-- Healthcare Analytics Lab - ETL: load healthcare_dw from healthcare_oltp
-- Run after star_schema.sql (tables must exist).
--
-- Full refresh: empties every warehouse table and reloads it, so the
-- script is rerunnable. The production incremental approach is described
-- in etl_design.txt.
--
-- Load order (parents before children, so every FK lookup succeeds):
--   1. dim_date   2. other dimensions   3. fact_encounters   4. bridges
-- =====================================================================

USE healthcare_dw;

-- Inserting 0 into an AUTO_INCREMENT column normally generates a new
-- value. This mode keeps 0, so the "Unknown" members really get key 0.
SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'NO_AUTO_VALUE_ON_ZERO');

-- dim_date needs 4,018 recursion steps (default limit is 1,000).
SET SESSION cte_max_recursion_depth = 5000;

-- ---------------------------------------------------------------------
-- 0. Empty the warehouse (children first). FK checks are switched off
--    only for the TRUNCATEs, which InnoDB otherwise refuses on parents.
-- ---------------------------------------------------------------------
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE bridge_encounter_procedures;
TRUNCATE TABLE bridge_encounter_diagnoses;
TRUNCATE TABLE fact_encounters;
TRUNCATE TABLE dim_procedure;
TRUNCATE TABLE dim_diagnosis;
TRUNCATE TABLE dim_encounter_type;
TRUNCATE TABLE dim_department;
TRUNCATE TABLE dim_specialty;
TRUNCATE TABLE dim_provider;
TRUNCATE TABLE dim_patient;
TRUNCATE TABLE dim_date;
SET FOREIGN_KEY_CHECKS = 1;


-- ---------------------------------------------------------------------
-- 1. dim_date: one row per day 2020-01-01 .. 2030-12-31, plus key 0.
--    Generated, not extracted: the calendar does not come from a source.
-- ---------------------------------------------------------------------
INSERT INTO dim_date (date_key) VALUES (0);

INSERT INTO dim_date
SELECT
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED),
    d,
    YEAR(d),
    QUARTER(d),
    MONTH(d),
    MONTHNAME(d),
    DATE_FORMAT(d, '%Y-%m'),
    DAYOFMONTH(d),
    WEEKDAY(d) + 1,                    -- 1 = Monday ... 7 = Sunday
    DAYNAME(d),
    WEEKDAY(d) >= 5,
    WEEK(d, 3)                         -- ISO week number
FROM (
    WITH RECURSIVE days (d) AS (
        SELECT DATE '2020-01-01'
        UNION ALL
        SELECT d + INTERVAL 1 DAY FROM days WHERE d < '2030-12-31'
    )
    SELECT d FROM days
) cal;


-- ---------------------------------------------------------------------
-- 2. Other dimensions: key 0 "Unknown" row, then one row per source row.
--    Derived columns (age_group, ICD chapter, CPT category...) are
--    computed here once, not in every report.
-- ---------------------------------------------------------------------

-- dim_patient
INSERT INTO dim_patient (patient_key, patient_id, first_name, last_name, age_group)
VALUES (0, 0, 'Unknown', 'Unknown', 'Unknown');

INSERT INTO dim_patient (patient_id, mrn, first_name, last_name, date_of_birth, gender, age_group)
SELECT
    p.patient_id,
    p.mrn,
    p.first_name,
    p.last_name,
    p.date_of_birth,
    p.gender,
    CASE
        WHEN p.date_of_birth IS NULL THEN 'Unknown'
        WHEN a.age < 18 THEN '0-17'
        WHEN a.age < 35 THEN '18-34'
        WHEN a.age < 50 THEN '35-49'
        WHEN a.age < 65 THEN '50-64'
        WHEN a.age < 80 THEN '65-79'
        ELSE '80+'
    END
FROM healthcare_oltp.patients p
CROSS JOIN LATERAL (
    SELECT TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) AS age
) a;

-- dim_specialty
INSERT INTO dim_specialty (specialty_key, specialty_id, specialty_name, specialty_code)
VALUES (0, 0, 'Unknown', 'UNK');

INSERT INTO dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, specialty_name, specialty_code
FROM healthcare_oltp.specialties;

-- dim_department
INSERT INTO dim_department (department_key, department_id, department_name)
VALUES (0, 0, 'Unknown');

INSERT INTO dim_department (department_id, department_name, floor, capacity)
SELECT department_id, department_name, floor, capacity
FROM healthcare_oltp.departments;

-- dim_provider: specialty and department names copied in (denormalized)
INSERT INTO dim_provider (provider_key, provider_id, full_name, specialty_name, department_name)
VALUES (0, 0, 'Unknown', 'Unknown', 'Unknown');

INSERT INTO dim_provider
    (provider_id, full_name, first_name, last_name, credential, specialty_name, department_name)
SELECT
    p.provider_id,
    CONCAT(CASE WHEN p.credential IN ('MD', 'DO') THEN 'Dr. ' ELSE '' END,
           p.first_name, ' ', p.last_name,
           CASE WHEN p.credential IN ('MD', 'DO') THEN '' ELSE CONCAT(', ', p.credential) END),
    p.first_name,
    p.last_name,
    p.credential,
    COALESCE(s.specialty_name, 'Unknown'),
    COALESCE(d.department_name, 'Unknown')
FROM healthcare_oltp.providers p
LEFT JOIN healthcare_oltp.specialties s ON s.specialty_id  = p.specialty_id
LEFT JOIN healthcare_oltp.departments d ON d.department_id = p.department_id;

-- dim_encounter_type: the 3 known types get their attributes; any new
-- type found in the source is still loaded, with care_setting 'Other'.
INSERT INTO dim_encounter_type (encounter_type_key, encounter_type_name, is_inpatient, care_setting)
VALUES (0, 'Unknown', 0, 'Unknown');

INSERT INTO dim_encounter_type (encounter_type_name, is_inpatient, care_setting)
SELECT
    t.encounter_type,
    t.encounter_type = 'Inpatient',
    CASE t.encounter_type
        WHEN 'Outpatient' THEN 'Ambulatory'
        WHEN 'Inpatient'  THEN 'Acute'
        WHEN 'ER'         THEN 'Emergency'
        ELSE 'Other'
    END
FROM (SELECT DISTINCT encounter_type
      FROM healthcare_oltp.encounters
      WHERE encounter_type IS NOT NULL) t
ORDER BY FIELD(t.encounter_type, 'Outpatient', 'Inpatient', 'ER'), t.encounter_type;

-- dim_diagnosis: category = first 3 characters, chapter from the code letter
INSERT INTO dim_diagnosis (diagnosis_key, diagnosis_id, icd10_code, icd10_description, icd10_category, icd10_chapter)
VALUES (0, 0, 'UNK', 'Unknown', 'UNK', 'Unknown');

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description, icd10_category, icd10_chapter)
SELECT
    diagnosis_id,
    icd10_code,
    icd10_description,
    LEFT(icd10_code, 3),
    CASE
        WHEN LEFT(icd10_code, 1) IN ('A', 'B')       THEN 'Infectious diseases'
        WHEN LEFT(icd10_code, 1) = 'C'
          OR LEFT(icd10_code, 3) BETWEEN 'D00' AND 'D49' THEN 'Neoplasms'
        WHEN LEFT(icd10_code, 1) = 'D'               THEN 'Blood and immune system'
        WHEN LEFT(icd10_code, 1) = 'E'               THEN 'Endocrine and metabolic'
        WHEN LEFT(icd10_code, 1) = 'F'               THEN 'Mental and behavioral'
        WHEN LEFT(icd10_code, 1) = 'G'               THEN 'Nervous system'
        WHEN LEFT(icd10_code, 1) = 'H'               THEN 'Eye and ear'
        WHEN LEFT(icd10_code, 1) = 'I'               THEN 'Circulatory system'
        WHEN LEFT(icd10_code, 1) = 'J'               THEN 'Respiratory system'
        WHEN LEFT(icd10_code, 1) = 'K'               THEN 'Digestive system'
        WHEN LEFT(icd10_code, 1) = 'L'               THEN 'Skin'
        WHEN LEFT(icd10_code, 1) = 'M'               THEN 'Musculoskeletal system'
        WHEN LEFT(icd10_code, 1) = 'N'               THEN 'Genitourinary system'
        WHEN LEFT(icd10_code, 1) = 'O'               THEN 'Pregnancy and childbirth'
        WHEN LEFT(icd10_code, 1) = 'P'               THEN 'Perinatal conditions'
        WHEN LEFT(icd10_code, 1) = 'Q'               THEN 'Congenital conditions'
        WHEN LEFT(icd10_code, 1) = 'R'               THEN 'Symptoms and signs'
        WHEN LEFT(icd10_code, 1) IN ('S', 'T')       THEN 'Injury and poisoning'
        WHEN LEFT(icd10_code, 1) IN ('V', 'W', 'X', 'Y') THEN 'External causes'
        WHEN LEFT(icd10_code, 1) = 'Z'               THEN 'Health status and services'
        ELSE 'Other'
    END
FROM healthcare_oltp.diagnoses;

-- dim_procedure: category from the CPT code range
INSERT INTO dim_procedure (procedure_key, procedure_id, cpt_code, cpt_description, cpt_category)
VALUES (0, 0, 'UNK', 'Unknown', 'Unknown');

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description, cpt_category)
SELECT
    procedure_id,
    cpt_code,
    cpt_description,
    CASE
        WHEN cpt_code LIKE '992%'                  THEN 'Evaluation & Management'
        WHEN LEFT(cpt_code, 1) = '7'               THEN 'Radiology'
        WHEN LEFT(cpt_code, 1) = '8'               THEN 'Pathology & Lab'
        WHEN LEFT(cpt_code, 1) = '9'               THEN 'Medicine'
        WHEN LEFT(cpt_code, 1) BETWEEN '1' AND '6' THEN 'Surgery'
        ELSE 'Other'
    END
FROM healthcare_oltp.procedures;


-- ---------------------------------------------------------------------
-- 3. fact_encounters: one row per encounter.
--    - Dimension keys: LEFT JOIN on the natural ID, COALESCE(key, 0) so a
--      missing reference points to the Unknown member instead of dropping
--      the row.
--    - Counts and billing totals: pre-aggregated per encounter in derived
--      tables, then joined 1:1 (no row multiplication).
--    - Readmission flag: same rule as OLTP Q3, computed once here.
-- ---------------------------------------------------------------------
INSERT INTO fact_encounters (
    encounter_id,
    encounter_date_key, discharge_date_key, patient_key, provider_key,
    specialty_key, department_key, encounter_type_key, primary_diagnosis_key,
    diagnosis_count, procedure_count, claim_count,
    total_claim_amount, total_allowed_amount,
    length_of_stay_hours, length_of_stay_days, age_at_encounter,
    readmitted_within_30_days
)
SELECT
    e.encounter_id,
    COALESCE(dd_enc.date_key, 0),
    COALESCE(dd_dis.date_key, 0),
    COALESCE(dp.patient_key, 0),
    COALESCE(dpr.provider_key, 0),
    COALESCE(ds.specialty_key, 0),          -- provider's specialty at load time
    COALESCE(ddep.department_key, 0),
    COALESCE(det.encounter_type_key, 0),
    COALESCE(ddx.diagnosis_key, 0),
    COALESCE(dx.diagnosis_count, 0),
    COALESCE(px.procedure_count, 0),
    COALESCE(b.claim_count, 0),
    COALESCE(b.total_claim_amount, 0),
    COALESCE(b.total_allowed_amount, 0),
    ROUND(TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date) / 60, 2),
    DATEDIFF(e.discharge_date, e.encounter_date),
    TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date),
    CASE
        WHEN e.encounter_type = 'Inpatient'
         AND EXISTS (SELECT 1
                     FROM healthcare_oltp.encounters r
                     WHERE r.patient_id     = e.patient_id
                       AND r.encounter_date >  e.discharge_date
                       AND r.encounter_date <= e.discharge_date + INTERVAL 30 DAY)
        THEN 1 ELSE 0
    END
FROM healthcare_oltp.encounters e
LEFT JOIN healthcare_oltp.patients  p   ON p.patient_id   = e.patient_id
LEFT JOIN healthcare_oltp.providers pr  ON pr.provider_id = e.provider_id
-- dimension key lookups
LEFT JOIN dim_date           dd_enc ON dd_enc.calendar_date      = DATE(e.encounter_date)
LEFT JOIN dim_date           dd_dis ON dd_dis.calendar_date      = DATE(e.discharge_date)
LEFT JOIN dim_patient        dp     ON dp.patient_id             = e.patient_id
LEFT JOIN dim_provider       dpr    ON dpr.provider_id           = e.provider_id
LEFT JOIN dim_specialty      ds     ON ds.specialty_id           = pr.specialty_id
LEFT JOIN dim_department     ddep   ON ddep.department_id        = e.department_id
LEFT JOIN dim_encounter_type det    ON det.encounter_type_name   = e.encounter_type
-- pre-aggregated measures (one row per encounter each)
LEFT JOIN (
    SELECT encounter_id,
           COUNT(*) AS diagnosis_count,
           MIN(CASE WHEN diagnosis_sequence = 1 THEN diagnosis_id END) AS primary_diagnosis_id
    FROM healthcare_oltp.encounter_diagnoses
    GROUP BY encounter_id
) dx ON dx.encounter_id = e.encounter_id
LEFT JOIN dim_diagnosis ddx ON ddx.diagnosis_id = dx.primary_diagnosis_id
LEFT JOIN (
    SELECT encounter_id, COUNT(*) AS procedure_count
    FROM healthcare_oltp.encounter_procedures
    GROUP BY encounter_id
) px ON px.encounter_id = e.encounter_id
LEFT JOIN (
    SELECT encounter_id,
           COUNT(*)            AS claim_count,
           SUM(claim_amount)   AS total_claim_amount,
           SUM(allowed_amount) AS total_allowed_amount
    FROM healthcare_oltp.billing
    GROUP BY encounter_id
) b ON b.encounter_id = e.encounter_id
ORDER BY e.encounter_id;


-- ---------------------------------------------------------------------
-- 4. Bridges: translate natural IDs to surrogate keys.
--    GROUP BY removes any duplicate (encounter, code) pair in the source,
--    which the bridge primary key would otherwise reject.
-- ---------------------------------------------------------------------
INSERT INTO bridge_encounter_diagnoses (encounter_key, diagnosis_key, diagnosis_sequence, is_primary)
SELECT
    f.encounter_key,
    COALESCE(d.diagnosis_key, 0)  AS diagnosis_key,
    MIN(ed.diagnosis_sequence),
    MIN(ed.diagnosis_sequence) = 1
FROM healthcare_oltp.encounter_diagnoses ed
JOIN fact_encounters    f ON f.encounter_id = ed.encounter_id
LEFT JOIN dim_diagnosis d ON d.diagnosis_id = ed.diagnosis_id
GROUP BY f.encounter_key, diagnosis_key;

INSERT INTO bridge_encounter_procedures (encounter_key, procedure_key, procedure_date_key)
SELECT
    f.encounter_key,
    COALESCE(pr.procedure_key, 0) AS procedure_key,
    COALESCE(MIN(dd.date_key), 0)
FROM healthcare_oltp.encounter_procedures ep
JOIN fact_encounters    f  ON f.encounter_id   = ep.encounter_id
LEFT JOIN dim_procedure pr ON pr.procedure_id  = ep.procedure_id
LEFT JOIN dim_date      dd ON dd.calendar_date = ep.procedure_date
GROUP BY f.encounter_key, procedure_key;


-- ---------------------------------------------------------------------
-- 5. Refresh optimizer statistics (stale stats = bad query plans)
-- ---------------------------------------------------------------------
ANALYZE TABLE dim_date, dim_patient, dim_specialty, dim_department, dim_provider,
    dim_encounter_type, dim_diagnosis, dim_procedure, fact_encounters,
    bridge_encounter_diagnoses, bridge_encounter_procedures;


-- ---------------------------------------------------------------------
-- 6. Reconciliation: warehouse vs source. Every row should say OK.
-- ---------------------------------------------------------------------
SELECT check_name, source_value, dw_value,
       IF(source_value = dw_value, 'OK', 'MISMATCH') AS status
FROM (
SELECT 'encounters -> fact rows' AS check_name,
       (SELECT COUNT(*) FROM healthcare_oltp.encounters) AS source_value,
       (SELECT COUNT(*) FROM fact_encounters)            AS dw_value
UNION ALL
SELECT 'encounter_diagnoses -> bridge rows',
       (SELECT COUNT(*) FROM healthcare_oltp.encounter_diagnoses),
       (SELECT COUNT(*) FROM bridge_encounter_diagnoses)
UNION ALL
SELECT 'encounter_procedures -> bridge rows',
       (SELECT COUNT(*) FROM healthcare_oltp.encounter_procedures),
       (SELECT COUNT(*) FROM bridge_encounter_procedures)
UNION ALL
SELECT 'billing rows -> SUM(claim_count)',
       (SELECT COUNT(*) FROM healthcare_oltp.billing),
       (SELECT SUM(claim_count) FROM fact_encounters)
UNION ALL
SELECT 'SUM(allowed_amount)',
       (SELECT SUM(allowed_amount) FROM healthcare_oltp.billing),
       (SELECT SUM(total_allowed_amount) FROM fact_encounters)
UNION ALL
SELECT 'SUM(claim_amount)',
       (SELECT SUM(claim_amount) FROM healthcare_oltp.billing),
       (SELECT SUM(total_claim_amount) FROM fact_encounters)
UNION ALL
SELECT 'patients -> dim rows (excl. Unknown)',
       (SELECT COUNT(*) FROM healthcare_oltp.patients),
       (SELECT COUNT(*) FROM dim_patient WHERE patient_key <> 0)
UNION ALL
SELECT 'fact rows pointing to an Unknown member',
       0,
       (SELECT COUNT(*) FROM fact_encounters
        WHERE 0 IN (encounter_date_key, discharge_date_key, patient_key, provider_key,
                    specialty_key, department_key, encounter_type_key, primary_diagnosis_key))
) checks;
