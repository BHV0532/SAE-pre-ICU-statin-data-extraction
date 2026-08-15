-- ==================================================================================================
-- Project: Pre-ICU statin use and sepsis-associated encephalopathy (SAE) in MIMIC-IV
-- File:    MIMIC-IV main variable extraction (cohort, exposure, outcome, mortality)
-- Database: MIMIC-IV v2.2 (PostgreSQL build)
-- Output:  sae_statin_mimic_final_cohort
--
-- Scope:
--   This script extracts the main variables of the study:
--     1) Base cohort: adult first-ICU admissions with Sepsis-3
--     2) SAE diagnostic eligibility (acute intracranial pathology / major neurologic disease
--        and alcohol use disorder define eligibility; the analytic cohort is restricted to
--        eligible patients, consistent with the study exclusions)
--     3) Exposure: pre-ICU statin use (any systemic statin started before ICU admission,
--        without restriction on the interval between prescription and ICU transfer)
--     4) Primary outcome: SAE within 24 hours of ICU admission
--        (first-day GCS < 15 OR first-day CAM-ICU positive delirium, among eligible patients)
--     5) Secondary outcome: in-ICU mortality
--
-- Requirements:
--   Standard MIMIC-IV build with schemas mimiciv_hosp, mimiciv_icu and the derived concept
--   tables (sepsis3, gcs) in the search path.
--
-- Notes:
--   - The GCS concept table "gcs" is the standard MIMIC-IV derived concept
--     (mimic-code/concepts/postgres).
--   - CAM-ICU delirium is derived from charted CAM-ICU features (itemids below).
-- ==================================================================================================

SET search_path TO mimiciv_derived, mimiciv_icu, mimiciv_hosp, public;

-- ==================================================================================================
-- 01. Base cohort: adults (>=18 years), first ICU stay, Sepsis-3
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_base CASCADE;
CREATE TABLE sae_statin_mimic_base AS
WITH first_icu AS (
    SELECT
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime AS icu_intime,
        icu.outtime AS icu_outtime,
        icu.los AS icu_los_days,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime, icu.stay_id) AS icu_order
    FROM mimiciv_icu.icustays icu
), sepsis AS (
    SELECT
        s3.stay_id,
        MIN(s3.suspected_infection_time) AS suspected_infection_time,
        MIN(s3.sofa_time) AS sepsis_time,
        MAX(s3.sofa_score) AS sofa_score
    FROM sepsis3 s3
    GROUP BY s3.stay_id
)
SELECT
    fi.subject_id,
    fi.hadm_id,
    fi.stay_id,
    fi.icu_intime,
    fi.icu_outtime,
    fi.icu_los_days,
    (pat.anchor_age + EXTRACT(YEAR FROM adm.admittime)::INT - pat.anchor_year)::INT AS age,
    pat.gender,
    adm.race,
    adm.admittime,
    adm.deathtime,
    pat.dod AS death_time,
    adm.hospital_expire_flag,
    sepsis.suspected_infection_time,
    sepsis.sepsis_time,
    sepsis.sofa_score
FROM first_icu fi
INNER JOIN mimiciv_hosp.patients pat
    ON fi.subject_id = pat.subject_id
INNER JOIN mimiciv_hosp.admissions adm
    ON fi.hadm_id = adm.hadm_id
INNER JOIN sepsis
    ON fi.stay_id = sepsis.stay_id
WHERE fi.icu_order = 1
  AND (pat.anchor_age + EXTRACT(YEAR FROM adm.admittime)::INT - pat.anchor_year) >= 18;

CREATE INDEX idx_sae_statin_mimic_base_stay ON sae_statin_mimic_base(stay_id);
CREATE INDEX idx_sae_statin_mimic_base_hadm ON sae_statin_mimic_base(hadm_id);

