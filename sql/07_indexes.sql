/* =====================================================================
   Pallet Adjustment - Recommended Non-Clustered Indexes
   -----------------------------------------------------------------
   ปัญหาปัจจุบัน:
     - dbo.tr_bag  มีแค่ PRIMARY KEY NONCLUSTERED บน [id] เท่านั้น
       -> ตัวตารางเป็น HEAP (ไม่มี clustered index) และไม่มี index อื่นเลย
     - dbo.tr_pallet มี PRIMARY KEY CLUSTERED บน [id] เท่านั้น
       -> ทุก filter ที่ไม่ใช่ id (grade, lot, cost_center, create_datetime,
          pallet_id, current_job_id, is_active, ...) จะเป็น full scan เสมอ

   ผลกระทบ: SP ทั้ง 01-06 จะ "ช้าลงเรื่อย ๆ" ตามจำนวนแถวใน tr_bag/tr_pallet
   ที่โตขึ้นทุกวัน (ตามที่ผู้ใช้กังวลไว้) เพราะทุก query ต้องสแกนทั้งตาราง

   ไฟล์นี้เพิ่ม non-clustered index ให้ตรงกับ WHERE / JOIN / ORDER BY ที่ใช้จริง
   ใน SP 01-06 ทั้งหมด -- รันไฟล์นี้ "หลังจาก" สร้าง SP ครบแล้วได้เลย
   (ไม่มีผลกระทบกับ schema/behavior เดิม เป็นแค่ index เพิ่ม)

   หมายเหตุ: ใช้ CREATE INDEX แบบมี "already exists" guard (DROP+CREATE)
   เพื่อให้ run ซ้ำได้โดยไม่ error หากต้องปรับ column ภายหลัง
   ===================================================================== */
USE [IRPC_QTRACK]
GO

------------------------------------------------------------------------
--  dbo.tr_bag
------------------------------------------------------------------------

--  1) รองรับ filter หลักของหน้า Overview: is_active + create_datetime (ช่วงวันที่)
--     ORDER BY create_datetime (orphan bags, reorder) ก็ใช้ index นี้ได้เช่นกัน
--     -- includes ให้ query ที่ SELECT คอลัมน์เหล่านี้ทำ "index-only scan" ได้เลย
--     ไม่ต้อง key-lookup กลับไปที่ heap
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_active_createdatetime' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_active_createdatetime ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_active_createdatetime
    ON dbo.tr_bag (is_active, create_datetime)
    INCLUDE (id, pallet_id, bag_no, grade, lot, cost_center, qr_text_data, bag_status_id);
GO

--  2) รองรับ filter ตาม pallet_id -- ใช้บ่อยสุด (GetBagList, PullBagOut reorder,
--     ShiftMissingBag, AddBagIn, ReorderPallet ทุก SP join/filter ผ่าน pallet_id)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_pallet_bagno' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_pallet_bagno ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_pallet_bagno
    ON dbo.tr_bag (pallet_id, bag_no)
    INCLUDE (id, grade, lot, qr_text_data, bag_status_id, is_active, create_datetime)
    WHERE (is_active = 'Y');
    --  filtered index (เฉพาะแถวที่ active) -- เล็กกว่า และตรงกับทุก SP ที่กรอง is_active = 'Y' เสมอ
GO

--  3) รองรับ filter cost_center และ grade แยก (กรณี user เลือก cc/grade แต่ไม่ใส่วันที่)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_costcenter' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_costcenter ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_costcenter
    ON dbo.tr_bag (cost_center, is_active)
    INCLUDE (pallet_id, grade, lot, create_datetime);
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_grade' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_grade ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_grade
    ON dbo.tr_bag (grade, is_active)
    INCLUDE (pallet_id, lot, create_datetime);
GO

--  4) lot ใช้ LIKE @Lot + '%' (prefix search) -- index ปกติใช้ seek ได้กับ prefix search
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_lot' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_lot ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_lot
    ON dbo.tr_bag (lot, is_active)
    INCLUDE (pallet_id, grade, create_datetime);
GO

------------------------------------------------------------------------
--  dbo.tr_pallet
------------------------------------------------------------------------

