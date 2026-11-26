/* Rollback: 113_pILogistic_ProcessCBGetShipmentStatus.sql */
USE [IRPC_QTRACK]
GO

IF OBJECT_ID('dbo.pILogistic_ProcessCBGetShipmentStatus', 'P') IS NOT NULL
    DROP PROCEDURE [dbo].[pILogistic_ProcessCBGetShipmentStatus];
GO
