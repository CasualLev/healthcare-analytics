-- =====================================================================
-- Healthcare Analytics Lab - Part 3.2: Star Schema DDL
-- Database: healthcare_dw (analytics), loaded from healthcare_oltp (source)
--
-- Design summary (see design_decisions.txt):
--   Grain: fact_encounters has one row per encounter.
--   8 dimensions with surrogate keys; key 0 = "Unknown" member (inserted by the ETL).
--   2 bridge tables for the many-to-many diagnosis and procedure details.
--
-- Rerunnable: drops and recreates every table (children before parents).
-- =====================================================================

CREATE DATABASE IF NOT EXISTS healthcare_dw;
USE healthcare_dw;

DROP TABLE IF EXISTS bridge_encounter_procedures;
DROP TABLE IF EXISTS bridge_encounter_diagnoses;
DROP TABLE IF EXISTS fact_encounters;
DROP TABLE IF EXISTS dim_procedure;
DROP TABLE IF EXISTS dim_diagnosis;
DROP TABLE IF EXISTS dim_encounter_type;
DROP TABLE IF EXISTS dim_department;
DROP TABLE IF EXISTS dim_specialty;
DROP TABLE IF EXISTS dim_provider;
DROP TABLE IF EXISTS dim_patient;
DROP TABLE IF EXISTS dim_date;


-- ---------------------------------------------------------------------
-- dim_date: one row per calendar day (2020-2030), plus key 0 = Unknown.
-- Pre-computed calendar attributes replace per-row date functions
-- (e.g. year_month_label replaces DATE_FORMAT(encounter_date, '%Y-%m')).
-- Role-playing dimension: referenced as encounter date, discharge date
-- and procedure date.
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INT          NOT NULL COMMENT 'YYYYMMDD smart key, e.g. 20240510; 0 = Unknown',
    calendar_date   DATE         NULL,
    year            SMALLINT     NULL,
    quarter         TINYINT      NULL,
    month           TINYINT      NULL,
    month_name      VARCHAR(10)  NULL,
    year_month_label CHAR(7)     NULL COMMENT 'YYYY-MM, ready for monthly grouping',
    day_of_month    TINYINT      NULL,
    day_of_week     TINYINT      NULL COMMENT '1 = Monday ... 7 = Sunday',
    day_name        VARCHAR(10)  NULL,
    is_weekend      TINYINT(1)   NULL,
    week_of_year    TINYINT      NULL,
    PRIMARY KEY (date_key),
    UNIQUE KEY uq_dim_date_calendar_date (calendar_date),
    KEY idx_dim_date_year_month (year_month_label)
) COMMENT = 'Calendar dimension: one row per day';


-- ---------------------------------------------------------------------
-- dim_patient: one row per patient (Type 1: overwritten on change).
-- age_group is the CURRENT age group; age at the time of care is on
-- fact_encounters.age_at_encounter.
-- ---------------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key     INT          NOT NULL AUTO_INCREMENT,
    patient_id      INT          NOT NULL COMMENT 'Natural key from healthcare_oltp.patients',
    mrn             VARCHAR(20)  NULL,
    first_name      VARCHAR(100) NULL,
    last_name       VARCHAR(100) NULL,
    date_of_birth   DATE         NULL,
    gender          CHAR(1)      NULL,
    age_group       VARCHAR(10)  NULL COMMENT '0-17, 18-34, 35-49, 50-64, 65-79, 80+',
    PRIMARY KEY (patient_key),
    UNIQUE KEY uq_dim_patient_patient_id (patient_id)
) COMMENT = 'Patient dimension: demographics (contains PHI)';


-- ---------------------------------------------------------------------
-- dim_specialty: one row per specialty. Referenced directly by the fact
-- table so specialty is one join away (it was two in the OLTP schema).
-- ---------------------------------------------------------------------
CREATE TABLE dim_specialty (
    specialty_key   INT          NOT NULL AUTO_INCREMENT,
    specialty_id    INT          NOT NULL COMMENT 'Natural key from healthcare_oltp.specialties',
    specialty_name  VARCHAR(100) NULL,
    specialty_code  VARCHAR(10)  NULL,
    PRIMARY KEY (specialty_key),
    UNIQUE KEY uq_dim_specialty_specialty_id (specialty_id)
) COMMENT = 'Specialty dimension';


-- ---------------------------------------------------------------------
-- dim_department: one row per hospital department.
-- ---------------------------------------------------------------------
CREATE TABLE dim_department (
    department_key  INT          NOT NULL AUTO_INCREMENT,
    department_id   INT          NOT NULL COMMENT 'Natural key from healthcare_oltp.departments',
    department_name VARCHAR(100) NULL,
    floor           INT          NULL,
    capacity        INT          NULL,
    PRIMARY KEY (department_key),
    UNIQUE KEY uq_dim_department_department_id (department_id)
) COMMENT = 'Department dimension';


