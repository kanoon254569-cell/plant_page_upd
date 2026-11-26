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
