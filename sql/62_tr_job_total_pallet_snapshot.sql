-- =============================================================
-- 62_tr_job_total_pallet_snapshot.sql  (IRPC_QTRACK)
-- =============================================================
-- Lets the board see that a job's source data changed in WMS Plus (or in
-- the delivery) after total_pallet was calculated on approve.
--
--   tr_job_total_pallet_snapshot             grade / qty / CC each item had
--                                            when the approve calculated it
--                                            (written by pProcessUpdateJobTotalPallet,
--                                            one set per job, replaced on every
--                                            approve / Save)
--   pProcessGetJobTotalPalletSourceChanged   compares the snapshot with the
--                                            current source rows for a batch of
--                                            jobs (job-list page / job-detail)
--
-- The current rows are read the same way pProcessGetJobItemsForTotalPallet
-- reads them (manual-mode TS / RC skipped). Jobs approved before this is
-- deployed have no snapshot and are never reported.
--
-- Run order: this file, then INSTALL_QR_CODE_SYSTEM_MAIN_API
-- sql/pProcessJobTotalPallet.sql (its pProcessUpdateJobTotalPallet writes
-- the snapshot table created here).
-- =============================================================
USE IRPC_QTRACK;
GO

IF OBJECT_ID('dbo.tr_job_total_pallet_snapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.tr_job_total_pallet_snapshot
    (
        id              INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_tr_job_total_pallet_snapshot PRIMARY KEY,
        job_main_id     INT            NOT NULL,
        item_id         INT            NOT NULL,
        grade           VARCHAR(50)    NULL,
        qty             DECIMAL(18, 3) NULL,
        cost_center     VARCHAR(50)    NULL,
        total_pallet    INT            NULL,
        create_user_id  INT            NULL,
        create_datetime DATETIME       NOT NULL CONSTRAINT DF_tr_job_total_pallet_snapshot_create_datetime DEFAULT (GETDATE())
    );

    CREATE INDEX IX_tr_job_total_pallet_snapshot_job ON dbo.tr_job_total_pallet_snapshot (job_main_id, item_id);
END
GO

--  @job_main_ids = '101,102,...'. One row per item whose grade / qty / CC
--  differs from the snapshot (change_type 'changed'), was removed from the
--  source ('removed') or added to it ('added'). No row = unchanged.
CREATE OR ALTER PROCEDURE [dbo].[pProcessGetJobTotalPalletSourceChanged]
    @job_main_ids NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#jm') IS NOT NULL DROP TABLE #jm;
    IF OBJECT_ID('tempdb..#cur') IS NOT NULL DROP TABLE #cur;

    SELECT jm.id AS job_main_id, jm.job_type_id, jm.interface_job_id AS header_id,
           NULLIF(LTRIM(RTRIM(jm.product_cc)), '') AS product_cc
    INTO #jm
    FROM dbo.tr_job_main AS jm
    WHERE jm.id IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@job_main_ids, ''), ','))
      AND jm.status_flag = 'A'
      AND EXISTS (SELECT 1 FROM dbo.tr_job_total_pallet_snapshot AS s WHERE s.job_main_id = jm.id);

    CREATE TABLE #cur
    (
        job_main_id INT,
        item_id     INT,
        grade       VARCHAR(50) COLLATE DATABASE_DEFAULT,
        qty         DECIMAL(18, 3),
        cost_center VARCHAR(50) COLLATE DATABASE_DEFAULT
    );

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms COLLATE DATABASE_DEFAULT)), ''))
    FROM #jm AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VTransferSlip AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 1 AND ISNULL(v.q_track_mode, 'A') <> 'M';

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms COLLATE DATABASE_DEFAULT)), ''))
    FROM #jm AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VReceiveForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 2 AND ISNULL(v.q_track_mode, 'A') <> 'M';

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(jm.product_cc, NULLIF(LTRIM(RTRIM(v.from_cc_code_wms COLLATE DATABASE_DEFAULT)), ''))
    FROM #jm AS jm
    INNER JOIN IRPC_E_TRANSFER.dbo.VRequestForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 3;

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(NULLIF(LTRIM(RTRIM(v.cc_code)), ''), jm.product_cc)
    FROM #jm AS jm
    INNER JOIN dbo.vPickingForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 4;

    INSERT INTO #cur
    SELECT jm.job_main_id, v.item_id, v.grade, v.qty,
           COALESCE(NULLIF(LTRIM(RTRIM(v.cc_code)), ''), jm.product_cc)
    FROM #jm AS jm
    INNER JOIN dbo.vShippingForm AS v ON v.header_id = jm.header_id
    WHERE jm.job_type_id = 5;

    SELECT
        COALESCE(s.job_main_id, c.job_main_id) AS job_main_id,
        COALESCE(s.item_id, c.item_id) AS item_id,
        CASE WHEN c.item_id IS NULL THEN 'removed'
             WHEN s.item_id IS NULL THEN 'added'
             ELSE 'changed' END AS change_type,
        s.grade AS old_grade, s.qty AS old_qty, s.cost_center AS old_cost_center, s.total_pallet AS old_total_pallet,
        c.grade AS new_grade, c.qty AS new_qty, c.cost_center AS new_cost_center,
        s.create_datetime AS calc_datetime
    FROM (SELECT * FROM dbo.tr_job_total_pallet_snapshot WHERE job_main_id IN (SELECT job_main_id FROM #jm)) AS s
    FULL OUTER JOIN #cur AS c ON c.job_main_id = s.job_main_id AND c.item_id = s.item_id
    WHERE c.item_id IS NULL
       OR s.item_id IS NULL
       OR ISNULL(s.grade, '') <> ISNULL(c.grade, '')
       OR ISNULL(s.qty, -1) <> ISNULL(c.qty, -1)
       OR ISNULL(s.cost_center, '') <> ISNULL(c.cost_center, '')
    ORDER BY job_main_id, item_id;
END
GO
