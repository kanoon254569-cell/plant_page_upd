/* =====================================================================
   Pallet Matching Service - pServiceRunPalletMatching
   -----------------------------------------------------------------
   Driver ที่ SQL Server Agent job รายนาทีเรียก (ดูสคริปต์สร้าง job ที่
   sql_agent_jobs.sql, project root) -- วนทุก grade ที่:
     - มีถุงค้าง (bag_status_id=1, pallet_id IS NULL)  หรือ
     - มี reject (is_active='R') ที่ยังค้าง match อยู่ หรือยังไม่ถูกประมวลผล (bag_status_id ไม่ใช่ 6/9)
   และมี ratio ใช้งานได้ (unit_pallet > 0) แล้วเรียก
   13_pServiceMatchBagToPallet.sql ต่อ grade (T-SQL ล้วน ไม่แตะ WMS API)

   grade ที่มีถุงค้างแต่ยังไม่มี ratio จะถูก list ออกมาใน result set สุดท้าย
   ให้ฝั่ง C# (ratio-refresh job) ไปดึงจาก WMS ต่อ

   sp_getapplock @LockTimeout = 0 : ถ้า job รอบก่อนยังไม่จบ -> ข้ามรอบนี้ทันที
   (กัน job ซ้อนกันเองถ้ารอบก่อนใช้เวลานานผิดปกติ)

   Dependencies: 09_ct_grade_package_ratio.sql, 13_pServiceMatchBagToPallet.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.pServiceRunPalletMatching
    @max_groups       INT = 30,
    @lot_idle_minutes INT = 30,
    @create_user_id   INT = 0,
    @preview          BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @lock INT, @grade VARCHAR(30), @err NVARCHAR(2048);

    EXEC @lock = sp_getapplock @Resource   = 'QTRACK_RunPalletMatching',
                               @LockMode   = 'Exclusive',
                               @LockOwner  = 'Session',
                               @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        PRINT 'pServiceRunPalletMatching: another run in progress -> skip';
        RETURN;
    END

    BEGIN TRY
        DECLARE gc CURSOR LOCAL FAST_FORWARD FOR
            SELECT b.grade
            FROM   dbo.tr_bag b
            JOIN   dbo.ct_grade_package_ratio r                        -- ratio ถูก stamp แบบตัด space (ดู 12_)
                   ON r.grade = REPLACE(b.grade, ' ', '') AND r.unit_pallet > 0
            WHERE  b.status_flag = 'A'
              AND ( (b.is_active = 'Y' AND b.bag_status_id = 1 AND b.pallet_id IS NULL)
                 OR (b.is_active = 'R' AND b.pallet_id IS NOT NULL)
                 OR (b.is_active = 'R' AND ISNULL(b.bag_status_id, 0) NOT IN (6, 9)) )   -- เงื่อนไขเดียวกับ #grp ใน 13_
            GROUP BY b.grade
            ORDER BY b.grade;

        OPEN gc;
        FETCH NEXT FROM gc INTO @grade;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.pServiceMatchBagToPallet
                 @grade            = @grade,
                 @create_user_id   = @create_user_id,
                 @max_groups       = @max_groups,
                 @lot_idle_minutes = @lot_idle_minutes,
                 @preview          = @preview;

            FETCH NEXT FROM gc INTO @grade;
        END
        CLOSE gc; DEALLOCATE gc;

        -- grade ที่มีถุงค้างแต่ยังไม่มี ratio (รอ refresh จาก WMS)
        SELECT b.grade, COUNT(*) AS pending_bags_no_ratio
        FROM   dbo.tr_bag b
        LEFT JOIN dbo.ct_grade_package_ratio r
               ON r.grade = REPLACE(b.grade, ' ', '') AND r.unit_pallet > 0
        WHERE  b.bag_status_id = 1
          AND  b.pallet_id IS NULL
          AND  b.is_active   = 'Y'
          AND  b.status_flag = 'A'
          AND  r.grade IS NULL
        GROUP BY b.grade;

        EXEC sp_releaseapplock @Resource = 'QTRACK_RunPalletMatching', @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        -- error ตอน compile statement ใน SP ลูก (เช่น collation conflict) ข้าม CATCH ของลูก
        -- -> transaction ของลูกค้างมาถึงตรงนี้
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        IF CURSOR_STATUS('local', 'gc') >= 0 BEGIN CLOSE gc; DEALLOCATE gc; END
        EXEC sp_releaseapplock @Resource = 'QTRACK_RunPalletMatching', @LockOwner = 'Session';
        SET @err = ERROR_MESSAGE();
        RAISERROR('pServiceRunPalletMatching failed: %s', 16, 1, @err);   -- ทำให้ job step ขึ้น Failed
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pServiceRunPalletMatching @create_user_id = 0, @preview = 0;
