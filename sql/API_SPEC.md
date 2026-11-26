# Pallet Adjustment — API Spec (สำหรับ Backend .NET)

เอกสารนี้สรุป endpoint ที่ frontend เรียกใช้จริงแล้ว (ดูของจริงได้ที่
[`crud.service.ts`](../src/app/services/crud.service.ts) บรรทัด `processGetPalletAdjustmentOverview`
เป็นต้นไป) จับคู่กับ Stored Procedure ที่มีให้ใน `sql/01-06_*.sql` แล้ว
พร้อม request/response ตรงกับ interface ใน
[`variables-type.ts`](../src/models/variables-type.ts) (บรรทัด 906-1004)

> Base URL (ตาม `this.processUrl` ของ frontend) : `{{baseUrl}}/process/`
> ทุก endpoint ต้องแนบ header `Authorization: Bearer {token}` (ดู `getAuthHeaders()`)
> Permission: ใช้ permission เดิม **`palletManagement`** (เดียวกับที่ sidebar guard เมนูนี้อยู่แล้ว
> ไม่ต้องแยก permission ใหม่ — ยืนยันแล้ว)

---

## 1) GET `/process/pallet-adjustment/overview`

โหลดข้อมูลหน้าแรกของจอ Pallet Adjustment (การ์ดสรุป + พาเลทแยกตามเกรด + ถุงกำพร้า)

**Query string parameters** (ทั้งหมด optional — ไม่ส่งมา = ไม่กรอง)

| ชื่อ | Type | ตรงกับ | หมายเหตุ |
|---|---|---|---|
| `printDateFrom` | string (`yyyy-MM-dd`) | `@PrintDateFrom` | วันที่พิมพ์เริ่มต้น (`tr_bag.create_datetime`, รวมวันนั้น) |
| `printDateTo` | string (`yyyy-MM-dd`) | `@PrintDateTo` | วันที่พิมพ์สิ้นสุด (รวมวันนั้น) |
| `printDate` | string (`yyyy-MM-dd`) | `@PrintDate` | (legacy) วันเดียว -- ใช้เมื่อไม่ส่ง From/To มาทั้งคู่ |
| `ccCode` | string | `@CcCode` | Cost Center code (มาจาก dropdown `ProcessGetOptionsSapCcCode`) |
| `grade` | string | `@Grade` | ตัวพิมพ์ใหญ่เสมอ (frontend บังคับแล้ว แต่ backend ควร `.ToUpper()` ซ้ำเพื่อความปลอดภัย) |
| `lot` | string | `@Lot` | ค้นหาแบบ prefix (`LIKE 'xxx%'`) — **อย่า** ใช้ contains-search เพราะจะ non-sargable |

> ⚠️ frontend ส่ง `printDateFrom`/`printDateTo`/`ccCode`/`grade`/`lot` เป็น empty string `''` เมื่อไม่ได้เลือก
> (ไม่ใช่ omit key) — backend ต้อง treat empty string เหมือน "ไม่กรอง" (แปลงเป็น `NULL` ก่อนส่งเข้า SP)

**Backend action**: `EXEC dbo.sp_PalletAdjustment_GetOverview @PrintDate, @CcCode, @Grade, @Lot, @PrintDateFrom, @PrintDateTo`
(SP คืน 3 result sets ตามลำดับ: summary / pallet-by-grade / orphan-bags — ใน .NET ใช้
`SqlDataReader.NextResultAsync()` อ่านทีละชุด หรือถ้าใช้ Dapper: `QueryMultipleAsync()`)

