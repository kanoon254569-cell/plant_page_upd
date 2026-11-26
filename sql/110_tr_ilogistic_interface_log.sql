/* =====================================================================
   iLogistic Interface Log (dbo.tr_ilogistic_interface_log)
   -----------------------------------------------------------------
   เก็บ log การเรียก interface ระหว่าง QTrack <-> iLogistic ทุกครั้ง
   (request / response / ผลสำเร็จหรือไม่) -- โครงสร้างเดียวกับ
   dbo.tr_wms_plus_interface_log เพื่อให้ query / หน้าจอดู log ใช้ pattern เดียวกัน

   คอลัมน์:
     job_main_id      tr_job_main.id ที่เกี่ยวข้อง (NULL ได้ ถ้าไม่ผูกกับ job)
     ref_no           เลขอ้างอิงฝั่ง iLogistic เช่น DO / Shipment No. (NULL ได้)
     mode             ประเภทการเรียก เช่น 'DO Preparing' (ProcessWarehousePrepareUpdate)
     method           HTTP method เช่น 'GET', 'POST'
     route            URL / endpoint ที่เรียก
     param            request body / query string (nvarchar(max))
     status_code      HTTP status code ที่ได้กลับมา เช่น '200', '500'
     message          response body / error message (nvarchar(max))
     is_success       'Y' / 'N'
     create_user_id   user ที่กระทำ (0 = system / background job)
     create_datetime  default GETDATE()
     status_flag      default 'A'

   Idempotent: รันซ้ำได้ (IF OBJECT_ID ... IS NULL / IF NOT EXISTS index)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.tr_ilogistic_interface_log', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tr_ilogistic_interface_log](
        [id]              [bigint] IDENTITY(1,1) NOT NULL,
        [job_main_id]     [int] NULL,
        [ref_no]          [varchar](100) NULL,
        [mode]            [varchar](50) NULL,
        [method]          [varchar](10) NULL,
        [route]           [varchar](255) NULL,
        [param]           [nvarchar](max) NULL,
        [status_code]     [varchar](10) NULL,
        [message]         [nvarchar](max) NULL,
        [is_success]      [varchar](1) NULL,
        [create_user_id]  [int] NULL,
        [create_datetime] [datetime] NOT NULL
            CONSTRAINT [DF_tr_ilogistic_interface_log_create_datetime] DEFAULT (GETDATE()),
        [status_flag]     [varchar](1) NOT NULL
            CONSTRAINT [DF_tr_ilogistic_interface_log_status_flag] DEFAULT ('A'),
     CONSTRAINT [PK_tr_ilogistic_interface_log] PRIMARY KEY CLUSTERED
    (
        [id] ASC
    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
    ) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_ilogistic_interface_log_job_main_id' AND object_id = OBJECT_ID(N'[dbo].[tr_ilogistic_interface_log]'))
    CREATE NONCLUSTERED INDEX [IX_tr_ilogistic_interface_log_job_main_id]
        ON [dbo].[tr_ilogistic_interface_log] ([job_main_id] ASC, [mode] ASC, [is_success] ASC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_ilogistic_interface_log_ref_no' AND object_id = OBJECT_ID(N'[dbo].[tr_ilogistic_interface_log]'))
    CREATE NONCLUSTERED INDEX [IX_tr_ilogistic_interface_log_ref_no]
        ON [dbo].[tr_ilogistic_interface_log] ([ref_no] ASC, [mode] ASC, [is_success] ASC);
GO

-- ตัวอย่าง insert:
-- INSERT INTO dbo.tr_ilogistic_interface_log
--     (job_main_id, ref_no, mode, method, route, param, status_code, message, is_success, create_user_id)
-- VALUES
--     (123, '7250', 'DO Preparing', 'POST', '/api/v1/Process/ProcessWarehousePrepareUpdate', N'{...}', '200', N'{...}', 'Y', 0);
-- SELECT TOP 20 * FROM dbo.tr_ilogistic_interface_log ORDER BY id DESC;
