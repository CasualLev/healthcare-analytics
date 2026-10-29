USE healthcare_oltp;

-- Q1: Monthly encounters by specialty
SELECT
    DATE_FORMAT(e.encounter_date, '%Y-%m') AS encounter_month,
    s.specialty_name,
    e.encounter_type,
    COUNT(*)                     AS total_encounters,
    COUNT(DISTINCT e.patient_id) AS unique_patients
FROM encounters e
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY encounter_month, s.specialty_name, e.encounter_type
ORDER BY encounter_month, s.specialty_name, e.encounter_type;

-- Q2: Top diagnosis-procedure pairs
SELECT
    d.icd10_code,
    d.icd10_description,
    pr.cpt_code,
    pr.cpt_description,
    COUNT(DISTINCT ed.encounter_id) AS encounter_count
FROM encounter_diagnoses ed
JOIN encounter_procedures ep ON ep.encounter_id = ed.encounter_id
JOIN diagnoses  d  ON d.diagnosis_id  = ed.diagnosis_id
JOIN procedures pr ON pr.procedure_id = ep.procedure_id
GROUP BY d.icd10_code, d.icd10_description, pr.cpt_code, pr.cpt_description
ORDER BY encounter_count DESC
LIMIT 10;

-- Q3: 30-day readmission rate by specialty
SELECT
    s.specialty_name,
    COUNT(DISTINCT i.encounter_id) AS inpatient_discharges,
    COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL THEN i.encounter_id END) AS readmissions,
    ROUND(100 * COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL THEN i.encounter_id END)
              / COUNT(DISTINCT i.encounter_id), 2) AS readmission_rate_pct
FROM encounters i
JOIN providers   p ON p.provider_id  = i.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
LEFT JOIN encounters r
       ON r.patient_id     = i.patient_id
      AND r.encounter_date >  i.discharge_date
      AND r.encounter_date <= i.discharge_date + INTERVAL 30 DAY
WHERE i.encounter_type = 'Inpatient'
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC;

-- Q4: Revenue by specialty and month
SELECT
    DATE_FORMAT(e.encounter_date, '%Y-%m') AS service_month,
    s.specialty_name,
    SUM(b.allowed_amount) AS total_allowed,
    SUM(b.claim_amount)   AS total_claimed,
    COUNT(*)              AS claims
FROM billing b
JOIN encounters  e ON e.encounter_id = b.encounter_id
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY service_month, s.specialty_name
ORDER BY service_month, total_allowed DESC;