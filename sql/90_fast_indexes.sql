/* =====================================================================
   90_fast_indexes.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   index ชุดเร่งความเร็ว ออกแบบจากสถิติจริงบน DB (2026-10-25)
     - sys.dm_db_missing_index_*      (index ที่ optimizer ขอ)
     - sys.dm_db_index_usage_stats    (seek / scan / lookup / update)
     - plan cache : key lookup ที่เกิดบ่อย (pProcessInsertTrBag,
       pServiceMatchBagToPallet, pProcessGetForkliftJobs)
   ขนาดตาราง : tr_bag 1.28M แถว , tr_pallet 47k , ที่เหลือเล็ก

   หลักการ
     1) ตาราง HEAP ที่ถูกอ่านบ่อย -> ใส่ PK CLUSTERED (id ไม่ซ้ำ ตรวจแล้ว)
     2) index ที่ seek แล้วต้อง key lookup กลับ clustered -> เพิ่ม INCLUDE
        (DROP_EXISTING = ON : สร้างทับ ไม่มีช่วงที่ไม่มี index)
     3) index ซ้ำ / เป็น subset ของตัวอื่น -> DROP (ลดต้นทุน INSERT/UPDATE
        ของ tr_bag ซึ่งโดนเขียน ~1.3M ครั้ง และ tr_pallet ~6.7M ครั้ง)
        DROP ทำเฉพาะเมื่อ index ที่มาแทนมีอยู่แล้วเท่านั้น

   - รันซ้ำได้ : ทุก step เช็คสถานะก่อน
   - Enterprise Edition -> ONLINE = ON ไม่ lock ตารางระหว่างสร้าง
   - index ของ tr_bag ที่อยู่บน partition scheme [ps_tr_bag_datetime] คงไว้บน
     scheme เดิม ; ตัวที่อยู่บน PRIMARY คงไว้บน PRIMARY
   - ไม่มี SP ไหนใช้ index hint ชื่อที่ถูก DROP (ตรวจจาก script.sql แล้ว)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   1) HEAP -> PK CLUSTERED
   ===================================================================== */

-- ct_location : HEAP 3,831 แถว ถูก scan 65k ครั้ง ; missing index อันดับ 1-3
-- ทั้งหมดเป็น seek ด้วย id -> clustered บน id แก้ได้ทั้งชุด
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ct_location') AND index_id = 1)
    ALTER TABLE dbo.ct_location ADD CONSTRAINT PK_ct_location PRIMARY KEY CLUSTERED (id)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- ct_location : ค้นด้วย wh_code (missing index : wh_code, is_active, status_flag)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ct_location_wh_code' AND object_id = OBJECT_ID(N'dbo.ct_location'))
    CREATE NONCLUSTERED INDEX IX_ct_location_wh_code
        ON dbo.ct_location (wh_code, is_active, status_flag)
        INCLUDE (location_master_id, priority_id)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- ct_location : ค้นด้วย location_master_id (missing index impact 89%)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ct_location_master' AND object_id = OBJECT_ID(N'dbo.ct_location'))
    CREATE NONCLUSTERED INDEX IX_ct_location_master
        ON dbo.ct_location (location_master_id, is_active, status_flag)
        INCLUDE (wh_code, priority_id)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- tr_job_assigness : HEAP มี RID lookup ~9.7k ครั้ง
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tr_job_assigness') AND index_id = 1)
    ALTER TABLE dbo.tr_job_assigness ADD CONSTRAINT PK_tr_job_assigness PRIMARY KEY CLUSTERED (id)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- tr_wms_interface_log : HEAP 24 MB , หน้า log อ่าน "ORDER BY id DESC" ~8k reads/ครั้ง
-- clustered บน id -> อ่าน TOP 1000 ล่าสุดจากท้าย index ตรง ๆ ไม่ต้อง scan + sort
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tr_wms_interface_log') AND index_id = 1)
    ALTER TABLE dbo.tr_wms_interface_log ADD CONSTRAINT PK_tr_wms_interface_log PRIMARY KEY CLUSTERED (id)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

/* =====================================================================
   2) tr_bag : ตัด key lookup (hot path)
   ===================================================================== */

