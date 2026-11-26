/* =====================================================================
   107_rollback_dummy_pallet.sql  (IRPC_QTRACK)
   ย้อน 107_dummy_pallet.sql -- ลบ SP ทั้ง 3 ตัว (SP ใหม่ ไม่มี definition เดิมให้คืน)
   ไม่ลบพาเลท pallet_type = 'D' ที่สร้างไปแล้ว และไม่คืนถุงที่ล้างไปแล้ว
   ===================================================================== */
USE [IRPC_QTRACK]
GO

DROP PROCEDURE IF EXISTS [dbo].[pProcessClearDummyPallet];
GO
DROP PROCEDURE IF EXISTS [dbo].[pProcessCreateDummyPallet];
GO
DROP PROCEDURE IF EXISTS [dbo].[pProcessGetDummyPalletList];
GO
