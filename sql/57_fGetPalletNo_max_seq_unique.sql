-- =============================================================
-- 57_fGetPalletNo_max_seq_unique.sql  (IRPC_QTRACK)
-- =============================================================
-- fGetPalletNo: next running no = highest number already used today for
-- this prefix + 1, instead of COUNT(today's rows of this type) + 1.
-- Plus a unique index on tr_pallet.pallet_no as a last guard.
--
-- Why: COUNT + 1 repeats an existing number as soon as any pallet created
-- that day is deleted (or created with another date). Checked 2026-10-01:
-- 3 past days already have COUNT <> highest number, so a new pallet on such
-- a day would have got a pallet_no that already exists. tr_pallet had no
-- unique index on pallet_no, so the duplicate was saved silently.
--
-- Output format is unchanged: 'PL' + type + yymmdd + running no padded to
-- 4 digits ('PLJ2610010061'); 10000+ still works (5 digits), same as
-- FORMAT(..., 'D4') did. When there is no gap, MAX = COUNT, so the numbers
-- it gives are the same as before.
--
-- Callers (all create one pallet at a time): pServiceMatchBagToPallet
-- (app lock), pProcessInsertJbPalletBag (app lock), pProcessSpecialPalletizing,
-- sp_PalletAdjustment_ShiftMissingBag. The last two have no lock: two calls
-- at the same moment can still pick the same number -- with the unique index
-- the second INSERT now fails (and rolls back) instead of saving a duplicate.
--
-- Checked before creating the index: no duplicate pallet_no, no NULL.
-- =============================================================

CREATE OR ALTER FUNCTION [dbo].[fGetPalletNo]
(
    @pallet_type VARCHAR(1)
)
RETURNS VARCHAR(30)
AS
BEGIN
    DECLARE @prefix VARCHAR(20) =
          'PL'
        + @pallet_type
        + RIGHT(CONVERT(VARCHAR(4), YEAR(GETDATE())), 2)
        + RIGHT('0' + CONVERT(VARCHAR(2), MONTH(GETDATE())), 2)
        + RIGHT('0' + CONVERT(VARCHAR(2), DAY(GETDATE())), 2);

    DECLARE @last INT = (
        SELECT MAX(TRY_CONVERT(INT, SUBSTRING(x.pallet_no, LEN(@prefix) + 1, 10)))
        FROM dbo.tr_pallet x
        WHERE x.pallet_no LIKE @prefix + '%'
    );

    RETURN @prefix + FORMAT(ISNULL(@last, 0) + 1, 'D4');
END
GO

-- -------------------------------------------------------------
-- Unique pallet_no (skipped with a message if duplicates exist)
-- -------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.tr_pallet') AND name = 'UX_tr_pallet_pallet_no')
BEGIN
    IF EXISTS (SELECT pallet_no FROM dbo.tr_pallet WHERE pallet_no IS NOT NULL GROUP BY pallet_no HAVING COUNT(*) > 1)
        RAISERROR('UX_tr_pallet_pallet_no not created: tr_pallet has duplicate pallet_no. Fix them first.', 16, 1);
    ELSE
        CREATE UNIQUE NONCLUSTERED INDEX UX_tr_pallet_pallet_no
            ON dbo.tr_pallet (pallet_no)
            WHERE pallet_no IS NOT NULL;
END
GO
