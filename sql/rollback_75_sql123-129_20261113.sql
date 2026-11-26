-- =============================================================
-- 10.31.1.75 rollback of deploy_75_sql123-129_20261113.sql (reverse order)
-- =============================================================


-- >>>>>>>>>> 129_rollback_pProcessUpdateInternalTransferJob_lock_advance_order.sql
-- 129 rollback : remove the sql/129 lock from pProcessUpdateInternalTransferJob
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessUpdateInternalTransferJob'));
DECLARE @old NVARCHAR(400) = N'is_advance_order = CASE WHEN @job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = @old
    + NCHAR(10) + N'                                        --  sql/129: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                        AND NOT (@job_status_id = 2 AND ISNULL(is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/129', @d) > 0
BEGIN
    IF CHARINDEX(@new, @d) = 0
        THROW 50130, 'pProcessUpdateInternalTransferJob: sql/129 block changed -- restore by hand', 1;

    SET @d = REPLACE(@d, @new, @old);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO


-- >>>>>>>>>> 128_rollback_pProcessApproveJob_lock_advance_order.sql
-- 128 rollback : remove the sql/128 lock from pProcessApproveJob
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessApproveJob'));
DECLARE @old NVARCHAR(400) = N'jm.is_advance_order = CASE WHEN jm.job_status_id IN (1, 2) AND @is_advance_order IN (''Y'', ''N'')';
DECLARE @new NVARCHAR(600) = @old
    + NCHAR(10) + N'                                    --  sql/128: approved as advance order -> stays ''Y'''
    + NCHAR(10) + N'                                    AND NOT (jm.job_status_id = 2 AND ISNULL(jm.is_advance_order, ''N'') = ''Y'')';

IF CHARINDEX(N'sql/128', @d) > 0
BEGIN
    IF CHARINDEX(@new, @d) = 0
        THROW 50129, 'pProcessApproveJob: sql/128 block changed -- restore by hand', 1;

    SET @d = REPLACE(@d, @new, @old);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO


-- >>>>>>>>>> 127_rollback_pProcessPickingPutAway_cleanup.sql
-- =============================================================
-- 127 rollback : put back the blocks 127_pProcessPickingPutAway_cleanup.sql
-- removed (reverse REPLACE on the live definition).
-- =============================================================

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessPickingPutAway'));
DECLARE @r TABLE (seq INT, old_text NVARCHAR(MAX), new_text NVARCHAR(MAX));

INSERT INTO @r (seq, old_text, new_text) VALUES
(1,
N'    IF NOT EXISTS (
        SELECT 1
        FROM dbo.tr_job_main jm
        INNER JOIN dbo.vPickingForm f ON f.header_id = jm.interface_job_id
        WHERE jm.id = @job_main_id
          AND jm.job_type_id = 4
          AND jm.status_flag = ''A''
          AND jm.is_active = ''Y''
          AND f.item_id = @job_item_id
    )',
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
    )'),
