/* =====================================================================
   81) tr_transaction_log -- ทำ detail ให้กระชับ
   ---------------------------------------------------------------------
   ข้อความ detail เดิมยาวและซ้ำกับคอลัมน์อื่นบนหน้า Transaction Log:
   - "โดย User ID: n"     -> ซ้ำกับคอลัมน์ Editor (create_user_id)
   - "Reject ถุง", "สร้างรายการย้ายสินค้าภายในคลัง" -> ซ้ำกับ topic/activity
   - Bag ID / Pallet ID ภายใน  -> user ไม่ได้ใช้ ใช้ pallet_no / QR / เลขถุงแทน
   และ tr_transaction_log.detail เป็น nvarchar(255) ข้อความยาวจึงถูกตัดท้าย

   รูปแบบใหม่: *pallet_no* / *QR* / *เลขที่งาน* ครอบด้วย *...* (หน้า FE ทำเป็นตัวหนา),
   "#n" = เลขถุง, "→" = จาก -> ไป (เหมือน log ของ Location/Forklift)

   วิธี patch: แก้ definition จริงบน DB (ไม่ใช้ไฟล์ .sql เดิมในโฟลเดอร์นี้ซึ่งอาจเก่ากว่า DB)
   - end_marker = NULL : REPLACE(marker -> new_text)
   - end_marker มีค่า  : แทนที่ช่วงตั้งแต่ marker ครั้งที่ occ ถึง end_marker ตัวแรกหลังจากนั้น
   แล้ว CREATE -> ALTER + sp_executesql -- รันซ้ำได้ (new_text ขึ้นต้นด้วย marker เดิม)
   Log เก่าที่บันทึกไปแล้วไม่ถูกแก้
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @patch TABLE (seq INT IDENTITY, proc_name SYSNAME, marker NVARCHAR(200), occ INT, end_marker NVARCHAR(200), new_text NVARCHAR(MAX));

INSERT INTO @patch (proc_name, marker, occ, end_marker, new_text) VALUES
-- Internal Transfer : *IT20260917-0001* จำนวน 2,000 kg
(N'pProcessCreateInternalTransferJob', N'DECLARE @detail NVARCHAR(MAX) = CONCAT(', 1, N';',
 N'DECLARE @detail NVARCHAR(MAX) = CONCAT(N''*'', @system_no, N''* จำนวน '', FORMAT(@source_total, N''#,0.###''), N'' '', ISNULL(@qty_unit, N''''));'),
(N'pProcessUpdateInternalTransferJob', N'DECLARE @detail NVARCHAR(MAX) = CONCAT(', 1, N';',
 N'DECLARE @detail NVARCHAR(MAX) = CONCAT(N''*'', @system_no, N''* จำนวน '', FORMAT(@source_total, N''#,0.###''), N'' '', ISNULL(@qty_unit, N''''));'),

-- Special Job : ID: 5 | ลบเอกสาร *SP-001*
(N'pProcessDeleteSpecialJob', N'DECLARE @sp_detail NVARCHAR(255) = LEFT(', 1, N';',
 N'DECLARE @sp_detail NVARCHAR(255) = LEFT(N''ID: '' + CAST(@id AS NVARCHAR(20)) + N'' | ลบเอกสาร *'' + ISNULL(@doc_no, N''-'') + N''*'', 255);'),

-- Bag : ID: 10 | เกรด *A* → *B*  /  ID: 10 | ลบถุง
(N'pProcessInsertUpdateTrBag', N'N'' | ถุง ID '' + CAST(@id AS VARCHAR(max)) + N'':'' + @detail', 1, NULL,
 N'N'' | '' + @detail'),
(N'pProcessInsertUpdateTrBag', N'N'' | ถุง ID '' + CAST(@id AS VARCHAR(max)) + N'':ลบออกจากระบบ''', 1, NULL,
 N'N'' | ลบถุง'''),

-- Edit Bag : *PL001* ถุง #5: Grade A → B, Ton 1 → 2   (เฉพาะช่องที่เปลี่ยน)
(N'pProcessPalletMgmtEditBag', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@PalletNo, N''-'') + N''* ถุง #'' + CAST(@BagNo AS VARCHAR(10)) + N'': '' + ISNULL(STUFF(
              CASE WHEN ISNULL(@OldCostCenter, '''') <> @CostCenter THEN N'', CC '' + ISNULL(@OldCostCenter, N''-'') + N'' → '' + @CostCenter ELSE N'''' END
            + CASE WHEN ISNULL(@OldGrade, '''') <> @Grade THEN N'', Grade '' + ISNULL(@OldGrade, N''-'') + N'' → '' + @Grade ELSE N'''' END
            + CASE WHEN ISNULL(@OldLot, '''') <> @Lot THEN N'', Lot '' + ISNULL(@OldLot, N''-'') + N'' → '' + @Lot ELSE N'''' END
            + CASE WHEN ISNULL(@OldBagNo, -1) <> @BagNo THEN N'', Bag '' + ISNULL(CAST(@OldBagNo AS VARCHAR(10)), N''-'') + N'' → '' + CAST(@BagNo AS VARCHAR(10)) ELSE N'''' END
            + CASE WHEN ISNULL(@OldPalletRunningNo, -1) <> @PalletRunningNo THEN N'', Ton '' + ISNULL(CAST(@OldPalletRunningNo AS VARCHAR(10)), N''-'') + N'' → '' + CAST(@PalletRunningNo AS VARCHAR(10)) ELSE N'''' END
            , 1, 2, N''''), N''ไม่มีการเปลี่ยนแปลง'');'),

-- Merge Pallet : *PL001* (10) → *PL002* (30) รวม 40, unit_pallet 30 → 40, ย้ายถุงต้นทาง 10 ถุง (Manual -> Auto)
(N'pProcessPalletMgmtMergePallet', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + @SrcNo + N''* ('' + CAST(@SrcQty AS VARCHAR(20)) + N'') → *'' + @TgtNo + N''* ('' + CAST(@TgtQty AS VARCHAR(20)) + N'') รวม '' + CAST(@TotalQty AS VARCHAR(20))
                         + N'', unit_pallet '' + ISNULL(CAST(@TgtUnitPallet AS VARCHAR(20)), N''-'') + N'' → '' + CAST(@NewUnitPallet AS VARCHAR(20))
                         + CASE WHEN @Case = 1 THEN N'', ลบถุงต้นทาง '' ELSE N'', ย้ายถุงต้นทาง '' END
                         + CAST(CASE WHEN @BagDetail IS NULL THEN 0 ELSE LEN(@BagDetail) - LEN(REPLACE(@BagDetail, N'', '', N'','')) + 1 END AS VARCHAR(10)) + N'' ถุง''
                         + ISNULL(N'' ('' + @CaseText + N'')'', N'''');'),

-- Move Bag : *PL001* #3 → *PL002* #7
(N'pProcessPalletMgmtMoveBag', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@SrcPalletNo, N''-'') + N''* #'' + ISNULL(CAST(@SrcBagNo AS VARCHAR(10)), N''-'') + N'' → *'' + ISNULL(@PalletNo, N''-'') + N''* #'' + CAST(@AssignedBagNo AS VARCHAR(10));'),

-- Swap Bag : *PL002* #4 ↔ *PL001* #2
(N'pProcessPalletMgmtReplaceBag', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + @NewPalletNo + N''* #'' + ISNULL(CAST(@NewSlotNo AS VARCHAR(10)), N''-'') + N'' ↔ *'' + @PalletNo + N''* #'' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N''-'');'),
-- Replace Bag : *PL001* #2: <QR เดิม> → <QR ใหม่> (ถุงเดิม Reject) เหตุผล: ...
(N'pProcessPalletMgmtReplaceBag', N'SET @LogDetail', 2, N';',
 N'SET @LogDetail = N''*'' + @PalletNo + N''* #'' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N''-'') + N'': '' + @OldQr + N'' → '' + @NewQr + N'' (ถุงเดิม Reject)''
                         + ISNULL(N'' เหตุผล: '' + NULLIF(LTRIM(RTRIM(@Reason)), ''''), N'''');'),

-- Reject Bag : *<QR>* ออกจาก *PL001* เหตุผล: ...   /   Unreject Bag : *<QR>*
(N'pProcessUpdateBagRejectStatus', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@qr, N''-'') + N''*''
                                 + ISNULL(N'' ออกจาก *'' + (SELECT pallet_no FROM dbo.tr_pallet WHERE id = @cur_pallet_id) + N''*'', N'''')
                                 + ISNULL(N'' เหตุผล: '' + NULLIF(@reason, ''''), N'''');'),
(N'pProcessUpdateBagRejectStatus', N'SET @LogDetail', 2, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@qr, N''-'') + N''*'';'),

-- Add Bag In : *<QR>* → *PL001* #7
(N'sp_PalletAdjustment_AddBagIn', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL((SELECT qr_text_data FROM dbo.tr_bag WHERE id = @BagId), N''-'') + N''* → *'' + ISNULL(@PalletNo, N''-'') + N''* #'' + CAST(@AssignedBagNo AS VARCHAR(10));'),

-- Create Pallet : *PL001* จาก Orphan <QR>, ratio 25×40 BAG (เดิม 25×30 BAG)   (grade อยู่ใน QR แล้ว)
(N'sp_PalletAdjustment_CreatePallet', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + @NewPalletNo + N''* จาก '' + CASE WHEN @IsActive = ''R'' THEN N''ถุง Reject '' ELSE N''Orphan '' END + ISNULL(@Qr, N''-'')
                         + N'', ratio '' + CAST(@UnitRatio AS VARCHAR(10)) + N''×'' + CAST(@UnitPallet AS VARCHAR(10)) + ISNULL(N'' '' + @UnitCode, N'''')
                         + CASE WHEN @RatioAction = N''แก้ไข''
                                THEN N'' (เดิม '' + ISNULL(CAST(@OldRatio AS VARCHAR(10)), N''-'') + N''×'' + ISNULL(CAST(@OldPallet AS VARCHAR(10)), N''-'') + ISNULL(N'' '' + @OldCode, N'''') + N'')''
                                WHEN @RatioAction = N''ไม่เปลี่ยน'' THEN N''''
                                ELSE N'' ('' + @RatioAction + N'' ratio)'' END;'),

-- Finish Pallet : *PL001* เป็นพาเลทเศษ 25/40 ถุง
(N'sp_PalletAdjustment_FinishPallet', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@palletNo, N''-'') + N''* เป็นพาเลทเศษ '' + CAST(@BagCount AS VARCHAR(10)) + N''/'' + CAST(@unitPallet AS VARCHAR(10)) + N'' ถุง'';'),

-- Pull Bag Out : 2 ถุง: *PL001* #2, *PL001* #5
(N'sp_PalletAdjustment_PullBagOut', N'SELECT  @BagSummary = STRING_AGG(', 1, N'FROM    @BeforeSnapshot;',
 N'SELECT  @BagSummary = STRING_AGG(CONCAT(N''*'', ISNULL(pallet_no, N''-''), N''* #'', ISNULL(CAST(bag_no AS VARCHAR(10)), N''-'')), N'', '')
        FROM    @BeforeSnapshot;'),
(N'sp_PalletAdjustment_PullBagOut', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = CAST((SELECT COUNT(*) FROM @Ids) AS VARCHAR(10)) + N'' ถุง: '' + ISNULL(@BagSummary, N''-'');'),

-- Reorder Pallet : *PL001* 40 ถุง
(N'sp_PalletAdjustment_ReorderPallet', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@PalletNo, N''-'') + N''* '' + CAST(@BagCount AS VARCHAR(10)) + N'' ถุง'';'),

-- Shift Missing Bag : ถุง #5 หาย: ย้าย 35 ถุง *PL001* → *PL009*
(N'sp_PalletAdjustment_ShiftMissingBag', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''ถุง #'' + CAST(@MissingBagNo AS VARCHAR(10)) + N'' หาย: ย้าย '' + CAST(@MovedCount AS VARCHAR(10)) + N'' ถุง *'' + ISNULL(@SrcPalletNo, N''-'') + N''* → *'' + ISNULL(@NewPalletNo, N''-'') + N''*'';');

DECLARE @proc SYSNAME, @d NVARCHAR(MAX), @seq INT, @marker NVARCHAR(200), @occ INT, @end NVARCHAR(200),
        @new NVARCHAR(MAX), @s INT, @e INT, @i INT, @err NVARCHAR(400);

DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT proc_name FROM @patch;
OPEN pc;
FETCH NEXT FROM pc INTO @proc;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @d = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @proc));
    IF @d IS NULL
    BEGIN
        SET @err = N'ไม่พบ dbo.' + @proc;
        THROW 50001, @err, 1;
    END

    SET @seq = 0;
    WHILE 1 = 1
    BEGIN
        SELECT TOP 1 @seq = seq, @marker = marker, @occ = occ, @end = end_marker, @new = new_text
        FROM   @patch WHERE proc_name = @proc AND seq > @seq ORDER BY seq;
        IF @@ROWCOUNT = 0 BREAK;

        IF @end IS NULL
            SET @d = REPLACE(@d, @marker, @new);
        ELSE
        BEGIN
            SET @s = 0;  SET @i = 0;
            WHILE @i < @occ
            BEGIN
                SET @s = CHARINDEX(@marker, @d, @s + 1);
                IF @s = 0 BREAK;
                SET @i += 1;
            END
            SET @e = CASE WHEN @s > 0 THEN CHARINDEX(@end, @d, @s) ELSE 0 END;
            IF @e = 0
            BEGIN
                SET @err = N'dbo.' + @proc + N': ไม่พบ "' + @marker + N'" ครั้งที่ ' + CAST(@occ AS NVARCHAR(5));
                THROW 50002, @err, 1;
            END
            SET @d = STUFF(@d, @s, @e + LEN(@end) - @s, @new);
        END
    END

    SET @s = PATINDEX(N'%CREATE%PROC%', @d);
    SET @d = STUFF(@d, @s, 6, N'ALTER');
    EXEC sys.sp_executesql @d;
    PRINT N'patched dbo.' + @proc;

    FETCH NEXT FROM pc INTO @proc;
END
CLOSE pc;
DEALLOCATE pc;
