/* =====================================================================
   104_sp_PalletAdjustment_GetBagList_manual_added.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   Bag List หน้า Pallet Adjustment แสดงถุงที่สร้างจากปุ่ม "เพิ่มข้อมูล" เป็นอีกสี
   -> เพิ่มคอลัมน์ is_manual_added (1 = ถุงที่สร้างเอง) ; definition อื่นตรงกับ prod (OBJECT_DEFINITION 2026-11-01)
   Rollback: 104_rollback_sp_PalletAdjustment_GetBagList.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_GetBagList]
    @PalletId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        b.id, b.bag_no, b.ton_no, b.grade, b.lot, b.qr_text_data,
        CASE WHEN EXISTS (
                SELECT 1
                FROM   dbo.tr_bag r
                CROSS APPLY dbo.fParseBagQr(r.qr_text_data) rq
                WHERE  r.grade = b.grade AND r.cost_center = b.cost_center AND r.lot = b.lot
                  AND  r.status_flag = 'A' AND r.is_active = 'R'
                  AND  ISNULL(r.bag_status_id, 0) <> 6
                  AND  rq.qr_format = q.qr_format          -- QR 5/6 ส่วน คนละกลุ่ม (ดู 13_)
                  AND  (   rq.pallet_running_no < q.pallet_running_no
                        OR (rq.pallet_running_no = q.pallet_running_no AND rq.bag_no < q.bag_no) )
                  AND  NOT EXISTS (
                        SELECT 1
                        FROM   dbo.tr_bag g
                        CROSS APPLY dbo.fParseBagQr(g.qr_text_data) gq
                        WHERE  g.grade = b.grade AND g.cost_center = b.cost_center AND g.lot = b.lot
                          AND  g.is_active = 'Y'
                          AND  gq.qr_format = rq.qr_format
                          AND  gq.pallet_running_no = rq.pallet_running_no AND gq.bag_no = rq.bag_no)
             ) THEN 1 ELSE 0 END AS reject_before,
        -- ถุงที่สร้างจากปุ่ม "เพิ่มข้อมูล" (ข้อความเดียวกับที่ 103_ บันทึก ; mode_id = 2 แยกไม่ได้เพราะงานพิมพ์ก็ใช้)
        CASE WHEN b.remark LIKE 'เพิ่มข้อมูลด้วยมือ%' THEN 1 ELSE 0 END AS is_manual_added,
        CASE
            WHEN b.bag_status_id = 4    THEN 'missing'
            WHEN b.pallet_id IS NULL    THEN 'orphan'
            ELSE 'matched'
        END AS status
    FROM    dbo.tr_bag b
    OUTER APPLY dbo.fParseBagQr(b.qr_text_data) q
    WHERE   b.pallet_id = @PalletId
      AND   b.is_active = 'Y'
    ORDER BY b.bag_no;
END
GO