(2,
N'IF @complete_qty >= @job_qty
',
N'IF @complete_qty >= @job_qty AND ISNULL(@current_job_status_id, 0) <> 5
'),
(3,
N'        SELECT TOP (1)
            ss.Shipment_id AS shipment_id,',
N'        SELECT
            ss.Shipment_id AS shipment_id,'),
(4,
N'            fp.to_location_id,
            fp.code_pallet_id,',
N'            fp.to_location_id,
            fp.to_location_cc_desc,
            fp.code_pallet_id,');

--  LF from this file, then the server's line ends (CRLF on 10.31.1.75).
UPDATE @r SET old_text = REPLACE(old_text, NCHAR(13), N''), new_text = REPLACE(new_text, NCHAR(13), N'');
IF CHARINDEX(NCHAR(13) + NCHAR(10), @d) > 0
    UPDATE @r SET old_text = REPLACE(old_text, NCHAR(10), NCHAR(13) + NCHAR(10)),
                  new_text = REPLACE(new_text, NCHAR(10), NCHAR(13) + NCHAR(10));

--  Not applied = the dbResult1 column is still there (line-end independent).
IF CHARINDEX(N'fp.to_location_cc_desc', @d) > 0
BEGIN
    PRINT 'pProcessPickingPutAway: 127 not applied, nothing to roll back';
    RETURN;
END

DECLARE @bad INT = (
    SELECT TOP (1) seq FROM @r
    WHERE (LEN(@d) - LEN(REPLACE(@d, old_text, N''))) / NULLIF(LEN(old_text), 0) <> 1
    ORDER BY seq
);
IF @bad IS NOT NULL
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('pProcessPickingPutAway rollback: block ', @bad, ' not found exactly once -- nothing changed');
    THROW 50128, @msg, 1;
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


-- >>>>>>>>>> 126_rollback_pProcessGetPickingPrepareUpdate.sql
-- 126 rollback : drop pProcessGetPickingPrepareUpdate
DROP PROCEDURE IF EXISTS dbo.pProcessGetPickingPrepareUpdate;
GO


-- >>>>>>>>>> rollback_75_pServiceGetGradeForMatching_20261113.sql
-- =============================================================
-- rollback (10.31.1.75) : pServiceGetGradeForMatching as it was on 75
-- before 125_75 (no wms_grade, no sql/124 block, daily refresh commented).
-- =============================================================

CREATE OR ALTER PROCEDURE [dbo].[pServiceGetGradeForMatching]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = 'success', @message NVARCHAR(400) = 'ok';

    CREATE TABLE #grade
    (
        grade        VARCHAR(30) NULL,
        pending_bags INT         NULL,
        unit_ratio   INT         NULL,
        unit_pallet  INT         NULL,
        unit_code    VARCHAR(20) NULL,
        need_refresh BIT         NULL
    );

    CREATE TABLE #src (grade VARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, pending_bags INT NOT NULL);

    BEGIN TRY
        -- grade ตามที่ส่งมา (ไม่ตัด space) -- ส่งไป WMS แบบนี้
        -- grades with bags waiting for a pallet -- เฉพาะ Auto Pallet (pallet_running_no IS NULL)
        INSERT INTO #src (grade, pending_bags)
        SELECT REPLACE(b.grade, ' SUB', 'SUB'), COUNT(*)
        FROM   dbo.tr_bag b
        WHERE  b.bag_status_id = 1
          AND  b.pallet_id IS NULL
          AND  b.pallet_running_no IS NULL
          AND  b.is_active   = 'Y'
          AND  b.status_flag = 'A'
          AND  REPLACE(b.grade, ' SUB', 'SUB') <> ''
        GROUP BY REPLACE(b.grade, ' SUB', 'SUB');

        -- grades of open inbound jobs (new) -- failure here must not block the bag grades
        BEGIN TRY
            INSERT INTO #src (grade, pending_bags)
            SELECT DISTINCT LEFT(REPLACE(x.grade, ' ', ''), 30) COLLATE DATABASE_DEFAULT, 0
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
              AND NOT EXISTS (SELECT 1 FROM #src s
                              WHERE s.grade = LEFT(REPLACE(x.grade, ' ', ''), 30) COLLATE DATABASE_DEFAULT) OPTION (KEEPFIXED PLAN);
        END TRY
        BEGIN CATCH
            SET @message = CONCAT('ok (job grades skipped: ', ERROR_MESSAGE(), ')');
        END CATCH

        INSERT INTO #grade (grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh)
        SELECT  s.grade,
                s.pending_bags,
                r.unit_ratio,
                r.unit_pallet,
                r.unit_code,
                CAST(CASE WHEN r.grade IS NULL
                           OR r.unit_pallet IS NULL
                           --OR r.last_update_datetime < DATEADD(DAY, -1, GETDATE())
                          THEN 1 ELSE 0 END AS BIT)
        FROM    #src s
        LEFT JOIN dbo.ct_grade_package_ratio r ON r.grade = s.grade;      -- both sides without spaces
    END TRY
    BEGIN CATCH
        SET @status  = 'error';
        SET @message = ERROR_MESSAGE();
    END CATCH

    SELECT @status AS status, @message AS message;                         -- dbResult
    SELECT grade, pending_bags, unit_ratio, unit_pallet, unit_code, need_refresh
    FROM   #grade
    ORDER BY grade;                                                        -- dbResult1
END
GO


-- >>>>>>>>>> 123_rollback_grade_package_cost_center.sql
-- =============================================================
-- 123 rollback : undo 123_grade_package_cost_center.sql
-- =============================================================

SET XACT_ABORT ON;
GO

-- 3. pProcessGetJobList ---------------------------------------
DECLARE @d   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pProcessGetJobList'));
DECLARE @old NVARCHAR(400) = N'NULLIF(LTRIM(RTRIM(jm.product_cc COLLATE DATABASE_DEFAULT)), ''''),';
DECLARE @new NVARCHAR(1500) = @old
    + NCHAR(10) + N'            --  grade master cost center (sql/123, ct_grade_package_ratio.cost_center),'
    + NCHAR(10) + N'            --  the CC the job card shows before Approve -- ahead of the raw pd_cc_code.'
    + NCHAR(10) + N'            NULLIF(LTRIM(RTRIM((SELECT TOP 1 gpr.cost_center FROM dbo.ct_grade_package_ratio gpr'
    + NCHAR(10) + N'                WHERE gpr.grade = REPLACE(dj.grade COLLATE DATABASE_DEFAULT, '' '', '''')))), ''''),';

IF CHARINDEX(N'gpr.cost_center', @d) > 0
BEGIN
    IF CHARINDEX(@new, @d) = 0
        THROW 50011, 'pProcessGetJobList: patched block changed since 123 -- restore by hand', 1;

    SET @d = REPLACE(@d, @new, @old);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE %PROC%', @d), LEN(N'CREATE'), N'ALTER');
    EXEC sys.sp_executesql @d;
END
GO

-- 2. pServiceStampGradePackageRatio (definition before 123) ----
CREATE OR ALTER PROCEDURE dbo.pServiceStampGradePackageRatio
    @grade       VARCHAR(30),
    @unit_ratio  INT         = NULL,
    @unit_pallet INT         = NULL,
    @unit_code   VARCHAR(20) = NULL
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

        MERGE dbo.ct_grade_package_ratio AS t
        USING (SELECT @grade AS grade) AS s
           ON (t.grade = s.grade)
        WHEN MATCHED THEN
            UPDATE SET unit_ratio           = @unit_ratio,
                       unit_pallet          = @unit_pallet,
                       unit_code            = @unit_code,
                       last_update_datetime = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (grade, unit_ratio, unit_pallet, unit_code, last_update_datetime)
            VALUES (@grade, @unit_ratio, @unit_pallet, @unit_code, GETDATE());

        SELECT 'success' AS status, 'stamped' AS message;                  -- dbResult
        SELECT grade, unit_ratio, unit_pallet, unit_code, last_update_datetime
        FROM   dbo.ct_grade_package_ratio
        WHERE  grade = @grade;                                             -- dbResult1
    END TRY
    BEGIN CATCH
        SELECT 'error' AS status, ERROR_MESSAGE() AS message;
    END CATCH
END
GO

-- 1. -----------------------------------------------------------
IF COL_LENGTH('dbo.ct_grade_package_ratio', 'cost_center') IS NOT NULL
    ALTER TABLE dbo.ct_grade_package_ratio DROP COLUMN cost_center;
GO

