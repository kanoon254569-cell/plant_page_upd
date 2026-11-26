/* Rollback: 110_tr_ilogistic_interface_log.sql
   WARNING: drops the table and every log row in it. */
USE [IRPC_QTRACK]
GO

IF OBJECT_ID('dbo.tr_ilogistic_interface_log', 'U') IS NOT NULL
    DROP TABLE [dbo].[tr_ilogistic_interface_log];
GO