-- pProcessInsertTrBag (เรียก ~160k ครั้ง) :
--   IF EXISTS (... WHERE qr_text_data = @qr AND mode_id <> 3 AND status_flag = 'A')
--   seek ได้แต่ต้อง lookup ไปเอา status_flag ทุกครั้ง (lookup รวม ~1.48M)
-- fCheckPalletType ใช้ pallet_id, is_active, status_flag ด้วย -> INCLUDE ทั้งหมด
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_qr_text_data' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_bag') AND i.name = N'IX_tr_bag_qr_text_data'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_bag_qr_text_data
        ON dbo.tr_bag (qr_text_data, mode_id, bag_status_id)
        INCLUDE (status_flag, is_active, pallet_id)
        WITH (DROP_EXISTING = ON, ONLINE = ON, SORT_IN_TEMPDB = ON)
        ON [PRIMARY];
GO

-- pServiceMatchBagToPallet : ทุก query ของกลุ่มกรอง grade + cost_center + lot + is_active
--   (step 0 is_active='R', step 2 is_active='Y', step 3.1 is_active='R')
--   ย้าย is_active ขึ้นเป็น key -> seek ตรงแถวที่ต้องการแทน residual filter
--   ครอบคลุม missing index (cost_center, grade, lot, is_active, status_flag)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_grade_cc_lot' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_bag') AND i.name = N'IX_tr_bag_grade_cc_lot'
                     AND c.name = N'is_active' AND ic.key_ordinal = 4)
    CREATE NONCLUSTERED INDEX IX_tr_bag_grade_cc_lot
        ON dbo.tr_bag (grade, cost_center, lot, is_active)
        INCLUDE (status_flag, bag_status_id, pallet_id, bag_no, ton_no, pallet_running_no, qr_text_data)
        WITH (DROP_EXISTING = ON, ONLINE = ON, SORT_IN_TEMPDB = ON)
        ON [PRIMARY];
GO

-- นับ / หาถุงบนพาเลท : รวม 3 index ของ pallet_id ให้เหลือตัวเดียวที่ครอบคลุมทุก query
--   (step 6.5 : pallet_id + grade + is_active , missing index : pallet_id, bag_status_id,
--    is_active, status_flag incl grade , หน้าจอ pallet : grade, lot, qr_text_data)
--   create_datetime + id เป็น clustered key -> ติดมาใน index อยู่แล้ว
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_full' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
    CREATE NONCLUSTERED INDEX IX_tr_bag_pallet_full
        ON dbo.tr_bag (pallet_id, is_active, status_flag)
        INCLUDE (bag_status_id, bag_no, grade, lot, cost_center, qr_text_data)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON)
        ON [ps_tr_bag_datetime] (create_datetime);
GO

-- ถุงจัดการด้วยมือ (bag_status_id 3, 6) : branch 2 ของ step 2 ต้องใช้ pallet_running_no / ton_no
-- เพิ่ม INCLUDE ให้ไม่ต้อง lookup (filtered index เล็กมาก ต้นทุนเขียนต่ำ)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_manual_status' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_bag') AND i.name = N'IX_tr_bag_manual_status'
                     AND c.name = N'pallet_running_no')
    CREATE NONCLUSTERED INDEX IX_tr_bag_manual_status
        ON dbo.tr_bag (bag_status_id)
        INCLUDE (qr_text_data, pallet_id, bag_no, is_active, status_flag,
                 grade, cost_center, lot, ton_no, pallet_running_no)
        WHERE bag_status_id IN (3, 6)
        WITH (DROP_EXISTING = ON, ONLINE = ON, SORT_IN_TEMPDB = ON)
        ON [ps_tr_bag_datetime] (create_datetime);
GO

-- ถุงค้าง match : #grp query ต้องใช้ qr_text_data (fParseBagQr) -> เดิม lookup
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pending_match' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_bag') AND i.name = N'IX_tr_bag_pending_match'
                     AND c.name = N'qr_text_data')
    CREATE NONCLUSTERED INDEX IX_tr_bag_pending_match
        ON dbo.tr_bag (grade, cost_center, lot)
        INCLUDE (is_active, status_flag, create_datetime, qr_text_data, bag_no, pallet_running_no)
        WHERE pallet_id IS NULL AND bag_status_id = 1
        WITH (DROP_EXISTING = ON, ONLINE = ON, SORT_IN_TEMPDB = ON)
        ON [PRIMARY];
GO

/* =====================================================================
   3) tr_pallet
   ===================================================================== */

