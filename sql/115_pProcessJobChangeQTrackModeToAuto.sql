/* =====================================================================
   115_pProcessJobChangeQTrackModeToAuto.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   เปลี่ยนงานจาก Q Track Mode 'M' (สร้าง QR แบบ Manual บน WMS+)
   เป็น 'A' (พิมพ์ผ่าน QTrack Bagging System) จากหน้า Job Detail ของ Boardman

   ทำ 2 อย่างใน transaction เดียว
     1. WMS+ (IRPC_E_TRANSFER) : q_track_mode 'M' -> 'A'
          job_type_id = 1 (TS) -> tr_transfer_slip_header
          job_type_id = 2 (RC) -> tr_receive_form_header
        + ล้าง total_pallet ที่ user คีย์ตอน Manual ของ item ที่ใช้งานอยู่ เป็น 0
     2. QTrack : tr_pallet_manual_item.status_flag 'A' -> 'D'
          ของ item ใน header นั้น (wms_plus_item_id + job_type_id)

   Input  : @job_main_id = tr_job_main.id , @user_id
   Output : 1 แถว status / message / header_id / manual_item_count

   API    : PATCH api/v1/process/job/{jobId}/qtrack-mode/auto
   Rollback: 115_rollback_pProcessJobChangeQTrackModeToAuto.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [dbo].[pProcessJobChangeQTrackModeToAuto]
    @job_main_id INT,
    @user_id     INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @job_type_id INT, @header_id INT, @q_track_mode VARCHAR(5);
    DECLARE @manual_item_count INT = 0;

    SELECT TOP (1)
           @job_type_id = jm.job_type_id,
           @header_id   = jm.interface_job_id
    FROM dbo.tr_job_main jm
    WHERE jm.id = @job_main_id;

    IF @header_id IS NULL
    BEGIN
        SELECT 'error' AS status, N'ไม่พบงาน' AS message,
               CAST(NULL AS INT) AS header_id, 0 AS manual_item_count;
        RETURN;
    END

    IF @job_type_id NOT IN (1, 2)
    BEGIN
        SELECT 'error' AS status, N'งานประเภทนี้ไม่รองรับการเปลี่ยน Q Track Mode (รองรับเฉพาะ TS / RC)' AS message,
               @header_id AS header_id, 0 AS manual_item_count;
        RETURN;
    END

    IF @job_type_id = 1
        SELECT TOP (1) @q_track_mode = h.q_track_mode
        FROM IRPC_E_TRANSFER.dbo.tr_transfer_slip_header h
        WHERE h.id = @header_id;
    ELSE
        SELECT TOP (1) @q_track_mode = h.q_track_mode
        FROM IRPC_E_TRANSFER.dbo.tr_receive_form_header h
        WHERE h.id = @header_id;

    IF ISNULL(@q_track_mode, '') <> 'M'
    BEGIN
        SELECT 'error' AS status, N'เอกสารนี้ไม่ได้อยู่ใน Q Track Mode M' AS message,
               @header_id AS header_id, 0 AS manual_item_count;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRAN;

        IF @job_type_id = 1
        BEGIN
            -- 1. WMS+ : Transfer Slip
            UPDATE IRPC_E_TRANSFER.dbo.tr_transfer_slip_header
            SET q_track_mode         = 'A',
                last_update_user_id  = @user_id,
                last_update_datetime = GETDATE()
            WHERE id = @header_id
              AND q_track_mode = 'M';

            UPDATE IRPC_E_TRANSFER.dbo.tr_transfer_slip_item
            SET total_pallet         = 0,
                last_update_user_id  = @user_id,
                last_update_datetime = GETDATE()
            WHERE header_id = @header_id
              AND status_flag = 'A';

            -- 2. QTrack : manual pallet items of this header
            UPDATE pmi
            SET pmi.status_flag = 'D'
            FROM dbo.tr_pallet_manual_item pmi
            WHERE pmi.job_type_id = @job_type_id
              AND pmi.status_flag = 'A'
              AND pmi.wms_plus_item_id IN (
                    SELECT i.id
                    FROM IRPC_E_TRANSFER.dbo.tr_transfer_slip_item i
                    WHERE i.header_id = @header_id);
            SET @manual_item_count = @@ROWCOUNT;
        END
        ELSE
        BEGIN
            -- 1. WMS+ : Receive Form
            --  (ยังไม่ยืนยันว่า RC มี last_update_* -- อัปเดตเฉพาะคอลัมน์ที่ใช้อยู่แล้ว)
            UPDATE IRPC_E_TRANSFER.dbo.tr_receive_form_header
            SET q_track_mode = 'A'
            WHERE id = @header_id
              AND q_track_mode = 'M';

            UPDATE IRPC_E_TRANSFER.dbo.tr_receive_form_item
            SET total_pallet = 0
            WHERE header_id = @header_id
              AND status_flag = 'A';

            -- 2. QTrack : manual pallet items of this header
            UPDATE pmi
            SET pmi.status_flag = 'D'
            FROM dbo.tr_pallet_manual_item pmi
            WHERE pmi.job_type_id = @job_type_id
              AND pmi.status_flag = 'A'
              AND pmi.wms_plus_item_id IN (
                    SELECT i.id
                    FROM IRPC_E_TRANSFER.dbo.tr_receive_form_item i
                    WHERE i.header_id = @header_id);
            SET @manual_item_count = @@ROWCOUNT;
        END

        COMMIT TRAN;

        SELECT 'success' AS status, N'เปลี่ยน Q Track Mode เป็น A เรียบร้อย' AS message,
               @header_id AS header_id, @manual_item_count AS manual_item_count;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        SELECT 'error' AS status, CAST(ERROR_MESSAGE() AS NVARCHAR(4000)) AS message,
               @header_id AS header_id, 0 AS manual_item_count;
    END CATCH
END
GO
