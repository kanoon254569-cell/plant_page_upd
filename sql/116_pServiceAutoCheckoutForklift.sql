/* =====================================================================
   116_pServiceAutoCheckoutForklift.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   Auto checkout คนขับ forklift ที่ไม่ได้ Get / Put นานเกิน @idle_minutes
   (default 60 นาที = 1 ชม. เท่ากับแอป forklift ที่ checkout เองเมื่อไม่ได้
   Get / Put ครบ 1 ชม. -- job นี้ปิดแถวที่แอปไม่ได้ปิด เช่น ปิดแท็บ / มือถือดับ)
   เรียกจาก Hangfire job "forklift-auto-checkout" (ForkliftAutoCheckoutService)
   ทุก 15 นาที ค่าจริงมาจาก Jobs:ForkliftAutoCheckout:IdleMinutes

   ทุกแถว tr_forklift_usage ที่ยังเปิดอยู่ (checkout_datetime IS NULL):
     last_activity = MAX(create_datetime) ของ tr_pallet_history
                     ที่ create_user_id = usage_user_id
                     AND process_id IN (1 Get Pallet, 2 Put Away)
                     AND create_datetime >= checkin_datetime
                     -- ถ้าไม่เคย Get / Put หลัง check-in ใช้ checkin_datetime
     ถ้า GETDATE() - last_activity > @idle_minutes
       -> checkout_datetime = last_activity  (เวลา Get / Put ล่าสุด
          ไม่ใช่เวลาที่ job รัน -- ให้เวลาใช้งานรถตรงกับความจริง)
       -> ปล่อย ct_forklift (current_user_id = NULL, last_used_user_id =
          user) เฉพาะถ้า user นี้ยังเป็นคนขับคันนั้นอยู่ -- เหมือน
          check-out ('U') ของ pProcessInsertUpdateTrForkliftUsage

   ทำใน transaction เดียว และคำนวณ last_activity ใหม่ใน UPDATE เอง
   (UPDLOCK) ถ้า user สแกนเข้ามาระหว่างนั้นจะไม่โดน checkout

   Input  : @idle_minutes (default 60), @user_id = update_user_id (0 = system)
   Output : dbResult   status / message / checked_out_count
            dbResult1  แถวที่ถูก checkout (usage_id, forklift_id,
                       usage_user_id, checkin_datetime, checkout_datetime)

   Rollback: 116_rollback_pServiceAutoCheckoutForklift.sql
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--	Last Get / Put per user -- seek instead of scanning tr_pallet_history.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_tr_pallet_history_user_activity' AND object_id = OBJECT_ID(N'[dbo].[tr_pallet_history]'))
    CREATE NONCLUSTERED INDEX [IX_tr_pallet_history_user_activity]
        ON [dbo].[tr_pallet_history] ([create_user_id] ASC, [process_id] ASC, [create_datetime] ASC);
GO

CREATE OR ALTER PROCEDURE [dbo].[pServiceAutoCheckoutForklift]
    @idle_minutes INT = 60,
    @user_id      INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @idle_minutes IS NULL OR @idle_minutes <= 0
    BEGIN
        SELECT 'error' AS status, 'Invalid @idle_minutes.' AS message, 0 AS checked_out_count;
        RETURN;
    END

    DECLARE @now DATETIME = GETDATE();
    DECLARE @closed TABLE (
        usage_id          BIGINT,
        forklift_id       INT,
        usage_user_id     INT,
        checkin_datetime  DATETIME,
        checkout_datetime DATETIME
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE fu
        SET checkout_datetime = la.last_activity,
            update_user_id    = @user_id,
            update_datetime   = @now
        OUTPUT inserted.id, inserted.forklift_id, inserted.usage_user_id,
               inserted.checkin_datetime, inserted.checkout_datetime
        INTO @closed
        FROM dbo.tr_forklift_usage fu WITH (UPDLOCK, ROWLOCK)
        CROSS APPLY (
            SELECT ISNULL(MAX(h.create_datetime), fu.checkin_datetime) AS last_activity
            FROM dbo.tr_pallet_history h
            WHERE h.create_user_id = fu.usage_user_id
              AND h.process_id IN (1, 2)
              AND h.create_datetime >= fu.checkin_datetime
        ) la
        WHERE fu.checkout_datetime IS NULL
          AND fu.checkin_datetime IS NOT NULL
          AND la.last_activity < DATEADD(MINUTE, -@idle_minutes, @now);

        --	Release the forklift only while this user is still the one on it.
        UPDATE cf
        SET current_user_id   = NULL,
            last_used_user_id = c.usage_user_id,
            update_user_id    = @user_id,
            update_datetime   = @now
        FROM dbo.ct_forklift cf
        INNER JOIN @closed c
            ON c.forklift_id = cf.id
           AND cf.current_user_id = c.usage_user_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'error' AS status, ERROR_MESSAGE() AS message, 0 AS checked_out_count;
        RETURN;
    END CATCH

    SELECT 'success' AS status, 'ok' AS message, COUNT(*) AS checked_out_count FROM @closed;
    SELECT usage_id, forklift_id, usage_user_id, checkin_datetime, checkout_datetime FROM @closed;
END
GO
