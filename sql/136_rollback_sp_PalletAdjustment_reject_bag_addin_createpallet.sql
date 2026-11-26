/* =====================================================================
   136_rollback -- คืน sp_PalletAdjustment_AddBagIn / sp_PalletAdjustment_CreatePallet
   เป็น definition ที่อยู่บน .75 ก่อน deploy 136_ (ดึงจาก OBJECT_DEFINITION 2026-11-20)
   หมายเหตุ : API ที่ส่ง @AllowReject จะ error หลัง rollback -> ต้อง rollback API ด้วย
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_AddBagIn]
    @BagId         BIGINT,
    @PalletId      BIGINT,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @AssignedBagNo INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @UnitPallet INT, @CurrentCount INT, @PalletNo VARCHAR(30);

        SELECT @UnitPallet = unit_pallet,
               @PalletNo   = pallet_no
        FROM   dbo.tr_pallet
        WHERE  id = @PalletId AND is_active = 'Y';

        IF @UnitPallet IS NULL
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบพาเลทปลายทาง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SELECT @CurrentCount = COUNT(*)
        FROM   dbo.tr_bag
        WHERE  pallet_id = @PalletId AND is_active = 'Y';

        IF @CurrentCount >= @UnitPallet
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'พาเลทเต็มแล้ว ไม่สามารถเพิ่มถุงได้';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        IF NOT EXISTS (
            SELECT 1 FROM dbo.tr_bag
            WHERE id = @BagId AND pallet_id IS NULL AND is_active = 'Y'
        )
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'ถุงนี้ถูกจับคู่กับพาเลทอื่นไปแล้ว หรือไม่พบข้อมูลถุง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SET @AssignedBagNo = @CurrentCount + 1;

        UPDATE dbo.tr_bag
        SET    pallet_id        = @PalletId,
               bag_no           = @AssignedBagNo,
               bag_status_id    = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @BagId;

        --  sync pallet_status_id -- @AssignedBagNo คือจำนวนถุงรวมของพาเลทหลังเพิ่มพอดี
        --  (= @CurrentCount + 1) ไม่ต้อง query นับใหม่
        UPDATE dbo.tr_pallet
        SET    pallet_status_id = CASE WHEN @AssignedBagNo >= @UnitPallet THEN 2 ELSE 1 END,
               update_user_id   = @UserId,
               update_datetime  = GETDATE()
        WHERE  id = @PalletId
          AND  ISNULL(pallet_status_id, 1) IN (1, 2)
          AND  pallet_status_id <> CASE WHEN @AssignedBagNo >= @UnitPallet THEN 2 ELSE 1 END;

        --  Log การแก้ไข -- ปลายทางเดิมของถุงเสมอคือ Orphan Bag (SP guard ไว้แล้วด้านบนว่า
        --  ต้องเป็น pallet_id IS NULL ก่อนถึงจะเพิ่มเข้าได้)
        --  EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT -- ต้อง build string
        --  ใส่ตัวแปรก่อน จะ concat ("+") ตรงใน EXEC ไม่ได้ (syntax error)
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'*' + ISNULL((SELECT qr_text_data FROM dbo.tr_bag WHERE id = @BagId), N'-') + N'* → *' + ISNULL(@PalletNo, N'-') + N'* #' + CAST(@AssignedBagNo AS VARCHAR(10));

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Add Bag In',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = ERROR_MESSAGE();
    END CATCH
END
GO

-- ===== dbo.sp_PalletAdjustment_CreatePallet =====
--  2) บันทึก ratio + สร้างพาเลทใหม่ให้ถุง orphan 1 ใบ
--     ResultCode : 0 สำเร็จ , 1 ไม่พบถุง/ถุงถูกผูกพาเลทแล้ว , 2 ข้อมูล ratio ไม่ถูกต้อง , -1 error
CREATE OR ALTER PROCEDURE [dbo].[sp_PalletAdjustment_CreatePallet]
    @BagId         BIGINT,
    @UnitRatio     INT,
    @UnitPallet    INT,
    @UnitCode      VARCHAR(20)   = NULL,
    @UserId        INT,
    @ResultCode    INT           OUTPUT,
    @ResultMessage NVARCHAR(255) OUTPUT,
    @NewPalletId   BIGINT        OUTPUT,
    @NewPalletNo   VARCHAR(50)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Grade VARCHAR(30), @GradeKey VARCHAR(30), @Cc VARCHAR(20), @Lot VARCHAR(20),
            @Qr VARCHAR(100), @Prn INT, @Fmt TINYINT, @Ref NVARCHAR(100) = NULL,
            @RatioAction NVARCHAR(20) = N'ไม่เปลี่ยน',
            @OldRatio INT, @OldPallet INT, @OldCode VARCHAR(20), @HasRatio BIT = 0,
            @IsActive VARCHAR(1), @LogDetail NVARCHAR(MAX);

    SET @UnitCode = NULLIF(LTRIM(RTRIM(@UnitCode)), '');

    BEGIN TRY
        IF ISNULL(@UnitRatio, 0) <= 0 OR ISNULL(@UnitPallet, 0) <= 0
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'กรุณาระบุ Unit Ratio และ Unit Pallet มากกว่า 0';
            RETURN;
        END

        BEGIN TRANSACTION;

        --  orphan (is_active='Y' ยังไม่ผูกพาเลท) หรือถุง Reject (is_active='R' -- อาจยังค้าง pallet_id
        --  เดิมถ้า matching ยังไม่ได้ปลด ; ย้ายมาพาเลทใหม่ได้เลย)
        SELECT @Grade = grade, @Cc = cost_center, @Lot = lot, @Qr = qr_text_data, @IsActive = is_active
        FROM   dbo.tr_bag WITH (UPDLOCK, ROWLOCK)
        WHERE  id = @BagId
          AND  ( (is_active = 'Y' AND pallet_id IS NULL) OR is_active = 'R' );

        IF @@ROWCOUNT = 0
        BEGIN
            SET @ResultCode = 1;
            SET @ResultMessage = N'ไม่พบถุง หรือถุงนี้ถูกผูกพาเลทไปแล้ว';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        SET @GradeKey = REPLACE(ISNULL(@Grade, ''), ' ', '');
        IF @GradeKey = ''
        BEGIN
            SET @ResultCode = 2;
            SET @ResultMessage = N'ถุงนี้ไม่มีข้อมูล Grade';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  ct_grade_package_ratio : insert ถ้ายังไม่มี / update ถ้าผู้ใช้แก้ค่า
        SELECT @HasRatio = 1, @OldRatio = unit_ratio, @OldPallet = unit_pallet, @OldCode = unit_code
        FROM   dbo.ct_grade_package_ratio WITH (UPDLOCK, HOLDLOCK)
        WHERE  grade = @GradeKey;

        IF @HasRatio = 0
        BEGIN
            INSERT INTO dbo.ct_grade_package_ratio (grade, unit_ratio, unit_pallet, unit_code, last_update_datetime)
            VALUES (@GradeKey, @UnitRatio, @UnitPallet, @UnitCode, GETDATE());
            SET @RatioAction = N'เพิ่มใหม่';
        END
        ELSE IF ISNULL(@OldRatio, -1) <> @UnitRatio OR ISNULL(@OldPallet, -1) <> @UnitPallet
             OR ISNULL(@OldCode, '') <> ISNULL(@UnitCode, '')
        BEGIN
            UPDATE dbo.ct_grade_package_ratio
            SET    unit_ratio = @UnitRatio, unit_pallet = @UnitPallet, unit_code = @UnitCode,
                   last_update_datetime = GETDATE()
            WHERE  grade = @GradeKey;
            SET @RatioAction = N'แก้ไข';
        END

        --  ref_pallet ตามตันใน QR ถ้ายังว่าง (ดูหัวไฟล์)
        --  QR format ใหม่ (มี |ddHHmm) ต่อท้าย '|F6' ให้ตรงกับพาเลทกลุ่ม format ใหม่ของ 13_
        SELECT @Prn = pallet_running_no, @Fmt = qr_format FROM dbo.fParseBagQr(@Qr);
        IF @Prn > 0
        BEGIN
            SET @Ref = CONCAT(@Cc, '|', @Grade, '|', @Lot, '|', @Prn, CASE WHEN @Fmt = 6 THEN '|F6' ELSE '' END);
            IF EXISTS (SELECT 1 FROM dbo.tr_pallet WHERE ref_pallet = @Ref AND status_flag = 'A')
                SET @Ref = NULL;
        END

        SET @NewPalletNo = dbo.fGetPalletNo('A');

        INSERT INTO dbo.tr_pallet
            ( ref_pallet, pallet_no, pallet_type, pd_group_code, unit_ratio, unit_pallet,
              pallet_status_id, is_active, remark,
              create_user_id, create_datetime, update_user_id, update_datetime, status_flag )
        VALUES
            ( @Ref, @NewPalletNo, 'A', 'A', @UnitRatio, @UnitPallet,
              CASE WHEN @UnitPallet <= 1 THEN 2 ELSE 1 END,   -- 1 ถุงก็เต็มแล้ว -> 2=COMPLETED
              'Y', CONCAT('Manual create: ', @Grade, ' / ', @Lot),
              @UserId, GETDATE(), @UserId, GETDATE(), 'A' );

        SET @NewPalletId = SCOPE_IDENTITY();

        UPDATE dbo.tr_bag
        SET    pallet_id       = @NewPalletId,
               bag_no          = 1,
               bag_status_id   = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               is_active       = 'Y', -- ถุง Reject กลับเป็นถุงปกติ
               --  ถุง Reject ที่ถูกปลดจากพาเลทแล้วมี ton_no = NULL -> ใช้เลขตันจาก QR
               ton_no          = CASE WHEN @IsActive = 'R' THEN COALESCE(ton_no, NULLIF(@Prn, 0)) ELSE ton_no END,
               update_user_id  = @UserId,
               update_datetime = GETDATE()
        WHERE  id = @BagId;

        SET @LogDetail = N'*' + @NewPalletNo + N'* จาก' + CASE WHEN @IsActive = 'R' THEN N'ถุง Reject ' ELSE N'ถุงที่ยังไม่ผูกพาเลท ' END + ISNULL(@Qr, N'-')
                         + N', ratio ' + CAST(@UnitRatio AS VARCHAR(10)) + N'×' + CAST(@UnitPallet AS VARCHAR(10)) + ISNULL(N' ' + @UnitCode, N'')
                         + CASE WHEN @RatioAction = N'แก้ไข'
                                THEN N' (เดิม ' + ISNULL(CAST(@OldRatio AS VARCHAR(10)), N'-') + N'×' + ISNULL(CAST(@OldPallet AS VARCHAR(10)), N'-') + ISNULL(N' ' + @OldCode, N'') + N')'
                                WHEN @RatioAction = N'ไม่เปลี่ยน' THEN N''
                                ELSE N' (' + @RatioAction + N' ratio)' END;

        EXEC dbo.pInsertTransactionLog
             @topic    = 'Pallet Adjustment',
             @activity = 'Create Pallet',
             @detail   = @LogDetail,
             @user_id  = @UserId;

        SET @ResultCode = 0;
        SET @ResultMessage = N'สร้างพาเลท ' + @NewPalletNo + N' สำเร็จ';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @ResultCode = -1;
        SET @ResultMessage = ERROR_MESSAGE();
        SET @NewPalletId = NULL;
        SET @NewPalletNo = NULL;
    END CATCH

    --  หลังสร้างพาเลทสำเร็จ (commit แล้ว) -> รัน auto-matching ทันที ให้ถุงค้างอื่นของ grade นี้
    --  (ตอนนี้มี ratio แล้ว) ถูกสร้าง/จับเข้าพาเลทเลย ไม่ต้องรอ SQL Agent job 1 นาที
    --  แยก TRY ของตัวเอง : matching ล้มเหลวต้องไม่ทำให้การสร้างพาเลทถูกรายงานว่า error
    --  (ถ้า job รายนาทีกำลังรันอยู่ 14_ จะข้ามรอบนี้เอง แล้ว job นั้นจับให้แทน)
    IF @ResultCode = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.pServiceRunPalletMatching @create_user_id = 0, @preview = 0;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SET @ResultMessage = LEFT(@ResultMessage + N' (จับคู่ถุงอัตโนมัติไม่สำเร็จ: ' + ERROR_MESSAGE()
                                      + N' -- job รายนาทีจะจับให้ภายหลัง)', 255);
        END CATCH
    END
END
GO
