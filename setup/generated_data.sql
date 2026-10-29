-- Generates a realistic volume of data on top of the sample data.
-- Run after 01_oltp_schema.sql and 02_oltp_sample_data.sql.
-- Deterministic: CRC32 of a fixed string replaces RAND(), so every run
-- produces exactly the same rows. To start over, rerun 01 and 02 first.

USE healthcare_oltp;

-- ---------------------------------------------------------------
-- Helper: a numbers table 1..200,000 used to generate rows
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS gen_digits;
DROP TABLE IF EXISTS gen_seq;
CREATE TABLE gen_digits (d INT PRIMARY KEY);
INSERT INTO gen_digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

CREATE TABLE gen_seq (n INT PRIMARY KEY);
INSERT INTO gen_seq (n)
SELECT 1 + a.d + b.d*10 + c.d*100 + d.d*1000 + e.d*10000 + f.d*100000 AS n
FROM gen_digits a, gen_digits b, gen_digits c, gen_digits d, gen_digits e, gen_digits f
HAVING n <= 200000;

-- ---------------------------------------------------------------
-- Reference data: 10 specialties, 10 departments
-- ---------------------------------------------------------------
INSERT INTO specialties VALUES
    (4, 'Neurology', 'NEURO'),
    (5, 'Orthopedics', 'ORTHO'),
    (6, 'Pulmonology', 'PULM'),
    (7, 'Oncology', 'ONC'),
    (8, 'Gastroenterology', 'GI'),
    (9, 'General Surgery', 'GSURG'),
    (10, 'Pediatrics', 'PEDS');

INSERT INTO departments VALUES
    (4, 'Neurology', 4, 25),
    (5, 'Orthopedics', 4, 30),
    (6, 'Pulmonology', 3, 20),
    (7, 'Oncology Center', 5, 35),
    (8, 'Gastroenterology', 2, 20),
    (9, 'Surgical Unit', 5, 40),
    (10, 'Pediatrics', 1, 30);

-- ---------------------------------------------------------------
-- Diagnoses (ICD-10) and procedures (CPT)
-- ---------------------------------------------------------------
INSERT INTO diagnoses VALUES
    (3004, 'E78.5', 'Hyperlipidemia'),
    (3005, 'I25.10', 'Coronary artery disease'),
    (3006, 'I48.91', 'Atrial fibrillation'),
    (3007, 'J44.9', 'COPD'),
    (3008, 'J18.9', 'Pneumonia'),
    (3009, 'N18.9', 'Chronic kidney disease'),
    (3010, 'J45.909', 'Asthma'),
    (3011, 'R07.9', 'Chest pain'),
    (3012, 'M54.50', 'Low back pain'),
    (3013, 'K21.9', 'GERD'),
    (3014, 'F32.9', 'Major depressive disorder'),
    (3015, 'F41.1', 'Generalized anxiety disorder'),
    (3016, 'E66.9', 'Obesity'),
    (3017, 'D64.9', 'Anemia'),
    (3018, 'E03.9', 'Hypothyroidism'),
    (3019, 'N39.0', 'Urinary tract infection'),
    (3020, 'J06.9', 'Upper respiratory infection'),
    (3021, 'R10.9', 'Abdominal pain'),
    (3022, 'R51.9', 'Headache'),
    (3023, 'M17.11', 'Osteoarthritis, right knee'),
    (3024, 'I21.9', 'Acute myocardial infarction'),
    (3025, 'I63.9', 'Cerebral infarction'),
    (3026, 'A41.9', 'Sepsis'),
    (3027, 'G43.909', 'Migraine'),
    (3028, 'G40.909', 'Epilepsy'),
    (3029, 'R55', 'Syncope'),
    (3030, 'K35.80', 'Acute appendicitis'),
    (3031, 'K80.20', 'Gallstones'),
    (3032, 'S72.001A', 'Hip fracture'),
    (3033, 'S06.0X0A', 'Concussion'),
    (3034, 'C34.90', 'Lung cancer'),
    (3035, 'C50.919', 'Breast cancer'),
    (3036, 'I95.9', 'Hypotension'),
    (3037, 'T78.40XA', 'Allergic reaction'),
    (3038, 'Z00.00', 'General adult exam');

