/* =====================================================================
   ct_special_status.name_th + pProcessGetSpecialStatusList
   ---------------------------------------------------------------------
   SPC01 Special List's "สถานะ" filter used to load its options from
   pProcessCBGetJobStatus @user_type = 3, which returns no rows for 3 and
   reads ct_job_status anyway -- the wrong set: pProcessGetSpecialJobList
   filters @job_status against tr_special_header.status_id, i.e.
   ct_special_status. So the dropdown only ever showed "All".

   1) ct_special_status.name_th  NVARCHAR(100) NULL -- Thai name
        1 SPC Approve    -> อนุมัติแล้ว
        2 Wait Location  -> รอจัดเก็บ
        3 Complete       -> เสร็จสิ้น
   2) pProcessGetSpecialStatusList -- active statuses for the dropdown
        result 1 : status / message
        result 2 : id, name, name_th (falls back to name when blank)
      Same shape as pProcessCBGetJobStatus, so the API/front end reuse
      ResponseProcessGetOptionsJobStatus.
      Used by GET api/v1/process-cb/special-status-list.

   pProcessCBGetJobStatus is NOT changed.
   รันซ้ำได้ (idempotent)
   Rollback: sql/135_rollback_ct_special_status_name_th.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1) ct_special_status.name_th
IF COL_LENGTH('dbo.ct_special_status', 'name_th') IS NULL
BEGIN
    ALTER TABLE dbo.ct_special_status ADD name_th NVARCHAR(100) NULL;
END
GO

UPDATE dbo.ct_special_status SET name_th = N'อนุมัติแล้ว' WHERE id = 1;
UPDATE dbo.ct_special_status SET name_th = N'รอจัดเก็บ'   WHERE id = 2;
UPDATE dbo.ct_special_status SET name_th = N'เสร็จสิ้น'    WHERE id = 3;
GO

-- 2) pProcessGetSpecialStatusList
-- EXEC dbo.pProcessGetSpecialStatusList
CREATE OR ALTER PROC [dbo].[pProcessGetSpecialStatusList]
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 'success' AS status,
           'Data retrieved successfully.' AS message;

    SELECT
        CAST(ss.id AS INT) AS id,
        ss.name,
        COALESCE(NULLIF(ss.name_th, N''), CAST(ss.name AS NVARCHAR(100))) AS name_th
    FROM dbo.ct_special_status ss
    WHERE ss.is_active = 'Y'
      AND ss.status_flag = 'A'
    ORDER BY ss.id;
END
GO
