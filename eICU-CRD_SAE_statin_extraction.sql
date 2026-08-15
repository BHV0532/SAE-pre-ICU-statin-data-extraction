-- ==================================================================================================
-- Project: Pre-ICU statin use and sepsis-associated encephalopathy (SAE) in eICU-CRD
-- File:    eICU-CRD main variable extraction (cohort, exposure, outcome, mortality)
-- Database: eICU Collaborative Research Database v2.0 (PostgreSQL build)
-- Output:  sae_statin_eicu_final_cohort
--
-- Scope:
--   This script extracts the main variables of the study:
--     1) Base cohort: adult first ICU admissions (unitvisitnumber = 1)
--     2) Sepsis: documented sepsis diagnoses (APACHE admission diagnosis or diagnosis table),
--        excluding rule-out and historical entries
--     3) SAE diagnostic eligibility (acute intracranial pathology / major neurologic disease
--        and alcohol use disorder define eligibility; the analytic cohort is restricted to
--        eligible patients, consistent with the study exclusions)
--     4) Exposure: pre-ICU statin use, ascertained from admission medication records
--        (admissionDrug), which document drugs taken before hospital admission
--     5) Primary outcome: SAE within 24 hours of ICU admission
--        (first-day GCS < 15 OR first-day documented delirium, among eligible patients)
--     6) Secondary outcome: in-ICU mortality
--
-- Notes:
--   - Times in eICU-CRD are expressed as offsets in minutes relative to unit admission
--     (unit admission = offset 0); the first 24 hours correspond to offsets 0-1440.
--   - GCS is sourced from nurseCharting (GCS Total or Score (Glasgow Coma Scale)).
--   - Delirium is sourced from nurse-charted delirium-related records with a documented
--     positive value.
-- ==================================================================================================

SET search_path TO public;

-- ==================================================================================================
-- 01. Base cohort: adults (>=18 years), first ICU stay per hospitalization
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_base CASCADE;
CREATE TABLE sae_statin_eicu_base AS
WITH parsed AS (
    SELECT
        p.uniquepid,
        p.patienthealthsystemstayid,
        p.patientunitstayid,
        p.unitvisitnumber,
        p.hospitalid,
        h.region,
        p.unittype,
        p.apacheadmissiondx,
        p.unitdischargeoffset,
        p.hospitaldischargeyear,
        CASE
            WHEN p.age = '> 89' THEN 91
            WHEN p.age ~ '^[0-9]+$' THEN p.age::INT
            ELSE NULL
        END AS age,
        CASE
            WHEN LOWER(p.gender) LIKE '%female%' THEN 0
            WHEN LOWER(p.gender) LIKE '%male%'   THEN 1
            ELSE NULL
        END AS sex_male,
        p.ethnicity AS race,
        CASE
            WHEN LOWER(p.hospitaldischargestatus) LIKE '%expired%' THEN 1
            WHEN LOWER(p.hospitaldischargestatus) LIKE '%alive%'   THEN 0
            ELSE NULL
        END AS hosp_mort,
        CASE
            WHEN LOWER(p.unitdischargestatus) LIKE '%expired%' THEN 1
            WHEN LOWER(p.unitdischargestatus) LIKE '%alive%'   THEN 0
            ELSE NULL
        END AS icu_mort
    FROM patient p
    LEFT JOIN hospital h
        ON p.hospitalid = h.hospitalid
    WHERE p.unitvisitnumber = 1
)
SELECT *
FROM parsed
WHERE age >= 18;

CREATE INDEX idx_sae_statin_eicu_base_stay
ON sae_statin_eicu_base(patientunitstayid);

-- ==================================================================================================
-- 02. Sepsis cohort: documented sepsis from APACHE admission diagnosis or the diagnosis table.
--     Rule-out and historical entries are excluded to reduce false positives.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_sepsis CASCADE;
CREATE TABLE sae_statin_eicu_sepsis AS
SELECT
    b.patientunitstayid,
    MAX(
      CASE
        WHEN LOWER(COALESCE(b.apacheadmissiondx, '')) LIKE '%sepsis%'
          OR (
              (LOWER(COALESCE(d.diagnosisstring, '')) LIKE '%sepsis%'
                OR LOWER(COALESCE(d.diagnosisstring, '')) LIKE '%septic%')
              AND LOWER(COALESCE(d.diagnosisstring, '')) !~ '(rule out|r/o|history of|hx of|past history|family history|screening)'
             )
          OR COALESCE(d.icd9code, '') ~ '(^|,| )995\.9[12]($|,| )'
          OR COALESCE(d.icd9code, '') ~ '(^|,| )785\.52($|,| )'
          OR COALESCE(d.icd9code, '') ~ '(^|,| )038'
        THEN 1 ELSE 0 END
    ) AS sepsis