INSERT INTO procedures VALUES
    (4004, '99214', 'Office visit, moderate'),
    (4005, '99203', 'Office visit, new patient'),
    (4006, '85025', 'Complete blood count'),
    (4007, '80053', 'Comprehensive metabolic panel'),
    (4008, '36415', 'Venipuncture'),
    (4009, '83036', 'Hemoglobin A1c'),
    (4010, '99284', 'ER visit, moderate'),
    (4011, '99285', 'ER visit, high'),
    (4012, '99223', 'Initial hospital care'),
    (4013, '99238', 'Hospital discharge'),
    (4014, '93306', 'Echocardiogram'),
    (4015, '70450', 'CT head'),
    (4016, '74177', 'CT abdomen and pelvis'),
    (4017, '72148', 'MRI lumbar spine'),
    (4018, '94010', 'Spirometry'),
    (4019, '93015', 'Cardiac stress test'),
    (4020, '90471', 'Immunization'),
    (4021, '99215', 'Office visit, high'),
    (4022, '93458', 'Cardiac catheterization'),
    (4023, '43239', 'Upper GI endoscopy'),
    (4024, '45378', 'Colonoscopy'),
    (4025, '95816', 'EEG'),
    (4026, '96413', 'Chemotherapy infusion'),
    (4027, '44970', 'Laparoscopic appendectomy'),
    (4028, '47562', 'Laparoscopic cholecystectomy'),
    (4029, '27447', 'Total knee replacement');

-- ---------------------------------------------------------------
-- 200 providers (ids 104-303), each working in their specialty's department
-- ---------------------------------------------------------------
INSERT INTO providers
SELECT
    103 + n,
    ELT(1 + CRC32(CONCAT('pf', n)) % 12, 'David','Maria','Ahmed','Grace','Peter','Aisha',
        'Daniel','Linda','Kevin','Fatima','Samuel','Emily'),
    ELT(1 + CRC32(CONCAT('pl', n)) % 12, 'Mugisha','Patel','Nguyen','Garcia','Okafor','Kim',
        'Brown','Uwase','Martin','Ali','Kowalski','Haddad'),
    ELT(1 + CRC32(CONCAT('pc', n)) % 10, 'MD','MD','MD','MD','MD','MD','DO','DO','NP','PA'),
    1 + CRC32(CONCAT('ps', n)) % 10,
    1 + CRC32(CONCAT('ps', n)) % 10
FROM gen_seq
WHERE n <= 200;

-- ---------------------------------------------------------------
-- 50,000 patients (ids 100001-150000)
-- ---------------------------------------------------------------
INSERT INTO patients
SELECT
    100000 + n,
    ELT(1 + CRC32(CONCAT('xf', n)) % 16, 'Jean','Alice','Eric','Claire','Moses','Diane','Paul','Ruth',
        'Brian','Nadia','Oscar','Esther','Felix','Hannah','Ivan','Joy'),
    ELT(1 + CRC32(CONCAT('xl', n)) % 16, 'Habimana','Ingabire','Smith','Lopez','Chen','Okoro','Muller',
        'Rossi','Silva','Ndayisaba','Johnson','Ivanova','Tanaka','Mensah','Dubois','Ahmed'),
    DATE_ADD('1935-01-01', INTERVAL CRC32(CONCAT('xd', n)) % 32000 DAY),
    ELT(1 + CRC32(CONCAT('xg', n)) % 2, 'M', 'F'),
    CONCAT('MRN', LPAD(100000 + n, 7, '0'))
FROM gen_seq
WHERE n <= 50000;

-- ---------------------------------------------------------------
-- 200,000 encounters (ids 1000001-1200000) over 2023-2024
-- Emergency providers see ER visits; others ~80% outpatient, ~20% inpatient.
-- ---------------------------------------------------------------
INSERT INTO encounters
SELECT
    e.encounter_id,
    e.patient_id,
    e.provider_id,
    e.encounter_type,
    e.encounter_date,
    CASE e.encounter_type
        WHEN 'Outpatient' THEN DATE_ADD(e.encounter_date, INTERVAL 30 + CRC32(CONCAT('eo', e.n)) % 91 MINUTE)
        WHEN 'ER'         THEN DATE_ADD(e.encounter_date, INTERVAL 120 + CRC32(CONCAT('eo', e.n)) % 600 MINUTE)
        ELSE                   DATE_ADD(e.encounter_date, INTERVAL 24 + CRC32(CONCAT('eo', e.n)) % 217 HOUR)
    END,
    e.department_id