-- ==================================================================================================
-- 02. SAE diagnostic eligibility: acute intracranial pathology / major neurologic disease
--     and alcohol use disorder are identified from ICD codes and diagnosis titles.
--     Patients with these conditions are not eligible for SAE assessment and are excluded
--     from the analytic cohort.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_eligibility CASCADE;
CREATE TABLE sae_statin_mimic_eligibility AS
WITH dx AS (
    SELECT
        d.hadm_id,
        REPLACE(UPPER(d.icd_code), '.', '') AS icd_code_clean,
        d.icd_version,
        LOWER(COALESCE(dic.long_title, '')) AS long_title
    FROM mimiciv_hosp.diagnoses_icd d
    LEFT JOIN mimiciv_hosp.d_icd_diagnoses dic
        ON d.icd_code = dic.icd_code
       AND d.icd_version = dic.icd_version
), flags AS (
    SELECT
        b.hadm_id,
        MAX(CASE WHEN
            (dx.icd_version = 10 AND (
                SUBSTR(dx.icd_code_clean, 1, 3) IN ('G00','G01','G02','G03','G04','G41','S06','I60','I61','I62','I63','I64')
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN 'I65' AND 'I69'
            ))
            OR
            (dx.icd_version = 9 AND (
                SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '320' AND '323'
                OR SUBSTR(dx.icd_code_clean, 1, 4) IN ('3453')
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '430' AND '438'
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '800' AND '804'
                OR SUBSTR(dx.icd_code_clean, 1, 3) BETWEEN '850' AND '854'
            ))
            OR dx.long_title ~ '(meningitis|encephalitis|status epilepticus|traumatic brain injury|intracranial hemorrhage|subarachnoid hemorrhage|subdural|epidural|cerebral infarction|ischemic stroke|haemorrhagic stroke|hemorrhagic stroke|cerebrovascular accident)'
        THEN 1 ELSE 0 END) AS acute_brain_injury,
        MAX(CASE WHEN
            (dx.icd_version = 10 AND SUBSTR(dx.icd_code_clean, 1, 3) = 'F10')
            OR (dx.icd_version = 9 AND (
                SUBSTR(dx.icd_code_clean, 1, 3) IN ('291','303')
                OR SUBSTR(dx.icd_code_clean, 1, 4) = '3050'
            ))
            OR dx.long_title ~ '(alcohol abuse|alcohol dependence|alcohol withdrawal|alcohol intoxication|alcoholism|alcohol-related)'
        THEN 1 ELSE 0 END) AS alcohol_abuse
    FROM sae_statin_mimic_base b
    LEFT JOIN dx
        ON b.hadm_id = dx.hadm_id
    GROUP BY b.hadm_id
)
SELECT
    b.stay_id,
    b.hadm_id,
    COALESCE(flags.acute_brain_injury, 0)::SMALLINT AS acute_brain_injury,
    COALESCE(flags.alcohol_abuse, 0)::SMALLINT AS alcohol_abuse,
    CASE
        WHEN COALESCE(flags.acute_brain_injury, 0) = 0
         AND COALESCE(flags.alcohol_abuse, 0) = 0
        THEN 1 ELSE 0
    END::SMALLINT AS sae_eligible
FROM sae_statin_mimic_base b
LEFT JOIN flags
    ON b.hadm_id = flags.hadm_id;

CREATE INDEX idx_sae_statin_mimic_elig_stay ON sae_statin_mimic_eligibility(stay_id);

-- ==================================================================================================
-- 03. SAE component 1: minimum GCS during the first 24 hours (GCS < 15)
--     Uses the standard MIMIC-IV derived GCS concept table.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_gcs_firstday CASCADE;
CREATE TABLE sae_statin_mimic_gcs_firstday AS
WITH gcs_fd AS (
    SELECT
        b.stay_id,
        g.charttime,
        g.gcs
    FROM sae_statin_mimic_base b
    LEFT JOIN gcs g
        ON b.stay_id = g.stay_id
       AND g.charttime >= b.icu_intime
       AND g.charttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
       AND g.gcs IS NOT NULL
       AND g.gcs BETWEEN 3 AND 15
), agg AS (
    SELECT
        stay_id,
        MIN(gcs) AS gcs_min_firstday,
        MIN(charttime) FILTER (WHERE gcs < 15) AS first_low_gcs_time
    FROM gcs_fd
    GROUP BY stay_id
)
SELECT
    b.stay_id,
    agg.gcs_min_firstday,
    agg.first_low_gcs_time,
    CASE WHEN agg.gcs_min_firstday < 15 THEN 1 ELSE 0 END::SMALLINT AS sae_by_gcs_firstday