FROM sae_statin_eicu_base b
LEFT JOIN diagnosis d
    ON b.patientunitstayid = d.patientunitstayid
GROUP BY b.patientunitstayid;

CREATE INDEX idx_sae_statin_eicu_sepsis_stay
ON sae_statin_eicu_sepsis(patientunitstayid);

-- ==================================================================================================
-- 03. SAE diagnostic eligibility: acute intracranial pathology / major neurologic disease and
--     alcohol use disorder identified from the diagnosis table, past history, and APACHE
--     admission diagnosis. Generic coma or reduced consciousness is intentionally not used,
--     because reduced consciousness is part of the SAE outcome definition.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_eligibility CASCADE;
CREATE TABLE sae_statin_eicu_eligibility AS
SELECT
    b.patientunitstayid,
    MAX(CASE
      WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~
           '(meningitis|encephalitis|status epilepticus|traumatic brain injury|head trauma|cerebrovascular accident|stroke|intracranial hemorrhage|subarachnoid hemorrhage|subdural|epidural|brain injury|brain abscess|anoxic brain)'
        OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~
           '(cva|stroke|intracranial|subarachnoid|head.*trauma|traumatic brain injury|seizures|status epilepticus|meningitis|encephalitis|brain abscess|nontraumatic coma due to anoxia|anoxia/ischemia)'
        OR LOWER(COALESCE(ph.pasthistorypath, '')) ~
           '(stroke|cva|subarachnoid|intracranial|traumatic brain injury|meningitis|encephalitis|seizure|epilepsy)'
      THEN 1 ELSE 0 END) AS acute_brain_injury_or_major_neuro,
    MAX(CASE
      WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcohol intoxication|alcoholism)'
        OR LOWER(COALESCE(ph.pasthistorypath, '')) ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcoholism)'
        OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~ '(overdose, alcohol|alcohol)'
      THEN 1 ELSE 0 END) AS alcohol_abuse,
    CASE
      WHEN MAX(CASE
          WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~
               '(meningitis|encephalitis|status epilepticus|traumatic brain injury|head trauma|cerebrovascular accident|stroke|intracranial hemorrhage|subarachnoid hemorrhage|subdural|epidural|brain injury|brain abscess|anoxic brain)'
            OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~
               '(cva|stroke|intracranial|subarachnoid|head.*trauma|traumatic brain injury|seizures|status epilepticus|meningitis|encephalitis|brain abscess|nontraumatic coma due to anoxia|anoxia/ischemia)'
            OR LOWER(COALESCE(ph.pasthistorypath, '')) ~
               '(stroke|cva|subarachnoid|intracranial|traumatic brain injury|meningitis|encephalitis|seizure|epilepsy)'
          THEN 1 ELSE 0 END) = 0
       AND MAX(CASE
          WHEN LOWER(COALESCE(d.diagnosisstring, '')) ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcohol intoxication|alcoholism)'
            OR LOWER(COALESCE(ph.pasthistorypath, '')) ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcoholism)'
            OR LOWER(COALESCE(b.apacheadmissiondx, '')) ~ '(overdose, alcohol|alcohol)'
          THEN 1 ELSE 0 END) = 0
      THEN 1 ELSE 0
    END AS sae_eligible
FROM sae_statin_eicu_base b
LEFT JOIN diagnosis d
    ON b.patientunitstayid = d.patientunitstayid
LEFT JOIN pasthistory ph
    ON b.patientunitstayid = ph.patientunitstayid
GROUP BY b.patientunitstayid;

CREATE INDEX idx_sae_statin_eicu_elig_stay
ON sae_statin_eicu_eligibility(patientunitstayid);