FROM (
    SELECT
        s.n,
        1000000 + s.n AS encounter_id,
        100001 + CRC32(CONCAT('ep', s.n)) % 50000 AS patient_id,
        p.provider_id,
        p.department_id,
        CASE
            WHEN p.specialty_id = 3 THEN 'ER'
            WHEN CRC32(CONCAT('et', s.n)) % 100 < 80 THEN 'Outpatient'
            ELSE 'Inpatient'
        END AS encounter_type,
        DATE_ADD('2023-01-01 00:00:00', INTERVAL CRC32(CONCAT('ed', s.n)) % (731 * 1440) MINUTE) AS encounter_date
    FROM gen_seq s
    JOIN providers p ON p.provider_id = 104 + CRC32(CONCAT('epr', s.n)) % 200
) e;

-- ---------------------------------------------------------------
-- Diagnoses: 1-4 distinct per encounter, skewed so some are far more common
-- ---------------------------------------------------------------
INSERT INTO encounter_diagnoses
SELECT
    e.encounter_id * 10 + k.n,
    e.encounter_id,
    3001 + (FLOOR(38 * POW((CRC32(CONCAT('dx', e.encounter_id)) % 10000) / 10000, 2)) + 7 * (k.n - 1)) % 38,
    k.n
FROM encounters e
JOIN gen_seq k ON k.n <= 1 + CRC32(CONCAT('nd', e.encounter_id)) % 4
WHERE e.encounter_id > 1000000;

-- ---------------------------------------------------------------
-- Procedures: 0-3 distinct per encounter, dated within the stay
-- ---------------------------------------------------------------
INSERT INTO encounter_procedures
SELECT
    e.encounter_id * 10 + k.n,
    e.encounter_id,
    4001 + (FLOOR(29 * POW((CRC32(CONCAT('px', e.encounter_id)) % 10000) / 10000, 2)) + 5 * (k.n - 1)) % 29,
    DATE(DATE_ADD(e.encounter_date, INTERVAL CRC32(CONCAT('pd', e.encounter_id, k.n))
        % (DATEDIFF(e.discharge_date, e.encounter_date) + 1) DAY))
FROM encounters e
JOIN gen_seq k ON k.n <= CRC32(CONCAT('np', e.encounter_id)) % 4
WHERE e.encounter_id > 1000000;

-- ---------------------------------------------------------------
-- Billing: ~95% of encounters billed; amounts depend on encounter type
-- ---------------------------------------------------------------
INSERT INTO billing
SELECT
    b.encounter_id + 1000000,
    b.encounter_id,
    b.claim_amount,
    CASE b.claim_status
        WHEN 'Denied' THEN 0
        ELSE ROUND(b.claim_amount * (60 + CRC32(CONCAT('ba', b.encounter_id)) % 31) / 100, 2)
    END,
    b.claim_date,
    b.claim_status
FROM (
    SELECT
        e.encounter_id,
        CASE e.encounter_type
            WHEN 'Outpatient' THEN 150 + CRC32(CONCAT('bc', e.encounter_id)) % 651
            WHEN 'ER'         THEN 800 + CRC32(CONCAT('bc', e.encounter_id)) % 4201
            ELSE                   5000 + CRC32(CONCAT('bc', e.encounter_id)) % 35001
        END AS claim_amount,
        DATE_ADD(DATE(e.discharge_date), INTERVAL 1 + CRC32(CONCAT('bd', e.encounter_id)) % 10 DAY) AS claim_date,
        ELT(1 + CRC32(CONCAT('bs', e.encounter_id)) % 10,
            'Paid','Paid','Paid','Paid','Paid','Paid','Paid','Paid','Denied','Pending') AS claim_status
    FROM encounters e
    WHERE e.encounter_id > 1000000
      AND CRC32(CONCAT('bx', e.encounter_id)) % 100 < 95
) b;

-- ---------------------------------------------------------------
-- Clean up helpers and refresh optimizer statistics
-- ---------------------------------------------------------------
DROP TABLE gen_seq;
DROP TABLE gen_digits;

ANALYZE TABLE patients, specialties, departments, providers, encounters,
    diagnoses, encounter_diagnoses, procedures, encounter_procedures, billing;

SELECT 'patients' AS table_name, COUNT(*) AS row_count FROM patients
UNION ALL SELECT 'providers', COUNT(*) FROM providers
UNION ALL SELECT 'encounters', COUNT(*) FROM encounters
UNION ALL SELECT 'encounter_diagnoses', COUNT(*) FROM encounter_diagnoses
UNION ALL SELECT 'encounter_procedures', COUNT(*) FROM encounter_procedures
UNION ALL SELECT 'billing', COUNT(*) FROM billing;