-- ---------------------------------------------------------------------
-- dim_provider: one row per provider. Specialty and department names are
-- copied in (denormalized) so provider-level reports need no extra joins.
-- ---------------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key    INT          NOT NULL AUTO_INCREMENT,
    provider_id     INT          NOT NULL COMMENT 'Natural key from healthcare_oltp.providers',
    full_name       VARCHAR(220) NULL COMMENT 'e.g. Dr. James Chen',
    first_name      VARCHAR(100) NULL,
    last_name       VARCHAR(100) NULL,
    credential      VARCHAR(20)  NULL,
    specialty_name  VARCHAR(100) NULL COMMENT 'Denormalized from specialties',
    department_name VARCHAR(100) NULL COMMENT 'Denormalized from departments',
    PRIMARY KEY (provider_key),
    UNIQUE KEY uq_dim_provider_provider_id (provider_id)
) COMMENT = 'Provider dimension';


-- ---------------------------------------------------------------------
-- dim_encounter_type: Outpatient / Inpatient / ER, with type-level flags.
-- ---------------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  INT         NOT NULL AUTO_INCREMENT,
    encounter_type_name VARCHAR(50) NOT NULL,
    is_inpatient        TINYINT(1)  NOT NULL DEFAULT 0,
    care_setting        VARCHAR(20) NULL COMMENT 'Ambulatory, Acute, Emergency',
    PRIMARY KEY (encounter_type_key),
    UNIQUE KEY uq_dim_encounter_type_name (encounter_type_name)
) COMMENT = 'Encounter type dimension';


-- ---------------------------------------------------------------------
-- dim_diagnosis: one row per ICD-10 code, with grouping levels.
-- ---------------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key     INT          NOT NULL AUTO_INCREMENT,
    diagnosis_id      INT          NOT NULL COMMENT 'Natural key from healthcare_oltp.diagnoses',
    icd10_code        VARCHAR(10)  NULL,
    icd10_description VARCHAR(200) NULL,
    icd10_category    VARCHAR(3)   NULL COMMENT 'First 3 characters, e.g. I50',
    icd10_chapter     VARCHAR(100) NULL COMMENT 'Body system, e.g. Circulatory system',
    PRIMARY KEY (diagnosis_key),
    UNIQUE KEY uq_dim_diagnosis_diagnosis_id (diagnosis_id)
) COMMENT = 'Diagnosis (ICD-10) dimension';


-- ---------------------------------------------------------------------
-- dim_procedure: one row per CPT code, with a category from the code range.
-- ---------------------------------------------------------------------
CREATE TABLE dim_procedure (
    procedure_key   INT          NOT NULL AUTO_INCREMENT,
    procedure_id    INT          NOT NULL COMMENT 'Natural key from healthcare_oltp.procedures',
    cpt_code        VARCHAR(10)  NULL,
    cpt_description VARCHAR(200) NULL,
    cpt_category    VARCHAR(50)  NULL COMMENT 'Evaluation & Management, Radiology, Pathology & Lab, Medicine, Surgery',
    PRIMARY KEY (procedure_key),
    UNIQUE KEY uq_dim_procedure_procedure_id (procedure_id)
) COMMENT = 'Procedure (CPT) dimension';


