/* =====================================================================
   tr_bag.ton_no -- "ตันที่" ของถุง (เลขตันหลัง re-run)
   -----------------------------------------------------------------
   pallet_running_no = เลขตันตาม QR ถุง (cost_center|grade|lot|bag_no|pallet_running_no)
                       -> ค่าตายตัว ไม่เปลี่ยนแม้มี reject
   ton_no            = เลขตันจริงของถุง ณ ปัจจุบัน
                       - ค่าเริ่มต้นตอน insert = pallet_running_no -> set ใน dbo.pProcessInsertTrBag
                         (INSERT ... ton_no = @pallet_id เดียวกับ pallet_running_no)
                       - เมื่อมีการ reject -> pServiceMatchBagToPallet (13) re-run ให้ = ordinal ใหม่
                         (ถุงหลังถุงที่ reject เลื่อนขึ้น เลขตันเลื่อนตาม) ; ถุงที่ถูก reject ออก -> NULL
                       - un-reject (15) / Edit Bag (27) -> set = pallet_running_no / Ton No. ที่กรอก

   คอลัมน์ tr_bag.ton_no (ระหว่าง pallet_running_no กับ bag_no) ถูกเพิ่มเองด้วยมือแล้ว
   ไฟล์นี้จึงเหลือแค่ backfill ข้อมูลเดิม (+ ลบ trigger รุ่นก่อนของไฟล์นี้ ถ้าเคยรันไว้)

   รันก่อน : 13_pServiceMatchBagToPallet.sql, 15_pProcessUpdateBagRejectStatus.sql,
             27_pProcessPalletManagement.sql (ทั้ง 3 ไฟล์อ้าง tr_bag.ton_no)
   รันซ้ำได้ (idempotent)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 0) trigger ค่าเริ่มต้นจากไฟล์นี้รุ่นก่อน ไม่ใช้แล้ว (pProcessInsertTrBag set ton_no เอง)
IF OBJECT_ID('dbo.trg_tr_bag_ton_no_default', 'TR') IS NOT NULL
    DROP TRIGGER dbo.trg_tr_bag_ton_no_default;
GO

-- 1) backfill ข้อมูลเดิม (เฉพาะแถวที่ยังไม่มีค่า)
--    - ถุงที่อยู่บนพาเลท auto ของกลุ่มตัวเอง (ref_pallet = cc|grade|lot|<ordinal>) -> ordinal ของพาเลทนั้น
--      (= เลขตันหลัง re-run ที่ matcher จัดไว้แล้ว)
--    - ถุง reject ที่ถูกปลดออกจากพาเลทแล้ว (is_active='R' และ bag_no = NULL) -> คง NULL
--    - อื่น ๆ -> pallet_running_no
UPDATE b
SET    b.ton_no = CASE
           WHEN b.is_active = 'R' AND b.bag_no IS NULL THEN NULL
           WHEN p.ref_pallet LIKE b.cost_center + '|' + b.grade + '|' + b.lot + '|%'
                AND CHARINDEX('|', REVERSE(p.ref_pallet)) > 1
               THEN TRY_CONVERT(INT, RIGHT(p.ref_pallet, CHARINDEX('|', REVERSE(p.ref_pallet)) - 1))
           ELSE b.pallet_running_no
       END
FROM   dbo.tr_bag b
LEFT JOIN dbo.tr_pallet p ON p.id = b.pallet_id AND p.pallet_type = 'A'
WHERE  b.ton_no IS NULL;
GO

-- ตรวจผล:
-- SELECT TOP 100 id, qr_text_data, is_active, pallet_id, pallet_running_no, ton_no, bag_no
-- FROM dbo.tr_bag ORDER BY id DESC;
--
-- ถุงที่เลขตันถูก re-run แล้ว (ต่างจาก QR):
-- SELECT id, qr_text_data, pallet_running_no, ton_no, bag_no
-- FROM dbo.tr_bag WHERE ton_no <> pallet_running_no;
--
-- ถุงที่ยังไม่มี ton_no (insert มาจากทางอื่นที่ไม่ใช่ pProcessInsertTrBag):
-- SELECT id, qr_text_data, pallet_running_no, ton_no FROM dbo.tr_bag
-- WHERE ton_no IS NULL AND is_active = 'Y' AND pallet_running_no IS NOT NULL;
