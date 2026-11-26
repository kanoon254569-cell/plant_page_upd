-- =============================================================
-- 91_pServiceMatchBagToPallet_skip_unmatchable.sql  (IRPC_QTRACK)
-- =============================================================
-- pServiceRunPalletMatching is the top CPU user of the DB
-- (2026-10-25, plan cache since 2026-10-11): 8,946 runs,
-- 12.6 s CPU / 7.6 s elapsed / 755k reads per run.
--
-- Cause: groups (cost_center + lot) that can never match are
-- processed again on every run. A pending bag (is_active 'Y',
-- bag_status_id 1, pallet_id NULL) puts its group into #grp, but
-- step 2 only takes bags with
--     COALESCE(q.pallet_running_no, b.pallet_running_no) > 0
-- A bag with pallet "000" on its QR (pallet_running_no = 0) is never
-- taken, so it stays pending, and every run rebuilds the whole lot
-- again (#bq_pos, #bq, #asg, steps 2-7) for the same result.
-- On 2026-10-25 for example:
--   1120NK / 1312 / 0261004019 : 1 pending bag (QR ...|02|000)
--                                -> 10,073 bags rebuilt each run
--   GA800  / 1372 / 0261008105 : 39 pending bags with pallet 000
--                                -> 4,107 bags rebuilt each run
--
-- Change (91): in #grp, a pending bag counts only when step 2 can take
-- it: COALESCE(q.pallet_running_no, b.pallet_running_no) > 0 (the same
-- expression as step 2). The reject branches (is_active 'R') are not
-- changed.
--   - A group with at least one matchable pending bag or a reject is
--     processed as before (the whole lot, as before).
--   - A group whose only pending bags have pallet 0 is skipped. It gave
--     the same canonical result on every run, so skipping it changes no
--     data. Its bags stay pending, as they do now.
--   - When such a bag is fixed (QR / pallet_running_no edited to > 0),
--     the group is picked up again on the next run.
--   - The 'unmatched=' count in the message only counts bags of groups
--     in #grp, so the skipped bags are not in it any more.
--
-- Patched from the live definition with REPLACE (same way as sql/85):
-- the piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the patch is already there.
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @proc SYSNAME       = N'dbo.pServiceMatchBagToPallet';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));
DECLARE @nl   NVARCHAR(2)   = NCHAR(10);
IF CHARINDEX(NCHAR(13), @d) > 0 SET @nl = NCHAR(13) + NCHAR(10);

IF @d LIKE N'%(91_)%'
BEGIN
    PRINT 'pServiceMatchBagToPallet already skips unmatchable groups (91_) - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400)  = N'AND ( (b.is_active = ''Y'' AND b.bag_status_id = 1 AND b.pallet_id IS NULL)';
DECLARE @n1 NVARCHAR(1000) = N'AND ( (b.is_active = ''Y'' AND b.bag_status_id = 1 AND b.pallet_id IS NULL' + @nl
    + N'                   -- (91_) เฉพาะถุงที่ step 2 หยิบได้จริง : ถุงพาเลท 0 (QR ...|000) ไม่มีวัน match' + @nl
    + N'                   -- ถ้านับด้วย กลุ่มนั้นจะถูกคำนวณใหม่ทั้ง lot ทุกรอบโดยได้ผลเท่าเดิม' + @nl
    + N'                   AND COALESCE(q.pallet_running_no, b.pallet_running_no) > 0)';

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('pServiceMatchBagToPallet: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pServiceMatchBagToPallet patched (skip groups with only unmatchable pending bags).';
GO
