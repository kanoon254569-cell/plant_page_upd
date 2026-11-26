-- =============================================================
-- 10.31.1.75 deploy -- sql/123 to sql/129 (sql/130 already on 75)
-- =============================================================
-- Order matters (125_75 needs the 123 column). Every part is re-runnable:
-- patches skip themselves once applied, new objects use CREATE OR ALTER.
--   123     ct_grade_package_ratio.cost_center + stamp proc + job list Product CC filter
--   125_75  pServiceGetGradeForMatching (124 job grades + 125 wms_grade), 75 refresh rule kept
--   126     pProcessGetPickingPrepareUpdate (advance-order Picking: held-back DO Preparing)
--   127     pProcessPickingPutAway cleanup (CRLF-aware)
--   128     pProcessApproveJob: advance order locked once approved
--   129     pProcessUpdateInternalTransferJob: same lock for WH03
-- (124 is not run on its own: 125_75 already contains its block.)
-- Rollback: rollback_75_sql123-129_20261113.sql
-- =============================================================


-- >>>>>>>>>> 123_grade_package_cost_center.sql
-- =============================================================
-- 123 : ct_grade_package_ratio.cost_center (grade master Product CC)
-- =============================================================
-- Problem: the job list's Product CC filter (pProcessGetJobList,
-- @product_ccs) matched COALESCE(tr_job_main.product_cc, item pd_cc_code).
-- Before Approve, product_cc is NULL and pd_cc_code is the raw WMS "from"
-- CC (eg. 0005), while the API shows the WMS grade master's cost_center
-- (eg. 1600). So a job shown as "CC 1600" was not found by 1600.
--
-- Fix: the Hangfire job sync-grade-package-ratio (PalletMatchingService.
-- RefreshRatioAsync) also reads the WMS grade master and passes the
-- grade's cost_center to pServiceStampGradePackageRatio, which keeps it
-- in ct_grade_package_ratio.cost_center. pProcessGetJobList's Product CC
-- filter uses it before pd_cc_code.
--
--   1. ct_grade_package_ratio.cost_center          (new column)
--   2. pServiceStampGradePackageRatio @cost_center (new param)
--   3. pProcessGetJobList                          (patched in place:
--      REPLACE on one unique line, keeps the rest of the live definition)
--
-- Rollback: 123_rollback_grade_package_cost_center.sql
-- =============================================================

SET XACT_ABORT ON;
GO

-- 1. ----------------------------------------------------------
IF COL_LENGTH('dbo.ct_grade_package_ratio', 'cost_center') IS NULL
    ALTER TABLE dbo.ct_grade_package_ratio ADD cost_center VARCHAR(50) NULL;
GO

-- 2. ----------------------------------------------------------
--  @cost_center NULL (grade master call failed / no exact grade) keeps
--  the value already stamped, so a WMS hiccup doesn't wipe it.
CREATE OR ALTER PROCEDURE dbo.pServiceStampGradePackageRatio
    @grade       VARCHAR(30),
    @unit_ratio  INT         = NULL,
    @unit_pallet INT         = NULL,
    @unit_code   VARCHAR(20) = NULL,
    @cost_center VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @grade IS NULL OR LTRIM(RTRIM(@grade)) = ''
        BEGIN
            SELECT 'error' AS status, 'grade is required' AS message;
            RETURN;
        END

        -- เก็บ grade แบบตัด space ออกทั้งหมด เช่น '1100NK SUB' -> '1100NKSUB'
        SET @grade = REPLACE(@grade, ' ', '');
        SET @cost_center = NULLIF(LTRIM(RTRIM(@cost_center)), '');

        MERGE dbo.ct_grade_package_ratio AS t
        USING (SELECT @grade AS grade) AS s
           ON (t.grade = s.grade)
        WHEN MATCHED THEN
            UPDATE SET unit_ratio           = @unit_ratio,
                       unit_pallet          = @unit_pallet,
                       unit_code            = @unit_code,
                       cost_center          = COALESCE(@cost_center, t.cost_center),
                       last_update_datetime = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (grade, unit_ratio, unit_pallet, unit_code, cost_center, last_update_datetime)
            VALUES (@grade, @unit_ratio, @unit_pallet, @unit_code, @cost_center, GETDATE());

        SELECT 'success' AS status, 'stamped' AS message;                  -- dbResult
        SELECT grade, unit_ratio, unit_pallet, unit_code, cost_center, last_update_datetime
        FROM   dbo.ct_grade_package_ratio
        WHERE  grade = @grade;                                             -- dbResult1
    END TRY
    BEGIN CATCH
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END
GO