-- ==================================================================================================
-- 04. SAE component 1: minimum GCS during the first 24 hours (offsets 0-1440), GCS < 15.
--     GCS is sourced from nurseCharting (GCS Total or Score (Glasgow Coma Scale) / Value).
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_gcs_firstday CASCADE;
CREATE TABLE sae_statin_eicu_gcs_firstday AS
WITH nc AS (
    SELECT
        patientunitstayid,
        nursingchartoffset AS chartoffset,
        MIN(CASE
            WHEN nursingchartcelltypevallabel = 'Glasgow coma score'
             AND nursingchartcelltypevalname = 'GCS Total'
             AND nursingchartvalue ~ '^[-]?[0-9]+[.]?[0-9]*$'
             AND nursingchartvalue NOT IN ('-', '.')
            THEN CAST(nursingchartvalue AS NUMERIC)
            WHEN nursingchartcelltypevallabel = 'Score (Glasgow Coma Scale)'
             AND nursingchartcelltypevalname = 'Value'
             AND nursingchartvalue ~ '^[-]?[0-9]+[.]?[0-9]*$'
             AND nursingchartvalue NOT IN ('-', '.')
            THEN CAST(nursingchartvalue AS NUMERIC)
            ELSE NULL
        END) AS gcs
    FROM nursecharting
    WHERE nursingchartcelltypecat IN ('Scores', 'Other Vital Signs and Infusions')
      AND nursingchartoffset BETWEEN 0 AND 1440
    GROUP BY patientunitstayid, nursingchartoffset
), valid AS (
    SELECT patientunitstayid, chartoffset, gcs
    FROM nc
    WHERE gcs > 2 AND gcs < 16
)
SELECT
    patientunitstayid,
    MIN(gcs) AS gcs_min_firstday,
    MIN(chartoffset) AS first_gcs_offset,
    MIN(CASE WHEN gcs < 15 THEN chartoffset END) AS first_low_gcs_offset_firstday,
    CASE WHEN MIN(gcs) < 15 THEN 1 ELSE 0 END::SMALLINT AS sae_by_gcs_firstday
FROM valid
GROUP BY patientunitstayid;

CREATE INDEX idx_sae_statin_eicu_gcs_stay
ON sae_statin_eicu_gcs_firstday(patientunitstayid);

-- ==================================================================================================
-- 05. SAE component 2: first-day documented (nurse-charted) delirium (offsets 0-1440)
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_delirium_firstday CASCADE;
CREATE TABLE sae_statin_eicu_delirium_firstday AS
SELECT
    patientunitstayid,
    MIN(nursingchartoffset) AS first_delirium_offset,
    1::SMALLINT AS delirium_firstday
FROM nursecharting
WHERE nursingchartoffset BETWEEN 0 AND 1440
  AND (
       LOWER(COALESCE(nursingchartcelltypevallabel, '')) LIKE '%delirium%'
    OR LOWER(COALESCE(nursingchartcelltypevalname,  '')) LIKE '%delirium%'
    OR LOWER(COALESCE(nursingchartvalue,            '')) LIKE '%delirium%'
  )
  AND (
       LOWER(COALESCE(nursingchartvalue, '')) IN ('yes', 'y', 'true', '1', 'present', 'positive')
    OR LOWER(COALESCE(nursingchartcelltypevallabel, '')) = 'symptoms of delirium present'
  )
GROUP BY patientunitstayid;

CREATE INDEX idx_sae_statin_eicu_del_stay
ON sae_statin_eicu_delirium_firstday(patientunitstayid);

-- ==================================================================================================
-- 06. Exposure: pre-ICU statin use from admission medication records (admissionDrug).
--     Generic and brand names of the seven systemic statins are matched.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_exposure CASCADE;
CREATE TABLE sae_statin_eicu_exposure AS
WITH statin_terms AS (
    SELECT 'atorvastatin' AS generic_name, 'lipophilic'  AS statin_type, 'atorvastatin' AS match_term UNION ALL
    SELECT 'atorvastatin', 'lipophilic',  'lipitor' UNION ALL
    SELECT 'simvastatin',  'lipophilic',  'simvastatin' UNION ALL
    SELECT 'simvastatin',  'lipophilic',  'zocor' UNION ALL
    SELECT 'lovastatin',   'lipophilic',  'lovastatin' UNION ALL
    SELECT 'lovastatin',   'lipophilic',  'mevacor' UNION ALL
    SELECT 'lovastatin',   'lipophilic',  'altoprev' UNION ALL
    SELECT 'pitavastatin', 'lipophilic',  'pitavastatin' UNION ALL
    SELECT 'pitavastatin', 'lipophilic',  'livalo' UNION ALL
    SELECT 'fluvastatin',  'lipophilic',  'fluvastatin' UNION ALL
    SELECT 'fluvastatin',  'lipophilic',  'lescol' UNION ALL
    SELECT 'pravastatin',  'hydrophilic', 'pravastatin' UNION ALL
    SELECT 'pravastatin',  'hydrophilic', 'pravachol' UNION ALL
    SELECT 'rosuvastatin', 'hydrophilic', 'rosuvastatin' UNION ALL
    SELECT 'rosuvastatin', 'hydrophilic', 'crestor'
), pre_raw AS (
    SELECT DISTINCT
        a.patientunitstayid,
        s.generic_name,
        s.statin_type
    FROM admissiondrug a
    JOIN statin_terms s
        ON LOWER(COALESCE(a.drugname::TEXT, '')) LIKE '%' || s.match_term || '%'
)
SELECT
    b.patientunitstayid,
    COALESCE(MAX(CASE WHEN pr.patientunitstayid IS NOT NULL THEN 1 ELSE 0 END), 0)::SMALLINT AS pre_statin,
    COALESCE(MAX(CASE WHEN pr.statin_type = 'lipophilic'  THEN 1 ELSE 0 END), 0)::SMALLINT AS pre_lipophilic_statin,
    COALESCE(MAX(CASE WHEN pr.statin_type = 'hydrophilic' THEN 1 ELSE 0 END), 0)::SMALLINT AS pre_hydrophilic_statin
