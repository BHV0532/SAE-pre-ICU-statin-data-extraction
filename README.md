# Pre-ICU Statin Use and Sepsis-Associated Encephalopathy: Data Extraction from MIMIC-IV and eICU-CRD

This repository contains the main variable extraction code (PostgreSQL) for the study on the association between pre-ICU statin use and sepsis-associated encephalopathy (SAE), based on two large, publicly accessible ICU databases: [MIMIC-IV](https://physionet.org/content/mimiciv/) and the [eICU Collaborative Research Database](https://physionet.org/content/eicu-crd/).

Only the extraction logic for the main study variables is provided. The complete covariate derivation and analysis pipeline are available from the corresponding author upon reasonable request.

## File Structure

| File | Description |
|------|-------------|
| `MIMIC-IV_SAE_statin_extraction.sql` | Main variable extraction from MIMIC-IV (cohort, eligibility, exposure, outcome, mortality) |
| `eICU-CRD_SAE_statin_extraction.sql` | Main variable extraction from eICU-CRD (cohort, eligibility, exposure, outcome, mortality) |
| `LICENSE` | MIT License |

## Definitions Used in the Study

### Study population

- Adults (aged >= 18 years) with a first ICU admission and sepsis.
  - MIMIC-IV: Sepsis-3 (suspected infection with an acute SOFA increase >= 2), using the standard derived `sepsis3` concept table.
  - eICU-CRD: documented sepsis diagnoses (APACHE admission diagnosis or diagnosis table), excluding rule-out and historical entries.
- Patients with acute intracranial pathology or major neurologic disease, and patients with alcohol use disorder, were excluded (they are not eligible for SAE assessment).

### Exposure: pre-ICU statin use

- MIMIC-IV: any systemic statin whose inpatient prescription start time precedes ICU admission, without restriction on the interval between prescription and ICU transfer, ascertained from the `prescriptions` table.
- eICU-CRD: any statin documented in the admission medication records (`admissionDrug`), which document drugs taken before hospital admission.
- Statins included: atorvastatin, simvastatin, lovastatin, pitavastatin, fluvastatin, pravastatin, and rosuvastatin (generic and brand names matched). Lipophilic and hydrophilic class flags are provided.

### Primary outcome: SAE within 24 hours of ICU admission

- Defined as a Glasgow Coma Scale (GCS) score < 15 and/or documented delirium during the first 24 hours after ICU admission, assessed among eligible patients.
  - MIMIC-IV: GCS from the standard derived `gcs` concept table; delirium from charted CAM-ICU features.
  - eICU-CRD: GCS from `nurseCharting`; delirium from nurse-charted delirium records with a documented positive value.

### Secondary outcome

- In-ICU mortality.

## How to Use

1. **Prerequisites**
   - A PostgreSQL server hosting MIMIC-IV v2.2 (schemas `mimiciv_hosp`, `mimiciv_icu`, and the derived concept tables such as `sepsis3` and `gcs`) or eICU-CRD v2.0.
   - Credentialed access to the respective databases through PhysioNet, and completion of the required data-use training.
2. **Execution**
   - Run each script step by step in a PostgreSQL client (e.g., psql, Navicat, DBeaver).
   - Each step creates intermediate indexed tables; the final analytic cohort is stored in `sae_statin_mimic_final_cohort` (MIMIC-IV) and `sae_statin_eicu_final_cohort` (eICU-CRD).
3. **Verification**
   - Verification queries with the expected cohort sizes are included at the end of each script (MIMIC-IV: approximately 15,133 patients; eICU-CRD: approximately 20,911 patients).

## Performance Notes

Indexes are created on key identifier columns (`stay_id` / `patientunitstayid`) and on outcome columns of the final cohort tables to speed up downstream queries.

## Ethics and Data Use

- MIMIC-IV and eICU-CRD contain de-identified data. Access requires credentialed PhysioNet login and signing of the data-use agreement.
- The use of MIMIC-IV was approved by the Institutional Review Boards of the Massachusetts Institute of Technology and Beth Israel Deaconess Medical Center, with a waiver of informed consent.
- eICU-CRD was released in accordance with the HIPAA safe harbor provision.
- No patient-level data are included in this repository.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgements

We thank the Laboratory for Computational Physiology at the Massachusetts Institute of Technology and the eICU Research Institute for developing and maintaining the MIMIC-IV and eICU-CRD databases, and all clinicians and patients who contributed the underlying data.
