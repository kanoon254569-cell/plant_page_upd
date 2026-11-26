/* =====================================================================
   136_sp_PalletAdjustment_reject_bag_addin_createpallet.sql  (IRPC_QTRACK)
   -----------------------------------------------------------------
   หน้า BG01 Pallet Adjustment -- รายการ "ถุงที่ถูก Reject" (2026-11-20)

   1) sp_PalletAdjustment_AddBagIn : เพิ่ม @AllowReject BIT = 0
      ปุ่มใหม่ "เพิ่มเข้าพาเลท" ของถุง Reject (เหมือนถุงที่ยังไม่ผูกพาเลท) -- endpoint
      pallet-adjustment/add-in ส่ง @AllowReject = 1 ; endpoint อื่นที่ใช้ SP นี้ (Pallet
      Management) ไม่ส่ง -> รับเฉพาะถุง orphan เหมือนเดิม
      ถุง Reject (is_active='R', อาจยังค้าง pallet_id เดิม) -> is_active='Y' เข้าพาเลทปลายทาง
      ต่อท้าย (bag_no = จำนวนถุง+1) , ton_no = ตันของพาเลทปลายทาง (ton_no ที่ถุงบนพาเลท
      ใช้มากสุด ; ไม่มี -> ค่าเดิม/ตันใน QR)

   2) sp_PalletAdjustment_CreatePallet : ถุง Reject -> เลขพาเลท = เลขพาเลทล่าสุด (ช่วงเวลาเดียวกัน) + 1
      เดิมถุง Reject ใช้เลขตันใน QR ซึ่งมีพาเลทอยู่แล้ว (เลขพาเลทซ้ำกับพาเลทเดิม)
      ตอนนี้ : ดูเลขพาเลท (tr_bag.pallet_running_no) ของ cost_center + grade + lot เดียวกัน
      ที่สร้างถุงภายใน ±24 ชม. จากเวลาสร้างถุง Reject -- lot เดียวกันอาจมีหลายชุดเลขวิ่งพร้อมกัน
      (เช่น 1312|1150H|0261005023 : 051-084 คู่กับ 512-542 แล้ววันอื่นมี 001, 400-402)
      -> เอาชุดเลขต่อเนื่องที่มีเลขตันใน QR ของถุงนี้ ใช้เลขสุดท้ายของชุด + 1
         (ไม่เจอชุด -> เลขสูงสุดในช่วงเวลา + 1 ; ช่วงเวลาไม่มีข้อมูล -> เลขสูงสุดทั้ง lot + 1)
      ถ้าเลขนั้นถูกใช้แล้วใน lot (ชุดเลขวันอื่น) -> ขยับไปเลขว่างถัดไป
      -> บันทึกลง pallet_running_no + ton_no ของถุง
      (หน้า Overview แสดงเลขพาเลทจาก tr_bag.pallet_running_no ดู 113_)
      ref_pallet = NULL (พาเลทมือล้วน -- auto-matching ไม่เอาถุงอื่นมาลงพาเลทนี้)
      กันกดพร้อมกันได้เลขซ้ำด้วย sp_getapplock ต่อ cost_center|grade|lot
      ถุง orphan (is_active='Y') ทำงานเหมือนเดิมทุกอย่าง

   ฐาน : definition จริงบน .75 (2026-11-20) -- รวม LogDetail แบบย่อของ 81_/82_ แล้ว
   rollback : 136_rollback_sp_PalletAdjustment_reject_bag_addin_createpallet.sql
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
    @AssignedBagNo INT           OUTPUT,
    @AllowReject   BIT           = 0      -- 1 = รับถุง Reject (is_active='R') ได้ด้วย
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @UnitPallet INT, @CurrentCount INT, @PalletNo VARCHAR(30),
                @IsActive VARCHAR(1), @Qr VARCHAR(100), @TargetTon INT;

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

        --  orphan (is_active='Y' ยังไม่ผูกพาเลท) หรือถุง Reject เมื่อ @AllowReject = 1
        SELECT @IsActive = is_active, @Qr = qr_text_data
        FROM   dbo.tr_bag WITH (UPDLOCK, ROWLOCK)
        WHERE  id = @BagId
          AND  ( (pallet_id IS NULL AND is_active = 'Y')
                 OR (@AllowReject = 1 AND is_active = 'R') );

        IF @IsActive IS NULL
        BEGIN
            SET @ResultCode = 3;
            SET @ResultMessage = N'ถุงนี้ถูกจับคู่กับพาเลทอื่นไปแล้ว หรือไม่พบข้อมูลถุง';
            ROLLBACK TRANSACTION;
            RETURN;
        END

        --  ถุง Reject : ตันของพาเลทปลายทาง = ton_no ที่ถุงบนพาเลทใช้มากสุด (เท่ากันเอาค่าน้อย)
        IF @IsActive = 'R'
            SELECT TOP (1) @TargetTon = ton_no
            FROM   dbo.tr_bag
            WHERE  pallet_id = @PalletId AND is_active = 'Y' AND ton_no IS NOT NULL
            GROUP BY ton_no
            ORDER BY COUNT(*) DESC, ton_no;

        SET @AssignedBagNo = @CurrentCount + 1;

        UPDATE dbo.tr_bag
        SET    pallet_id        = @PalletId,
               bag_no           = @AssignedBagNo,
               bag_status_id    = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               is_active        = 'Y', -- ถุง Reject กลับเป็นถุงปกติ
               ton_no           = CASE WHEN @IsActive = 'R'
                                       THEN COALESCE(@TargetTon, ton_no, pallet_running_no)
                                       ELSE ton_no END,
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

        --  EXEC parameter รับได้แค่ constant/variable/NULL/DEFAULT -- ต้อง build string ก่อน
        DECLARE @LogDetail NVARCHAR(MAX);
        SET @LogDetail = N'*' + ISNULL(@Qr, N'-') + N'* → *' + ISNULL(@PalletNo, N'-') + N'* #' + CAST(@AssignedBagNo AS VARCHAR(10))
                         + CASE WHEN @IsActive = 'R' THEN N' (จากถุง Reject)' ELSE N'' END;

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

--  บันทึก ratio + สร้างพาเลทใหม่ให้ถุง orphan / ถุง Reject 1 ใบ
--  ResultCode : 0 สำเร็จ , 1 ไม่พบถุง/ถุงถูกผูกพาเลทแล้ว , 2 ข้อมูล ratio ไม่ถูกต้อง , -1 error
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
            @IsActive VARCHAR(1), @LogDetail NVARCHAR(MAX),
            @NewPrn INT = NULL, @LockKey NVARCHAR(255),
            @BagTime DATETIME, @WindowHours INT = 24;   -- "ช่วงเวลาเดียวกัน" = ±24 ชม. จากเวลาสร้างถุง

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
        SELECT @Grade = grade, @Cc = cost_center, @Lot = lot, @Qr = qr_text_data, @IsActive = is_active,
               @BagTime = create_datetime
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

        SELECT @Prn = pallet_running_no, @Fmt = qr_format FROM dbo.fParseBagQr(@Qr);

        IF @IsActive = 'R'
        BEGIN
            --  ถุง Reject : เลขพาเลท = เลขพาเลทล่าสุดของ cost_center + grade + lot + 1 (ดูหัวไฟล์)
            --  lock ต่อ cc|grade|lot ถึง commit -- กดสร้างพร้อมกัน 2 ใบจะไม่ได้เลขซ้ำ
            SET @LockKey = CONCAT(N'PA_CreatePallet|', @Cc, N'|', @Grade, N'|', @Lot);
            EXEC sp_getapplock @Resource = @LockKey, @LockMode = 'Exclusive',
                               @LockOwner = 'Transaction', @LockTimeout = 15000;

            --  เลขพาเลทที่ใช้ในช่วงเวลาเดียวกัน (สร้างถุงภายใน ±@WindowHours ชม. จากเวลาสร้างถุง Reject)
            DECLARE @Win TABLE (p INT PRIMARY KEY);
            INSERT INTO @Win (p)
            SELECT DISTINCT pallet_running_no
            FROM   dbo.tr_bag
            WHERE  grade = @Grade AND cost_center = @Cc AND lot = @Lot
              AND  is_active IN ('Y', 'R')
              AND  pallet_running_no IS NOT NULL
              AND  create_datetime >= DATEADD(HOUR, -@WindowHours, @BagTime)
              AND  create_datetime <  DATEADD(HOUR,  @WindowHours, @BagTime);

            --  lot เดียวกันอาจมีหลายชุดเลขวิ่งพร้อมกัน (เช่น 051-076 กับ 512-531) -> เอาชุดเลขต่อเนื่อง
            --  ที่มีเลขตันใน QR ของถุงนี้ แล้วใช้เลขสุดท้ายของชุด + 1
            ;WITH g AS (SELECT p, p - ROW_NUMBER() OVER (ORDER BY p) AS grp FROM @Win)
            SELECT @NewPrn = MAX(p) + 1
            FROM   g
            WHERE  grp = (SELECT grp FROM g WHERE p = @Prn);

            --  ไม่เจอชุดของถุงนี้ -> เลขสูงสุดในช่วงเวลาเดียวกัน + 1 ; ช่วงเวลานั้นไม่มีเลย -> ทั้ง lot + 1
            IF @NewPrn IS NULL
                SELECT @NewPrn = MAX(p) + 1 FROM @Win;
            IF @NewPrn IS NULL
                SELECT @NewPrn = ISNULL(MAX(pallet_running_no), 0) + 1
                FROM   dbo.tr_bag
                WHERE  grade = @Grade AND cost_center = @Cc AND lot = @Lot
                  AND  is_active IN ('Y', 'R');

            --  กันเลขซ้ำกับพาเลทนอกช่วงเวลา (เช่นชุดเลขที่พิมพ์วันอื่น) -> ขยับไปเลขว่างถัดไป
            WHILE EXISTS (SELECT 1 FROM dbo.tr_bag
                          WHERE  grade = @Grade AND cost_center = @Cc AND lot = @Lot
                            AND  is_active IN ('Y', 'R') AND pallet_running_no = @NewPrn)
                SET @NewPrn += 1;

            SET @Ref = NULL;   -- พาเลทมือล้วน
        END
        ELSE IF @Prn > 0
        BEGIN
            --  ถุง orphan : ref_pallet ตามตันใน QR ถ้ายังว่าง
            --  QR format ใหม่ (มี |ddHHmm) ต่อท้าย '|F6' ให้ตรงกับพาเลทกลุ่ม format ใหม่ของ 13_
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
        SET    pallet_id         = @NewPalletId,
               bag_no            = 1,
               bag_status_id     = 3,   -- MANUAL_MATCHED (see 00_master_bag_status.sql)
               is_active         = 'Y', -- ถุง Reject กลับเป็นถุงปกติ
               pallet_running_no = CASE WHEN @IsActive = 'R' THEN @NewPrn ELSE pallet_running_no END,
               ton_no            = CASE WHEN @IsActive = 'R' THEN @NewPrn ELSE ton_no END,
               update_user_id    = @UserId,
               update_datetime   = GETDATE()
        WHERE  id = @BagId;

        SET @LogDetail = N'*' + @NewPalletNo + N'* จาก' + CASE WHEN @IsActive = 'R' THEN N'ถุง Reject ' ELSE N'ถุงที่ยังไม่ผูกพาเลท ' END + ISNULL(@Qr, N'-')
                         + CASE WHEN @IsActive = 'R' THEN N', เลขพาเลท ' + RIGHT('000' + CAST(@NewPrn AS VARCHAR(10)), 3) ELSE N'' END
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
        SET @ResultMessage = N'สร้างพาเลท ' + @NewPalletNo
                             + CASE WHEN @IsActive = 'R' THEN N' (เลขพาเลท ' + RIGHT('000' + CAST(@NewPrn AS VARCHAR(10)), 3) + N')' ELSE N'' END
                             + N' สำเร็จ';
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