FROM sae_statin_mimic_base b
LEFT JOIN agg
    ON b.stay_id = agg.stay_id;

CREATE INDEX idx_sae_statin_mimic_gcs_stay ON sae_statin_mimic_gcs_firstday(stay_id);

-- ==================================================================================================
-- 04. SAE component 2: first-day CAM-ICU positive delirium
--     CAM-ICU feature itemids:
--       feat1 (acute change / fluctuation): 228337, 228300, 229326
--       feat2 (inattention):                228336, 228301, 229325
--       feat3 (altered level of consciousness): 228335, 228303, 229324
--       feat4 (disorganized thinking):      228302, 228334
--     Positive rule: (feat1 + feat2 + feat3 >= 3) OR (feat1 + feat2 + feat4 >= 3)
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_delirium_features CASCADE;
CREATE TABLE sae_statin_mimic_delirium_features AS
SELECT DISTINCT
    b.stay_id,
    ce.charttime,
    ce.itemid,
    ce.valuenum,
    CASE WHEN ce.itemid IN (228337, 228300, 229326) THEN 1 ELSE 0 END AS feat1,
    CASE WHEN ce.itemid IN (228336, 228301, 229325) THEN 1 ELSE 0 END AS feat2,
    CASE WHEN ce.itemid IN (228335, 228303, 229324) THEN 1 ELSE 0 END AS feat3,
    CASE WHEN ce.itemid IN (228302, 228334) THEN 1 ELSE 0 END AS feat4
FROM sae_statin_mimic_base b
JOIN mimiciv_icu.chartevents ce
    ON b.stay_id = ce.stay_id
WHERE ce.itemid IN (
    228337, 228300, 229326,
    228336, 228301, 229325,
    228335, 228303, 229324,
    228302, 228334
)
  AND ce.charttime >= b.icu_intime
  AND ce.charttime < LEAST(b.icu_outtime, b.icu_intime + INTERVAL '24 hours')
  AND ce.value NOT ILIKE '%Unable to Assess%'
  AND ce.valuenum IS NOT NULL;

CREATE INDEX idx_sae_statin_mimic_del_feat_stay_time
ON sae_statin_mimic_delirium_features(stay_id, charttime);

DROP TABLE IF EXISTS sae_statin_mimic_delirium_status CASCADE;
CREATE TABLE sae_statin_mimic_delirium_status AS
WITH delirium_assessment AS (
    SELECT
        stay_id,
        charttime,
        COALESCE(MAX(feat1), 0) AS feat1,
        COALESCE(MAX(feat2), 0) AS feat2,
        COALESCE(MAX(feat3), 0) AS feat3,
        COALESCE(MAX(feat4), 0) AS feat4
    FROM sae_statin_mimic_delirium_features
    GROUP BY stay_id, charttime
), cam_evaluation AS (
    SELECT
        stay_id,
        charttime,
        CASE
            WHEN (feat1 + feat2 + feat3 >= 3)
              OR (feat1 + feat2 + feat4 >= 3)
            THEN 1 ELSE 0
        END AS cam_positive
    FROM delirium_assessment
), agg AS (
    SELECT
        b.stay_id,
        MIN(CASE WHEN ce.cam_positive = 1 THEN ce.charttime END) AS first_delirium_time,
        MAX(CASE WHEN ce.cam_positive = 1 THEN 1 ELSE 0 END) AS delirium_positive_firstday
    FROM sae_statin_mimic_base b
    LEFT JOIN cam_evaluation ce
        ON b.stay_id = ce.stay_id
    GROUP BY b.stay_id
)
SELECT
    b.stay_id,
    agg.first_delirium_time,
    COALESCE(agg.delirium_positive_firstday, 0)::SMALLINT AS delirium_positive_firstday
