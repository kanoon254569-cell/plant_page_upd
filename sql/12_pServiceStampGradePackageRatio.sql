/* =====================================================================
   Pallet Matching Service - pServiceStampGradePackageRatio
   -----------------------------------------------------------------
   Upsert package ratio ของ 1 grade ลง ct_grade_package_ratio พร้อม stamp
   last_update_datetime = GETDATE() -- เรียกโดย C# (PalletMatchingService.
   RefreshRatiosAsync) หลังยิง WMS+ API (GetMasterGradePackage) สำเร็จ
   เพราะ T-SQL เรียก HTTP ไม่ได้ตรง ๆ
   ถ้า unit_ratio / unit_pallet / unit_code เป็น NULL ทั้งหมด (WMS ไม่มีข้อมูล)
   -> stamp ค่าเริ่มต้น unit_ratio = 25, unit_pallet = 40, unit_code = 'BG' (2026-11-06)

   dbResult  : status / message
   dbResult1 : grade, unit_ratio, unit_pallet, unit_code, last_update_datetime

   Dependencies: 09_ct_grade_package_ratio.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

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

        -- 2026-11-06: WMS ไม่มีข้อมูล package ratio ของ grade นี้ (ส่งมาเป็น NULL ทั้ง 3 ค่า)
        -- -> ใช้ค่าเริ่มต้น 25 กก./ถุง , 40 ถุง/พาเลท , BG
        IF @unit_ratio IS NULL AND @unit_pallet IS NULL AND @unit_code IS NULL
        BEGIN
            SET @unit_ratio  = 25;
            SET @unit_pallet = 40;
            SET @unit_code   = 'BG';
        END

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

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pServiceStampGradePackageRatio
--      @grade = '1126NK/750', @unit_ratio = 750, @unit_pallet = 1, @unit_code = 'JB';
