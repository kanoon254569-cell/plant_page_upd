/* =====================================================================
   pProcessGetPalletListByLocation
   -----------------------------------------------------------------
   Lists every pallet currently sitting in one MWH location -- backs the
   "เลือกเป็นรายพาเลท" (pallet-mode) picker on the Source-location step of
   job-wh-internal-transfer-list (component: select-internal-transfer-
   location.ts, onOpenPalletPicker).

   Unlike the existing pProcessGetPalletList (grade/lot/pallet_no search
   across all locations, used by Pallet Management/Information), this is
   scoped purely by location: a single MWH location can physically hold
   pallets of more than one grade/lot, and the picker needs to show every
   pallet actually sitting there -- not just whatever grade/lot the Stock
   Inquiry filter happened to be on when the location was found.

   Filter: tr_pallet.current_location_type = @location_type ('MWH')
           AND tr_pallet.current_location_id = @location_id
           AND tr_pallet.status_flag = 'A'
   (plus is_active = 'Y', matching the convention every other tr_pallet
   query in this project already uses to exclude closed/emptied pallets
   -- see pProcessGetPalletList.sql and pallet_matching_service.sql step 8).

   cost_center/grade/lot/ton_no/qty per pallet are looked up from tr_bag (tr_pallet itself
   has no grade/lot column) -- all active bags on one pallet share the
   same grade/lot by construction (pallet key = cost_center+grade+lot,
   see pallet-matching-service memory), so TOP 1 is sufficient.
   ===================================================================== */
USE [IRPC_QTRACK]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[pProcessGetPalletListByLocation]
    @location_type  NVARCHAR(255)   = 'MWH',
    @location_id    INT             = NULL,
    @page           INT             = 1,
    @page_size      INT             = 1000
AS
BEGIN
    SET NOCOUNT ON;

    -- =============================================================
    -- Return status and message based on data retrieval result.
    -- status stays 'success' even with zero matching pallets (only
    -- "message" differs) -- an empty location is not an error
    -- condition, same convention as pProcessGetPalletList.
    -- =============================================================

    SELECT
        'success' AS status,
        CASE WHEN EXISTS (
            SELECT 1
            FROM dbo.tr_pallet tp
            WHERE tp.current_location_type = @location_type
              AND tp.current_location_id  = @location_id
              AND tp.status_flag = 'A'
              AND tp.is_active   = 'Y'
        ) THEN 'Data retrieved successfully.' ELSE 'No data retrieved.' END AS message;

    -- =============================================================
    -- Paginated pallet list for this location.
    -- =============================================================

    SELECT
        tp.id               AS id,
        tp.pallet_no        AS pallet_no,
        b.cost_center       AS cost_center,
        b.grade             AS grade,
        b.lot               AS lot,
        b.ton_no            AS ton_no,
        ISNULL(bc.bag_count, 0) * tp.unit_ratio AS qty,
        tp.create_datetime  AS create_datetime
    FROM dbo.tr_pallet tp
    OUTER APPLY (
        SELECT TOP 1 tb.cost_center, tb.grade, tb.lot, tb.ton_no
        FROM dbo.tr_bag tb
        WHERE tb.pallet_id = tp.id
          AND tb.is_active = 'Y'
          AND tb.status_flag = 'A'
    ) b
    OUTER APPLY (
        SELECT COUNT(*) AS bag_count
        FROM dbo.tr_bag tb
        WHERE tb.pallet_id = tp.id
          AND tb.is_active = 'Y'
          AND tb.status_flag = 'A'
    ) bc
    WHERE tp.current_location_type = @location_type
      AND tp.current_location_id  = @location_id
      AND tp.status_flag = 'A'
      AND tp.is_active   = 'Y'
    ORDER BY tp.id
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;

    -- =============================================================
    -- total_count must match the grain of the list above (1 row per
    -- pallet) so pagination on the frontend stays correct.
    -- =============================================================

    SELECT COUNT(*) AS total_count
    FROM dbo.tr_pallet tp
    WHERE tp.current_location_type = @location_type
      AND tp.current_location_id  = @location_id
      AND tp.status_flag = 'A'
      AND tp.is_active   = 'Y';
END
GO

-- ตัวอย่างเรียกใช้:
-- EXEC dbo.pProcessGetPalletListByLocation @location_type = 'MWH', @location_id = 123
