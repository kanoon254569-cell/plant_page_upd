-- =============================================================
-- 93_fRequestJob_drop_hash_hint.sql  (IRPC_QTRACK)
-- =============================================================
-- fRequestJob: drop the LEFT HASH JOIN hint on the pallet CTE
-- (same change as fTransferSlipJob got on 2026-10-07).
--
-- After 92, the fRequestJob INSERT is the slowest part of GET
-- process/job (pProcessGetJobList): 330 ms / 8.7k reads of a 711 ms
-- call for 2026-10-01..25.
--
-- Cause (from STATISTICS PROFILE): a join hint (HASH/LOOP/MERGE)
-- anywhere in a query forces the join order of the WHOLE query,
-- including everything inlined from fRequestBags. fRequestBags is
-- written "FROM dbo.tr_pallet p INNER JOIN (history) ph ...", so with
-- the order forced, every request job scans tr_pallet first:
--   Index Scan IX_tr_pallet_lookup_covering : 16 executes,
--   190,380 rows, for 16 jobs that have 690 bags.
-- Without the hint the optimizer starts from the job's
-- tr_pallet_history rows and seeks tr_pallet by id.
--
-- Only change vs. the deployed version: "LEFT HASH JOIN pallet AS p" ->
-- "LEFT JOIN pallet AS p".
--
-- Measured on IRPC_QTRACK 2026-10-25 (same plan cache, no compile in
-- the timing), same rows returned:
--   2026-10-01..25 (16 jobs)   328 ms -> 32 ms
--   all request jobs (79)      375 ms -> 94 ms
--   one job_main_id (778)       62 ms ->  0 ms
--   all 79 jobs, all 59 columns : EXCEPT both ways = 0 rows;
--   COUNT and SUM(receive_qty + complete_qty) equal in every case.
--
-- Callers: pProcessGetJobList, pProcessGetForkliftJobs,
-- pServiceGetGradeForMatching, vRequestJob (SELECT * ... (NULL, NULL,
-- NULL)). Columns and column order are not changed.
--
-- Patched from the live definition with REPLACE (same way as sql/85):
-- the piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when the hint is already gone.
-- Rollback: sql/93_rollback_fRequestJob.sql (the definition before
-- this patch, SHA-256 checked).
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @proc SYSNAME       = N'dbo.fRequestJob';
DECLARE @d    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@proc));

IF @d NOT LIKE N'%LEFT HASH JOIN pallet AS p%'
BEGIN
    PRINT 'fRequestJob has no LEFT HASH JOIN on pallet (93_) - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(100) = N'LEFT HASH JOIN pallet AS p';
DECLARE @n1 NVARCHAR(100) = N'LEFT JOIN pallet AS p';

IF (DATALENGTH(@d) - DATALENGTH(REPLACE(@d, @o1, N''))) / DATALENGTH(@o1) <> 1
BEGIN
    RAISERROR('fRequestJob: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
SET @d = STUFF(@d, CHARINDEX(N'CREATE', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'fRequestJob patched (93_: LEFT HASH JOIN -> LEFT JOIN).';
GO
