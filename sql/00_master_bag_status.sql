/* =====================================================================
   Pallet Adjustment - Master: bag_status_id (proposed values)
   -----------------------------------------------------------------
   [dbo].[tr_bag].[bag_status_id] currently has no master/lookup table
   in the schema provided. This is a PROPOSED set of values needed by
   the Pallet Adjustment screen and its stored procedures.

   NOTE: If a ct_bag_status (or similar) table already exists elsewhere
   in the system, ignore this file and just confirm the id mapping below
   matches reality, then update the SPs accordingly.
   ===================================================================== */
USE [IRPC_QTRACK]
GO

/*
    id | code            | description (TH)
    ---|-----------------|--------------------------------------------------
    1  | PRINTED         | พิมพ์ QR แล้ว ยังไม่ถูกจับคู่กับ pallet ใด ๆ (ค่า default ของ tr_bag)
    2  | MATCHED         | จับคู่กับ pallet แล้วโดย matching service อัตโนมัติ
    3  | MANUAL_MATCHED  | จับคู่ / ย้ายเข้าพาเลทด้วยมือผ่านหน้า Pallet Adjustment
    4  | MISSING         | ตรวจพบว่าตำแหน่ง bag_no นี้ขาดหายไปจากพาเลท (ใช้เป็น marker ก่อน shift)
    5  | PULLED_OUT      | เคยอยู่ในพาเลทแล้วถูกดึงออกด้วยมือ (กลายเป็น orphan แต่มีประวัติว่าเคยอยู่)
    6  | REPLACED        | ถูกเปลี่ยนออกจากพาเลทผ่านหน้า Pallet Management (Replace) คู่กับ is_active = 'R'
       |                 | (27_pProcessPalletManagement.sql) -- matching ยังนับครองช่องเดิมไว้ให้ถุงที่ใส่แทน
    9  | VOID           | ยกเลิก/ไม่ใช้งาน (คู่กับ is_active = 'N')

    ตัวอย่างการสร้างตาราง master จริง หากยังไม่มี:
*/

-- IF OBJECT_ID('dbo.ct_bag_status', 'U') IS NULL
-- BEGIN
--     CREATE TABLE dbo.ct_bag_status (
--         id          INT           NOT NULL PRIMARY KEY,
--         code        VARCHAR(30)   NOT NULL,
--         description NVARCHAR(255) NULL
--     );
--
--     INSERT INTO dbo.ct_bag_status (id, code, description) VALUES
--         (1, 'PRINTED',        N'พิมพ์ QR แล้ว ยังไม่ถูกจับคู่กับ pallet ใด ๆ'),
--         (2, 'MATCHED',        N'จับคู่กับ pallet แล้วโดย matching service อัตโนมัติ'),
--         (3, 'MANUAL_MATCHED', N'จับคู่ / ย้ายเข้าพาเลทด้วยมือผ่านหน้า Pallet Adjustment'),
--         (4, 'MISSING',        N'ตรวจพบว่าตำแหน่ง bag_no นี้ขาดหายไปจากพาเลท'),
--         (5, 'PULLED_OUT',     N'เคยอยู่ในพาเลทแล้วถูกดึงออกด้วยมือ'),
--         (6, 'REPLACED',       N'ถูกเปลี่ยนออกจากพาเลท (Replace) คู่กับ is_active = R'),
--         (9, 'VOID',           N'ยกเลิก/ไม่ใช้งาน');
-- END
-- GO
