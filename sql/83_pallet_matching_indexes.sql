/* =====================================================================
   Pallet Matching Service - Indexes สำหรับ pServiceRunPalletMatching (14_)
   และ pServiceMatchBagToPallet (13_)
   -----------------------------------------------------------------
   job รันทุก 1 นาที x ทุก grade ที่มีงานค้าง x ทุกกลุ่ม (cost_center, lot, format)
   query ที่ไม่มี index รองรับ (07_indexes.sql ทำไว้ให้หน้า Pallet Adjustment) :
     1) ถุงของกลุ่ม : grade + cost_center + lot  -> IX_tr_bag_grade (grade, is_active) ไม่มี
        cost_center / qr_text_data / bag_status_id -> key lookup กลับ heap ทุกแถว
     2) ถุงจัดการด้วยมือ (bag_status_id 3/6) ของกลุ่ม -- เดิมไม่มี filter คอลัมน์ไหนเลย
        ต้องสแกน + แกะ QR ทั้ง tr_bag ทุกกลุ่ม ; 14_ หา grade ที่มีถุงค้าง/reject ก็สแกนทั้งตาราง
     3) พาเลทที่ไม่เหลือถุง (step 8) : NOT EXISTS tr_bag.pallet_id ทุกสถานะ -- IX_tr_bag_pallet_bagno
        เป็น filtered (is_active='Y') ใช้ไม่ได้
     4) หา ordinal -> พาเลท : tr_pallet.ref_pallet = @ref (ทุก ordinal ทุกกลุ่ม) -- สแกน tr_pallet ทุกครั้ง

   ไม่มี filtered index (กัน INSERT/UPDATE จาก session ที่ SET option ไม่ครบแล้ว error)
   ไม่เปลี่ยน schema/ผลลัพธ์ -- รันซ้ำได้ (DROP + CREATE)
   Dependencies: ไม่มี (รันก่อนหรือหลัง 13_/14_ ก็ได้)
   ===================================================================== */
USE [IRPC_QTRACK]
GO

--  1) ถุงของกลุ่ม (13_ step 0, 2, 3, 3.1, #grp)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_match_group' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_match_group ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_match_group
    ON dbo.tr_bag (grade, cost_center, lot)
    INCLUDE (is_active, status_flag, bag_status_id, pallet_id, bag_no, pallet_running_no, ton_no, qr_text_data);
GO

--  2) ถุงค้าง / reject ที่ยังไม่ประมวลผล (14_ cursor, 13_ #grp) + ถุงจัดการด้วยมือ 3/6 (13_ step 2, 3)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_match_status' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_match_status ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_match_status
    ON dbo.tr_bag (is_active, bag_status_id, pallet_id)
    INCLUDE (grade, cost_center, lot, status_flag, bag_no, qr_text_data);
GO

--  3) นับ/เช็คถุงต่อพาเลททุกสถานะ (13_ step 6.5, 8)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_bag_pallet_id' AND object_id = OBJECT_ID('dbo.tr_bag'))
    DROP INDEX IX_tr_bag_pallet_id ON dbo.tr_bag;
GO
CREATE NONCLUSTERED INDEX IX_tr_bag_pallet_id
    ON dbo.tr_bag (pallet_id)
    INCLUDE (grade, is_active);
GO

--  4) ordinal -> พาเลท (13_ step 4) ; step 6.5 / 8 (ref_pallet LIKE '%|grade|%') สแกน index นี้แทนตารางเต็ม
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tr_pallet_ref' AND object_id = OBJECT_ID('dbo.tr_pallet'))
    DROP INDEX IX_tr_pallet_ref ON dbo.tr_pallet;
GO
CREATE NONCLUSTERED INDEX IX_tr_pallet_ref
    ON dbo.tr_pallet (ref_pallet)
    INCLUDE (pallet_no, pallet_type, status_flag, is_active, inbound_to_wh_id, unit_pallet, pallet_status_id);
GO