-- 3. ----------------------------------------------------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @old NVARCHAR(400) = N'NULLIF(LTRIM(RTRIM(jm.product_cc COLLATE DATABASE_DEFAULT)), ''''),';
DECLARE @new NVARCHAR(1500) = @old
    + NCHAR(10) + N'            --  grade master cost center (sql/123, ct_grade_package_ratio.cost_center),'
    + NCHAR(10) + N'            --  the CC the job card shows before Approve -- ahead of the raw pd_cc_code.'
    + NCHAR(10) + N'            NULLIF(LTRIM(RTRIM((SELECT TOP 1 gpr.cost_center FROM dbo.ct_grade_package_ratio gpr'
    + NCHAR(10) + N'                WHERE gpr.grade = REPLACE(dj.grade COLLATE DATABASE_DEFAULT, '' '', '''')))), ''''),';

IF CHARINDEX(N'gpr.cost_center', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50002, 'pProcessGetJobList: anchor line not found exactly once', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO


-- >>>>>>>>>> 125_75_pServiceGetGradeForMatching_wms_grade.sql
-- =============================================================
-- 125 (10.31.1.75 variant) : pServiceGetGradeForMatching
--   = sql/124 (grades of not-yet-Approved jobs, last 90 days)
--   + sql/125 (wms_grade: send WMS the grade as WMS spells it)
-- =============================================================
-- Same as 125_pServiceGetGradeForMatching_wms_grade.sql except the
-- need_refresh rule: on 10.31.1.75 the daily refresh line is commented out
-- (grades with a ratio are never refreshed). Kept that way; the only
-- addition is that a grade whose ct_grade_package_ratio.cost_center
-- (sql/123) is still empty is retried once a day, so existing rows get
-- their cost center and a grade WMS has none for isn't hit every run.
-- Needs sql/123 (cost_center column) first.
-- Rollback: rollback_75_pServiceGetGradeForMatching_20261113.sql
-- =============================================================

CREATE OR ALTER PROCEDURE [dbo].[pServiceGetGradeForMatching]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = 'ok';

    CREATE TABLE #grade
    (
        grade        VARCHAR(30) NULL,
        wms_grade    VARCHAR(50) NULL,
        pending_bags INT         NULL,
        unit_ratio   INT         NULL,
        unit_pallet  INT         NULL,
        unit_code    VARCHAR(20) NULL,
        need_refresh BIT         NULL
    );

    --  grade = key without spaces, wms_grade = the spelling sent to WMS (sql/125)
    CREATE TABLE #src
    (
        grade        VARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        wms_grade    VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL,
        pending_bags INT NOT NULL
    );

    BEGIN TRY
        -- grades with bags waiting for a pallet -- เฉพาะ Auto Pallet (pallet_running_no IS NULL)
        INSERT INTO #src (grade, wms_grade, pending_bags)
        SELECT LEFT(REPLACE(b.grade, ' ', ''), 30),
               MIN(LEFT(REPLACE(LTRIM(RTRIM(b.grade)), ' SUB', 'SUB'), 50)),
               COUNT(*)
        FROM   dbo.tr_bag b
        WHERE  b.bag_status_id = 1
          AND  b.pallet_id IS NULL
          AND  b.pallet_running_no IS NULL
          AND  b.is_active   = 'Y'
          AND  b.status_flag = 'A'
          AND  REPLACE(b.grade, ' ', '') <> ''
        GROUP BY LEFT(REPLACE(b.grade, ' ', ''), 30);

        -- grades of open jobs created today -- failure here must not block the bag grades
        BEGIN TRY
            INSERT INTO #src (grade, wms_grade, pending_bags)
            SELECT g.grade, MIN(g.wms_grade), 0
            FROM (
                SELECT LEFT(REPLACE(x.grade, ' ', ''), 30) COLLATE DATABASE_DEFAULT AS grade,
                       LEFT(REPLACE(LTRIM(RTRIM(x.grade)), ' SUB', 'SUB'), 50) COLLATE DATABASE_DEFAULT AS wms_grade
                FROM (
                    SELECT grade, job_status_id FROM dbo.fTransferSlipJob(NULL, CAST(GETDATE() AS DATE), NULL)
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fReceiveJob(NULL, CAST(GETDATE() AS DATE), NULL)
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fTransferWhJob(NULL, CAST(GETDATE() AS DATE), NULL)
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fInternalTransferJob(NULL, CAST(GETDATE() AS DATE))
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fRequestJob(NULL, CAST(GETDATE() AS DATE), NULL)
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fPickingJob(NULL, CAST(GETDATE() AS DATE), NULL)
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fShippingJob(NULL, CAST(GETDATE() AS DATE), NULL)
                    UNION ALL
                    SELECT grade, job_status_id FROM dbo.fLoadingJob(NULL, CAST(GETDATE() AS DATE))
                ) x
                WHERE x.grade IS NOT NULL
                  AND LTRIM(RTRIM(x.grade)) <> ''
                  AND ISNULL(x.job_status_id, 0) <> 5
            ) g
            WHERE NOT EXISTS (SELECT 1 FROM #src s WHERE s.grade = g.grade)
            GROUP BY g.grade
            OPTION (KEEPFIXED PLAN);
        END TRY
        BEGIN CATCH
            SET @message = CONCAT('ok (job grades skipped: ', ERROR_MESSAGE(), ')');
        END CATCH

        -- sql/124: grades of jobs (last 90 days) not Approved yet (tr_job_main.product_cc
        -- empty) -- their Product CC filter uses ct_grade_package_ratio.cost_center.
        -- failure here must not block the other grades
        BEGIN TRY
            DECLARE @cc_from DATE = DATEADD(DAY, -90, CAST(GETDATE() AS DATE));
            DECLARE @cc_to   DATE = CAST(GETDATE() AS DATE);

            INSERT INTO #src (grade, wms_grade, pending_bags)
            SELECT g.grade, MIN(g.wms_grade), 0
            FROM (
                SELECT LEFT(REPLACE(x.grade, ' ', ''), 30) COLLATE DATABASE_DEFAULT AS grade,
                       LEFT(REPLACE(LTRIM(RTRIM(x.grade)), ' SUB', 'SUB'), 50) COLLATE DATABASE_DEFAULT AS wms_grade
                FROM (
                    SELECT id, grade FROM dbo.fTransferSlipJob(NULL, @cc_from, @cc_to)
                    UNION ALL SELECT id, grade FROM dbo.fReceiveJob(NULL, @cc_from, @cc_to)
                    UNION ALL SELECT id, grade FROM dbo.fRequestJob(NULL, @cc_from, @cc_to)
                    UNION ALL SELECT id, grade FROM dbo.fPickingJob(NULL, @cc_from, @cc_to)
                    UNION ALL SELECT id, grade FROM dbo.fShippingJob(NULL, @cc_from, @cc_to)
                    UNION ALL SELECT id, grade FROM dbo.fSpecialJob(NULL, @cc_from, @cc_to)
                    UNION ALL SELECT id, grade FROM dbo.fBrokenBagJob(NULL, @cc_from, @cc_to)
                ) x
                INNER JOIN dbo.tr_job_main jm
                    ON jm.id = x.id
                WHERE NULLIF(LTRIM(RTRIM(jm.product_cc)), '') IS NULL
                  AND NULLIF(LTRIM(RTRIM(x.grade)), '') IS NOT NULL
            ) g
            WHERE NOT EXISTS (SELECT 1 FROM #src s WHERE s.grade = g.grade)
            GROUP BY g.grade
            OPTION (KEEPFIXED PLAN);
        END TRY
        BEGIN CATCH
            SET @message = CONCAT(@message, ' (job product cc grades skipped: ', ERROR_MESSAGE(), ')');
        END CATCH

        INSERT INTO #grade (grade, wms_grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh)
        SELECT  s.grade,
                s.wms_grade,
                s.pending_bags,
                r.unit_ratio,
                r.unit_pallet,
                r.unit_code,
                CAST(CASE WHEN r.grade IS NULL
                           OR r.unit_pallet IS NULL
                           --OR r.last_update_datetime < DATEADD(DAY, -1, GETDATE())
                           --  sql/123 on 10.31.1.75: no cost center yet -> retry once a day
                           OR (r.cost_center IS NULL AND r.last_update_datetime < DATEADD(DAY, -1, GETDATE()))
                          THEN 1 ELSE 0 END AS BIT)
        FROM    #src s
        LEFT JOIN dbo.ct_grade_package_ratio r ON r.grade = s.grade;      -- both sides without spaces
    END TRY
    BEGIN CATCH
        SET @status  = 'error';
        SET @message = ERROR_MESSAGE();
    END CATCH

    SELECT @status AS status, @message AS message;                         -- dbResult
    SELECT grade, wms_grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh
    FROM   #grade
    ORDER BY grade;                                                        -- dbResult1
END
GO


-- >>>>>>>>>> 126_pProcessGetPickingPrepareUpdate.sql
-- =============================================================
-- 126 : pProcessGetPickingPrepareUpdate
-- =============================================================
-- Advance-order Picking jobs now hold back BOTH completion sends -- the
-- iLogistic DO Preparing update (ProcessWarehousePrepareUpdate) and WMS+
-- WMS251 -- until the user presses the send button in job detail
-- (PATCH job/{id}/wms-plus/resend). pProcessPickingPutAway only returns
-- the iLogistic payload (its dbResult1) on the call that completes the
-- job, so this rebuilds the same row later from the finished job.
--
-- dbResult  : status, message
-- dbResult1 : same columns as pProcessPickingPutAway's dbResult1 (after
--             sql/127), only when
--             the job is a Picking job (type 4), Complete (status 5), its
--             shipment/DO is found in VsearchStatus, and no successful
--             "Do Preparing" log exists yet (never sent twice).
--
-- Rollback: 126_rollback_pProcessGetPickingPrepareUpdate.sql
-- =============================================================

CREATE OR ALTER PROCEDURE dbo.pProcessGetPickingPrepareUpdate
    @job_main_id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.tr_job_main WHERE id = @job_main_id AND job_type_id = 4 AND job_status_id = 5)
    BEGIN
        SELECT 'not_applicable' AS status, 'Not a completed Picking job' AS message;
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM dbo.tr_ilogistic_interface_log
        WHERE job_main_id = @job_main_id
          AND mode = 'Do Preparing'
          AND is_success = 'Y'
          AND ISNULL(status_flag, 'A') = 'A'
    )
    BEGIN
        SELECT 'not_applicable' AS status, 'DO Preparing already sent' AS message;
        RETURN;
    END

    SELECT 'success' AS status, 'OK' AS message;                           -- dbResult

    SELECT TOP 1
        ss.Shipment_id AS shipment_id,
        ss.DO_id AS do_id,
        fp.job_start_datetime,
        fp.job_end_datetime,
        fp.to_location_id,
        fp.code_pallet_id,
        fp.pallet_lot,
        fp.pallet_qty,
        fp.pallet_weight,
        fp.special_type_package_id,
        176 AS user_id                                                     -- same as pProcessPickingPutAway
    FROM dbo.fPickingJob(@job_main_id, NULL, NULL) fp
    INNER JOIN [IRPC].[dbo].[VsearchStatus] ss
        ON ss.Shipment_No = fp.shipment_no COLLATE Thai_CI_AI
        AND ss.Deliver_No = fp.do_no COLLATE Thai_CI_AI;                   -- dbResult1
END
GO


-- >>>>>>>>>> 127_pProcessPickingPutAway_cleanup.sql
-- =============================================================
-- 127 : pProcessPickingPutAway -- remove duplicate / unused parts
-- =============================================================
-- Behaviour unchanged. Patches the live definition in place (each old
-- block must be found exactly once, else nothing is changed):
--
--   1. Job check ran twice: a plain tr_job_main existence check
--      (is_active = 'Y' AND status_flag = 'A'), then the same job joined
--      to vPickingForm with looser "IS NULL OR" flags. One check now,
--      with the strict flags of the first (same result; no Picking job
--      has NULL flags).
--   2. Completion test "AND ISNULL(@current_job_status_id, 0) <> 5": a job
--      already at status 5 RETURNs right after the UPDLOCK read at the top
--      of the transaction, so this was always true.
--   3. dbResult1 (iLogistic DO Preparing payload): to_location_cc_desc is
--      never read (JobService.BuildPickingPrepareCompletePayload), and only
--      Rows[0] is used -> TOP (1), column dropped.
--
-- Kept on purpose: the Pre-zone over-qty check (@loc_qty). Most Pre-zone
-- to-locations are added here with qty 0 (check skipped), but some carry a
-- planned qty (3 rows on 10.31.1.74), so the check still runs for those.
--
-- Rollback: 127_rollback_pProcessPickingPutAway_cleanup.sql
-- =============================================================

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
DECLARE @r TABLE (seq INT, old_text NVARCHAR(MAX), new_text NVARCHAR(MAX));

INSERT INTO @r (seq, old_text, new_text) VALUES
(1,
N'    IF NOT EXISTS (
        SELECT 1 FROM dbo.tr_job_main
        WHERE id = @job_main_id AND is_active = ''Y'' AND status_flag = ''A''
    )
    OR NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND (jm.status_flag IS NULL OR jm.status_flag = ''A'')
          AND (jm.is_active IS NULL OR jm.is_active = ''Y'')
          AND f.item_id = @job_item_id
    )',
N'    IF NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND jm.status_flag = ''A''
          AND jm.is_active = ''Y''
          AND f.item_id = @job_item_id
    )'),
(2,
N'IF @complete_qty >= @job_qty AND ISNULL(@current_job_status_id, 0) <> 5',
N'IF @complete_qty >= @job_qty'),
(3,
N'        SELECT
            ss.Shipment_id AS shipment_id,',
N'        SELECT TOP (1)
            ss.Shipment_id AS shipment_id,'),
(4,
N'            fp.to_location_cc_desc,
',
N'');

--  Normalise this file's own line ends to LF, then use the server's: CRLF
--  when the stored definition has CR (10.31.1.75), else LF (10.31.1.74).
UPDATE @r SET old_text = REPLACE(old_text, NCHAR(13), N''), new_text = REPLACE(new_text, NCHAR(13), N'');
IF CHARINDEX(NCHAR(13) + NCHAR(10), @d) > 0
    UPDATE @r SET old_text = REPLACE(old_text, NCHAR(10), NCHAR(13) + NCHAR(10)),
                  new_text = REPLACE(new_text, NCHAR(10), NCHAR(13) + NCHAR(10));

--  Applied = the unused dbResult1 column is gone (line-end independent).
IF CHARINDEX(N'fp.to_location_cc_desc', @d) = 0
BEGIN
    PRINT 'pProcessPickingPutAway: 127 already applied';
    RETURN;
END

DECLARE @bad INT = (
    SELECT TOP (1) seq FROM @r
    WHERE (LEN(@d) - LEN(REPLACE(@d, old_text, N''))) / NULLIF(LEN(old_text), 0) <> 1
    ORDER BY seq
);
IF @bad IS NOT NULL
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('pProcessPickingPutAway: block ', @bad, ' not found exactly once -- nothing changed');
    THROW 50127, @msg, 1;
END

DECLARE @seq INT = 1;
WHILE @seq <= (SELECT MAX(seq) FROM @r)
BEGIN
    SELECT @d = REPLACE(@d, old_text, new_text) FROM @r WHERE seq = @seq;
    SET @seq += 1;
END

SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
EXEC sys.sp_executesql @d;
GO


-- >>>>>>>>>> 128_pProcessApproveJob_lock_advance_order.sql
-- =============================================================
-- 128 : pProcessApproveJob -- advance order locked once approved with it
-- =============================================================
-- tr_job_main.is_advance_order could be changed on every approve while
-- the job was Pending (1) or WH Approved (2), so a job approved as an
-- advance order could be saved back to 'N' later. Now, once the job is
-- WH Approved (2) with is_advance_order = 'Y', later approves keep 'Y'.
-- (Pending -> approve with 'Y' still works; a job approved with 'N' can
-- still be switched on while it is WH Approved.) job-detail disables the
-- chip the same way (canSetAdvanceOrder).
--
-- Patched in place on one unique block of the live definition.
-- Rollback: 128_rollback_pProcessApproveJob_lock_advance_order.sql
-- =============================================================

DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessApproveJob'));
DECLARE @old NVARCHAR(400) = N'jm.is_advance_order = CASE WHEN jm.job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = N'jm.is_advance_order = CASE WHEN jm.job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')'
    + NCHAR(10) + N'                                    --  sql/128: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                    AND NOT (jm.job_status_id = 2 AND ISNULL(jm.is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/128', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50128, 'pProcessApproveJob: anchor not found exactly once -- nothing changed', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO


-- >>>>>>>>>> 129_pProcessUpdateInternalTransferJob_lock_advance_order.sql
-- =============================================================
-- 129 : pProcessUpdateInternalTransferJob -- advance order locked once approved
-- =============================================================
-- WH03 counterpart of sql/128 (pProcessApproveJob, used by WH01/02/04).
-- pProcessCreateInternalTransferJob saves the job straight to WH Approved
-- (2); before this, every later edit could still flip is_advance_order back
-- to 'N'. Now a WH Approved job saved with 'Y' keeps 'Y'.
-- job-wh-internal-transfer-detail disables the chip the same way.
--
-- Patched in place on one unique block of the live definition.
-- Rollback: 129_rollback_pProcessUpdateInternalTransferJob_lock_advance_order.sql
-- =============================================================

DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessUpdateInternalTransferJob'));
DECLARE @old NVARCHAR(400) = N'is_advance_order = CASE WHEN @job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = @old
    + NCHAR(10) + N'                                        --  sql/129: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                        AND NOT (@job_status_id = 2 AND ISNULL(is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/129', @d) = 0
BEGIN
    IF (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old) <> 1
        THROW 50129, 'pProcessUpdateInternalTransferJob: anchor not found exactly once -- nothing changed', 1;

    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO

