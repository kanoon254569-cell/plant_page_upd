/* Rollback: 111_pProcessInsertTrILogisticInterfaceLog.sql */
USE [IRPC_QTRACK]
GO

IF OBJECT_ID('dbo.pProcessInsertTrILogisticInterfaceLog', 'P') IS NOT NULL
    DROP PROCEDURE [dbo].[pProcessInsertTrILogisticInterfaceLog];
GO
