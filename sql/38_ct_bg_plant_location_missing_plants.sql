-- =============================================================
-- 38_ct_bg_plant_location_missing_plants.sql  (IRPC_QTRACK)
-- =============================================================
-- RC (Receive) jobs take their source plant from
-- IRPC_E_TRANSFER.dbo.ct_receive_cost_center (via VReceiveForm
-- .from_plant_cc_code), but the GET-location picker on job-detail reads
-- dbo.ct_bg_plant_location by that same code. These 10 cost centers
-- exist in ct_receive_cost_center with no row here, so an RC job from
-- them (e.g. job 669, 1305 PLBG) had no selectable source location.
--
-- The real plant location codes are not known yet, so bg_plant_location
-- is set to the cost center's own description for now (1305 -> 'PLBG').
-- Replace with the real code later via UPDATE on bg_plant_location --
-- tr_job_from_location stores the row id, so saved jobs keep pointing
-- at the same row.
--
-- Idempotent: only inserts rows not already present (active).
-- =============================================================

SET NOCOUNT ON;

INSERT INTO dbo.ct_bg_plant_location (bg_plant_code, bg_plant_location, bg_plant_desc)
SELECT src.bg_plant_code, src.bg_plant_location, src.bg_plant_desc
FROM (VALUES
    ('1305', 'PLBG',           'PLBG'),
    ('1376', 'PLBG (TABS)',    'PLBG (TABS)'),
    ('1606', 'MWH',            'MWH'),
    ('3324', 'NANO Plant',     'NANO Plant'),
    ('3325', 'NANO Plant',     'NANO Plant'),
    ('P001', 'RD',             'RD'),
    ('P002', 'Store Chemical', 'Store Chemical'),
    ('P003', 'SIPL',           'SIPL'),
    ('P004', 'SISA',           'SISA'),
    ('P005', 'MKT',            'MKT')
) AS src (bg_plant_code, bg_plant_location, bg_plant_desc)
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.ct_bg_plant_location bg
    WHERE bg.bg_plant_code = src.bg_plant_code
      AND bg.bg_plant_location = src.bg_plant_location
      AND bg.is_active = 'Y'
      AND bg.status_flag = 'A'
);

SELECT id, bg_plant_code, bg_plant_location, bg_plant_desc, is_active, status_flag
FROM dbo.ct_bg_plant_location
WHERE bg_plant_code IN ('1305', '1376', '1606', '3324', '3325', 'P001', 'P002', 'P003', 'P004', 'P005')
ORDER BY bg_plant_code, id;
