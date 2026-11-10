/* =====================================================================
   Pallet Adjustment - Master: ct_pallet_status (dbo.tr_pallet.pallet_status_id)
   -----------------------------------------------------------------
   [dbo].[tr_pallet].[pallet_status_id] มีอยู่แล้วในตาราง แต่ก่อนหน้านี้ไม่มี
   master/lookup table รองรับ -- ทุกจุดที่สร้างพาเลทใหม่ใส่ค่า 1 คงที่เท่านั้น
   (pallet_matching_service.sql object #3 ขั้นตอน 4 / 03_sp_PalletAdjustment_
   ShiftMissingBag.sql) ไม่มีจุดไหน UPDATE เป็นค่าอื่นมาก่อน

   ตารางนี้ยืนยันความหมายของแต่ละค่าตามที่ผู้ใช้ระบุ:

    id | code       | description (TH)
    ---|------------|--------------------------------------------------
    1  | CREATED    | map ถุงแรก แล้วพาเลทแล้ว (สร้างพาเลทและเริ่มมีถุงจับคู่แล้ว)
    2  | COMPLETED  | พาเลทครบแล้ว (bag_count >= unit_pallet)
    3  | CONFIRMED  | ยืนยันพาเลทเศษแล้ว (พาเลทสุดท้ายของ lot ที่ไม่เต็ม แต่ถูกกด
                       "จบพาเลท" ยืนยันว่าไม่ต้องรอถุงมาเติมอีก)
    4  | VOID       | ยกเลิกพาเลท

   NOTE: ตารางนี้ใช้ MERGE แทน INSERT ตรง ๆ เพื่อให้ rerun สคริปต์นี้ซ้ำได้เสมอ
   โดยไม่ error/ไม่สร้างข้อมูลซ้ำ (idempotent เหมือน pattern ของ
   pServiceStampGradePackageRatio ในไฟล์ pallet_matching_service.sql)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ct_pallet_status', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ct_pallet_status
    (
        id          INT           NOT NULL,
        code        VARCHAR(30)   NOT NULL,
        description NVARCHAR(255) NULL,
        CONSTRAINT PK_ct_pallet_status PRIMARY KEY CLUSTERED (id ASC),
        CONSTRAINT UQ_ct_pallet_status_code UNIQUE (code)
    );
END
GO

MERGE dbo.ct_pallet_status AS target
USING (VALUES
    (1, 'CREATED',   N'map ถุงแรก แล้วพาเลทแล้ว'),
    (2, 'COMPLETED', N'พาเลทครบแล้ว'),
    (3, 'CONFIRMED', N'ยืนยันพาเลทเศษแล้ว'),
    (4, 'VOID',      N'ยกเลิกพาเลท')
) AS src (id, code, description)
ON target.id = src.id
WHEN MATCHED AND (target.code <> src.code OR ISNULL(target.description, N'') <> ISNULL(src.description, N''))
    THEN UPDATE SET code = src.code, description = src.description
WHEN NOT MATCHED BY TARGET
    THEN INSERT (id, code, description) VALUES (src.id, src.code, src.description);
GO

-- ตัวอย่างเรียกดู:
-- SELECT * FROM dbo.ct_pallet_status ORDER BY id;
