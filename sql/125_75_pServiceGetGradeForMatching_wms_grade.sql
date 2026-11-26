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
