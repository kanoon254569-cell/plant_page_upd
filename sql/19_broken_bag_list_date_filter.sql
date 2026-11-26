/* ============================================================================
   Broken Bag list -- add a server-side @date filter to pProcessGetBrokenBagList
   ----------------------------------------------------------------------------
   The checker page (broken-bag-list PWA) used to filter the list by date on
   the frontend. It now sends ?date=YYYY-MM-DD (ISO) and expects the stored
   procedure to filter by create_datetime, so the FE keeps no date logic of
   its own. (BrokenBagController parses the ISO string into a DATE before
   binding @date, so the proc still just receives a DATE.)

   The full body of pProcessGetBrokenBagList is NOT in this repo (it was created
   directly in IRPC_QTRACK, like the other pProcess*BrokenBag* procs). Apply the
   three edits below to the LIVE copy.

   BrokenBagController is already forward/backward compatible: it passes @date
   when calling the proc and, if the proc rejects it ("too many arguments",
   error 8144), retries once WITHOUT @date. So the list keeps working before
   this patch is applied -- it just won't filter by date until then.

   Contract:
     @date DATE = NULL
        NULL / not supplied  -> return every date (do NOT default to today;
                                the frontend decides the default and sends it)
        a date               -> only rows whose create_datetime falls on that
                                calendar day

   Dependencies: none -- this is a manual-patch runbook for a stored procedure
   that lives outside this repo (see note above), not a runnable CREATE/ALTER
   script like the other files in this folder. Apply whenever convenient.
   ============================================================================ */

USE [IRPC_QTRACK];
GO

/* ----------------------------------------------------------------------------
   EDIT 1 -- add the parameter to the procedure signature.
   Place it wherever it reads best; keeping it next to @status_id matches the
   BrokenBagController parameter order (@wh_code, @doc_no, @status_id, @date,
   @page, @page_size).

       ALTER PROCEDURE [dbo].[pProcessGetBrokenBagList]
           @wh_code     NVARCHAR(255) = NULL,
           @doc_no      NVARCHAR(255) = NULL,
           @status_id   INT           = NULL,
           @date        DATE          = NULL,     -- <== ADD THIS LINE
           @page        INT           = 1,
           @page_size   INT           = 10
       AS
       BEGIN
           SET NOCOUNT ON;

   ---------------------------------------------------------------------------
   EDIT 2 -- right after SET NOCOUNT ON, derive a SARGable half-open range
   (same pattern as pProcessGetJobList.optimized.sql). Do NOT default @date
   to GETDATE(): a NULL @date must mean "all dates" here.

       DECLARE @date_start DATETIME2(0) = CASE WHEN @date IS NULL THEN NULL
                                               ELSE CAST(@date AS DATETIME2(0)) END;
       DECLARE @date_end   DATETIME2(0) = CASE WHEN @date IS NULL THEN NULL
                                               ELSE DATEADD(DAY, 1, @date_start) END;

   ---------------------------------------------------------------------------
   EDIT 3 -- add one predicate to the WHERE clause of the query that selects
   the broken-bag header rows (the one that produces dbResult1 / the row set
   BrokenBagService.BuildBrokenBagListResponse reads as "dbResult1", and the
   matching COUNT that produces dbResult2 / total_count). Use the same
   create_datetime column the proc already returns as create_datetime:

       AND (@date IS NULL
            OR (h.create_datetime >= @date_start AND h.create_datetime < @date_end))

   Apply the identical predicate to BOTH the data SELECT and the total_count
   SELECT so the count stays consistent with the returned page.
   ---------------------------------------------------------------------------- */
GO
