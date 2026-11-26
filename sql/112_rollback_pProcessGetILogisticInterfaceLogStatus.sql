/* Rollback: 112_pProcessGetILogisticInterfaceLogStatus.sql */
USE [IRPC_QTRACK]
GO

IF OBJECT_ID('dbo.pProcessGetILogisticInterfaceLogStatus', 'P') IS NOT NULL
    DROP PROCEDURE [dbo].[pProcessGetILogisticInterfaceLogStatus];
GO