FROM sae_statin_eicu_base b
LEFT JOIN pre_raw pr
    ON b.patientunitstayid = pr.patientunitstayid
GROUP BY b.patientunitstayid;

CREATE INDEX idx_sae_statin_eicu_exposure_stay
ON sae_statin_eicu_exposure(patientunitstayid);

-- ==================================================================================================
-- 07. Final analytic cohort
--     Sepsis cohort restricted to SAE-eligible patients. SAE within 24 hours = first-day
--     GCS < 15 OR first-day documented delirium, matching the study population.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_eicu_final_cohort CASCADE;
CREATE TABLE sae_statin_eicu_final_cohort AS
SELECT
    b.uniquepid,
    b.patienthealthsystemstayid,
    b.patientunitstayid,
    b.hospitalid,
    b.region,
    b.unittype,
    b.apacheadmissiondx,
    b.unitdischargeoffset,
    b.hospitaldischargeyear,
    b.age,
    b.sex_male,
    b.race,
    b.icu_mort,
    b.hosp_mort,
    e.acute_brain_injury_or_major_neuro,
    e.alcohol_abuse,
    e.sae_eligible,
    g.gcs_min_firstday,
    g.first_gcs_offset,
    g.first_low_gcs_offset_firstday,
    COALESCE(g.sae_by_gcs_firstday, 0)::SMALLINT AS sae_by_gcs_firstday,
    d.first_delirium_offset,
    COALESCE(d.delirium_firstday, 0)::SMALLINT AS delirium_firstday,
    CASE
        WHEN COALESCE(g.sae_by_gcs_firstday, 0) = 1
          OR COALESCE(d.delirium_firstday, 0) = 1
        THEN 1 ELSE 0
    END::SMALLINT AS sae_within_24h,
    ex.pre_statin AS statin_before_icu,
    ex.pre_lipophilic_statin AS lipophilic_statin_before_icu,
    ex.pre_hydrophilic_statin AS hydrophilic_statin_before_icu
FROM sae_statin_eicu_base b
INNER JOIN sae_statin_eicu_sepsis s
    ON b.patientunitstayid = s.patientunitstayid
   AND s.sepsis = 1
INNER JOIN sae_statin_eicu_eligibility e
    ON b.patientunitstayid = e.patientunitstayid
   AND e.sae_eligible = 1
LEFT JOIN sae_statin_eicu_gcs_firstday g
    ON b.patientunitstayid = g.patientunitstayid
LEFT JOIN sae_statin_eicu_delirium_firstday d
    ON b.patientunitstayid = d.patientunitstayid
LEFT JOIN sae_statin_eicu_exposure ex
    ON b.patientunitstayid = ex.patientunitstayid;

CREATE INDEX idx_sae_statin_eicu_final_stay
ON sae_statin_eicu_final_cohort(patientunitstayid);
CREATE INDEX idx_sae_statin_eicu_final_sae
ON sae_statin_eicu_final_cohort(sae_within_24h);

-- ==================================================================================================
-- 08. Quick verification queries (expected values in the study)
-- ==================================================================================================
-- Analytic cohort size (expected approximately 20,911):
-- SELECT COUNT(*) FROM sae_statin_eicu_final_cohort;
--
-- Pre-ICU statin use (expected approximately 2,049; 9.8%):
-- SELECT SUM(statin_before_icu) FROM sae_statin_eicu_final_cohort;
--
-- SAE within 24 hours (expected approximately 9,458; 45.2%):
-- SELECT SUM(sae_within_24h) FROM sae_statin_eicu_final_cohort;

-- End of the eICU-CRD extraction script
