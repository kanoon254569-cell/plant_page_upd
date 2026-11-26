/* =====================================================================
   Pallet Adjustment - Transaction Log (dbo.tr_transaction_log)
   -----------------------------------------------------------------
   ทุกครั้งที่ User แก้ไขข้อมูลจากหน้า /pallet-adjustment (Quick Actions ทั้ง
   6 ปุ่ม: Shift ถุงหาย / ดึงถุงออก / เพิ่มถุงเข้า / Re-order / จบพาเลท /
   Reject-คืนค่าถุง) ให้บันทึกลง dbo.tr_transaction_log 1 แถวเสมอ (เฉพาะตอน
   ทำสำเร็จ -- อยู่ใน TRANSACTION เดียวกับตัว action นั้น ๆ ถ้า action ถูก
   ROLLBACK แถว log ก็จะหายไปด้วย ไม่ log การกระทำที่ไม่สำเร็จ)

   ตาราง tr_transaction_log เป็น shared log table (ใช้ร่วมกับหน้าจออื่นในระบบ
   ได้ในอนาคต ไม่ใช่ของ Pallet Adjustment โดยเฉพาะ) จึงสร้างแบบ idempotent
   (IF OBJECT_ID ... IS NULL) เผื่อมีการ deploy ซ้ำ/ตารางถูกสร้างไว้แล้วจากที่อื่น

   dbo.pInsertTransactionLog เป็น helper กลาง ให้ SP อื่นเรียกแทนการ INSERT
   ตรง ๆ ทุกที่ -- กัน error จากการ log (เช่น detail เกิน length) ไม่ให้ไป
   ROLLBACK การกระทำหลักโดยไม่ตั้งใจ (กลืน exception ไว้ในตัวเอง)

   คอลัมน์ตามที่กำหนด (schema เดิม):
     topic           หมวดของ log เช่น 'Pallet Adjustment'
     activity        การกระทำสั้น ๆ เช่น 'Shift Missing Bag', 'Reject Bag'
     detail          รายละเอียดภาษาไทยแบบเต็ม (แก้ไขอะไร / ทำอะไร / จากไหน /
                     ไปไหน / โดยใคร) -- nvarchar(max)
     is_active       'Y' เสมอสำหรับ log ปกติ (ไม่มี flow ลบ log)
     create_user_id  user_id ของคนที่กระทำ (จาก JWT ฝั่ง FE ส่งมาเป็น userId)
     update_user_id  0 เสมอตอน insert (ยังไม่เคยถูกแก้ไข) -- ตาม pattern ตัวอย่าง
     status_flag     'A' เสมอ (Active)
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.tr_transaction_log', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[tr_transaction_log](
        [id]              [bigint] IDENTITY(1,1) NOT NULL,
        [topic]           [varchar](50) NOT NULL,
        [activity]        [varchar](50) NOT NULL,
        [detail]          [nvarchar](max) NOT NULL,
        [is_active]       [varchar](1) NOT NULL,
        [create_user_id]  [int] NOT NULL,
        [create_datetime] [datetime] NOT NULL,
        [update_user_id]  [int] NOT NULL,
        [update_datetime] [datetime] NOT NULL,
        [status_flag]     [varchar](1) NOT NULL,
     CONSTRAINT [PK_tr_transaction_log] PRIMARY KEY CLUSTERED
    (
        [id] ASC
    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
    ) ON [PRIMARY]
END
GO

CREATE OR ALTER PROCEDURE [dbo].[pInsertTransactionLog]
    @topic          VARCHAR(50),
    @activity       VARCHAR(50),
    @detail         NVARCHAR(MAX),
    @user_id        INT
AS
BEGIN
    SET NOCOUNT ON;

    --  Logging ต้องไม่มีวันทำให้ business action หลัก (caller) ล้มเหลว/ROLLBACK
    --  จึงกลืน exception ไว้ในตัวเอง (เช่น detail ยาวเกินคาด, ตารางถูกล็อกนาน)
    BEGIN TRY
        INSERT INTO dbo.tr_transaction_log
            (topic, activity, detail, is_active,
             create_user_id, create_datetime,
             update_user_id, update_datetime, status_flag)
        VALUES
            (@topic, @activity, @detail, 'Y',
             ISNULL(@user_id, 0), GETDATE(),
             0, GETDATE(), 'A');
    END TRY
    BEGIN CATCH
        -- swallow: การ log ล้มเหลวไม่ควรทำให้ action หลักที่เรียกมาล้มเหลวตาม
        RETURN;
    END CATCH
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pInsertTransactionLog
--      @topic = 'Pallet Adjustment', @activity = 'Reject Bag',
--      @detail = N'Reject ถุง (Bag ID: 12345) ออกจากพาเลท ID 4 โดย User ID: 101',
--      @user_id = 101;
-- SELECT TOP 20 * FROM dbo.tr_transaction_log ORDER BY id DESC;
