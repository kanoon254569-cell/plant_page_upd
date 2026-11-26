/* Rollback for sql/135_ct_special_status_name_th.sql -- drops
   pProcessGetSpecialStatusList and the ct_special_status.name_th column.
   Run only after the API no longer calls special-status-list. */
USE [IRPC_QTRACK]
GO

DROP PROC IF EXISTS dbo.pProcessGetSpecialStatusList;
GO

IF COL_LENGTH('dbo.ct_special_status', 'name_th') IS NOT NULL
BEGIN
    ALTER TABLE dbo.ct_special_status DROP COLUMN name_th;
END
GO
