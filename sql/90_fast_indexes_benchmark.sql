/* =====================================================================
   90_fast_indexes_benchmark.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   วัดความเร็ว query หลักที่ 90_fast_indexes.sql ตั้งใจเร่ง
   รันก่อนและหลัง 90_ แล้วเทียบ ms / logical reads (read-only ไม่แก้ข้อมูล)

   baseline RY19-OPS13DBPRD 2026-10-25 (ก่อนรัน 90_) :
     qr_dup_check x200          47 ms     1,200 reads
     ct_location_by_id x200    141 ms     7,600 reads
     bags_on_pallet x200        62 ms     1,600 reads
     open_pallets_by_grade x20 3485 ms    5,620 reads
     history_by_pallet x200    297 ms    25,600 reads
     wms_log_top1000 x5         15 ms       375 reads
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET NOCOUNT ON;
DECLARE @r TABLE (test varchar(60), ms int, reads bigint);
DECLARE @t0 datetime2, @r0 bigint, @x int, @qr varchar(100), @pid bigint, @wh varchar(50), @grade varchar(30);
SELECT TOP 1 @qr = qr_text_data, @pid = pallet_id, @grade = grade FROM dbo.tr_bag WHERE pallet_id IS NOT NULL ORDER BY create_datetime DESC;

DECLARE @i int = 0;
-- 1) pProcessInsertTrBag : duplicate QR check
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME(); SET @i = 0;
WHILE @i < 200 BEGIN IF EXISTS (SELECT 1 FROM dbo.tr_bag WHERE qr_text_data = @qr AND mode_id <> 3 AND status_flag = 'A') SET @x = 1; SET @i += 1; END
INSERT @r SELECT 'qr_dup_check x200', DATEDIFF(ms, @t0, SYSDATETIME()), logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

-- 2) ct_location by id
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME(); SET @i = 0;
WHILE @i < 200 BEGIN SELECT @wh = wh_code FROM dbo.ct_location WHERE id = 1000 + @i AND is_active = 'Y' AND status_flag = 'A'; SET @i += 1; END
INSERT @r SELECT 'ct_location_by_id x200', DATEDIFF(ms, @t0, SYSDATETIME()), logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

-- 3) bags on pallet (step 6.5 / missing index)
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME(); SET @i = 0;
WHILE @i < 200 BEGIN SELECT @x = COUNT(*) FROM dbo.tr_bag WHERE pallet_id = @pid AND bag_status_id IN (2, 3) AND is_active = 'Y' AND status_flag = 'A' AND grade = @grade; SET @i += 1; END
INSERT @r SELECT 'bags_on_pallet x200', DATEDIFF(ms, @t0, SYSDATETIME()), logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

-- 4) pServiceMatchBagToPallet step 6.5 / 8 : open auto pallets of grade
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME(); SET @i = 0;
WHILE @i < 20 BEGIN SELECT @x = COUNT(*) FROM dbo.tr_pallet p WHERE p.pallet_type = 'A' AND p.status_flag = 'A' AND p.is_active = 'Y' AND p.ref_pallet LIKE '%|' + @grade + '|%'; SET @i += 1; END
INSERT @r SELECT 'open_pallets_by_grade x20', DATEDIFF(ms, @t0, SYSDATETIME()), logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

-- 5) tr_pallet_history by pallet_id
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME(); SET @i = 0;
WHILE @i < 200 BEGIN SELECT @x = COUNT(*) FROM dbo.tr_pallet_history WHERE pallet_id = CAST(@pid AS int) AND is_active = 'Y' AND status_flag = 'A'; SET @i += 1; END
INSERT @r SELECT 'history_by_pallet x200', DATEDIFF(ms, @t0, SYSDATETIME()), logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

-- 6) WMS interface log page : TOP 1000 ORDER BY id DESC
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME(); SET @i = 0;
WHILE @i < 5 BEGIN SELECT @x = MAX(LEN(t.route)) FROM (SELECT TOP 1000 route FROM dbo.tr_wms_interface_log ORDER BY id DESC) t; SET @i += 1; END
INSERT @r SELECT 'wms_log_top1000 x5', DATEDIFF(ms, @t0, SYSDATETIME()), logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

SELECT * FROM @r;
GO
