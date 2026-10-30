USE healthcare_dw;

-- Q1: Monthly encounters by specialty
SELECT
    m.encounter_month,
    s.specialty_name,
    t.encounter_type_name AS encounter_type,
    m.total_encounters,
    m.unique_patients
FROM (
    SELECT d.year_month_label           AS encounter_month,
           f.specialty_key,
           f.encounter_type_key,
           COUNT(*)                     AS total_encounters,
           COUNT(DISTINCT f.patient_key) AS unique_patients
    FROM dim_date d
    JOIN fact_encounters f ON f.encounter_date_key = d.date_key
    GROUP BY d.year_month_label, f.specialty_key, f.encounter_type_key
) m
JOIN dim_specialty      s ON s.specialty_key      = m.specialty_key
JOIN dim_encounter_type t ON t.encounter_type_key = m.encounter_type_key
ORDER BY m.encounter_month, s.specialty_name, encounter_type;

-- Q2: Top diagnosis-procedure pairs
SELECT
    dx.icd10_code,
    dx.icd10_description,
    px.cpt_code,
    px.cpt_description,
    pairs.encounter_count
FROM (
    SELECT bd.diagnosis_key, bp.procedure_key, COUNT(*) AS encounter_count
    FROM bridge_encounter_diagnoses  bd
    JOIN bridge_encounter_procedures bp ON bp.encounter_key = bd.encounter_key
    GROUP BY bd.diagnosis_key, bp.procedure_key
    ORDER BY encounter_count DESC
    LIMIT 10
) pairs
JOIN dim_diagnosis dx ON dx.diagnosis_key = pairs.diagnosis_key
JOIN dim_procedure px ON px.procedure_key = pairs.procedure_key
ORDER BY pairs.encounter_count DESC;

-- Q3: 30-day readmission rate by specialty
SELECT
    s.specialty_name,
    COUNT(*)                         AS inpatient_discharges,
    SUM(f.readmitted_within_30_days) AS readmissions,
    ROUND(100 * SUM(f.readmitted_within_30_days) / COUNT(*), 2) AS readmission_rate_pct
FROM fact_encounters f
JOIN dim_specialty      s ON s.specialty_key      = f.specialty_key
JOIN dim_encounter_type t ON t.encounter_type_key = f.encounter_type_key
WHERE t.is_inpatient = 1
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC;

-- Q4: Revenue by specialty and month
SELECT
    d.year_month_label     AS service_month,
    s.specialty_name,
    SUM(daily.allowed)     AS total_allowed,
    SUM(daily.claimed)     AS total_claimed,
    SUM(daily.claims)      AS claims
FROM (
    SELECT encounter_date_key, specialty_key,
           SUM(total_allowed_amount) AS allowed,
           SUM(total_claim_amount)   AS claimed,
           SUM(claim_count)          AS claims
    FROM fact_encounters
    WHERE claim_count > 0
    GROUP BY encounter_date_key, specialty_key
) daily
JOIN dim_date      d ON d.date_key      = daily.encounter_date_key
JOIN dim_specialty s ON s.specialty_key = daily.specialty_key
GROUP BY d.year_month_label, s.specialty_name
ORDER BY service_month, total_allowed DESC;
