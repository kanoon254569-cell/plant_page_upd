/* =====================================================================
   Pallet Matching Service - FUNCTION: fParseBagQr
   -----------------------------------------------------------------
   แกะ qr_text_data เป็นตาราง 1 แถว รองรับ 2 format:
     - เดิม (5 ส่วน) : cost_center|grade|lot|bag_no|pallet_running_no
                       เช่น 1095|1126NK|0260805036|01|002            -> qr_format = 5, qr_time = NULL
     - ใหม่ (6 ส่วน) : cost_center|grade|lot|bag_no|pallet_running_no|ddHHmm
                       เช่น 1095|1126NK|0260805036|01|002|211630     -> qr_format = 6, qr_time = '211630'
                       (21 = วันที่, 16 = ชั่วโมง, 30 = นาที)
   2 format "ห้ามรวบกลุ่มกัน" -- ผู้เรียกที่จัดกลุ่มพาเลท (13_) ต้องแยกตาม qr_format ด้วย
   bag_no / pallet_running_no เป็น NULL ถ้า parse ไม่ได้
   (รูปแบบ QR ผิด) -- ผู้เรียกต้องกรองเอง ใช้ CHARINDEX/SUBSTRING (ไม่พึ่ง
   STRING_SPLIT) ทำงานได้ทุกเวอร์ชัน SQL Server

   ตัวเดียว ใช้ร่วมกันทั้ง 13_pServiceMatchBagToPallet.sql และ
   15_pProcessUpdateBagRejectStatus.sql กัน bag_no/pallet_running_no ใน
   คอลัมน์เพี้ยน/ถูก NULL ไป -- qr_text_data คือความจริงเดียว (single
   source of truth) ของลำดับถุง ไม่ใช่คอลัมน์ tr_bag.bag_no/pallet_running_no
   ที่ reject จะ NULL ทิ้งได้

   Dependencies: ไม่มี
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--  ทุก SUBSTRING ครอบด้วย CASE WHEN t4.p4 > 0 -- SQL Server อาจคำนวณ SELECT list ก่อน
--  กรอง WHERE (ขึ้นกับ plan) ถ้าส่งค่าที่ไม่ใช่ QR ถุง (เช่น pallet_no 'PLA2609250001' ไม่มี '|')
--  เข้ามา ความยาวจะติดลบ -> Msg 537 "Invalid length parameter passed to the LEFT or
--  SUBSTRING function" ทั้งที่ WHERE จะตัดแถวนั้นทิ้งอยู่แล้ว
CREATE OR ALTER FUNCTION dbo.fParseBagQr (@qr VARCHAR(100))
RETURNS TABLE
AS
RETURN (
    SELECT
        cost_center       = CASE WHEN t4.p4 > 0 THEN SUBSTRING(@qr, 1, t1.p1 - 1) END,
        grade             = CASE WHEN t4.p4 > 0 THEN SUBSTRING(@qr, t1.p1 + 1, t2.p2 - t1.p1 - 1) END,
        lot               = CASE WHEN t4.p4 > 0 THEN SUBSTRING(@qr, t2.p2 + 1, t3.p3 - t2.p2 - 1) END,
        bag_no            = CASE WHEN t4.p4 > 0 THEN TRY_CONVERT(INT, SUBSTRING(@qr, t3.p3 + 1, t4.p4 - t3.p3 - 1)) END,
        --  p5 = '|' ตัวที่ 5 (มีเฉพาะ format ใหม่) -- pallet_running_no จบก่อน p5 ไม่งั้นจบท้ายสตริง
        pallet_running_no = CASE WHEN t5.p5 > 0 THEN TRY_CONVERT(INT, SUBSTRING(@qr, t4.p4 + 1, t5.p5 - t4.p4 - 1))
                                 WHEN t4.p4 > 0 THEN TRY_CONVERT(INT, SUBSTRING(@qr, t4.p4 + 1, LEN(@qr) - t4.p4)) END,
        qr_time           = CASE WHEN t5.p5 > 0 THEN SUBSTRING(@qr, t5.p5 + 1, LEN(@qr) - t5.p5) END,
        qr_format         = CASE WHEN t5.p5 > 0 THEN 6 WHEN t4.p4 > 0 THEN 5 END
    FROM (SELECT p1 = CHARINDEX('|', @qr, 1)) t1
    CROSS APPLY (SELECT p2 = CASE WHEN t1.p1 > 0 THEN CHARINDEX('|', @qr, t1.p1 + 1) ELSE 0 END) t2
    CROSS APPLY (SELECT p3 = CASE WHEN t2.p2 > 0 THEN CHARINDEX('|', @qr, t2.p2 + 1) ELSE 0 END) t3
    CROSS APPLY (SELECT p4 = CASE WHEN t3.p3 > 0 THEN CHARINDEX('|', @qr, t3.p3 + 1) ELSE 0 END) t4
    CROSS APPLY (SELECT p5 = CASE WHEN t4.p4 > 0 THEN CHARINDEX('|', @qr, t4.p4 + 1) ELSE 0 END) t5
    WHERE @qr IS NOT NULL AND t1.p1 > 0 AND t2.p2 > 0 AND t3.p3 > 0 AND t4.p4 > 0
);
GO
