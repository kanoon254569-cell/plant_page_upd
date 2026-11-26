/* =====================================================================
   115_rollback_pProcessJobChangeQTrackModeToAuto.sql  (IRPC_QTRACK)
   ลบ proc ใหม่ของ 115_ (ไม่ย้อนข้อมูลที่ถูกเปลี่ยนไปแล้ว)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
DROP PROCEDURE IF EXISTS [dbo].[pProcessJobChangeQTrackModeToAuto];
GO