--  5) รองรับ filter is_active + ORDER BY pallet_no (Result Set #2 ของ Overview)
--     current_job_id ยัง INCLUDE ไว้เผื่อ query อื่นในระบบใช้ -- sp_PalletAdjustment_
--     GetOverview เองไม่ได้อ่านคอลัมน์นี้แล้ว (status คำนวณจาก bag_count/pallet_status_id
--     เท่านั้น ตั้งแต่ 2026-09-13)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_pallet_active' AND object_id = OBJECT_ID('dbo.tr_pallet'))
    DROP INDEX IX_tr_pallet_active ON dbo.tr_pallet;
GO
CREATE NONCLUSTERED INDEX IX_tr_pallet_active
    ON dbo.tr_pallet (is_active)
    INCLUDE (pallet_no, pallet_type, pd_group_code, pd_type_code, unit_ratio,
             unit_pallet, current_job_id, current_location_type, current_location_id,
             pallet_status_id, create_datetime);
GO

--  6) รองรับ dbo.fGetPalletNo() ที่ query COUNT(*) ... WHERE YEAR/MONTH/DAY(create_datetime)
--     = วันนี้ AND pallet_type = @pallet_type -- ฟังก์ชันนี้ถูกเรียกทุกครั้งที่
--     สร้าง pallet ใหม่ (matching service ปกติ + ShiftMissingBag ของหน้านี้)
--     ปัจจุบัน YEAR()/MONTH()/DAY() ทำให้ index บน create_datetime ตรง ๆ ใช้ไม่ได้
--     (non-sargable) แต่ pallet_type มี cardinality ต่ำมาก การ filter ผ่าน
--     pallet_type ก่อนแล้วค่อย scan เฉพาะกลุ่มนั้นก็ช่วยลด scan ได้มากอยู่แล้ว
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_pallet_type_createdatetime' AND object_id = OBJECT_ID('dbo.tr_pallet'))
    DROP INDEX IX_tr_pallet_type_createdatetime ON dbo.tr_pallet;
GO
CREATE NONCLUSTERED INDEX IX_tr_pallet_type_createdatetime
    ON dbo.tr_pallet (pallet_type, create_datetime);
GO

-- TODO(optional/ต้องมี DBA อนุมัติ): ถ้าเป็นไปได้ ควรแก้ dbo.fGetPalletNo ให้ใช้ช่วงวันที่
-- (create_datetime >= @today AND create_datetime < @tomorrow) แทน YEAR()/MONTH()/DAY()
-- จะทำให้ index ด้านบน "seek" ได้เต็มรูปแบบแทนที่จะยัง scan ในขอบเขต pallet_type
-- (ผมไม่แก้ function ให้ตรงนี้เพราะเป็น object ที่มีอยู่แล้วในระบบ ไม่ได้อยู่ใน
--  ขอบเขตที่ขออนุญาตแก้ไข -- แจ้งได้หากต้องการให้ปรับ)

------------------------------------------------------------------------
--  หมายเหตุการดูแลระยะยาว (Maintenance)
------------------------------------------------------------------------
--  1) Index ด้านบนช่วยเรื่อง "read" (SELECT) แต่จะเพิ่ม cost เล็กน้อยตอน
--     INSERT/UPDATE (เครื่องพิมพ์ insert ถุงใหม่ทุกใบ) -- ยอมรับ trade-off นี้ได้
--     เพราะจำนวน column ที่ index ไม่เยอะ และ insert เป็น pattern แบบ append เท่านั้น
--  2) ควรตั้ง SQL Server Agent Job รัน REBUILD/REORGANIZE index เป็นระยะ (เช่น
--     ทุกคืน หรือทุกสัปดาห์ตามปริมาณข้อมูล) เพราะ tr_bag เป็น HEAP ที่ insert
--     ทุกวันจำนวนมาก จะเกิด fragmentation สะสมเร็ว ตัวอย่าง job:
--
--     ALTER INDEX ALL ON dbo.tr_bag REORGANIZE;
--     ALTER INDEX ALL ON dbo.tr_pallet REORGANIZE;
--
--  3) พิจารณาทำ Partitioning ตาม create_datetime (รายเดือน/รายไตรมาส) ในระยะยาว
--     ถ้าปริมาณ tr_bag เกินหลักสิบล้านแถว เพื่อให้ query ที่กรองด้วยวันที่เร็วขึ้นอีก
--     (เกินขอบเขตงานนี้ แต่ฝากไว้เป็นแนวทางล่วงหน้า)