FROM sae_statin_mimic_base b
LEFT JOIN agg
    ON b.stay_id = agg.stay_id;

CREATE INDEX idx_sae_statin_mimic_del_status_stay ON sae_statin_mimic_delirium_status(stay_id);

-- ==================================================================================================
-- 05. Exposure: pre-ICU statin use
--     Any systemic statin whose inpatient prescription start time precedes ICU admission,
--     without restriction on the interval between prescription and ICU transfer.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_all_statins CASCADE;
CREATE TABLE sae_statin_mimic_all_statins AS
SELECT DISTINCT
    b.stay_id,
    p.drug AS drug_name_original,
    CASE
        WHEN LOWER(p.drug) LIKE '%atorvastatin%' OR LOWER(p.drug) LIKE '%lipitor%' OR LOWER(p.drug) LIKE '%atorvaliq%' THEN 'atorvastatin'
        WHEN LOWER(p.drug) LIKE '%simvastatin%' OR LOWER(p.drug) LIKE '%zocor%' OR LOWER(p.drug) LIKE '%flolipid%' OR LOWER(p.drug) LIKE '%cholesnone%' OR LOWER(p.drug) LIKE '%vytorin%' THEN 'simvastatin'
        WHEN LOWER(p.drug) LIKE '%lovastatin%' OR LOWER(p.drug) LIKE '%mevacor%' OR LOWER(p.drug) LIKE '%altoprev%' OR LOWER(p.drug) LIKE '%altocor%' THEN 'lovastatin'
        WHEN LOWER(p.drug) LIKE '%pitavastatin%' OR LOWER(p.drug) LIKE '%livalo%' OR LOWER(p.drug) LIKE '%zypitamag%' OR LOWER(p.drug) LIKE '%livazo%' OR LOWER(p.drug) LIKE '%alipza%' THEN 'pitavastatin'
        WHEN LOWER(p.drug) LIKE '%fluvastatin%' OR LOWER(p.drug) LIKE '%lescol%' THEN 'fluvastatin'
        WHEN LOWER(p.drug) LIKE '%pravastatin%' OR LOWER(p.drug) LIKE '%pravachol%' OR LOWER(p.drug) LIKE '%lipostat%' OR LOWER(p.drug) LIKE '%mevalotin%' THEN 'pravastatin'
        WHEN LOWER(p.drug) LIKE '%rosuvastatin%' OR LOWER(p.drug) LIKE '%crestor%' OR LOWER(p.drug) LIKE '%vivacor%' OR LOWER(p.drug) LIKE '%roszet%' THEN 'rosuvastatin'
        ELSE NULL
    END AS statin_type,
    CASE
        WHEN LOWER(p.drug) LIKE '%atorvastatin%' OR LOWER(p.drug) LIKE '%lipitor%' OR LOWER(p.drug) LIKE '%atorvaliq%'
          OR LOWER(p.drug) LIKE '%simvastatin%' OR LOWER(p.drug) LIKE '%zocor%' OR LOWER(p.drug) LIKE '%flolipid%' OR LOWER(p.drug) LIKE '%cholesnone%' OR LOWER(p.drug) LIKE '%vytorin%'
          OR LOWER(p.drug) LIKE '%lovastatin%' OR LOWER(p.drug) LIKE '%mevacor%' OR LOWER(p.drug) LIKE '%altoprev%' OR LOWER(p.drug) LIKE '%altocor%'
          OR LOWER(p.drug) LIKE '%pitavastatin%' OR LOWER(p.drug) LIKE '%livalo%' OR LOWER(p.drug) LIKE '%zypitamag%' OR LOWER(p.drug) LIKE '%livazo%' OR LOWER(p.drug) LIKE '%alipza%'
          OR LOWER(p.drug) LIKE '%fluvastatin%' OR LOWER(p.drug) LIKE '%lescol%'
        THEN 'lipophilic'
        WHEN LOWER(p.drug) LIKE '%pravastatin%' OR LOWER(p.drug) LIKE '%pravachol%' OR LOWER(p.drug) LIKE '%lipostat%' OR LOWER(p.drug) LIKE '%mevalotin%'
          OR LOWER(p.drug) LIKE '%rosuvastatin%' OR LOWER(p.drug) LIKE '%crestor%' OR LOWER(p.drug) LIKE '%vivacor%' OR LOWER(p.drug) LIKE '%roszet%'
        THEN 'hydrophilic'
        ELSE NULL
    END AS statin_class,
    p.starttime,
    p.stoptime