-- หา pallet ด้วย ref_pallet (seek 2.5M ครั้ง) : เพิ่ม unit_ratio ให้ fCheckPalletType (J pallet)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_ref' AND object_id = OBJECT_ID(N'dbo.tr_pallet'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_pallet') AND i.name = N'IX_tr_pallet_ref'
                     AND c.name = N'unit_ratio')
    CREATE NONCLUSTERED INDEX IX_tr_pallet_ref
        ON dbo.tr_pallet (ref_pallet)
        INCLUDE (pallet_no, pallet_type, status_flag, is_active, inbound_to_wh_id,
                 unit_pallet, unit_ratio, pallet_status_id)
        WITH (DROP_EXISTING = ON, ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- pServiceMatchBagToPallet step 6.5 / 8 : ref_pallet LIKE '%|' + @grade + '|%' (seek ไม่ได้)
-- เดิม scan clustered 47k แถวทุกรอบ -> filtered index เก็บเฉพาะพาเลท A ที่เปิดอยู่ (ไม่กี่ร้อยแถว)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_open_auto' AND object_id = OBJECT_ID(N'dbo.tr_pallet'))
    CREATE NONCLUSTERED INDEX IX_tr_pallet_open_auto
        ON dbo.tr_pallet (ref_pallet)
        INCLUDE (inbound_to_wh_id, unit_pallet, pallet_status_id)
        WHERE pallet_type = 'A' AND status_flag = 'A' AND is_active = 'Y'
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

/* =====================================================================
   4) ตารางเล็กที่ถูกเรียกถี่ : ตัด key lookup
   ===================================================================== */

-- ct_grade_package_ratio : seek grade แล้ว lookup unit_ratio, unit_pallet 132k ครั้ง
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ct_grade_package_ratio_grade_cover' AND object_id = OBJECT_ID(N'dbo.ct_grade_package_ratio'))
    CREATE UNIQUE NONCLUSTERED INDEX IX_ct_grade_package_ratio_grade_cover
        ON dbo.ct_grade_package_ratio (grade)
        INCLUDE (unit_ratio, unit_pallet, unit_code, last_update_datetime)
        WITH (ONLINE = ON);
GO

-- tr_pallet_manual_item : seek pallet_id แล้ว lookup 129k ครั้ง
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_manual_item_pallet_id_wms' AND object_id = OBJECT_ID(N'dbo.tr_pallet_manual_item'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_pallet_manual_item') AND i.name = N'IX_tr_pallet_manual_item_pallet_id_wms'
                     AND c.name = N'job_type_id')
    CREATE NONCLUSTERED INDEX IX_tr_pallet_manual_item_pallet_id_wms
        ON dbo.tr_pallet_manual_item (pallet_id)
        INCLUDE (wms_plus_item_id, job_type_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_job_main : pProcessGetForkliftJobs lookup is_urgent, is_multi_forklift, start/end_datetime
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_main_type_create' AND object_id = OBJECT_ID(N'dbo.tr_job_main'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_job_main') AND i.name = N'IX_tr_job_main_type_create'
                     AND c.name = N'is_urgent')
    CREATE NONCLUSTERED INDEX IX_tr_job_main_type_create
        ON dbo.tr_job_main (job_type_id, create_datetime)
        INCLUDE (interface_job_id, job_status_id, is_active, status_flag,
                 is_urgent, is_multi_forklift, start_datetime, end_datetime)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_main_interface_lookup' AND object_id = OBJECT_ID(N'dbo.tr_job_main'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_job_main') AND i.name = N'IX_tr_job_main_interface_lookup'
                     AND c.name = N'is_urgent')
    CREATE NONCLUSTERED INDEX IX_tr_job_main_interface_lookup
        ON dbo.tr_job_main (job_type_id, interface_job_id)
        INCLUDE (job_status_id, is_active, status_flag,
                 is_urgent, is_multi_forklift, start_datetime, end_datetime, create_datetime)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_job_to_location : lookup location_name 56k ครั้ง
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_to_location_lookup' AND object_id = OBJECT_ID(N'dbo.tr_job_to_location'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_job_to_location') AND i.name = N'IX_tr_job_to_location_lookup'
                     AND c.name = N'location_name')
    CREATE NONCLUSTERED INDEX IX_tr_job_to_location_lookup
        ON dbo.tr_job_to_location (job_main_id, interface_job_item_id, is_active, status_flag)
        INCLUDE (to_location_id, to_location_type, qty, actual_qty, location_name)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

