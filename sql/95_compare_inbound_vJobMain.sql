-- =============================================================
-- 95_compare_inbound_vJobMain.sql  (IRPC_QTRACK)  -- READ ONLY
-- =============================================================
-- Checks that the base-table tests of sql/95 give the same answer as the
-- dbo.vJobMain statements they replace in pProcessInboundGetPallet /
-- pProcessInboundPutAway. Nothing is written (temp tables only).
--
-- 1. job + item check: every TS / RC job (any flags) x every item of its
--    form header, every item on its from/to locations, and item -1.
--    old = EXISTS vJobMain(id, item_id), new = the 95 test.
-- 2. current-job type: every pallet with a current_job_id, for both
--    inbound types t = 1, 2. The proc only uses it as
--    "current job type = this job's type", so that is what is compared.
--
-- Expected: diff_rows = 0 in both result rows.
-- =============================================================
USE IRPC_QTRACK;
SET NOCOUNT ON;

-- 1 -----------------------------------------------------------------------
IF OBJECT_ID('tempdb..#pairs') IS NOT NULL DROP TABLE #pairs;
CREATE TABLE #pairs (job_main_id INT NOT NULL, job_item_id INT NOT NULL, PRIMARY KEY (job_main_id, job_item_id));

INSERT INTO #pairs
SELECT DISTINCT x.job_main_id, x.job_item_id
FROM (
    SELECT jm.id AS job_main_id, ts.item_id AS job_item_id
    FROM dbo.tr_job_main jm JOIN IRPC_E_TRANSFER.dbo.VTransferSlip ts ON ts.header_id = jm.interface_job_id
    WHERE jm.job_type_id = 1 AND ts.item_id IS NOT NULL
    UNION ALL
    SELECT jm.id, rc.item_id
    FROM dbo.tr_job_main jm JOIN IRPC_E_TRANSFER.dbo.VReceiveForm rc ON rc.header_id = jm.interface_job_id
    WHERE jm.job_type_id = 2 AND rc.item_id IS NOT NULL
    UNION ALL
    SELECT fl.job_main_id, fl.interface_job_item_id
    FROM dbo.tr_job_from_location fl JOIN dbo.tr_job_main jm ON jm.id = fl.job_main_id
    WHERE jm.job_type_id IN (1, 2) AND fl.interface_job_item_id IS NOT NULL
    UNION ALL
    SELECT tl.job_main_id, tl.interface_job_item_id
    FROM dbo.tr_job_to_location tl JOIN dbo.tr_job_main jm ON jm.id = tl.job_main_id
    WHERE jm.job_type_id IN (1, 2) AND tl.interface_job_item_id IS NOT NULL
    UNION ALL
    SELECT jm.id, -1 FROM dbo.tr_job_main jm WHERE jm.job_type_id IN (1, 2)
) x;

IF OBJECT_ID('tempdb..#c1') IS NOT NULL DROP TABLE #c1;
SELECT p.job_main_id, p.job_item_id,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.vJobMain v
                         WHERE v.id = p.job_main_id AND v.item_id = p.job_item_id) THEN 1 ELSE 0 END AS old_ok,
       CASE WHEN EXISTS (
            SELECT 1
            FROM dbo.tr_job_main jm
            LEFT JOIN dbo.ct_job_type jt ON jt.id = jm.job_type_id
            LEFT JOIN dbo.ct_job_status js ON js.id = jm.job_status_id
            WHERE jm.id = p.job_main_id
              AND (jm.status_flag IS NULL OR jm.status_flag = 'A') AND (jm.is_active IS NULL OR jm.is_active = 'Y')
              AND (jt.is_active IS NULL OR jt.is_active = 'Y') AND (js.is_active IS NULL OR js.is_active = 'Y')
              AND (jt.status_flag IS NULL OR jt.status_flag = 'A') AND (js.status_flag IS NULL OR js.status_flag = 'A')
              AND (   (jm.job_type_id = 1 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferSlip ts
                                                   WHERE ts.header_id = jm.interface_job_id AND ts.item_id = p.job_item_id))
                   OR (jm.job_type_id = 2 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VReceiveForm rc
                                                   WHERE rc.header_id = jm.interface_job_id AND rc.item_id = p.job_item_id))))
            THEN 1 ELSE 0 END AS new_ok
INTO #c1
FROM #pairs p;

-- 2 -----------------------------------------------------------------------
IF OBJECT_ID('tempdb..#c2') IS NOT NULL DROP TABLE #c2;
SELECT p.id AS pallet_id, t.job_type_id,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.vJobMain v
                         WHERE v.id = p.current_job_id AND v.job_type_id = t.job_type_id) THEN 1 ELSE 0 END AS old_same,
       CASE WHEN EXISTS (
            SELECT 1
            FROM dbo.tr_job_main jm
            LEFT JOIN dbo.ct_job_type jt ON jt.id = jm.job_type_id
            LEFT JOIN dbo.ct_job_status js ON js.id = jm.job_status_id
            WHERE jm.id = p.current_job_id
              AND jm.job_type_id = t.job_type_id
              AND (jm.status_flag IS NULL OR jm.status_flag = 'A') AND (jm.is_active IS NULL OR jm.is_active = 'Y')
              AND (jt.is_active IS NULL OR jt.is_active = 'Y') AND (js.is_active IS NULL OR js.is_active = 'Y')
              AND (jt.status_flag IS NULL OR jt.status_flag = 'A') AND (js.status_flag IS NULL OR js.status_flag = 'A')
              AND (   (jm.job_type_id = 1 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VTransferSlip ts
                                                   WHERE ts.header_id = jm.interface_job_id AND ts.item_id IS NOT NULL))
                   OR (jm.job_type_id = 2 AND EXISTS (SELECT 1 FROM IRPC_E_TRANSFER.dbo.VReceiveForm rc
                                                   WHERE rc.header_id = jm.interface_job_id AND rc.item_id IS NOT NULL))))
            THEN 1 ELSE 0 END AS new_same
INTO #c2
FROM dbo.tr_pallet p
CROSS JOIN (VALUES (1), (2)) t(job_type_id)
WHERE p.current_job_id IS NOT NULL AND p.is_active = 'Y' AND p.status_flag = 'A';

SELECT '1 job+item check' AS test, COUNT(*) AS cases, SUM(old_ok) AS old_true, SUM(new_ok) AS new_true,
       SUM(CASE WHEN old_ok <> new_ok THEN 1 ELSE 0 END) AS diff_rows
FROM #c1
UNION ALL
SELECT '2 current job same type', COUNT(*), SUM(old_same), SUM(new_same),
       SUM(CASE WHEN old_same <> new_same THEN 1 ELSE 0 END)
FROM #c2;

-- rows that differ (expected: none)
SELECT 'job+item' AS test, job_main_id AS id, job_item_id AS item_or_type, old_ok AS old_, new_ok AS new_ FROM #c1 WHERE old_ok <> new_ok
UNION ALL
SELECT 'current type', pallet_id, job_type_id, old_same, new_same FROM #c2 WHERE old_same <> new_same;
