/* =====================================================================
   82) pProcessGetTransactionLog -- อย่าตัด detail ที่ไม่มี prefix "ID: n | "
   ---------------------------------------------------------------------
   เดิมตัดทุกอย่างถึง '|' ตัวแรก เพื่อซ่อน prefix "ID: n | " / "ID=n | " ของ log
   master (Location/Forklift/Bag/Special Job) แต่ detail ที่มี QR ถุง
   (1311|1100NK|...) ถูกตัด cost center หายไปด้วย เช่น
   "*1311|1100NK|0261001018|30|085* ..." -> "1100NK|0261001018|30|085* ..."
   แก้: ตัดเฉพาะเมื่อขึ้นต้นด้วย "ID:" หรือ "ID=" -- ทั้งคอลัมน์ผลลัพธ์และ filter @detail
   patch ด้วย REPLACE บน definition จริง idempotent
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.pProcessGetTransactionLog'));
DECLARE @old NVARCHAR(200) = N'LTRIM(SUBSTRING(detail, CHARINDEX(''|'', detail) + 1, LEN(detail)))';
DECLARE @new NVARCHAR(400) = N'CASE WHEN detail LIKE ''ID[:=]%|%'' THEN LTRIM(SUBSTRING(detail, CHARINDEX(''|'', detail) + 1, LEN(detail))) ELSE detail END';

IF CHARINDEX(@old, @d) > 0 AND CHARINDEX(N'ID[:=]%|%', @d) = 0
BEGIN
    SET @d = REPLACE(@d, @old, @new);
    SET @d = STUFF(@d, PATINDEX(N'%CREATE%PROC%', @d), 6, N'ALTER');
    EXEC sys.sp_executesql @d;
END
