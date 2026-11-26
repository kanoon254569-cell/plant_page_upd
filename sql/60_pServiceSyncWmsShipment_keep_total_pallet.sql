-- =============================================================
-- 60_pServiceSyncWmsShipment_keep_total_pallet.sql  (IRPC_QTRACK)
-- =============================================================
-- total_pallet of picking (4) / shipping (5) jobs is now calculated by
-- the QTrack API on PATCH job/{jobId}/approve and written to
-- tr_delivery.total_pallet (INSTALL_QR_CODE_SYSTEM_MAIN_API
-- sql/pProcessJobTotalPallet.sql). POST job/picking now sends
-- @total_pallet = NULL, and a WMS shipment can also come without one.
--
-- Change: on update, keep the stored total_pallet when no value is sent,
-- the same way code_t is already kept:
--   total_pallet = ds.total_pallet
--   -> total_pallet = COALESCE(ds.total_pallet, dbo.tr_delivery.total_pallet)
-- A value sent by WMS (sync/wms-shipment) still overwrites it.
--
-- Patched from the live definition with REPLACE (same way as sql/47):
-- the piece must be found exactly once, else nothing is changed.
-- Idempotent: skipped when already patched. Needs 53 deployed first.
-- =============================================================
USE IRPC_QTRACK;
GO

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.pServiceSyncWmsShipment'));

IF @d LIKE N'%COALESCE(ds.total_pallet, dbo.tr_delivery.total_pallet)%'
BEGIN
    PRINT 'pServiceSyncWmsShipment already keeps total_pallet - skipped.';
    RETURN;
END

DECLARE @o1 NVARCHAR(400) = N'total_pallet = ds.total_pallet,';
DECLARE @n1 NVARCHAR(400) = N'total_pallet = COALESCE(ds.total_pallet, dbo.tr_delivery.total_pallet),';

IF (LEN(@d) - LEN(REPLACE(@d, @o1, N''))) / LEN(@o1) <> 1
BEGIN
    RAISERROR('pServiceSyncWmsShipment: text to patch not found exactly once - not patched.', 16, 1);
    RETURN;
END

SET @d = REPLACE(@d, @o1, @n1);
--  53 deployed it as CREATE OR ALTER -- only a plain CREATE needs turning into ALTER
IF CHARINDEX(N'CREATE OR ALTER', @d) = 0
    SET @d = STUFF(@d, CHARINDEX(N'CREATE PROC', @d), LEN(N'CREATE'), N'ALTER');

EXEC sp_executesql @d;
PRINT 'pServiceSyncWmsShipment patched: keep total_pallet when none is sent.';
GO
