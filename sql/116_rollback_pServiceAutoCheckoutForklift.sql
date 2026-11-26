/* =====================================================================
   116_rollback_pServiceAutoCheckoutForklift.sql  (IRPC_QTRACK)
   ลบ proc และ index ที่ 116 เพิ่ม (ปิด job ก่อน: Jobs:ForkliftAutoCheckout:Enabled = false)
   แถวที่ถูก auto checkout ไปแล้วไม่ถูกย้อนกลับ
   ===================================================================== */
USE [IRPC_QTRACK]
GO
DROP PROCEDURE IF EXISTS [dbo].[pServiceAutoCheckoutForklift];
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_user_activity' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    DROP INDEX [IX_tr_pallet_history_user_activity] ON [dbo].[tr_pallet_history];
GO