/* =====================================================================
   4.1) ตารางอื่น ๆ : HEAP -> PK CLUSTERED
   ---------------------------------------------------------------------
   id ไม่ซ้ำทุกตาราง (ตรวจแล้ว) ; ตาราง master เล็ก แต่ถูก scan ถี่มาก
   (ct_job_type 1.37M ครั้ง) -> clustered บน id ให้ JOIN ด้วย id เป็น seek
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ct_job_type') AND index_id = 1)
    ALTER TABLE dbo.ct_job_type ADD CONSTRAINT PK_ct_job_type PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ct_forklift_status') AND index_id = 1)
    ALTER TABLE dbo.ct_forklift_status ADD CONSTRAINT PK_ct_forklift_status PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ct_location_type') AND index_id = 1)
    ALTER TABLE dbo.ct_location_type ADD CONSTRAINT PK_ct_location_type PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ct_priority') AND index_id = 1)
    ALTER TABLE dbo.ct_priority ADD CONSTRAINT PK_ct_priority PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ct_special_status') AND index_id = 1)
    ALTER TABLE dbo.ct_special_status ADD CONSTRAINT PK_ct_special_status PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.sys_api_key') AND index_id = 1)
    ALTER TABLE dbo.sys_api_key ADD CONSTRAINT PK_sys_api_key PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tr_broken_bag_replace_detail') AND index_id = 1)
    ALTER TABLE dbo.tr_broken_bag_replace_detail ADD CONSTRAINT PK_tr_broken_bag_replace_detail PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tr_broken_bag_status_log') AND index_id = 1)
    ALTER TABLE dbo.tr_broken_bag_status_log ADD CONSTRAINT PK_tr_broken_bag_status_log PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tr_special_history') AND index_id = 1)
    ALTER TABLE dbo.tr_special_history ADD CONSTRAINT PK_tr_special_history PRIMARY KEY CLUSTERED (id) WITH (ONLINE = ON);
GO

-- sys_api_key : ตรวจ key ทุก request -> WHERE interface_system = @x AND is_active = 'Y' AND status_flag = 'A'
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_sys_api_key_system' AND object_id = OBJECT_ID(N'dbo.sys_api_key'))
    CREATE NONCLUSTERED INDEX IX_sys_api_key_system
        ON dbo.sys_api_key (interface_system, is_active, status_flag)
        INCLUDE (api_key)
        WITH (ONLINE = ON);
GO

/* =====================================================================
   4.2) ตารางอื่น ๆ : ตัด key lookup / clustered scan
   ===================================================================== */

-- tr_pallet_history : JOIN @pallets ON pallet_id (8 จุด) ไม่มี index ที่ขึ้นต้นด้วย pallet_id
-- -> scan clustered 41k ครั้ง
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_pallet_id' AND object_id = OBJECT_ID(N'dbo.tr_pallet_history'))
    CREATE NONCLUSTERED INDEX IX_tr_pallet_history_pallet_id
        ON dbo.tr_pallet_history (pallet_id, is_active, status_flag)
        INCLUDE (job_main_id, job_item_id, process_id, pallet_seq, bag_id,
                 location_type, location_id, create_user_id, create_datetime)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- tr_pallet_history : WHERE job_main_id = @x [AND pallet_id = @y] seek แล้ว lookup 38k ครั้ง
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_pallet_lookup' AND object_id = OBJECT_ID(N'dbo.tr_pallet_history'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_pallet_history') AND i.name = N'IX_tr_pallet_history_pallet_lookup'
                     AND c.name = N'pallet_seq')
    CREATE NONCLUSTERED INDEX IX_tr_pallet_history_pallet_lookup
        ON dbo.tr_pallet_history (job_main_id, job_item_id, pallet_id, process_id, create_datetime DESC)
        INCLUDE (location_id, location_type, create_user_id,
                 pallet_seq, bag_id, is_active, status_flag, update_user_id, update_datetime)
        WITH (DROP_EXISTING = ON, ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- tr_job_from_location : lookup location_name (เหมือน tr_job_to_location ข้อ 4)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_job_from_location_lookup' AND object_id = OBJECT_ID(N'dbo.tr_job_from_location'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_job_from_location') AND i.name = N'IX_tr_job_from_location_lookup'
                     AND c.name = N'location_name')
    CREATE NONCLUSTERED INDEX IX_tr_job_from_location_lookup
        ON dbo.tr_job_from_location (job_main_id, interface_job_item_id, is_active, status_flag)
        INCLUDE (from_location_id, from_location_type, qty, actual_qty, location_name)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_wms_plus_interface_log : WHERE job_main_id + mode + is_success ORDER BY create_datetime DESC
