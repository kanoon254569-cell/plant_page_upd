/* =====================================================================
   Pallet Matching Service - pServiceGetGradeForMatching
   -----------------------------------------------------------------
   คืนรายชื่อ grade ที่ต้องมี package ratio พร้อมธง need_refresh
   บอกว่า package ratio ของ grade นั้นควรไปดึงใหม่จาก WMS หรือยัง
   (C# PalletMatchingService.RefreshRatiosAsync เอาเฉพาะ need_refresh = 1)

   grade มาจาก 2 แหล่ง
   1) tr_bag ที่ค้างรอจับคู่พาเลท เฉพาะ Auto Pallet (pallet_running_no IS NULL)
      (pending_bags = จำนวนถุง) -- 2026-10-29
   2) งานที่ยังไม่ปิด (job_status_id <> 5) ที่ "สร้างวันนี้" ของ
      TS / RC / TW / Internal Transfer / Request / Picking / Shipping / Loading
      (pending_bags = 0) -- error ส่วนนี้ไม่บล็อกแหล่งที่ 1

   need_refresh = 1 เมื่อ  ไม่มี grade ใน ct_grade_package_ratio
                      หรือ  unit_pallet IS NULL
                      (2026-11-06: ตัดเงื่อนไข last_update_datetime < 1 วัน ออก -- grade ที่มีค่าครบแล้วจะไม่ถูก refresh ทับ)

   dbResult  : status / message
   grade ในผลลัพธ์ (ตาม DB 2026-10-29)
     - จาก tr_bag : ตัดเฉพาะ ' SUB' -> 'SUB' ('1140U SUB' -> '1140USUB') space อื่นคงไว้
     - จาก job    : ตัด space ทั้งหมด
   JOIN ct_grade_package_ratio ด้วย grade ตรง ๆ (12_ stamp แบบตัด space ทั้งหมด)

   dbResult1 : grade , pending_bags , unit_ratio , unit_pallet , unit_code , need_refresh

   ไฟล์นี้ = เวอร์ชันล่าสุด (2026-10-27) -- แทนเวอร์ชันใน 45_ และ patch ใน 47_ / 84_ (รวม f*Job 3 param + KEEPFIXED PLAN แล้ว)
   (ห้ามรัน 45_ ซ้ำ จะทับเวอร์ชันนี้)

   Dependencies: 09_ct_grade_package_ratio.sql, dbo.f*Job (TS/RC/TW/IT/RQ/PK/SH/LD)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.pServiceGetGradeForMatching
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
        -- grade จาก bag : ตัดเฉพาะ ' SUB' -> 'SUB' -- ส่งไป WMS แบบนี้
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
                -- 2026-11-06: ไม่ refresh ค่าเดิมตามอายุแล้ว (เอา last_update_datetime < 1 วัน ออก)
                CAST(CASE WHEN r.grade IS NULL
                           OR r.unit_pallet IS NULL
                          THEN 1 ELSE 0 END AS BIT)
        FROM    #src s
        LEFT JOIN dbo.ct_grade_package_ratio r ON r.grade = s.grade;
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

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pServiceGetGradeForMatching;
