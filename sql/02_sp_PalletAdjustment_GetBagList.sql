/* =====================================================================
   Pallet Adjustment - GetBagList
   -----------------------------------------------------------------
   Loads bag list of a selected pallet for the right-hand bag panel.
   bag_status_id values per 00_master_bag_status.sql (4 = MISSING).
   ton_no = ตันที่ระบบจัดให้ (= ordinal, 13_pServiceMatchBagToPallet step 6) --
   หน้าจอเทียบกับตันใน QR: ตรงทุกใบ = ไม่มีการเลื่อน ใช้เลขถุงใน QR เป็นเลขช่องได้ ,
   ไม่ตรง (reject เลื่อนถุงข้ามตัน) หรือ NULL = ใช้ bag_no
   reject_before = 1 ถ้ามีถุง reject ในกลุ่ม (cost_center+grade+lot) ที่อยู่ก่อนถุงนี้ตามลำดับ QR
   (ตันน้อยกว่า หรือ ตันเดียวกันแต่เลขถุงน้อยกว่า) -- กฎเดียวกับ #rj ใน 13_pServiceMatchBagToPallet
   (ไม่นับ 6=REPLACED และไม่นับตำแหน่งที่มีถุงดีที่ QR ซ้ำอยู่แล้ว) = ถุงนี้ถูกเลื่อนขึ้นมาแล้ว
   หน้าจอจึงต้องแสดงตาม bag_no ไม่ใช่เลข QR (กรณี reject แล้วถุงยังเป็นตันเดียวกันทั้งพาเลท
   ton_no ยังตรงกับ QR ทำให้เช็คด้วย ton_no อย่างเดียวไม่พอ)
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

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.sp_PalletAdjustment_GetBagList @PalletId = 4