-- index เดิมชื่ออัตโนมัติจาก SSMS -> สร้างตัวใหม่ชื่อมาตรฐานที่ covering แล้วลบตัวเดิม
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_wms_plus_interface_log_job' AND object_id = OBJECT_ID(N'dbo.tr_wms_plus_interface_log'))
    CREATE NONCLUSTERED INDEX IX_tr_wms_plus_interface_log_job
        ON dbo.tr_wms_plus_interface_log (job_main_id, mode, is_success, create_datetime DESC)
        INCLUDE (status_code, status_flag, method, route)
        WITH (ONLINE = ON);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_wms_plus_interface_log_job' AND object_id = OBJECT_ID(N'dbo.tr_wms_plus_interface_log'))
   AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NonClusteredIndex-20261005-154524' AND object_id = OBJECT_ID(N'dbo.tr_wms_plus_interface_log'))
    DROP INDEX [NonClusteredIndex-20261005-154524] ON dbo.tr_wms_plus_interface_log;
GO

-- tr_broken_bag_detail : seek header_id แล้ว lookup 105k ครั้ง
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_broken_bag_detail_header' AND object_id = OBJECT_ID(N'dbo.tr_broken_bag_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_broken_bag_detail') AND i.name = N'IX_tr_broken_bag_detail_header'
                     AND c.name = N'grade')
    CREATE NONCLUSTERED INDEX IX_tr_broken_bag_detail_header
        ON dbo.tr_broken_bag_detail (header_id)
        INCLUDE (grade, lot, qty, bag, status, status_flag, create_datetime)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_special_item : seek header_id แล้ว lookup 79k ครั้ง
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_item_header_id' AND object_id = OBJECT_ID(N'dbo.tr_special_item'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_special_item') AND i.name = N'IX_tr_special_item_header_id'
                     AND c.name = N'grade')
    CREATE NONCLUSTERED INDEX IX_tr_special_item_header_id
        ON dbo.tr_special_item (header_id)
        INCLUDE (grade, lot, total_pallet, delivery_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_special_detail : IX_tr_special_detail_aggregation (item_id, is_active, status_flag) lookup 2.2k
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_special_detail_aggregation' AND object_id = OBJECT_ID(N'dbo.tr_special_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_special_detail') AND i.name = N'IX_tr_special_detail_aggregation'
                     AND c.name = N'pallet_id')
    CREATE NONCLUSTERED INDEX IX_tr_special_detail_aggregation
        ON dbo.tr_special_detail (item_id, is_active, status_flag)
        INCLUDE (pallet_id, pallet_no, reserved_pallet_no, qty, bag, is_approve)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_internal_transfer_detail : seek header_id แล้ว lookup 19.5k ครั้ง (ไม่ include pallet_json nvarchar(max))
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_internal_transfer_detail_header_id' AND object_id = OBJECT_ID(N'dbo.tr_internal_transfer_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_internal_transfer_detail') AND i.name = N'IX_tr_internal_transfer_detail_header_id'
                     AND c.name = N'grade')
    CREATE NONCLUSTERED INDEX IX_tr_internal_transfer_detail_header_id
        ON dbo.tr_internal_transfer_detail (header_id)
        INCLUDE (job_location_type, job_location_id, grade_id, grade, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

-- tr_picking_detail / tr_shipping_detail / tr_loading_detail : ตาราง detail ของ delivery
-- seek ด้วย header_id หรือ delivery_id แล้ว lookup เอา is_active / status_flag / อีก FK
-- (tr_picking_detail : clustered scan 802k + lookup 27k)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_picking_detail_picking_header_id' AND object_id = OBJECT_ID(N'dbo.tr_picking_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_picking_detail') AND i.name = N'IX_tr_picking_detail_picking_header_id'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_picking_detail_picking_header_id
        ON dbo.tr_picking_detail (header_id)
        INCLUDE (delivery_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_picking_detail_delivery_id' AND object_id = OBJECT_ID(N'dbo.tr_picking_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_picking_detail') AND i.name = N'IX_tr_picking_detail_delivery_id'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_picking_detail_delivery_id
        ON dbo.tr_picking_detail (delivery_id)
        INCLUDE (header_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_shipping_detail_shipping_header_id' AND object_id = OBJECT_ID(N'dbo.tr_shipping_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_shipping_detail') AND i.name = N'IX_tr_shipping_detail_shipping_header_id'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_shipping_detail_shipping_header_id
        ON dbo.tr_shipping_detail (header_id)
        INCLUDE (delivery_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_shipping_detail_delivery_id' AND object_id = OBJECT_ID(N'dbo.tr_shipping_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_shipping_detail') AND i.name = N'IX_tr_shipping_detail_delivery_id'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_shipping_detail_delivery_id
        ON dbo.tr_shipping_detail (delivery_id)
        INCLUDE (header_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_loading_detail_loading_header_id' AND object_id = OBJECT_ID(N'dbo.tr_loading_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_loading_detail') AND i.name = N'IX_tr_loading_detail_loading_header_id'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_loading_detail_loading_header_id
        ON dbo.tr_loading_detail (header_id)
        INCLUDE (delivery_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_loading_detail_delivery_id' AND object_id = OBJECT_ID(N'dbo.tr_loading_detail'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.object_id = OBJECT_ID(N'dbo.tr_loading_detail') AND i.name = N'IX_tr_loading_detail_delivery_id'
                     AND c.name = N'status_flag')
    CREATE NONCLUSTERED INDEX IX_tr_loading_detail_delivery_id
        ON dbo.tr_loading_detail (delivery_id)
        INCLUDE (header_id, is_active, status_flag)
        WITH (DROP_EXISTING = ON, ONLINE = ON);
GO

/* =====================================================================
   5) DROP index ซ้ำ (ทำหลังตัวแทนสร้างเสร็จเท่านั้น)
   ---------------------------------------------------------------------
   ทุก index ที่ถูก DROP ข้างล่าง มี index อื่นที่ key เดียวกัน/ครอบคลุมกว่าแล้ว
   ไม่อยากให้ DROP -> comment section นี้ออกได้ (step 1-4 ยังได้ผลเต็ม)
   ===================================================================== */

-- IX_tr_bag_match_group (grade, cost_center, lot) = key ซ้ำกับ IX_tr_bag_grade_cc_lot
-- ซึ่ง INCLUDE ครบทุกคอลัมน์แล้ว
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_grade_cc_lot' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
   AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_match_group' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
    DROP INDEX IX_tr_bag_match_group ON dbo.tr_bag;
GO

-- 3 ตัวของ pallet_id -> แทนด้วย IX_tr_bag_pallet_full
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_full' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_id' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
        DROP INDEX IX_tr_bag_pallet_id ON dbo.tr_bag;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_id_covering' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
        DROP INDEX IX_tr_bag_pallet_id_covering ON dbo.tr_bag;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_bag_pallet_id_aligned' AND object_id = OBJECT_ID(N'dbo.tr_bag'))
        DROP INDEX IX_tr_bag_pallet_id_aligned ON dbo.tr_bag;
END
GO

-- IX_tr_pallet_ref_pallet (ref_pallet) = key ซ้ำกับ IX_tr_pallet_ref ที่ INCLUDE มากกว่า
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_ref' AND object_id = OBJECT_ID(N'dbo.tr_pallet'))
   AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_ref_pallet' AND object_id = OBJECT_ID(N'dbo.tr_pallet'))
    DROP INDEX IX_tr_pallet_ref_pallet ON dbo.tr_pallet;
GO

-- UQ_ct_grade_package_ratio_grade : ถูกแทนด้วย unique covering index ข้างบน
-- เป็น constraint -> DROP ได้เฉพาะเมื่อไม่มี FK อ้างถึง
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ct_grade_package_ratio_grade_cover' AND object_id = OBJECT_ID(N'dbo.ct_grade_package_ratio'))
   AND EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_ct_grade_package_ratio_grade')
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE referenced_object_id = OBJECT_ID(N'dbo.ct_grade_package_ratio'))
    ALTER TABLE dbo.ct_grade_package_ratio DROP CONSTRAINT UQ_ct_grade_package_ratio_grade;
GO

/* =====================================================================
   6) statistics ของตารางหลัก (ให้ optimizer เลือก index ใหม่ทันที)
   ===================================================================== */
UPDATE STATISTICS dbo.tr_bag     WITH SAMPLE 25 PERCENT;
UPDATE STATISTICS dbo.tr_pallet  WITH FULLSCAN;
UPDATE STATISTICS dbo.ct_location WITH FULLSCAN;
GO
