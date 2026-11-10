/* =====================================================================
   109_rollback_dummy_pallet_transfer.sql  (IRPC_QTRACK)
   ย้อน 109_dummy_pallet_transfer.sql -- ลบ SP ทั้ง 2 ตัว (SP ใหม่ ไม่มี definition เดิมให้คืน)
   ข้อมูลที่ย้ายไปแล้ว (tr_bag / tr_pallet) ไม่ถูกย้อน
   ===================================================================== */
USE [IRPC_QTRACK]
GO
DROP PROCEDURE IF EXISTS [dbo].[pProcessDummyPalletTransferBags];
GO
DROP PROCEDURE IF EXISTS [dbo].[pProcessDummyPalletAddBag];
GO
