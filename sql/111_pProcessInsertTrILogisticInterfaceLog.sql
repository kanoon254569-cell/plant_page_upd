/* =====================================================================
   dbo.pProcessInsertTrILogisticInterfaceLog
   -----------------------------------------------------------------
   Insert 1 แถวลง dbo.tr_ilogistic_interface_log (สร้างใน 110_...)
   ทุกครั้งที่ API เรียก iLogistic -- pattern เดียวกับ
   dbo.pProcessInsertTrWmsPlusInterfaceLog คืนค่า id ของแถวที่ insert

   เรียกจาก API: Services/ILogisticApiLogService.cs
   (ใช้ใน ILogisticClient.ProcessWarehousePrepareUpdate)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessInsertTrILogisticInterfaceLog]
    @job_main_id    INT             = NULL,
    @ref_no         VARCHAR(100)    = NULL,
    @mode           VARCHAR(50)     = NULL,
    @method         VARCHAR(10)     = NULL,
    @route          VARCHAR(255)    = NULL,
    @param          NVARCHAR(MAX)   = NULL,
    @status_code    VARCHAR(10)     = NULL,
    @message        NVARCHAR(MAX)   = NULL,
    @is_success     VARCHAR(1)      = NULL,
    @create_user_id INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.tr_ilogistic_interface_log
        (job_main_id, ref_no, mode, method, route, param, status_code, message, is_success, create_user_id, create_datetime, status_flag)
    VALUES
        (@job_main_id, @ref_no, @mode, @method, @route, @param, @status_code, @message, @is_success, @create_user_id, GETDATE(), 'A');

    SELECT SCOPE_IDENTITY() AS id;
END
GO