FROM sae_statin_mimic_base b
JOIN mimiciv_hosp.prescriptions p
    ON b.hadm_id = p.hadm_id
WHERE p.starttime IS NOT NULL
  AND COALESCE(p.drug_type, '') <> 'BASE'
  AND (
    LOWER(p.drug) LIKE '%atorvastatin%' OR LOWER(p.drug) LIKE '%lipitor%' OR LOWER(p.drug) LIKE '%atorvaliq%' OR
    LOWER(p.drug) LIKE '%simvastatin%' OR LOWER(p.drug) LIKE '%zocor%' OR LOWER(p.drug) LIKE '%flolipid%' OR LOWER(p.drug) LIKE '%cholesnone%' OR LOWER(p.drug) LIKE '%vytorin%' OR
    LOWER(p.drug) LIKE '%lovastatin%' OR LOWER(p.drug) LIKE '%mevacor%' OR LOWER(p.drug) LIKE '%altoprev%' OR LOWER(p.drug) LIKE '%altocor%' OR
    LOWER(p.drug) LIKE '%pitavastatin%' OR LOWER(p.drug) LIKE '%livalo%' OR LOWER(p.drug) LIKE '%zypitamag%' OR LOWER(p.drug) LIKE '%livazo%' OR LOWER(p.drug) LIKE '%alipza%' OR
    LOWER(p.drug) LIKE '%fluvastatin%' OR LOWER(p.drug) LIKE '%lescol%' OR
    LOWER(p.drug) LIKE '%pravastatin%' OR LOWER(p.drug) LIKE '%pravachol%' OR LOWER(p.drug) LIKE '%lipostat%' OR LOWER(p.drug) LIKE '%mevalotin%' OR
    LOWER(p.drug) LIKE '%rosuvastatin%' OR LOWER(p.drug) LIKE '%crestor%' OR LOWER(p.drug) LIKE '%vivacor%' OR LOWER(p.drug) LIKE '%roszet%'
  );

CREATE INDEX idx_sae_statin_mimic_statins_stay ON sae_statin_mimic_all_statins(stay_id);

DROP TABLE IF EXISTS sae_statin_mimic_exposure CASCADE;
CREATE TABLE sae_statin_mimic_exposure AS
WITH flagged AS (
    SELECT
        b.stay_id,
        s.statin_type,
        s.statin_class,
        s.starttime,
        CASE WHEN s.starttime < b.icu_intime THEN 1 ELSE 0 END AS is_before_icu
    FROM sae_statin_mimic_base b
    LEFT JOIN sae_statin_mimic_all_statins s
        ON b.stay_id = s.stay_id
)
SELECT
    b.stay_id,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 THEN 1 ELSE 0 END), 0)::SMALLINT AS statin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_class = 'lipophilic' THEN 1 ELSE 0 END), 0)::SMALLINT AS lipophilic_statin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_class = 'hydrophilic' THEN 1 ELSE 0 END), 0)::SMALLINT AS hydrophilic_statin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'atorvastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS atorvastatin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'simvastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS simvastatin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'rosuvastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS rosuvastatin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'pravastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS pravastatin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'lovastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS lovastatin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'pitavastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS pitavastatin_before_icu,
    COALESCE(MAX(CASE WHEN f.is_before_icu = 1 AND f.statin_type = 'fluvastatin' THEN 1 ELSE 0 END), 0)::SMALLINT AS fluvastatin_before_icu
FROM sae_statin_mimic_base b
LEFT JOIN flagged f
    ON b.stay_id = f.stay_id
GROUP BY b.stay_id;

