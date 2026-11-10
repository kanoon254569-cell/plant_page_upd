/* =====================================================================
   82) tr_transaction_log -- ทำ detail ให้กระชับ (รอบ 2)
   ---------------------------------------------------------------------
   pProcessPalletMgmtEditBag, pProcessPalletMgmtReplaceBag,
   sp_PalletAdjustment_CreatePallet ถูก ALTER ทับเมื่อ 2026-10-22
   ข้อความ log จึงกลับเป็นแบบเก่า ("... (ID: n) ... โดย User ID: n")
   ไฟล์นี้ใช้ patch ชุดเดียวกับ 81_tr_transaction_log_concise_detail.sql
   เฉพาะ 3 proc นี้ -- แก้เฉพาะบล็อก SET @LogDetail, logic อื่นของ proc ไม่ถูกแตะ
   สาเหตุ: commit 2026-10-22 (6207cdf, 982a92e) รันไฟล์ 27_/79_ ซ้ำเพื่อรองรับ QR format ใหม่
   (|ddHHmm, ref_pallet '|F6') แต่ไฟล์ยังเป็น log แบบเก่า -> ทับ patch 81
   ไฟล์ 27_/79_ แก้เป็น format ใหม่แล้ว รันซ้ำจะไม่ทับอีก
   Create Pallet ใช้คำ "ถุงที่ยังไม่ผูกพาเลท" แทน "Orphan" ตามที่ 10-22 เปลี่ยนไว้
   รันซ้ำได้, Log เก่าที่บันทึกไปแล้วไม่ถูกแก้
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @patch TABLE (seq INT IDENTITY, proc_name SYSNAME, marker NVARCHAR(200), occ INT, end_marker NVARCHAR(200), new_text NVARCHAR(MAX));

INSERT INTO @patch (proc_name, marker, occ, end_marker, new_text) VALUES
-- Edit Bag : *PL001* ถุง #5: Grade A → B, Ton 1 → 2   (เฉพาะช่องที่เปลี่ยน)
(N'pProcessPalletMgmtEditBag', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + ISNULL(@PalletNo, N''-'') + N''* ถุง #'' + CAST(@BagNo AS VARCHAR(10)) + N'': '' + ISNULL(STUFF(
              CASE WHEN ISNULL(@OldCostCenter, '''') <> @CostCenter THEN N'', CC '' + ISNULL(@OldCostCenter, N''-'') + N'' → '' + @CostCenter ELSE N'''' END
            + CASE WHEN ISNULL(@OldGrade, '''') <> @Grade THEN N'', Grade '' + ISNULL(@OldGrade, N''-'') + N'' → '' + @Grade ELSE N'''' END
            + CASE WHEN ISNULL(@OldLot, '''') <> @Lot THEN N'', Lot '' + ISNULL(@OldLot, N''-'') + N'' → '' + @Lot ELSE N'''' END
            + CASE WHEN ISNULL(@OldBagNo, -1) <> @BagNo THEN N'', Bag '' + ISNULL(CAST(@OldBagNo AS VARCHAR(10)), N''-'') + N'' → '' + CAST(@BagNo AS VARCHAR(10)) ELSE N'''' END
            + CASE WHEN ISNULL(@OldPalletRunningNo, -1) <> @PalletRunningNo THEN N'', Ton '' + ISNULL(CAST(@OldPalletRunningNo AS VARCHAR(10)), N''-'') + N'' → '' + CAST(@PalletRunningNo AS VARCHAR(10)) ELSE N'''' END
            , 1, 2, N''''), N''ไม่มีการเปลี่ยนแปลง'');'),

-- Swap Bag : *PL002* #4 ↔ *PL001* #2
(N'pProcessPalletMgmtReplaceBag', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + @NewPalletNo + N''* #'' + ISNULL(CAST(@NewSlotNo AS VARCHAR(10)), N''-'') + N'' ↔ *'' + @PalletNo + N''* #'' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N''-'');'),
-- Replace Bag : *PL001* #2: <QR เดิม> → <QR ใหม่> (ถุงเดิม Reject) เหตุผล: ...
(N'pProcessPalletMgmtReplaceBag', N'SET @LogDetail', 2, N';',
 N'SET @LogDetail = N''*'' + @PalletNo + N''* #'' + ISNULL(CAST(@SlotNo AS VARCHAR(10)), N''-'') + N'': '' + @OldQr + N'' → '' + @NewQr + N'' (ถุงเดิม Reject)''
                         + ISNULL(N'' เหตุผล: '' + NULLIF(LTRIM(RTRIM(@Reason)), ''''), N'''');'),

-- Create Pallet : *PL001* จากถุงที่ยังไม่ผูกพาเลท <QR>, ratio 25×40 BAG (เดิม 25×30 BAG)   (grade อยู่ใน QR แล้ว)
(N'sp_PalletAdjustment_CreatePallet', N'SET @LogDetail', 1, N';',
 N'SET @LogDetail = N''*'' + @NewPalletNo + N''* จาก'' + CASE WHEN @IsActive = ''R'' THEN N''ถุง Reject '' ELSE N''ถุงที่ยังไม่ผูกพาเลท '' END + ISNULL(@Qr, N''-'')
                         + N'', ratio '' + CAST(@UnitRatio AS VARCHAR(10)) + N''×'' + CAST(@UnitPallet AS VARCHAR(10)) + ISNULL(N'' '' + @UnitCode, N'''')
                         + CASE WHEN @RatioAction = N''แก้ไข''
                                THEN N'' (เดิม '' + ISNULL(CAST(@OldRatio AS VARCHAR(10)), N''-'') + N''×'' + ISNULL(CAST(@OldPallet AS VARCHAR(10)), N''-'') + ISNULL(N'' '' + @OldCode, N'''') + N'')''
                                WHEN @RatioAction = N''ไม่เปลี่ยน'' THEN N''''
                                ELSE N'' ('' + @RatioAction + N'' ratio)'' END;');

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