-- ---------------------------------------------------------------------
-- fact_encounters: one row per encounter.
-- Dimension keys point to key 0 (Unknown) instead of NULL when a source
-- reference is missing, so inner joins never drop facts.
-- Measures are pre-computed by the ETL so queries avoid joins to billing,
-- the junction tables, and the readmission self-join.
-- ---------------------------------------------------------------------
CREATE TABLE fact_encounters (
    encounter_key             INT           NOT NULL AUTO_INCREMENT,
    encounter_id              INT           NOT NULL COMMENT 'Degenerate dimension: source encounter ID',

    -- Dimension foreign keys
    encounter_date_key        INT           NOT NULL DEFAULT 0,
    discharge_date_key        INT           NOT NULL DEFAULT 0,
    patient_key               INT           NOT NULL DEFAULT 0,
    provider_key              INT           NOT NULL DEFAULT 0,
    specialty_key             INT           NOT NULL DEFAULT 0 COMMENT 'Provider specialty at time of encounter',
    department_key            INT           NOT NULL DEFAULT 0,
    encounter_type_key        INT           NOT NULL DEFAULT 0,
    primary_diagnosis_key     INT           NOT NULL DEFAULT 0 COMMENT 'Diagnosis with sequence 1',

    -- Pre-aggregated / pre-computed measures
    diagnosis_count           SMALLINT      NOT NULL DEFAULT 0,
    procedure_count           SMALLINT      NOT NULL DEFAULT 0,
    claim_count               SMALLINT      NOT NULL DEFAULT 0 COMMENT '0 = not billed yet',
    total_claim_amount        DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    total_allowed_amount      DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    length_of_stay_hours      DECIMAL(8,2)  NULL,
    length_of_stay_days       SMALLINT      NULL,
    age_at_encounter          SMALLINT      NULL,
    readmitted_within_30_days TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '1 = inpatient stay followed by any encounter within 30 days of discharge',

    -- Audit
    etl_loaded_at             DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (encounter_key),
    UNIQUE KEY uq_fact_encounters_encounter_id (encounter_id),

    -- Q1 (and Q4): month x specialty x type. Covering for Q1: the whole
    -- query can be answered from this index without reading table rows.
    KEY idx_fact_date_specialty_type (encounter_date_key, specialty_key, encounter_type_key, patient_key),

    -- Q3: readmission rate by specialty for inpatient stays. Covering.
    KEY idx_fact_specialty_type_readmit (specialty_key, encounter_type_key, readmitted_within_30_days),

    -- Remaining foreign keys (InnoDB needs an index on every FK column;
    -- encounter_date_key and specialty_key are already covered above).
    KEY idx_fact_discharge_date (discharge_date_key),
    KEY idx_fact_patient (patient_key),
    KEY idx_fact_provider (provider_key),
    KEY idx_fact_department (department_key),
    KEY idx_fact_encounter_type (encounter_type_key),
    KEY idx_fact_primary_diagnosis (primary_diagnosis_key),

    CONSTRAINT fk_fact_encounter_date  FOREIGN KEY (encounter_date_key)    REFERENCES dim_date (date_key),
    CONSTRAINT fk_fact_discharge_date  FOREIGN KEY (discharge_date_key)    REFERENCES dim_date (date_key),
    CONSTRAINT fk_fact_patient         FOREIGN KEY (patient_key)           REFERENCES dim_patient (patient_key),
    CONSTRAINT fk_fact_provider        FOREIGN KEY (provider_key)          REFERENCES dim_provider (provider_key),
    CONSTRAINT fk_fact_specialty       FOREIGN KEY (specialty_key)         REFERENCES dim_specialty (specialty_key),
    CONSTRAINT fk_fact_department      FOREIGN KEY (department_key)        REFERENCES dim_department (department_key),
    CONSTRAINT fk_fact_encounter_type  FOREIGN KEY (encounter_type_key)    REFERENCES dim_encounter_type (encounter_type_key),
    CONSTRAINT fk_fact_primary_dx      FOREIGN KEY (primary_diagnosis_key) REFERENCES dim_diagnosis (diagnosis_key)
) COMMENT = 'Encounter fact table: one row per encounter';


-- ---------------------------------------------------------------------
-- bridge_encounter_diagnoses: all diagnoses of each encounter.
-- PK guarantees each diagnosis appears once per encounter, so counts need
-- no DISTINCT. Clustered on encounter_key, so all of an encounter's
-- diagnoses are stored together.
-- ---------------------------------------------------------------------
CREATE TABLE bridge_encounter_diagnoses (
    encounter_key      INT        NOT NULL,
    diagnosis_key      INT        NOT NULL,
    diagnosis_sequence SMALLINT   NOT NULL COMMENT '1 = primary',
    is_primary         TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (encounter_key, diagnosis_key),
    KEY idx_bridge_dx_diagnosis (diagnosis_key, encounter_key) COMMENT 'Find encounters by diagnosis',
    CONSTRAINT fk_bridge_dx_encounter FOREIGN KEY (encounter_key) REFERENCES fact_encounters (encounter_key),
    CONSTRAINT fk_bridge_dx_diagnosis FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis (diagnosis_key)
) COMMENT = 'Bridge: encounter to diagnoses (many-to-many)';


-- ---------------------------------------------------------------------
-- bridge_encounter_procedures: all procedures of each encounter.
-- ---------------------------------------------------------------------
CREATE TABLE bridge_encounter_procedures (
    encounter_key      INT NOT NULL,
    procedure_key      INT NOT NULL,
    procedure_date_key INT NOT NULL DEFAULT 0,
    PRIMARY KEY (encounter_key, procedure_key),
    KEY idx_bridge_px_procedure (procedure_key, encounter_key) COMMENT 'Find encounters by procedure',
    KEY idx_bridge_px_date (procedure_date_key),
    CONSTRAINT fk_bridge_px_encounter FOREIGN KEY (encounter_key)      REFERENCES fact_encounters (encounter_key),
    CONSTRAINT fk_bridge_px_procedure FOREIGN KEY (procedure_key)      REFERENCES dim_procedure (procedure_key),
    CONSTRAINT fk_bridge_px_date      FOREIGN KEY (procedure_date_key) REFERENCES dim_date (date_key)
) COMMENT = 'Bridge: encounter to procedures (many-to-many)';