# Pallet Adjustment — SQL Draft (IRPC_QTRACK)

ไฟล์ในโฟลเดอร์นี้เป็น **ร่าง Stored Procedure** สำหรับ backend ของหน้า
`Pallet Adjustment` (bag ↔ pallet maintenance) อ้างอิงจาก schema
`dbo.tr_bag` / `dbo.tr_pallet` ที่มีอยู่แล้ว และฟังก์ชัน `dbo.fGetPalletNo`
ที่ใช้ generate `pallet_no` อยู่แล้วในระบบ

> ⚠️ นี่คือ**ร่างเริ่มต้น** ยังไม่ได้ deploy ต้องให้ทีม backend/DBA รีวิวก่อนใช้จริง
> โดยเฉพาะจุดที่มาร์คว่า `-- TODO(confirm)`

## ไฟล์ทั้งหมด

| ไฟล์ | ใช้ทำอะไร |
|---|---|
| `00_master_bag_status.sql` | เสนอค่ามาตรฐานของ `tr_bag.bag_status_id` (ยังไม่เคยกำหนดมาก่อน) |
| `00_master_pallet_status.sql` | สร้างตาราง `dbo.ct_pallet_status` + seed ค่ามาตรฐานของ `tr_pallet.pallet_status_id` (CREATED/COMPLETED/CONFIRMED/VOID) -- รันได้จริง (ไม่ใช่แค่ร่างคอมเมนต์เหมือนไฟล์ bag_status) |
| `01_sp_PalletAdjustment_GetOverview.sql` | โหลดข้อมูลหน้าแรก: การ์ดสรุป + กลุ่มพาเลทตามเกรด + orphan bags |
| `02_sp_PalletAdjustment_GetBagList.sql` | โหลดรายการถุงของ pallet ที่เลือก (bag panel ด้านขวา) |
| `03_sp_PalletAdjustment_ShiftMissingBag.sql` | เลื่อนถุงที่อยู่หลังตำแหน่งถุงที่หายไปทั้งหมด ไปขึ้น pallet ใหม่ (ใช้ `fGetPalletNo`) |
| `04_sp_PalletAdjustment_PullBagOut.sql` | ดึงถุงออกจาก pallet (กลายเป็น orphan) + auto re-order เลขถุงที่เหลือ |
| `05_sp_PalletAdjustment_AddBagIn.sql` | เพิ่มถุง orphan เข้า pallet ที่เลือก |
| `06_sp_PalletAdjustment_ReorderPallet.sql` | Re-order เลข `bag_no` ของทุกถุงใน pallet ใหม่ทั้งหมด |
| `07_indexes.sql` | **Non-clustered index** รองรับทุก SP ด้านบน (ดูหัวข้อ "Performance / Index" ด้านล่าง) — รันหลังสร้าง SP ครบแล้ว |
| `08_sp_PalletAdjustment_FinishPallet.sql` | Quick Action "จบพาเลท" — ยืนยันพาเลทสุดท้ายของ Lot ที่ไม่เต็มเป็น "พาเลทเศษ" (`pallet_status_id = 3 CONFIRMED`) |
| `79_sp_PalletAdjustment_CreatePallet.sql` | Orphan Bag "สร้างพาเลทใหม่" — `sp_PalletAdjustment_GetGradeRatio` (pop-up แสดง/แก้ `ct_grade_package_ratio`) + `sp_PalletAdjustment_CreatePallet` (insert/update ratio แล้วสร้างพาเลท ถุงเป็น `bag_status_id = 3`) — รันหลัง `00`, `09`, `10`, `20` |
| `80_pProcessPalletMgmtMoveBag.sql` | Forklift PWA Pallet Management: Add Bag ด้วย QR พาเลท (`PL<code>\|grade\|lot\|qty`) — `pProcessPalletMgmtMoveBag` ย้ายถุงจากพาเลทอื่นเข้าพาเลทปลายทางทีละถุงใน transaction เดียว (เช็คเต็ม/Grade-Lot, เรียง bag_no ต้นทางใหม่, sync `pallet_status_id` ทั้งสองพาเลท) ผ่าน `POST api/v1/process/pallet-management/move-bag` — รันหลัง `20` |
| `81_pProcessPalletMgmtMergePallet.sql` | Forklift PWA Pallet Management: Add Bag ด้วย QR พาเลท เมื่อมีพาเลท Manual (`pallet_type='M'`, `PLM...`) — `pProcessPalletMgmtMergePallet` รวมทั้งพาเลทในครั้งเดียว: ปลายทาง `unit_pallet = (qty ต้นทาง + qty ปลายทาง) / unit_ratio ปลายทาง` (qty Manual = unit_pallet×unit_ratio, Auto = ถุง×unit_ratio, ต้องหารลงตัว) — M→M ลบ `tr_bag` ต้นทาง, M→A / A→M ย้ายถุงต้นทางมาปลายทาง (bag_status_id=3) — เพิ่มคอลัมน์ `tr_pallet.merge_datetime` (ALTER TABLE ในไฟล์) ปลายทางได้ `merge_datetime` + `pallet_status_id` 1→2 — รวมพาเลท VOID/เข้าคลังแล้วได้ — ต้นทาง `is_active='N'` — A→A ไม่ใช้ (ใช้ `80` เหมือนเดิม) — API `POST pallet-management/merge-pallet` — **ยังไม่ได้รันบน DB** |
| `82_pServiceMatchBagToPallet_skip_merged.sql` | patch definition จริงของ `pServiceMatchBagToPallet` (REPLACE แบบ `44`, idempotent) ให้ step 6.5 ข้ามพาเลทที่ `merge_datetime IS NOT NULL` — ไม่เปลี่ยน `pallet_status_id` ของพาเลทที่รวมแล้วกลับเป็น 1 — ไฟล์ `13` ใน repo แก้แบบเดียวกันแล้ว — deploy `81` → `82` — **ยังไม่ได้รันบน DB** |
| `83_pallet_matching_indexes.sql` | Index ให้ Pallet Matching job (`13`/`14`): ถุงตามกลุ่ม grade+cost_center+lot, ถุงค้าง/reject/ถุงจัดการด้วยมือ (is_active, bag_status_id, pallet_id), ถุงต่อพาเลททุกสถานะ (pallet_id), `tr_pallet.ref_pallet` — ไม่มี filtered index, ไม่เปลี่ยนผลลัพธ์ — รันเมื่อไรก็ได้ — **ยังไม่ได้รันบน DB** |
| `81_tr_transaction_log_concise_detail.sql` | ทำ `tr_transaction_log.detail` ให้กระชับ — ตัด "โดย User ID" (ซ้ำคอลัมน์ Editor), คำที่ซ้ำกับ topic/activity และ Bag ID/Pallet ID ภายใน เหลือ `*pallet_no*` / `*QR*` / `#เลขถุง` / `→` — patch ด้วย `STUFF`/`REPLACE` บน definition จริงของ 15 SP (Pallet Adjustment, Pallet Management, Internal Transfer, Special Job, Bag) idempotent — log เก่าไม่ถูกแก้ |
| `83_pProcessGetJobList_keepfixed_plan.sql` | `GET job` ช้า 15–25 วินาทีเป็นช่วงๆ เพราะ compile ไม่ใช่ run — `INSERT INTO @data_jobs` แต่ละ TVF compile 0.5–3.8 วินาที (รวม ~10–13 วินาที) และ recompile ทุกครั้งที่ stats ของ `tr_bag` อัปเดต — ใส่ `OPTION (KEEPFIXED PLAN)` ทั้ง 8 บรรทัด + ข้าม TVF ที่ topic ไม่ตรง `@topic_name` (TS/RC = Inbound, ที่เหลือ = Outbound) ผลลัพธ์เท่าเดิม — patch ด้วย `REPLACE` บน definition จริง idempotent — **รันบน DB แล้ว (2026-10-22)** |
| `84_keepfixed_plan_forklift_jobs_grade_matching.sql` | แก้แบบเดียวกับ `83` ให้ `pProcessGetForkliftJobs` (`INSERT INTO @recent_jobs` 9 บรรทัด compile รวม ~11–12 วินาที recompile 11,000+ ครั้ง) และ `pServiceGetGradeForMatching` (`INSERT INTO #src` ส่วน job grades compile 2.3 วินาที) — ใส่ `OPTION (KEEPFIXED PLAN)` เฉพาะ statement ที่เรียก TVF ส่วน statement #temp ไม่แตะ — patch ด้วย `REPLACE` บน definition จริง idempotent — **รันบน DB แล้ว (2026-10-22)** |
| `85_pServiceMatchBagToPallet_parse_once.sql` | `pServiceMatchBagToPallet` ช้า 5–30 วินาทีและถือ lock ตลอด เพราะ `fParseBagQr` (inline + collation Thai) ถูกเรียกกับถุงทั้ง lot 2 รอบต่อกลุ่ม — แกะ QR ของ lot ครั้งเดียวต่อกลุ่มลง `#bq_pos`/`#bq` (หาตำแหน่ง `\|` แบบต่อทอดด้วย BIN2) แล้วใช้ใน step 2 / 3 / 3.1 แทน — ผล parse เท่า `fParseBagQr` ทุกแถว (เทียบ 28,559 + 9,295 แถว diff 0) — `@preview = 1` เทียบก่อน/หลัง: 1126NK 17.7 → 2.6 วินาที, 1120NK 11.7 → 2.7, GA800 5.9 → 2.3, F6024L 4.3 → 1.0 ผลตรงกัน ยกเว้นถุงที่เข้ามาระหว่างสองรอบ — backup: `..\scratch_backup_pServiceMatchBagToPallet_20261022.sql` (SHA-256 ตรงกับ DB) — **รันบน DB แล้ว (2026-10-22)** |
| `97_pServiceMatchBagToPallet_commit_per_lot.sql` | การบันทึกถุงตอนพิมพ์ QR (`pProcessInsertTrBag`) timeout เพราะ `pServiceMatchBagToPallet` ใช้ transaction เดียวครอบทั้ง grade (สูงสุด 30 lot นานสุด 229 วินาที) ถือ lock `tr_bag` ไว้ทั้งหมด — แก้เป็น COMMIT ทีละ lot + อีก 1 transaction สำหรับ step 6.5/8, `sp_getapplock` ขอใหม่ทุก lot, lock ไม่ว่างจะหยุดที่ lot นั้น (`status = warning`), error ย้อนเฉพาะ lot ที่กำลังทำ — logic จับคู่ไม่เปลี่ยน `@preview = 1` ยังย้อนทั้งหมด — `CREATE OR ALTER` ทั้งตัวจาก definition จริงบน prod (`13` + `85`) และหยุดเองถ้ามี `91` อยู่แล้ว (`91` ยัง patch ต่อหลังไฟล์นี้ได้) — ย้อนกลับด้วย `97_rollback_pServiceMatchBagToPallet.sql` — **ยังไม่ได้รันบน DB** |
| `98_sp_PalletAdjustment_RejectMissingSlot.sql` | หน้า Pallet Adjustment กด "ถุง Reject" ช่องว่างที่ไม่มีข้อมูลการพิมพ์ได้ (ช่องแดงใน Bag List = ตำแหน่ง QR ที่ไม่มีแถวใน `tr_bag`) — `sp_PalletAdjustment_GetMissingSlots @PalletId` คืนช่องว่างของพาเลท (ตามลำดับ canonical ของ `13`), `sp_PalletAdjustment_RejectMissingSlot` INSERT ถุง placeholder (`is_active = 'R'`, `mode_id = 9`, ไม่มีพาเลท) แล้ว reconcile → ถุงหลังจากนั้นเลื่อนขึ้นมาแทน ; `pProcessUpdateBagRejectStatus` (definition จริงบน prod) "คืนค่า" placeholder = ยกเลิก (`is_active = 'N'`, `status_flag = 'D'`) + ปลดถุง auto 1 ใบหลังช่องนั้นให้ reconcile ถุงเลื่อนกลับ — พิมพ์ QR เดียวกับ placeholder ซ้ำจะติด Duplicate จนกว่าจะคืนค่า — ทดสอบบน LocalDB แล้ว — ย้อนกลับด้วย `98_rollback_sp_PalletAdjustment_RejectMissingSlot.sql` — ต้อง deploy API/WEB คู่กัน — **ยังไม่ได้รันบน DB** |
| `103_sp_PalletAdjustment_AddMissingBag.sql` | ปุ่ม "เพิ่มข้อมูล" หน้า Pallet Adjustment : เพิ่ม `tr_bag` ด้วยมือให้ช่องว่างที่ไม่มีข้อมูลการพิมพ์ ด้วย QR format เดิม (`mode_id = 2`, รอจับคู่) แล้ว reconcile ลงพาเลทตามตำแหน่ง QR — พิมพ์ QR เดิมซ้ำภายหลังจะติด Duplicate — ต้องรันหลัง `98` และ deploy API/WEB คู่กัน — ทดสอบบน LocalDB แล้ว — ย้อนกลับด้วย `103_rollback_sp_PalletAdjustment_AddMissingBag.sql` — **ยังไม่ได้รันบน DB** |
| `104_sp_PalletAdjustment_GetBagList_manual_added.sql` | `sp_PalletAdjustment_GetBagList` คืน `is_manual_added` ให้ Bag List แสดงถุงที่สร้างจากปุ่ม "เพิ่มข้อมูล" เป็นอีกสี พร้อมข้อความเมื่อชี้เมาส์ — ดูจาก `remark` ที่ `103` บันทึก — ย้อนกลับด้วย `104_rollback_sp_PalletAdjustment_GetBagList.sql` — **ยังไม่ได้รันบน DB** |
| `105_pProcessGetPalletList_sort.sql` | หน้า Pallet Management เรียงลำดับจาก header ได้ทั้งรายการ — เพิ่ม `@sort_by`, `@sort_order` ให้ `pProcessGetPalletList` ไม่ส่ง = ลำดับเดิม — Pallet Location เรียงตามประเภท + id ไม่ใช่ชื่อ — ย้อนกลับด้วย `105_rollback_pProcessGetPalletList.sql` — **ยังไม่ได้รันบน DB** |
| `106_pProcessGetPalletList_pallet_status.sql` | `pProcessGetPalletList` คืน `pallet_status_id` ให้หน้า Pallet Management แสดงสี QTY ตามสถานะพาเลท — ต้องรันหลัง `105` — ย้อนกลับด้วย `106_rollback_pProcessGetPalletList.sql` — **ยังไม่ได้รันบน DB** |
| `107_dummy_pallet.sql` | หน้า Pallet Management แท็บ "Dummy Pallet" — พาเลทเปล่าหมุนเวียนใน Warehouse (`pallet_type = 'D'`, `PLDyyMMddNNNN`) : `pProcessGetDummyPalletList` (รายการ + ตำแหน่ง + จำนวนถุง) และ `pProcessCreateDummyPallet @Qty` (สร้างครั้งละ 1–100 ถือ app lock กันเลขซ้ำ, running no ต่อเนื่องข้ามวัน) ผ่าน `GET/POST api/v1/process/pallet-management/dummy` และ `pProcessClearDummyPallet` (ล้างพาเลท: ถุง `pallet_id = NULL` + `is_active = 'N'`, พาเลทกลับ Bagging Area) ผ่าน `POST pallet-management/dummy/clear` — 1 พาเลทมีได้ Grade / Lot เดียว — flow เบิกยังไม่ใช้ — ต้องรันหลัง `20` — ย้อนกลับด้วย `107_rollback_dummy_pallet.sql` — **ยังไม่ได้รันบน DB** |
| `108_pProcessPalletMgmtGetPallet_dummy.sql` | PWA Forklift หน้า Pallet Management สแกน QR Dummy Pallet (`PLD...`) ดูข้อมูลถุงบนพาเลท — `pProcessPalletMgmtGetPallet` คืน `pallet_type` และ dummy pallet ที่ไม่มี `unit_ratio` ใช้ package ratio ตาม grade ของถุง (`ct_grade_package_ratio`) คิดน้ำหนักพาเลท/ถุง (เดิมเป็น 0) และคืน `package_ratio` (กก./ถุง ตาม grade) ทุกพาเลท ให้ PWA คิดจำนวนถุงที่เบิกได้จากพาเลท Manual — ต้องรันหลัง `27`, `107` และ deploy API/PWA คู่กัน — ย้อนกลับด้วย `108_rollback_pProcessPalletMgmtGetPallet.sql` — **ยังไม่ได้รันบน DB** |
| `109_dummy_pallet_transfer.sql` | PWA Forklift หน้า Pallet Management เบิกของรายถุงลง Dummy Pallet (Grade / Lot ต้องตรงกัน, dummy ว่าง = ชุดแรกกำหนด) — `pProcessDummyPalletAddBag` (ถุงที่มี QR ข้างถุงต้องสแกนทีละใบ: orphan / บนพาเลท Auto หรือ Dummy อื่น) และ `pProcessDummyPalletTransferBags` (สแกน QR พาเลท + จำนวนถุง: Manual = สร้างแถว `tr_bag` บน dummy ตามจำนวน คัดลอกป้าย WMS+ แล้วหักน้ำหนัก จำนวน × package ratio ออกจากพาเลท Manual เหลือ 0 ปิดพาเลท ; Dummy = ย้ายถุงท้ายพาเลทเฉพาะแถวที่ไม่มี QR ข้างถุง ; พาเลท Auto ไม่รับ ต้องสแกนทุกถุง) ผ่าน `POST pallet-management/dummy/add-bag`, `/dummy/transfer` — ไม่แก้ `05` / `80` / `81` — ต้องรันหลัง `107`, `108` และ deploy API/PWA คู่กัน — ทดสอบบน LocalDB แล้ว — ย้อนกลับด้วย `109_rollback_dummy_pallet_transfer.sql` — **ยังไม่ได้รันบน DB** |
| `110_sp_PalletAdjustment_GetMissingSlots_parse_once.sql` | `sp_PalletAdjustment_GetMissingSlots` (ช่องว่างใน Bag List หน้า Pallet Adjustment) ช้า 3–16 วินาทีต่อพาเลทของ lot ใหญ่ เพราะ `fParseBagQr` (inline + collation Thai ขยาย CHARINDEX เป็นร้อยครั้งต่อแถว) — แกะ QR ครั้งเดียวด้วย BIN2 แบบ `85` + index ที่ `#g` — ผลเท่าเดิมทุกพาเลทที่เทียบบน prod (read-only) เร็วขึ้น 5–15 เท่า — ต้องรันหลัง `98` — ย้อนกลับด้วย `110_rollback_sp_PalletAdjustment_GetMissingSlots.sql` — **ยังไม่ได้รันบน DB** |
| `111_pServiceMatchBagToPallet_ton_cap.sql` | lot เดียวกันมีตัน 40 / 60 ถุงปนกัน — `pServiceMatchBagToPallet` (base = `97` = definition บน prod 2026-11-04) เปลี่ยนจาก unit pallet เดียวทั้ง lot เป็น **ต่อตัน** : cap ของตัน = bag_no สูงสุดใน QR ปัดขึ้นเป็นขนาดมาตรฐาน (40 , 60 , unit_pallet ของ grade) , planned_pos = ผลรวม cap ตันก่อนหน้า + bag_no , `tr_pallet.unit_pallet` = cap ของตัน — พาเลท 40 ไม่ถูกแก้เป็น 60 อีก , ถุงท้ายตันหายยังเป็นช่องว่าง — ทดสอบบน LocalDB แล้ว — deploy คู่กับ `112` — ย้อนกลับด้วย `111_rollback_pServiceMatchBagToPallet.sql` — **ยังไม่ได้รันบน DB** |
| `112_sp_PalletAdjustment_GetMissingSlots_ton_cap.sql` | `sp_PalletAdjustment_GetMissingSlots` ใช้ขนาดต่อตันแบบเดียวกับ `111` (base = `110`) — ช่องว่างใน Bag List / Reject ช่องว่าง (`98`) / เพิ่มข้อมูล (`103`) ถูกตันใน lot ที่ปนขนาด — ต้องรันคู่กับ `111` — ย้อนกลับด้วย `112_rollback_sp_PalletAdjustment_GetMissingSlots.sql` — **ยังไม่ได้รันบน DB** |
| `113_sp_PalletAdjustment_GetOverview_fast.sql` | หน้า Pallet Adjustment โหลดช้า — `sp_PalletAdjustment_GetOverview` (base = `01` = definition บน QAS 2026-11-06) ใช้ ~20 วินาทีกับ filter วันนี้ (~59k ถุง) เพราะแกะ QR ทุกถุงด้วย `fParseBagQr` เพื่อหา running pallet no (~9.6 วินาที) แบบทีละพาเลท — เปลี่ยนเป็นใช้คอลัมน์ `tr_bag.pallet_running_no` (เทียบ 780,064 แถว diff 0) + อ่าน tr_bag รอบเดียว GROUP BY ลง `#BagGroup` (~2k แถว แทนการเขียนถุง ~59k แถวลง tempdb) แล้วคำนวณต่อพาเลทแบบ set-based + orphan ดึงจาก tr_bag ตรง + `OPTION (RECOMPILE)` ทุก query ที่เป็น catch-all filter — เทียบผล 1,946 พาเลท diff 0 , ส่วนที่ช้า ~20 → ~0.5–0.7 วินาที — ย้อนกลับด้วย `113_rollback_sp_PalletAdjustment_GetOverview.sql` — **ยังไม่ได้รันบน DB** |
| `09_ct_grade_package_ratio.sql` | ตาราง cache package ratio ต่อ grade (จาก WMS+) — แยกออกมาจาก `pallet_matching_service.sql` เดิม (project root) |
| `10_fParseBagQr.sql` | ฟังก์ชันแกะ `qr_text_data` เป็น cost_center/grade/lot/bag_no/pallet_running_no — ใช้ร่วมกันโดย `13` และ `15` |
| `11_pServiceGetGradeForMatching.sql` | หา grade ที่มีถุงค้าง + ธง need_refresh (ratio หมดอายุ/ยังไม่มี) |
| `12_pServiceStampGradePackageRatio.sql` | Upsert package ratio ของ 1 grade (เรียกโดย C# หลังยิง WMS+ API) |
| `13_pServiceMatchBagToPallet.sql` | **หัวใจของ auto-matching** — จับถุงเข้าพาเลทตามลำดับ QR (1 grade/call, idempotent reconcile) พร้อม sync `pallet_status_id` |
| `14_pServiceRunPalletMatching.sql` | Driver วนทุก grade แล้วเรียก `13` — ตัวที่ SQL Server Agent job รายนาทีเรียก |
| `15_pProcessUpdateBagRejectStatus.sql` | Reject/Un-reject ถุง (SP เดียวใช้ทั้ง 2 ทิศทาง ผ่าน `@reject`) — ที่มาของปุ่ม "ถุง Reject"/"คืนค่า" ในหน้า Pallet Adjustment |
| `16_broken_bag_replace_detail.sql` | Broken Bag (CHECKER Replace flow) — สร้างตาราง `tr_broken_bag_replace_detail` + `pProcessConfirmReplaceBrokenBag` |
| `17_broken_bag_forklift_scan.sql` | Broken Bag (FL "เปลี่ยนของกับ Warehouse" modal) — `pProcessForkliftScanBrokenBag`, เบากว่า 16 (ไม่มี 4-way login) |
| `18_broken_bag_reason_breakdown.sql` | Broken Bag — ตาราง `tr_broken_bag_reason` + `pProcessSaveBrokenBagReasons`/`pProcessGetBrokenBagReasons` (multi-reason breakdown) |
| `19_broken_bag_list_date_filter.sql` | Broken Bag list — **runbook** (ไม่ใช่สคริปต์รันได้) สำหรับแก้ `pProcessGetBrokenBagList` (นอกโปรเจกต์นี้) ให้กรองตาม `@date` ได้ |
| `20_tr_transaction_log.sql` | ตาราง `dbo.tr_transaction_log` (shared log, สร้างแบบ idempotent) + helper `dbo.pInsertTransactionLog` — เรียกจาก SP `03`/`04`/`05`/`06`/`08`/`15` ทุกครั้งที่ user แก้ไขข้อมูลจากหน้า Pallet Adjustment สำเร็จ (Shift/Pull-out/Add-in/Reorder/Finish/Reject/Unreject) เพื่อบันทึกว่าแก้ไขอะไร ทำอะไร จากไหน ไปไหน โดยใคร |
| `21_pProcessGetPalletListByLocation.sql` | List พาเลททั้งหมดที่อยู่จริงใน 1 MWH location (ไม่กรองตาม grade/lot) — ใช้โดยตัวเลือก "เลือกเป็นรายพาเลท" ในขั้นตอนเลือก Source location ของหน้า `job-wh-internal-transfer-list` (`select-internal-transfer-location.ts` `onOpenPalletPicker`/`fetchPalletListByLocation`) ผ่าน endpoint ใหม่ `GET api/v1/process/pallet/by-location` (`PalletController.GetPalletByLocation`) — แยกจาก `pProcessGetPalletList`/`GET pallet` เดิมที่ใช้โดย Pallet Management/Information ซึ่งค้นด้วย grade/lot/pallet_no |
| `22_pProcessCreateInternalTransferJob.sql` | สร้างตาราง `dbo.tr_internal_transfer_header`/`dbo.tr_internal_transfer_detail` (ใหม่, ตามแพทเทิร์น `tr_special_header`/`tr_special_detail`) + SP สร้าง WH02 Internal Transfer job ครบ 3 ตาราง (`tr_job_main` ที่มีอยู่แล้ว + header/detail ใหม่) ในทรานแซกชันเดียว — เรียกตอนกดปุ่ม "สร้างรายการย้ายสินค้า" บนหน้า `job-wh-internal-transfer-list` ผ่าน endpoint ใหม่ `POST api/v1/process/job/internal-transfer` (`JobController.CreateInternalTransferJob`) `job_type_id`/`job_status_id` อ้างอิง `ct_job_type`/`ct_job_status` ที่มีอยู่แล้ว (10='IT' Internal Transfer, 1=Pending) |
| `23_pProcessGetInternalTransferJobList.sql` | List หน้า `job-wh-internal-transfer-list` เอง (แยกจาก unified WH01 Job List เหมือนที่ Special Job มี `pProcessGetSpecialJobList` ของตัวเอง) — 1 แถวต่อ job พร้อม source/destination summary ที่รวมด้วย `STRING_AGG` ผ่าน endpoint ใหม่ `GET api/v1/process/job/internal-transfer` (`JobController.GetInternalTransferJobList`) |
| `24_pProcessGetInternalTransferJobDetail.sql` | โหลด 1 job แบบละเอียด (header + ทุก location ทั้ง 2 ฝั่ง) สำหรับปุ่ม Edit บนหน้า `job-wh-internal-transfer-list` — ให้ modal เดียวกับตอน Create เอาไป pre-fill ผ่าน endpoint ใหม่ `GET api/v1/process/job/internal-transfer/{jobId}` (`JobController.GetInternalTransferJobDetail`) |
| `25_pProcessUpdateInternalTransferJob.sql` | แก้ไข Internal Transfer job ที่มีอยู่แล้ว (update header ที่ id เดิม + ลบ/สร้าง detail ใหม่ทั้งหมด) — เงื่อนไขและ payload เดียวกับตอน Create เกือบทั้งหมด ต่างแค่ไม่สร้าง `tr_job_main`/`tr_internal_transfer_header` แถวใหม่ และแก้ไขได้เฉพาะ job ที่ยัง `job_status_id = 1` (Drafted) เท่านั้น ผ่าน endpoint ใหม่ `PUT api/v1/process/job/internal-transfer/{jobId}` (`JobController.UpdateInternalTransferJob`) |
| `27_pProcessPalletManagement.sql` | หน้า Pallet Management ของ Forklift PWA (`IRPC_BARCODE_FE_PWA_FL`) — `pProcessPalletMgmtGetPallet` (สแกน QR ถุง หรือ pallet_no → ข้อมูลพาเลท + รายการถุง), `pProcessPalletMgmtFindBag` (หาถุง orphan จาก QR หรือ grade+lot+bag_no), `pProcessPalletMgmtReplaceBag` (ถุงเดิม → Reject `bag_status_id=6`, ถุงใหม่เข้าช่องเดิม `bag_status_id=3`), `pProcessPalletMgmtEditBag` + filtered index `IX_tr_bag_manual_status` — Add Bag ใช้ `05` เดิม ผ่าน endpoint `api/v1/process/pallet-management/*` (`PalletController`) |
| `28_tr_bag_ton_no.sql` | backfill `tr_bag.ton_no` (ตันที่หลัง re-run; คอลัมน์เพิ่มเองด้วยมือแล้ว, ค่าเริ่มต้น = `pallet_running_no` set ใน `pProcessInsertTrBag`) — `13` re-run เป็น ordinal ใหม่เมื่อมี reject, `15` (un-reject) / `27` (Edit Bag) set ค่ากลับ — **รันไฟล์นี้ก่อน `13`/`15`/`27`** |
| `32_pProcessGetJobList_product_cc_filter.sql` | `pProcessGetJobList` ฉบับล่าสุด (ต่อจาก `../scratch_alter_pProcessGetJobList.sql` ที่ใช้งานจริงบน DB — **ไม่ใช่** `26` ซึ่งไม่มีคอลัมน์ `assignee_user_*`) — เพิ่ม `@product_cc` (default NULL) กรองงานตาม `tr_job_main.product_cc` ใช้กับ filter "ปลายทาง (Product CC)" ของหน้า WH01 Inbound (`job-wh-list`) ผ่าน `GET api/v1/process/job?productCc=` (`JobController.GetJob`) — caller อื่นที่ไม่ส่ง `productCc` ทำงานเหมือนเดิม |
| `33_ct_job_type_is_list.sql` | เพิ่มคอลัมน์ `ct_job_type.is_list` (`Y`/`N`, default `Y`) + ให้ `pProcessCBGetJobType` คืนคอลัมน์นี้ — ตั้ง Loading (9) / Internal Transfer (10) เป็น `N` เพื่อซ่อนแท็บบนหน้า Job List (`pProcessGetJobList` ไม่มี branch ของ 2 type นี้ แท็บเลยว่างเสมอ) โดยไม่กระทบหน้า `job-accept` ของ Forklift PWA ที่ใช้ endpoint เดียวกัน — idempotent |
| `34_pProcessGetJobList_to_wh_filter.sql` | `pProcessGetJobList` ฉบับล่าสุด (ต่อจาก `32`) — เพิ่ม `@to_wh_code` (default NULL) กรองงานที่มี to-location ประเภท MWH อยู่ในคลังที่เลือก (`ct_location.wh_code`, กรองระดับ job) ใช้กับ filter "To Warehouse" ของหน้า WH01 Inbound ผ่าน `GET api/v1/process/job?toWhCode=` |
| `35_pProcessGetJobList_location_filter.sql` | `pProcessGetJobList` ฉบับล่าสุด (ต่อจาก `34`) — เพิ่ม `@from_location_type`/`@from_location_key` และ `@to_location_type`/`@to_location_key` (default NULL; type อย่างเดียว = ทั้งประเภท, มี key = location เดียว: wh_code สำหรับ MWH, ชื่อ location สำหรับประเภทอื่น) กรองระดับ job ใช้กับ filter "From Location" / "To Location" ของหน้า WH02 Outbound |
| `36_pProcessCBGetJobLocationOptions.sql` | ตัวเลือกของ filter "From Location" / "To Location" ดึงจากตาราง master ของแต่ละประเภท location (`ct_storage`, `ct_bg_plant_location`, `ct_request_cost_center`, `ct_strorage_zone`, `ct_strorage_dock`, `ct_special_location`, `ct_replace_location`) จัดกลุ่มตาม `ct_location_type` ผ่าน `GET api/v1/process-cb/job-location` |
| `37_pProcessGetInternalTransferJobList_forklift_section.sql` | `pProcessGetInternalTransferJobList` ฉบับที่ใช้บน DB (ใหม่กว่า `23`) + ผลลัพธ์ forklift คืน `section_id` / `section_name` เพิ่ม เพื่อแสดง Section ของ forklift บนการ์ด Forklift หน้า `job-wh-internal-transfer-detail` |
| `38_ct_bg_plant_location_missing_plants.sql` | เพิ่ม `ct_bg_plant_location` ให้ 10 cost center ที่มีใน `IRPC_E_TRANSFER.dbo.ct_receive_cost_center` (source plant ของงาน RC) แต่ไม่มี location ให้เลือก (1305 PLBG, 1376, 1606, 3324, 3325, P001–P005) — `bg_plant_location` ใช้ชื่อ cost center ไปก่อนเพราะยังไม่รู้รหัส location จริง แก้ทีหลังด้วย UPDATE ได้ — idempotent, **รันบน DB แล้ว** (id 32–41) |
| `39_pServiceSnapshotRestorePallet.sql` | เก็บ/ย้อนสถานะการเคลื่อนย้ายของพาเลท (`current_job_*`, `current_location_*`, inbound/outbound ทั้งหมด) — `@action = 'SNAPSHOT'` เก็บค่าปัจจุบันลงตารางใหม่ `tr_pallet_reset_snapshot`, `'RESTORE'` (default) คัดค่ากลับไป `tr_pallet` — แทน `pServiceResetTestPallet` เดิม (set NULL, ลบทิ้งแล้ว) — ไม่ย้อน `tr_bag`/`tr_pallet_history`/`pallet_status_id` — **รันบน DB แล้ว** |
| `40_fCheckPalletType.sql` | `fCheckPalletType` ฉบับใหม่ — แกะ QR ถุงแล้วคืน 1 แถวพร้อม INSERT `tr_pallet` + `tr_bag` (`pallet_running_no`/`bag_no_int`/`qty_num`, `pallet_type_code` A/J, `unit_ratio`/`unit_pallet` จาก `ct_grade_package_ratio` (JB: `unit_ratio = qty_num`, `unit_pallet = 1`, grade ไม่ตัด เช่น `1105RC/750`), พาเลท/ถุงที่มีอยู่แล้ว + ธง `is_new_pallet`/`is_new_bag`, `status`/`message`) — **ผลลัพธ์เปลี่ยน schema จากเดิม** (ตัด `bag_no`/`pallet_id`/`qty`/`jb_type`/`pallet_type` ออก), แกะ QR ด้วย `CHARINDEX` แทน `STRING_SPLIT` (SQL 2017 ไม่รับประกันลำดับ), ไม่ generate `pallet_no` (ให้ caller เรียก `fGetPalletNo` ใน transaction ตอน INSERT) |
| `41_pProcessInboundGetPallet_jb.sql` | `pProcessInboundGetPallet` + เรียก `42` ก่อน lookup QR เพื่อสร้างพาเลท/ถุง JB ตอนสแกนครั้งแรก แล้วค่อยเข้า flow เดิม — ถุงปกติ (`A`) ไม่สร้าง (เป็นงานของ `13`) — ย้าย job check มาก่อน lookup QR — deploy ลำดับ `40` → `42` → `41` — **รันบน DB แล้ว** |
| `42_pProcessInsertJbPalletBag.sql` | สร้าง `tr_pallet` (`J`, `fGetPalletNo('J')`, `unit_ratio = qty`, `unit_pallet = 1`, `pallet_status_id = 2`) + `tr_bag` (`bag_status_id = 2`) จาก QR ถุง JB ที่สแกนครั้งแรก (ใช้ `40_fCheckPalletType`) ใน transaction + app lock — คืน `@status` `success`/`skip`/`error` + `@pallet_id`/`@bag_id` ทาง OUTPUT (`@return_result = 0` ไม่คืน result set ใช้ตอนเรียกจาก proc อื่น) — `TODO(confirm)` `mode_id = 2` — **รันบน DB แล้ว** (เดิมชื่อ `pProcessCreateJbPalletBag` — ลบชื่อเดิมออกจาก DB แล้ว) |
| `43_ct_grade_package_ratio_is_jb.sql` | **ถูกแทนด้วย `45`** — เพิ่มคอลัมน์ `ct_grade_package_ratio.is_jb` (`Y`/`N`, default `N`) + patch `pProcessGetForkliftJobs` ให้เลือก `sys_pallet_scan_setting` แถว `J` เมื่อ grade เป็น JB (ลำดับ `M` → `J` → `A`) — patch ด้วย `REPLACE` บน definition จริง (proc ยาว ~23k ตัวอักษร) idempotent — grade JB จะแสดงเป็น `A` จนกว่าจะสแกนถุงแรกของ grade นั้น — deploy ลำดับ `40` → `43` → `42` → `41` — **รันบน DB แล้ว** |
| `44_pProcessGetForkliftJobs_item_scan_qty.sql` | `pProcessGetForkliftJobs` — ย้ายการหา `scan_qty` ไประดับ item (`#item_summary` ต่อ `header_id`/`job_type_id`/`item_id` + `grade`) แทนการ join `sys_pallet_scan_setting` ทุกแถว location — คอลัมน์ `scan_qty` ในผลลัพธ์ชื่อ/ตำแหน่งเดิม (`ism.scan_qty`) — patch ด้วย `REPLACE` idempotent — ต้องรัน `43` ก่อน — **รันบน DB แล้ว** |
| `45_jb_grade_from_wms_unit_code.sql` | ใช้ `ct_grade_package_ratio.unit_code = 'JB'` (จาก WMS `pkUnitCode` ผ่าน `PalletMatchingService` เดิม) เป็นแหล่งเดียวว่า grade ไหนเป็น JB — `pServiceGetGradeForMatching` เพิ่ม grade ของ job inbound ที่ยังไม่เสร็จ ให้ถูก stamp ก่อน forklift เห็นงาน — `pProcessGetForkliftJobs` เปลี่ยนเงื่อนไข `J` เป็น `unit_code` — ลบคอลัมน์ `is_jb` (มี guard) — API ไม่เรียก WMS ตอนโหลด list แล้ว ส่ง `items[].scan_qty` ต่อตรงๆ — deploy ลำดับ `42` → `45` — **รันบน DB แล้ว** (ลบ `is_jb` แล้ว) |
| `46_job_type_transfer_wh.sql` | job type ใหม่ `11` `TW` (Inbound / Transfer WH, `is_list = 'Y'`) จาก `IRPC_E_TRANSFER.dbo.VTransferWhForm` (`tr_job_main.interface_job_id` = `header_id`) — `fTransferWhJob`/`vTransferWhJob`, `fTransferWhPallets`/`vTransferWhPallets` clone จาก RC (`fReceiveJob`/`fReceivePallets`) คอลัมน์เหมือนกันทุกตัว — view ไม่มี `wh_name`/`total_pallet` จึงเอา `wh_name` จาก `ct_wh_to` และคิด `total_pallet = CEILING(qty / (unit_ratio × unit_pallet))` จาก `ct_grade_package_ratio` (ไม่มี ratio ใช้ 1000 kg) — idempotent — **รันบน DB แล้ว** (2026-10-01) |
| `47_job_type_transfer_wh_patch.sql` | ต่อ type `11` เข้า object ที่มี RC อยู่แล้ว: `vJobMain`, `fManualPallets`, `pProcessApproveJob`, `pProcessInboundPutAway`, `pServiceGetGradeForMatching`, `pProcessGetJobList`, `pProcessGetForkliftJobs` (job + pallet + `scan_qty`) — สิทธิ์ใช้ `inbound_receive` (ไม่มีคอลัมน์ของ TW ใน `VRolePermission`) — ไม่แก้ `pWmsPlus_InboundApprove`/`pWmsPlus_InboundGetPutAway` (รอ backend กำหนดว่าจะส่งอะไรให้ WMS+) — patch ด้วย `REPLACE` บน definition จริงแบบ `44` idempotent — deploy ลำดับ `46` → `47` — **รันบน DB แล้ว** (2026-10-01) |
| `48_pProcessGetTransferWhJobList.sql` | หน้า WH04 Transfer Warehouse (`job-wh-transfer-list`) มี API ของตัวเองแบบ WH03 — SP ใหม่ `pProcessGetTransferWhJobList` (1 แถวต่อ job จาก `fTransferWhJob`: item แรก + `item_count`, พาเลท total/receive/complete, `wh_code`/area/level/location จาก `VTransferWhForm`) ผ่าน `GET api/v1/process/job/transfer-wh` (`JobController.GetTransferWhJobList`) — patch `pProcessGetJobList` ให้คืน TW เฉพาะตอนมี `@id` (job-detail) หน้า WH01/WH02 จึงไม่เห็น TW — idempotent — ต้องรัน `47` ก่อน — **รันบน DB แล้ว** (2026-10-01) |
| `49_pProcessGetTransferWhJobList_detail.sql` | หน้า list และ detail ของ WH04 ใช้ SP ตัวเดียวกัน — `pProcessGetTransferWhJobList` ส่ง `@id` = โหมด detail คืน 4 result set แบบ `pProcessGetJobList` (status, แถว item/location, forklift, total_count) ให้ `BuildJobResponse`/หน้า `job-wh-transfer-detail` ใช้ได้ ดึงจาก `fTransferWhJob` อย่างเดียว (ไม่ UNION 8 ตัว) เช็คสิทธิ์ `inbound_receive` ด้วย `@user_id` — ไม่ส่ง `@id` = โหมด list เหมือน `48` — ส่วนสรุป/แบ่งพาเลท/forklift copy จาก `pProcessGetJobList` แก้ที่นั่นต้องแก้ที่นี่ด้วย — `GET job/transfer-wh?id=` (`JobController.GetTransferWhJobDetail`) เรียก SP นี้แทน `pProcessGetJobList` — idempotent — **ยังไม่รันบน DB** |
| `50_pProcessGetTransferWhJobList_job_list_shape.sql` | `GET job/transfer-wh` ทำงานแบบเดียวกับ `GET job` — `pProcessGetTransferWhJobList` ทั้งโหมด list (`@id` NULL) และ detail (`@id`) คืน 4 result set แบบ `pProcessGetJobList` (status, แถว job/item/location, forklift, total_count) แบ่งหน้าเป็นระดับ job, ไม่ส่งวันที่และ id = วันนี้, เช็คสิทธิ์ `inbound_receive` ด้วย `@user_id` — controller ส่ง user id จาก token และใช้ `BuildJobResponse` — หน้า `job-wh-transfer-list` / `job-wh-transfer-detail` ยังเป็นหน้าแยกของ WH04 — แทนรูปแบบ list 1 แถวต่อ job ของ `48`/`49` — **ยังไม่รันบน DB** |
| `51_pProcessGetTransferWhJobList_wh_filter.sql` | ตัวกรอง "WH ต้นทาง" / "WH ปลายทาง" ของหน้า WH04 — เพิ่ม `@from_wh_code` (`VTransferWhForm.source` เช่น M42) และ `@to_wh_code` (`VTransferWhForm.wh_code` เช่น M38/M40) ให้ `pProcessGetTransferWhJobList` (default NULL) กรองระดับ job — ตัวเลือกจาก `process-cb/location-wh?wh=MWH` — `GET job/transfer-wh?fromWhCode=&toWhCode=` — patch ด้วย `REPLACE` idempotent — ต้องรัน `50` ก่อน — **ยังไม่รันบน DB** |
| `52_pProcessGetJobList_product_type.sql` | `pProcessGetJobList` คืน `jm.product_type AS job_product_type` (คู่กับ `job_product_cc`) — Picking ไม่มี `code_t` (`tr_delivery.code_t` ว่าง) ทำให้ Product Type ที่บันทึกตอน Approve ไม่แสดง/ไม่ re-select — base จาก definition live (ไม่ใช่ sql/35) — **รันบน DB แล้ว (2026-10-01)** |
| `53_pServiceSyncWmsShipment_product_type.sql` | `pServiceSyncWmsShipment` รับ `@product_type` (default NULL) จาก WMS `tshipmentsub.PDTYPECODE` → บันทึก `tr_delivery.code_t` (update ทับเฉพาะเมื่อส่งค่ามา) — ทำให้ Picking มี `pd_type` — `ServiceController.SyncShipment` ส่ง `@product_type` แล้ว ต้องรันก่อน deploy API — base จาก definition live — **รันบน DB แล้ว (2026-10-01)** |
| `54_pILogistic_ProcessGetShipmentStatus_paged.sql` | `GET job/shipment` ใช้ iLogistic (`VsearchStatus`) เป็นหลัก — เปลี่ยน `@pairs_json` เป็น `@shipment_no`/`@delivery_no` (contains) + `@page`/`@page_size` คืน dbResult1 (แถว + `Shipment_id`/`DO_id`) และ dbResult2 (`total_count`) — คงเงื่อนไข `Product_preparing_Datetime IS NULL` — API ไปดึง WMS เฉพาะ shipment ในหน้านั้น — ต้องรันก่อน API ใหม่ — **รันบน DB แล้ว (2026-10-01)** |
| `55_fCheckPalletType_jb_no_recreate.sql` | ทับ `40` — พาเลท/ถุง JB ที่เคยสร้างแล้วไม่สร้างซ้ำ (หาพาเลท J / ถุง JB เดิมโดยไม่สนสถานะ) + คืน `pallet_exist_active` / `bag_exist_active` / `bag_exist_pallet_id` + qty ของ JB ต้องเป็นจำนวนเต็ม — ไม่เปลี่ยน: เลข running ไม่เกิน 3 หลัก, `pd_group_code` 'A' — รันก่อน `56` — **รันบน DB แล้ว (2026-10-01)** |
| `56_pProcessInsertJbPalletBag_no_recreate.sql` | ทับ `42` — ถ้าพาเลท/ถุง JB เคยสร้างแต่ inactive หรือถุงอยู่บนพาเลทอื่น คืน `error` พร้อมข้อความชัดเจนแทนการสร้างใหม่ (`41` ส่งข้อความต่อให้เครื่องสแกน) — ต้องรัน `55` ก่อน — **รันบน DB แล้ว (2026-10-01)** |
| `57_fGetPalletNo_max_seq_unique.sql` | `fGetPalletNo` ใช้เลขสูงสุดของวันนั้น + 1 แทน COUNT + 1 (มี 3 วันในอดีตที่มีช่องว่างจากการลบ ซึ่ง COUNT จะได้เลขซ้ำ) + unique index `UX_tr_pallet_pallet_no` — **รันบน DB แล้ว (2026-10-01)** |
| `58_pProcessInboundResetPallet_actual_qty.sql` | reset พาเลท inbound ลบ `actual_qty` ที่พาเลทนั้นเคยบวกไว้ (get → `tr_job_from_location`, put-away → `tr_job_to_location`) ไม่ให้ต่ำกว่า 0 แล้วค่อยปิด history เหมือนเดิม ทั้งหมดใน transaction เดียว — **รันบน DB แล้ว (2026-10-01)** |
| `59_get_pallet_jb_all_jobs.sql` | ใส่การสร้างพาเลท/ถุง JB ตอนสแกนครั้งแรก (`pProcessInsertJbPalletBag`) ให้ get ของทุกงานที่เหลือ: Request, Internal Transfer, Shipping, Loading, Special, Broken Bag (Inbound มีแล้วจาก `41`, Picking มีอยู่แล้ว) — ทำเฉพาะเมื่อ job / item มีอยู่จริง แทรกก่อน lookup QR ส่วนอื่นของแต่ละ proc เหมือน live 2026-10-01 — ต้องมี `55` + `56` — **รันบน DB แล้ว (2026-10-01)** |
| `60_pServiceSyncWmsShipment_keep_total_pallet.sql` | `pServiceSyncWmsShipment` ตอน update ใช้ `COALESCE(ds.total_pallet, tr_delivery.total_pallet)` — ไม่ส่ง total_pallet มาจะไม่ทับค่าเดิมเป็น NULL (picking/shipping คำนวณ total_pallet ตอน approve แล้ว, `POST job/picking` ส่ง NULL) — patch ด้วย `REPLACE` idempotent — ต้องรัน `53` ก่อน |
| `63_pProcessRequestResetPallet_fixes.sql` | reset พาเลท RQ: หัก `tr_job_from_location.actual_qty` ที่ Get บวกไว้ (ไม่ต่ำกว่า 0), คำนวณ `tr_job_to_location.actual_qty` ใหม่สูตรเดียวกับ PutAway, QR หา `pallet_seq` แล้ว reset ทั้งกลุ่ม (pallet ทุกตัวใน job/item/`pallet_seq` เดียวกัน, seq NULL = พาเลทเดียว), job ที่ปิดแล้ว (5) กลับเป็น 4, ทั้งหมดใน transaction เดียว, history `status_flag = 'D'` — และ `pProcessRequestGetPallet` mode 2 เช็คเฉพาะ history ที่ active ให้สแกนซ้ำหลัง reset ได้ — **รันบน DB แล้ว (2026-10-02)** |
| `64_pProcessSpecialResetPallet_fixes.sql` | เหมือน `63` แต่สำหรับ Special: QR หา `pallet_seq` แล้ว reset ทั้งกลุ่ม, หัก `tr_job_from_location.actual_qty` (bag × `unit_ratio` ตามที่ Get บวก), คำนวณ `tr_job_to_location.actual_qty` ใหม่สูตร PutAway, job 5 กลับเป็น 4, transaction เดียว — และ `pProcessSpecialGetPallet` mode 2 เช็คเฉพาะ history ที่ active — **รันบน DB แล้ว (2026-10-02)** |
| `65_pProcessInternalTransferResetPallet_fixes.sql` | เหมือน `63` แต่สำหรับ Internal Transfer (M/S ใช้ `fGetPalletQty`) — **เปลี่ยนพฤติกรรม**: เดิม reset แค่ bag ที่สแกน (QR pallet ไม่ reset อะไร) ตอนนี้ reset ทั้งกลุ่ม `pallet_seq` — และ `pProcessInternalTransferGetPallet` mode 2 เช็คเฉพาะ history ที่ active — **รันบน DB แล้ว (2026-10-02)** |
| `66_pProcessLoadingPickingShippingResetPallet_actual_qty.sql` | reset พาเลท Loading / Picking / Shipping แบบเดียวกับ `58`: หัก `actual_qty` ที่ get (`tr_job_from_location`) / put-away (`tr_job_to_location`) บวกไว้ (`fGetPalletQty` × จำนวนสแกนที่ active) ไม่ต่ำกว่า 0, history `status_flag = 'D'`, transaction เดียว — job ที่ปิดแล้ว (5): Loading กลับเป็น 4, Picking / Shipping **ไม่ให้ reset** (ตอนปิด job สร้าง job Shipping / Loading ถัดไปแล้ว) — **รันบน DB แล้ว (2026-10-02)** |
| `API_SPEC.md` | **API Spec ฉบับเต็ม** สำหรับสั่งงาน backend .NET — request/response ของทั้ง 7 endpoint จับคู่กับ SP แต่ละตัว (เฉพาะกลุ่ม Pallet Adjustment `01`-`08`; ไฟล์ `09`-`19` ไม่มีใน spec นี้) |

> ไฟล์ `09`-`15` แยกออกมาจาก `pallet_matching_service.sql` และไฟล์ `16`-`19` คัดลอกมาจาก
> `broken_bag_forklift_scan.sql` / `broken_bag_list_date_filter.sql` / `broken_bag_reason_breakdown.sql`
> / `broken_bag_replace_detail.sql` (ทั้งหมดอยู่ที่ project root, นอกโฟลเดอร์นี้) ซึ่งไฟล์ต้นฉบับที่ root
> ยังคงมีอยู่เดิมทุกไฟล์ — ให้ถือว่าไฟล์ในโฟลเดอร์นี้ (`sql/09`-`19`) เป็นฉบับที่ใช้จริง/แก้ไขต่อจากนี้ไป
> ไฟล์ root เดิมมีไว้เป็นข้อมูลอ้างอิงเท่านั้น

## Business rule ที่ยึดตามที่คุยกัน

- **Pallet status** (ไม่ได้เก็บ column ของตัว status เอง — map ตรงตัวจาก `pallet_status_id`
  ตั้งแต่ 2026-09-13 หลังปรับ 2 รอบในวันเดียวกัน: (1) ยุบ 3-state เดิมที่แยกตาม
  `current_job_id` เหลือแค่ "เต็มหรือไม่เต็ม" ตามคำขอ "กำลังดำเนินการ = ถุงยังไม่ครบ ไม่ต้อง
  สนใจเรื่อง current_job_id" — Quick Actions และปุ่ม "จบพาเลท" เลยไม่เช็คงาน WMS อีกต่อไป
  ไม่มี concept "พาเลทถูกล็อก" แล้ว (2) เปลี่ยนจากเทียบ `bag_count >= unit_pallet` สด ๆ มาอ่าน
  `pallet_status_id` ตรง ๆ **และแยก complete ออกจาก confirmed อีกครั้ง** ตามคำขอให้เห็นชัดว่า
  พาเลทไหนเต็มเองตามธรรมชาติ กับพาเลทไหนถูกยืนยันด้วยมือ):
  - `complete`    : `pallet_status_id = 2` (COMPLETED เท่านั้น -- sync อัตโนมัติโดย
    `pServiceMatchBagToPallet` ขั้นตอน 6.5 เมื่อ bag_count >= unit_pallet)
  - `confirmed`   : `pallet_status_id = 3` (CONFIRMED -- ยืนยันพาเลทเศษผ่านปุ่ม "จบพาเลท")
  - `wh_process`  : นอกนั้นทั้งหมด (`pallet_status_id = 1` CREATED)
  - พาเลทที่ `pallet_status_id = 4` (VOID) จะถูกตัดออกจาก overview ทั้งหมด ไม่นับใน summary การ์ดใด ๆ
  - ดูค่าทั้ง 4 ของ `pallet_status_id` ใน `00_master_pallet_status.sql` (`dbo.ct_pallet_status`)
  - **แก้ไขแล้ว 2026-09-13**: `sp_PalletAdjustment_ShiftMissingBag` (03) / `PullBagOut` (04) /
    `AddBagIn` (05) เคยแก้ `bag_count` ตรง ๆ โดยไม่ sync `pallet_status_id` เอง (ต้องรอ
    `pServiceMatchBagToPallet` auto job ไปทำให้ ซึ่งอาจไม่มาถ้ากลุ่มนั้นไม่มีถุงค้าง/reject) —
    ตอนนี้ทั้ง 3 ไฟล์ sync `pallet_status_id` (1↔2) เองทันทีหลังย้าย/ดึง/เพิ่มถุงทุกครั้ง แล้ว
    (pattern เดียวกับ `13_pServiceMatchBagToPallet.sql` ขั้นตอน 6.5 — ไม่แตะพาเลทที่เป็น
    3=CONFIRMED หรือ 4=VOID) ส่วน `ReorderPallet` (06) ไม่ต้อง sync เพราะไม่เปลี่ยน `bag_count`
- **Orphan bag** = `tr_bag.pallet_id IS NULL` (ถุงที่พิมพ์แล้วแต่ยังไม่ถูกจับคู่ หรือถูกดึงออกมา)
- **Pallet No. ใหม่** (ตอน shift-missing-bag) ใช้ `dbo.fGetPalletNo(@pallet_type)` ของเดิมในระบบ ไม่ generate เอง
- ทุก mutation SP ทำใน `TRANSACTION` + คืนค่า `@ResultCode` (0 = success, > 0 = business validation error, < 0 = system error) และ `@ResultMessage` (ข้อความภาษาไทยสำหรับ SweetAlert ฝั่ง FE)

## `bag_status_id` ที่เสนอ (schema เดิมไม่เคยกำหนดไว้)

ดูรายละเอียดใน `00_master_bag_status.sql` — สรุปสั้น ๆ:

| id | code | ความหมาย |
|---|---|---|
| 1 | PRINTED | พิมพ์ QR แล้ว ยังไม่ถูกจับคู่ (default ตาม constraint เดิมของ tr_bag) |
| 2 | MATCHED | จับคู่กับ pallet แล้ว (ผ่าน matching service ปกติ) |
| 3 | MANUAL_MATCHED | จับคู่/ย้ายด้วยมือผ่านหน้า Pallet Adjustment |
| 4 | MISSING | ตรวจพบว่าตำแหน่ง bag_no นี้หายไปจาก pallet (ใช้เป็น marker ชั่วคราวก่อน shift) |
| 5 | PULLED_OUT | เคยอยู่ใน pallet แล้วถูกดึงออกด้วยมือ (กลายเป็น orphan แต่มีประวัติว่าเคยอยู่) |
| 6 | REPLACED | ถูกเปลี่ยนออกจาก pallet ผ่านหน้า Pallet Management (Replace) คู่กับ `is_active = 'R'` |
| 9 | VOID | ยกเลิก/ไม่ใช้งาน (คู่กับ `is_active = 'N'`) |

> **โปรดยืนยัน/แก้ไขชุดนี้ตามที่ต้องการจริง** — ผมอิงจาก flow ที่คุยกันเท่านั้น ยังไม่เห็น master table
> ของ `bag_status_id` ในโปรเจกต์นี้

## Performance / Index (สำคัญ — อ่านก่อน deploy)

schema เดิมของ `tr_bag` มีแค่ `PRIMARY KEY NONCLUSTERED` บน `id` (แปลว่าตัวตารางเป็น
**HEAP**) และ `tr_pallet` มีแค่ `PRIMARY KEY CLUSTERED` บน `id` — ไม่มี index อื่นรองรับ
`is_active`, `create_datetime`, `cost_center`, `grade`, `lot`, `pallet_id`, `current_job_id`
เลย ซึ่งเป็น column หลักที่ทุก SP ในโฟลเดอร์นี้ใช้ filter/join ดังนั้น **ถ้าไม่เพิ่ม index
query จะช้าลงเรื่อย ๆ ตามจำนวนแถวที่โตขึ้นทุกวัน**

แก้ไว้ให้ 2 ส่วน:

1. **`07_indexes.sql`** — non-clustered index (บาง index เป็น *filtered index*
   เฉพาะ `is_active = 'Y'` เพื่อให้เล็กและตรงกับทุก SP) รองรับทุก query pattern ที่ใช้ใน
   SP 01-06 พร้อม `INCLUDE` columns ที่จำเป็น เพื่อให้เกิด **index-only scan** ได้เลย
   (ไม่ต้อง key-lookup กลับไปที่ heap)
2. **แก้ query pattern ที่ "non-sargable"** ใน `01_sp_PalletAdjustment_GetOverview.sql`:
   - เดิม `CAST(b.create_datetime AS DATE) = @PrintDate` → เปลี่ยนเป็นช่วง
     `create_datetime >= @start AND create_datetime < @end` (ใช้ index ได้)
   - เดิม `lot LIKE '%' + @Lot + '%'` (wildcard นำหน้า ใช้ index ไม่ได้เลย) →
     เปลี่ยนเป็น `LIKE @Lot + '%'` (prefix search ใช้ index seek ได้)
   - เดิมใช้ CTE (`WITH ...`) ซึ่งใน SQL Server **มีผลแค่ 1 statement ถัดไปเท่านั้น**
     แต่ SP ต้องคืน 3 result sets ที่ต้อง reuse ผลลัพธ์เดียวกัน → เปลี่ยนเป็น
     `#temp table` + สร้าง index บน temp table เอง ทำให้ query จริงบน `tr_bag`/`tr_pallet`
     รันแค่รอบเดียว ไม่ต้อง scan ซ้ำ 3 รอบต่อ 1 request
   - เพิ่ม `OPTION (RECOMPILE)` ที่ query หลักเพราะ pattern
     `@param IS NULL OR column = @param` (optional filter) เสี่ยงเกิด
     **parameter sniffing** (SQL Server จำแผนตาม parameter ชุดแรกที่เจอ แล้วใช้ผิดกับ
     ชุดถัดไป) — ถ้ากังวลเรื่อง CPU cost ของการ compile ซ้ำทุกครั้ง ทางเลือกระยะยาวคือ
     เปลี่ยนเป็น dynamic SQL + `sp_executesql`

**ลำดับการรัน**: `00 (ทั้งคู่) → 20 → 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 18 → 19 → 21 → 22 → 23 → 24 → 25 → 26 → 27`
- `27` (Pallet Management) ต้องรัน**หลัง** `10` (`fParseBagQr`) และ `20` (`pInsertTransactionLog`) — และควรรัน `13` ฉบับใหม่คู่กัน
  เพราะ `13` ถูกแก้ให้ไม่ re-point ถุง `bag_status_id = 3` (MANUAL_MATCHED) / `6` (REPLACED) ที่หน้านี้สร้างขึ้น
- `21` (`pProcessGetPalletListByLocation`) เป็นอิสระ ไม่พึ่งไฟล์อื่นในโฟลเดอร์นี้ (อ่านจาก `tr_pallet`/`tr_bag` ตรง ๆ เหมือน `pProcessGetPalletList` เดิมที่ root) รันตอนไหนก็ได้ วางท้ายสุดไว้ตามลำดับเลขไฟล์เฉย ๆ
- `22` (`pProcessCreateInternalTransferJob`) ต้องรัน**หลัง** `20` (`tr_transaction_log.sql`) เสมอ เพราะเรียก `EXEC dbo.pInsertTransactionLog` ตอนสร้างสำเร็จ เหมือน `03`/`04`/`05`/`06`/`08`/`15` — สร้างตาราง `tr_internal_transfer_header`/`tr_internal_transfer_detail` ของตัวเองภายในไฟล์เดียวกัน ไม่ต้องรันไฟล์อื่นเพิ่ม (ไม่แตะ `tr_job_main`/`ct_job_type`/`ct_job_status` ซึ่งมีอยู่แล้วบน live DB)
- `23`-`25` ต้องรัน**หลัง** `22` เสมอ (พึ่งตาราง `tr_internal_transfer_header`/`tr_internal_transfer_detail` ที่ `22` สร้าง) — `25` ยังพึ่ง `20` เหมือน `22` ด้วย (เรียก `pInsertTransactionLog` เช่นกัน) `23`/`24` เป็น SELECT ล้วน ไม่พึ่ง `20`
- `20` (ตาราง `tr_transaction_log` + `pInsertTransactionLog`) ต้องรัน**ก่อน** `03`/`04`/`05`/`06`/`08`/`15`
  เพราะทุกตัวเรียก `EXEC dbo.pInsertTransactionLog` ตอนทำสำเร็จ (SQL Server ยอม `CREATE PROCEDURE`
  อ้างอิง object ที่ยังไม่มีได้ด้วย deferred name resolution แต่จะ error ตอน**เรียกใช้งานจริง**
  ถ้ายังไม่ได้รัน `20` ก่อน) -- ลำดับเลขไม่ได้บังคับตำแหน่งนี้ตรง ๆ จึงระบุไว้ตรงนี้เป็นพิเศษ
- index (`07`) ต้องรันหลังสุดในกลุ่ม SP `01`-`06` เพราะอ้างอิงชื่อตารางเดิม ไม่ได้ผูกกับ SP โดยตรง
  จะรันตอนไหนก็ได้จริง ๆ แต่แนะนำให้รันครบ SP ก่อนเพื่อความเป็นระเบียบ
- `08` ต้องรัน **หลัง** `00_master_pallet_status.sql` เสมอ เพราะอ้างอิง `pallet_status_id = 3`
  ตามความหมายที่ตารางนั้นกำหนด
- `09`-`15` (Pallet Matching Service, แยกจาก `pallet_matching_service.sql` เดิม) มีลำดับ
  dependency ภายในตัวเอง: `09` (ตาราง) และ `10` (ฟังก์ชัน) ไม่พึ่งอะไร ต้องรันก่อน `11`-`15`
  ทั้งหมด; `13` พึ่ง `09`+`10`; `14` พึ่ง `13`; `15` พึ่ง `10`+`13` (เรียก auto-reconcile ต่อท้าย)
  — เรียงเลข `09→15` ตามลำดับนี้พอดีอยู่แล้ว รันตามเลขไปเรื่อย ๆ ได้เลย
- `16`-`19` (Broken Bag, คัดลอกมาจากไฟล์ root `broken_bag_*.sql`) เป็นฟีเจอร์คนละส่วนกับ
  Pallet Adjustment/Matching ด้านบน ไม่เกี่ยวข้องกัน แต่มี dependency ภายในกลุ่มตัวเอง:
  `16` สร้างตาราง `tr_broken_bag_replace_detail` ต้องรันก่อน `17` ซึ่งแก้ตารางเดียวกัน;
  `18` และ `19` เป็นอิสระ (ไม่พึ่ง `16`/`17`/กันเอง) — `19` เป็น runbook สำหรับแก้ manual
  ที่ live DB เท่านั้น ไม่ใช่สคริปต์ที่รันตรง ๆ ได้เหมือนไฟล์อื่น

**ข้อควรระวังระยะยาว** (รายละเอียดอยู่ท้ายไฟล์ `07_indexes.sql`):
- Index จะเพิ่ม cost เล็กน้อยตอน insert ถุงใหม่จากเครื่องพิมพ์ — ยอมรับ trade-off ได้เพราะ insert เป็น append-only
- ควรตั้ง job รัน `REORGANIZE`/`REBUILD` index เป็นระยะ เพราะ `tr_bag` เป็น HEAP ที่ insert เยอะทุกวัน จะ fragment เร็ว
- ถ้าปริมาณข้อมูลเกินหลักสิบล้านแถวในระยะยาว ควรพิจารณา table partitioning ตาม `create_datetime`

## จุดที่ยังต้อง confirm เพิ่ม

1. `@pallet_type` ตอนสร้าง pallet ใหม่ (shift-missing-bag) — ผมใช้ค่า `pallet_type` เดิมของ pallet ต้นทาง
   (สมมติว่าพาเลทใหม่ควรเป็นประเภทเดียวกับพาเลทที่แตกออกมา) ถ้าไม่ใช่ตามนี้แจ้งได้
2. ลำดับ (`ORDER BY`) ตอน auto re-order หลัง pull-out / reorder ผมใช้ `create_datetime, id` (เรียงตามเวลาพิมพ์จริง)
   ถ้าต้องการอิงจาก `bag_no` เดิมแทน แจ้งได้
3. `dbo.fGetPalletNo` ใช้ `YEAR()/MONTH()/DAY(create_datetime)` ซึ่งเป็น non-sargable เหมือนกัน
   (ดู TODO ใน `07_indexes.sql`) — ถ้าต้องการให้ผมช่วยแก้ function นี้ด้วย แจ้งได้ เพราะตอนนี้
   ผมไม่ได้แก้ให้เนื่องจากเป็น object เดิมที่มีอยู่แล้วในระบบ นอกขอบเขตที่ขออนุญาตไว้