**Response 200**
```jsonc
{
  "status": "success",
  "message": "",
  "data": {
    "summary": {
      "total_pallets": 12,
      "wh_process": 5,
      "complete": 7,
      "total_bags": 431,
      "orphan_bags": 5,
      "confirmed_remainder": 2
    },
    "grades": [
      {
        "grade": "1126NK",
        "unit_pallet": 40,
        "pallets": [
          {
            "id": 4,
            "pallet_no": "PLA26083000012",
            "lot": "L2608A",
            "pallet_type": "A",
            "bag_count": 38,
            "unit_pallet": 40,
            "location_type": "WH",
            "current_location": "A-01-02",
            "create_datetime": "2026-08-30T09:12:00",
            "status": "wh_process"
          },
          {
            "id": 7,
            "pallet_no": "PLA26083000015",
            "lot": "L2608B",
            "pallet_type": "A",
            "bag_count": 22,
            "unit_pallet": 40,
            "location_type": "WH",
            "current_location": "A-01-05",
            "create_datetime": "2026-08-31T14:40:00",
            "status": "confirmed"
          }
        ]
      }
    ],
    "orphan_bags": [
      {
        "id": 9991,
        "bag_no": null,
        "grade": "1126NK",
        "lot": "L2608A",
        "qr_text_data": "1460|1126NK|L2608A|15|0",
        "status": "orphan"
      }
    ]
  }
}
```
> **จับคู่ column → field**: SP result set #2 คืน column `grade, unit_pallet, id, pallet_no, lot,
> pallet_type, bag_count, pallet_unit_pallet, current_location_type, current_location_id,
> create_datetime, status` แบบ **flat rows** (1 row ต่อ 1 pallet) — backend ต้อง **group by
> `grade`** เองก่อนแมพเป็น `grades[].pallets[]` ตาม shape ด้านบน (แนะนำ `GroupBy` ฝั่ง C#
> เพราะทำใน SQL แล้วจะซับซ้อน/แก้ยากกว่า) ส่วน `current_location` (string ใน response) ต้อง
> map มาจาก `current_location_type` + `current_location_id` — **ต้อง confirm กับผมว่าจะ join
> ตาราง location master ตัวไหนเพื่อแปลง id → ชื่อสถานที่จริง** (SP ปัจจุบันคืนแค่ id ดิบ)

> **status**: map ตรงตัวจาก `pallet_status_id` (ดู `dbo.ct_pallet_status`,
> `00_master_pallet_status.sql`) — `1` CREATED → `wh_process` · `2` COMPLETED (sync
> อัตโนมัติโดย `pServiceMatchBagToPallet` เมื่อ bag_count ≥ unit_pallet) → `complete` ·
> `3` CONFIRMED (ยืนยันพาเลทเศษผ่านปุ่ม "จบพาเลท" — ดู endpoint #7) → `confirmed` (คนละ
> ค่ากับ `complete` โดยตั้งใจ ให้แยกพาเลทที่เต็มเองตามธรรมชาติออกจากพาเลทที่ถูกยืนยันด้วยมือ)
> พาเลทที่ `pallet_status_id = 4` (VOID) จะไม่ปรากฏใน overview นี้เลย
>
> ⚠️ ตั้งแต่ 2026-09-13 SP นี้อ่าน status จาก `pallet_status_id` โดยตรง **ไม่ได้เทียบ**
> `bag_count >= unit_pallet` สด ๆ อีกต่อไป — endpoint #3/#4/#5 (shift-missing/pull-out/
> add-in) sync `pallet_status_id` เองทันทีหลังแก้ bag_count แล้ว (ไม่ต้องรอ auto-matching
> job อีกต่อไป) endpoint #6 (reorder) ไม่ต้อง sync เพราะไม่เปลี่ยน bag_count เลย

> **`summary.confirmed_remainder`**: จำนวน**พาเลท** (ไม่ใช่ถุง) ที่ `pallet_status_id = 3`
> (CONFIRMED) — คือพาเลทที่ถูกกด "จบพาเลท" ยืนยันเป็นพาเลทเศษไปแล้ว (endpoint #7) เท่ากับ
> จำนวนพาเลทที่ `status === 'confirmed'` ใน `grades[].pallets[]` พอดี

**Response เมื่อไม่มีข้อมูล**: `data.grades = []`, `data.orphan_bags = []` (ไม่ใช่ `null`)

**Error response** (`4xx`/`5xx`)
```json
{ "status": "error", "message": "เกิดข้อผิดพลาดในการดึงข้อมูล", "data": null }
```

---

## 2) GET `/process/pallet-adjustment/bag?palletId={id}`

โหลดรายการถุงของ pallet ที่เลือก (แสดงในแผงด้านขวา)

| Query param | Type | หมายเหตุ |
|---|---|---|
| `palletId` | number (required) | `tr_pallet.id` |

**Backend action**: `EXEC dbo.sp_PalletAdjustment_GetBagList @PalletId`

**Response 200**
```json
{
  "status": "success",
  "message": "",
  "data": [
    { "id": 1001, "bag_no": 1, "grade": "1126NK", "lot": "L2608A", "qr_text_data": "1460|1126NK|L2608A|1|4", "status": "matched" },
    { "id": 1015, "bag_no": 15, "grade": "1126NK", "lot": "L2608A", "qr_text_data": "1460|1126NK|L2608A|15|4", "status": "missing" }
  ],
  "total_count": 2
}
```
`status` มาจาก SP โดยตรง (`missing` | `orphan` | `matched`) — ไม่ต้องคำนวณเพิ่มฝั่ง backend

**Error case**: ถ้า `palletId` ไม่พบ → SP จะคืน 0 rows (ไม่ error) → backend ตอบ `200`
พร้อม `data: []`, `total_count: 0` (ไม่ต้องคืน 404 เพื่อลด edge case ฝั่ง frontend)

---

## 3) POST `/process/pallet-adjustment/shift-missing`

กรณีถุงหายกลางพาเลท → เลื่อนทุกถุงหลังตำแหน่งที่หายไปพาเลทใหม่ (auto-generate เลขพาเลทใหม่)

**Request body**
```json
{ "palletId": 4, "missingBagNo": 15, "userId": 101 }
```

**Backend action**: `EXEC dbo.sp_PalletAdjustment_ShiftMissingBag @PalletId, @MissingBagNo, @UserId, @ResultCode OUT, @ResultMessage OUT, @NewPalletId OUT, @NewPalletNo OUT, @MovedCount OUT`

**Response 200 (สำเร็จ, `@ResultCode = 0`)**
```json
{
  "status": "success",
  "message": "สำเร็จ",
  "result": {
    "newPalletId": 27,
    "newPalletNo": "PLA260831 0007",
    "movedCount": 25
  }
}
```

**Response 400 (ทางธุรกิจไม่ผ่าน, `@ResultCode` = 1 หรือ 2)** — backend ต้องตอบ
HTTP 400 (ยืนยันแล้ว ไม่ใช่ 500 และไม่ใช่ 200):
```json
{ "status": "error", "message": "ไม่พบถุงที่ต้องเลื่อนหลังตำแหน่งที่ระบุ", "result": null }
```

**Response 500 (`@ResultCode = -1`, exception จริงจาก DB)**
```json
{ "status": "error", "message": "ERROR_MESSAGE() จาก SQL", "result": null }
```

> mapping `@ResultCode`: `0` = success (HTTP 200) · code อื่นที่ไม่ใช่ 0/-1 (business validation
> เช่น 1, 2) = fail (HTTP 400) · `-1` = unexpected DB error (HTTP 500) — mapping นี้ยืนยันแล้ว
> และใช้เหมือนกันทุก endpoint #3-6 ด้านล่าง

---

## 4) POST `/process/pallet-adjustment/pull-out`

ดึงถุง 1 ใบขึ้นไปออกจาก pallet (กลายเป็น orphan) + auto re-order เลขถุงที่เหลือในทุก
pallet ที่ได้รับผลกระทบ

**Request body**
```json
{ "bagIds": [1005, 1006], "userId": 101 }
```

**Backend action**: แปลง `bagIds` (array) เป็น comma-separated string ก่อนส่งเข้า SP —
`EXEC dbo.sp_PalletAdjustment_PullBagOut @BagIds = '1005,1006', @UserId, @ResultCode OUT, @ResultMessage OUT`

**Response 200 (สำเร็จ)**
```json
{ "status": "success", "message": "สำเร็จ", "result": null }
```

**Response 400 (`@ResultCode = 1` — ไม่พบรายการถุงที่เลือก)**
```json
{ "status": "error", "message": "ไม่พบรายการถุงที่เลือก", "result": null }
```

---

## 5) POST `/process/pallet-adjustment/add-in`

เพิ่มถุง orphan 1 ใบเข้า pallet ที่เลือก (ระบบ assign `bag_no` ต่อท้ายอัตโนมัติ)

**Request body**
```json
{ "bagId": 9990, "palletId": 4, "userId": 101 }
```

**Backend action**: `EXEC dbo.sp_PalletAdjustment_AddBagIn @BagId, @PalletId, @UserId, @ResultCode OUT, @ResultMessage OUT, @AssignedBagNo OUT`

**Response 200 (สำเร็จ)**
```json
{ "status": "success", "message": "สำเร็จ", "result": { "assignedBagNo": 39 } }
```

**Response 400** (`@ResultCode`):
| Code | message |
|---|---|
| 1 | ไม่พบพาเลทปลายทาง |
| 2 | พาเลทเต็มแล้ว ไม่สามารถเพิ่มถุงได้ |
| 3 | ถุงนี้ถูกจับคู่กับพาเลทอื่นไปแล้ว หรือไม่พบข้อมูลถุง |

---

## 6) POST `/process/pallet-adjustment/reorder`

Re-number `bag_no` ของทุกถุง active ใน pallet ใหม่ทั้งหมด ตามลำดับ `create_datetime`

**Request body**
```json
{ "palletId": 4, "userId": 101 }
```

**Backend action**: `EXEC dbo.sp_PalletAdjustment_ReorderPallet @PalletId, @UserId, @ResultCode OUT, @ResultMessage OUT, @BagCount OUT`

**Response 200 (สำเร็จ)**
```json
{ "status": "success", "message": "สำเร็จ", "result": { "bagCount": 38 } }
```

**Response 400 (`@ResultCode = 1`)**
```json
{ "status": "error", "message": "ไม่พบพาเลทที่ต้องการ re-order", "result": null }
```

---

## 7) POST `/process/pallet-adjustment/finish`

Quick Action **"จบพาเลท"** — ใช้กับพาเลทสุดท้ายของ Lot ที่ผลิตไม่ครบจำนวนถุง/พาเลท
(unit_pallet) เพื่อยืนยันพาเลทนี้เป็น **"พาเลทเศษ"** ทันที ด้วยจำนวนถุงปัจจุบัน
โดยไม่ย้าย/แก้ไขถุงใด ๆ และไม่แตะ `unit_pallet` — set แค่ `tr_pallet.pallet_status_id = 3`
(`CONFIRMED`, ดูตาราง `dbo.ct_pallet_status` ใน `00_master_pallet_status.sql`) ของ
พาเลทใบนี้ใบเดียว (สถานะที่คำนวณใน endpoint #1 จะกลายเป็น `confirmed` ทันที — คนละค่ากับ
`complete`, ดู endpoint #1 — ไม่กระทบพาเลทใบอื่นของ grade เดียวกัน)

**Request body**
```json
{ "palletId": 4, "userId": 101 }
```

**Backend action**: `EXEC dbo.sp_PalletAdjustment_FinishPallet @PalletId, @UserId, @ResultCode OUT, @ResultMessage OUT, @BagCount OUT`

**Response 200 (สำเร็จ)**
```json
{ "status": "success", "message": "สำเร็จ", "result": { "bagCount": 27 } }
```

**Response 400** (`@ResultCode`) — ไม่เช็ค `current_job_id`/WH-Process อีกต่อไป
(ตั้งแต่ 2026-09-13 จบพาเลทได้เสมอตราบใดที่ยังไม่ครบ ไม่สนใจว่ามีงาน WMS ผูกอยู่หรือไม่):
| Code | message |
|---|---|
| 1 | ไม่พบพาเลทที่ต้องการจบพาเลท |
| 2 | พาเลทนี้ยังไม่มีถุง ไม่สามารถจบพาเลทได้ |
| 3 | พาเลทนี้ครบจำนวนถุงอยู่แล้ว ไม่จำเป็นต้องจบพาเลท |
| 4 | พาเลทนี้ถูกยืนยันเป็นพาเลทเศษไปแล้ว (`pallet_status_id = 3` อยู่ก่อนแล้ว) |
| 5 | พาเลทนี้ถูกยกเลิกแล้ว (`pallet_status_id = 4` VOID) ไม่สามารถจบพาเลทได้ |

> Frontend guard: ปุ่ม "จบพาเลท" แสดงเฉพาะพาเลทที่ `status === 'wh_process'` และมี
> `bagCount > 0` เท่านั้น (ดู `canFinishSelectedPallet` ใน `pallet-adjustment.ts`) —
> **ไม่ใช่** `!== 'complete'` เฉย ๆ เพราะ `confirmed` เป็น status แยกต่างหากแล้ว
> (พาเลทที่ confirmed ไปแล้วไม่ควรกดซ้ำได้อีก)

---

## 8) GET `/process/pallet-adjustment/grade-ratio?grade={grade}`

Pop-up ปุ่ม **"สร้างพาเลทใหม่"** ของถุงที่ยังไม่ผูกพาเลท — ดึง `ct_grade_package_ratio`
ของ grade (ตัด space) มาให้ผู้ใช้ตรวจ/แก้ `found = false` = ยังไม่มีข้อมูล ให้ผู้ใช้คีย์เอง

**Backend action**: `EXEC dbo.sp_PalletAdjustment_GetGradeRatio @Grade`

```json
{ "status": "success", "message": "", "result": { "grade": "1100NK", "found": true, "unit_ratio": 25, "unit_pallet": 40, "unit_code": "BAG", "last_update_datetime": "2026-10-11T08:00:00" } }
```

## 9) POST `/process/pallet-adjustment/create-pallet`

บันทึกค่าจาก pop-up ลง `ct_grade_package_ratio` (insert ถ้ายังไม่มี / update ถ้าแก้) แล้วสร้าง
พาเลทใหม่ (`fGetPalletNo('A')`) ใส่ถุงนี้เป็นถุงที่ 1 (`bag_status_id = 3` MANUAL_MATCHED)
จากนั้น SP เรียก `EXEC dbo.pServiceRunPalletMatching @create_user_id = 0, @preview = 0` ต่อทันที
(หลัง commit, TRY แยก -- matching ล้มเหลวไม่ทำให้การสร้างพาเลทเป็น error แค่ต่อท้าย message)
เพื่อสร้าง/จับพาเลทของถุงค้างที่เหลือของ grade นั้น -- API ตั้ง `CommandTimeout = 180` วินาที

Pop-up: grade ที่ยังไม่มีข้อมูล ใส่ค่าแนะนำให้ Unit Ratio = 25, Unit Pallet = 40, Unit Code = BG

**Request body**
```json
{ "bagId": 9990, "unitRatio": 25, "unitPallet": 40, "unitCode": "BAG", "userId": 101 }
```

**Backend action**: `EXEC dbo.sp_PalletAdjustment_CreatePallet @BagId, @UnitRatio, @UnitPallet, @UnitCode, @UserId, @ResultCode OUT, @ResultMessage OUT, @NewPalletId OUT, @NewPalletNo OUT`

**Response 200**
```json
{ "status": "success", "message": "สร้างพาเลท A2610110001 สำเร็จ", "result": { "newPalletId": 1234, "newPalletNo": "A2610110001" } }
```

**Response 400** (`@ResultCode`):
| Code | message |
|---|---|
| 1 | ไม่พบถุง หรือถุงนี้ถูกผูกพาเลทไปแล้ว |
| 2 | Unit Ratio / Unit Pallet ไม่ถูกต้อง หรือถุงไม่มี Grade |

---

## สรุป mapping (สำหรับ copy ไปสั่ง AI/Backend .NET โดยตรง)

| # | HTTP | Route | Request | SP | Response wrapper |
|---|---|---|---|---|---|
| 1 | GET | `pallet-adjustment/overview?printDateFrom&printDateTo&ccCode&grade&lot` | query string | `sp_PalletAdjustment_GetOverview` | `{status,message,data}` |
| 2 | GET | `pallet-adjustment/bag?palletId=` | query string | `sp_PalletAdjustment_GetBagList` | `{status,message,data,total_count}` |
| 3 | POST | `pallet-adjustment/shift-missing` | `{palletId, missingBagNo, userId}` | `sp_PalletAdjustment_ShiftMissingBag` | `{status,message,result}` |
| 4 | POST | `pallet-adjustment/pull-out` | `{bagIds:number[], userId}` | `sp_PalletAdjustment_PullBagOut` | `{status,message,result}` |
| 5 | POST | `pallet-adjustment/add-in` | `{bagId, palletId, userId}` | `sp_PalletAdjustment_AddBagIn` | `{status,message,result}` |
| 6 | POST | `pallet-adjustment/reorder` | `{palletId, userId}` | `sp_PalletAdjustment_ReorderPallet` | `{status,message,result}` |
| 7 | POST | `pallet-adjustment/finish` | `{palletId, userId}` | `sp_PalletAdjustment_FinishPallet` | `{status,message,result}` |
| 8 | GET | `pallet-adjustment/grade-ratio?grade=` | query string | `sp_PalletAdjustment_GetGradeRatio` | `{status,message,result}` |
| 9 | POST | `pallet-adjustment/create-pallet` | `{bagId, unitRatio, unitPallet, unitCode?, userId}` | `sp_PalletAdjustment_CreatePallet` | `{status,message,result}` |

หมายเหตุ:
- Endpoint #1 ใช้ key ชื่อ `data` (ไม่ใช่ `result`) เพราะมี field เพิ่ม `total_count`
  ในบาง endpoint (#2) — ตรงตาม interface จริงที่ frontend ประกาศไว้แล้วใน `variables-type.ts`
  **backend ต้องตามชื่อ key นี้เป๊ะ ๆ ห้ามสลับเป็น `result`** มิฉะนั้น frontend deserialize ไม่ตรง
- Endpoint #3-6 ใช้ key `result` (ตาม `ResponseStandard` interface ที่ใช้อยู่ทั่วทั้งระบบแล้ว)
- ทุก endpoint ที่เป็น POST ควรมี `[HttpPost]` + DTO ที่ตรงกับ Request body ด้านบนแบบ 1:1,
  แนะนำ FluentValidation หรือ DataAnnotations ตรวจ required field ก่อนเรียก SP
  (เช่น `palletId > 0`, `bagIds.Count > 0`)
- ทุก mutation endpoint (#3-6) ควรทำเป็น `async` + เรียกผ่าน `SqlCommand` พร้อม
  `CommandType.StoredProcedure` และอ่านค่า output parameter กลับมาหลัง `ExecuteNonQueryAsync()`

## จุดที่ confirm แล้ว

1. **`current_location` string** ใน response ของ endpoint #1 — ผู้ใช้จะปรับ query ใน stored
   procedure เอง (join กับ master table ที่มีอยู่แล้วในระบบ) แล้วส่ง SP ที่แก้ไขแล้วมาให้ —
   **API/adapter ฝั่ง backend ไม่ต้องทำ transform เพิ่ม** รับค่าตรงจาก SP แล้ว pass-through เป็น
   `current_location` ได้เลย
2. **HTTP status code ของ business-validation failure** — ยืนยันแล้วว่าให้ตอบ **`400 Bad Request`**
   (ไม่ใช่ 200) เมื่อ `@ResultCode` = 1, 2, 3 (แล้วแต่ SP) โดย body ยังใช้ shape เดิม
   `{status:"error", message, result:null}` — endpoint #3-6 ทุกตัวใช้ mapping เดียวกัน:
   `0` → 200 · validation code อื่น (1,2,3...) → 400 · `-1` → 500
3. **Auth/permission**: ใช้ permission เดิม **`palletManagement`** (permission เดียวกับที่ sidebar
   ใช้ guard เมนูนี้อยู่แล้ว) ไม่ต้องแยก permission ใหม่

