/* =====================================================================
   Pallet Matching Service - TABLE: ct_grade_package_ratio
   -----------------------------------------------------------------
   Cache ค่า package ratio ต่อ grade (จาก WMS+ `GetMasterGradePackage`) --
   TTL 1 วัน (ดู pServiceGetGradeForMatching's need_refresh logic ใน
   11_pServiceGetGradeForMatching.sql) เพราะ T-SQL เรียก HTTP ไม่ได้ตรง ๆ
   จึง cache ค่าไว้แล้วให้ C# (PalletMatchingService.RefreshRatiosAsync)
   เป็นคนอัปเดตผ่าน 12_pServiceStampGradePackageRatio.sql เป็นระยะ

   ใช้โดย: 11 (ดูว่า grade ไหน ratio หมดอายุ), 13 (อ่าน unit_pallet/unit_ratio
   จริงตอน match), 14 (join กรอง grade ที่มี ratio ใช้งานได้)

   Dependencies: ไม่มี -- ต้องรันไฟล์นี้ก่อนไฟล์อื่นในชุด Pallet Matching Service
   (09-15) ทั้งหมด เพราะทุกตัวอ้างอิงตารางนี้ (ตรงหรือผ่าน foreign อ้างอิงชื่อ)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ct_grade_package_ratio', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ct_grade_package_ratio
    (
        id                   INT IDENTITY(1,1) NOT NULL,
        grade                VARCHAR(30)  NOT NULL,
        unit_ratio           INT          NULL,     -- kg ต่อถุง        (WMS: unitRatio)
        unit_pallet          INT          NULL,     -- ถุงต่อพาเลท (n)  (WMS: unitPallet)
        unit_code            VARCHAR(20)  NULL,     -- WMS: pkUnitCode
        last_update_datetime DATETIME     NOT NULL
            CONSTRAINT DF_ct_grade_package_ratio_lud DEFAULT (GETDATE()),
        CONSTRAINT PK_ct_grade_package_ratio PRIMARY KEY CLUSTERED (id ASC),
        CONSTRAINT UQ_ct_grade_package_ratio_grade UNIQUE (grade)   -- 1 row / grade (จำเป็นสำหรับ MERGE)
    );
END
GO