CREATE INDEX idx_sae_statin_mimic_exposure_stay ON sae_statin_mimic_exposure(stay_id);

-- ==================================================================================================
-- 06. Outcome: in-ICU mortality
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_mortality CASCADE;
CREATE TABLE sae_statin_mimic_mortality AS
SELECT
    b.stay_id,
    CASE
        WHEN b.deathtime BETWEEN b.icu_intime AND b.icu_outtime THEN 1
        ELSE 0
    END::SMALLINT AS icu_death
FROM sae_statin_mimic_base b;

CREATE INDEX idx_sae_statin_mimic_mort_stay ON sae_statin_mimic_mortality(stay_id);

-- ==================================================================================================
-- 07. Final analytic cohort
--     SAE within 24 hours = first-day GCS < 15 OR first-day CAM-ICU positive delirium,
--     assessed among SAE-eligible patients. The analytic cohort is restricted to eligible
--     patients, matching the study population.
-- ==================================================================================================
DROP TABLE IF EXISTS sae_statin_mimic_final_cohort CASCADE;
CREATE TABLE sae_statin_mimic_final_cohort AS
SELECT
    b.subject_id,
    b.hadm_id,
    b.stay_id,
    b.icu_intime,
    b.icu_outtime,
    b.icu_los_days,
    b.age,
    b.gender,
    b.race,
    b.suspected_infection_time,
    b.sepsis_time,
    b.sofa_score,
    e.acute_brain_injury,
    e.alcohol_abuse,
    e.sae_eligible,
    g.gcs_min_firstday,
    g.first_low_gcs_time,
    COALESCE(g.sae_by_gcs_firstday, 0)::SMALLINT AS sae_by_gcs_firstday,
    d.first_delirium_time,
    COALESCE(d.delirium_positive_firstday, 0)::SMALLINT AS delirium_positive_firstday,
    CASE
        WHEN COALESCE(g.sae_by_gcs_firstday, 0) = 1
          OR COALESCE(d.delirium_positive_firstday, 0) = 1
        THEN 1 ELSE 0
    END::SMALLINT AS sae_within_24h,
    ex.statin_before_icu,
    ex.lipophilic_statin_before_icu,
    ex.hydrophilic_statin_before_icu,
    ex.atorvastatin_before_icu,
    ex.simvastatin_before_icu,
    ex.rosuvastatin_before_icu,
    ex.pravastatin_before_icu,
    ex.lovastatin_before_icu,
    ex.pitavastatin_before_icu,
    ex.fluvastatin_before_icu,
    m.icu_death
FROM sae_statin_mimic_base b
INNER JOIN sae_statin_mimic_eligibility e
    ON b.stay_id = e.stay_id
LEFT JOIN sae_statin_mimic_gcs_firstday g
    ON b.stay_id = g.stay_id
LEFT JOIN sae_statin_mimic_delirium_status d
    ON b.stay_id = d.stay_id
LEFT JOIN sae_statin_mimic_exposure ex
    ON b.stay_id = ex.stay_id
LEFT JOIN sae_statin_mimic_mortality m
    ON b.stay_id = m.stay_id
WHERE e.sae_eligible = 1;

CREATE INDEX idx_sae_statin_mimic_final_stay ON sae_statin_mimic_final_cohort(stay_id);
CREATE INDEX idx_sae_statin_mimic_final_sae ON sae_statin_mimic_final_cohort(sae_within_24h);

-- ==================================================================================================
-- 08. Quick verification queries (expected values in the study)
-- ==================================================================================================
-- Analytic cohort size (expected approximately 15,133):
-- SELECT COUNT(*) FROM sae_statin_mimic_final_cohort;
--
-- Pre-ICU statin use (expected approximately 2,911; 19.2%):
-- SELECT SUM(statin_before_icu) FROM sae_statin_mimic_final_cohort;
--
-- SAE within 24 hours (expected approximately 2,341; 15.5%):
-- SELECT SUM(sae_within_24h) FROM sae_statin_mimic_final_cohort;

-- End of the MIMIC-IV extraction script
