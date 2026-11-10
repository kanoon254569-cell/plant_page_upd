//  Guided-tour content for the "?" button (app-page-help), one entry per page.
//  Each step highlights the elements tagged data-tour="<target>" on the page
//  (all of them, as one box). A step without target shows in the middle of
//  the screen. A step whose target is not on the page (hidden by *ngIf or a
//  permission) is skipped.
//
//  Add a page here, put <app-page-help page="<key>"> in its header, then
//  tag the elements with data-tour="...".

export interface PageHelpStep {
  target?: string;
  //  Highlight only the first tagged element (e.g. the first card of a list)
  //  instead of one box around all of them.
  firstOnly?: boolean;
  icon: string;
  title: string;
  text: string[];
  //  Optional numbered list under the text (e.g. the order of data entry).
  orderedList?: { title: string; items: string[] };
  //  Optional warning under the text (shown in amber).
  note?: string;
}

export interface PageHelpContent {
  title: string;
  steps: PageHelpStep[];
}

export const PAGE_HELP: Record<string, PageHelpContent> = {
  'job-detail': {
    title: 'วิธีใช้หน้า Job Detail',
    steps: [
      {
        icon: 'menu_book',
        title: 'วิธีใช้หน้า Job Detail',
        text: [
          'หน้านี้ใช้กำหนด Location ต้นทาง/ปลายทาง และเลือกโฟร์คลิฟท์ แล้วกด "อนุมัติ" เพื่อส่งงานให้โฟร์คลิฟท์',
          'กด "ถัดไป" เพื่อดูทีละขั้นตอน กด Esc เพื่อปิด',
        ],
        orderedList: {
          title: 'ขั้นตอนการใส่ข้อมูล',
          items: [
            'เลือก Product Cost Center และ Product Type',
            'ตั้งค่างาน: 1/2 Step, งานเร่งด่วน, สั่งงานล่วงหน้า (ถ้าต้องการ)',
            'เพิ่ม Location ต้นทาง (GET)',
            'เพิ่ม Location ปลายทาง (PUT) ให้ครบตาม QTY',
            'เลือกโฟร์คลิฟท์',
            'กด "อนุมัติ" / "บันทึก"',
          ],
        },
      },
      {
        target: 'job-info',
        icon: 'list_alt',
        title: 'ข้อมูลงาน',
        text: [
          'เลขที่งาน, เลข WMS และสถานะงาน',
          'รหัสงาน, ประเภทงาน, เวลาทำงาน และประเภทสินค้า',
          'เลข WMS ไอคอนเขียว = ส่งข้อมูลไป WMS สำเร็จ, ไอคอนแดง = ส่งไม่สำเร็จ',
          'กดที่เลข WMS เพื่อดู Interface Log ถ้าส่งไม่สำเร็จ กดปุ่ม refresh ข้างเลขเพื่อส่งซ้ำ',
        ],
      },
      {
        target: 'source-changed',
        icon: 'warning',
        title: 'ข้อมูลต้นทางเปลี่ยน',
        text: [
          'แถบนี้ขึ้นเมื่อข้อมูลต้นทางเปลี่ยนหลังอนุมัติ และแสดงรายการที่ถูกลบ, เพิ่มใหม่ หรือเปลี่ยน',
          'กด "บันทึก" เพื่อคำนวณจำนวนพาเลทใหม่',
        ],
      },
      {
        target: 'filters',
        icon: 'tune',
        title: '1. เลือก Product Cost Center และ Product Type',
        text: [
          'เลือกทั้ง 2 ช่องก่อนทำขั้นตอนอื่น',
          'ช่องที่ยังไม่ได้เลือกจะมีขอบสีแดง',
        ],
        note: 'ถ้ายังไม่เลือกทั้ง 2 ช่อง จะเพิ่ม Location ของ Manual Warehouse ไม่ได้',
      },
      {
        target: 'job-options',
        icon: 'flag',
        title: '2. ตั้งค่างาน (ถ้าต้องการ)',
        text: [
          '1 Step: Forklift 1 คัน ขนจากต้นทางไปปลายทาง',
          '2 Step: Forklift 2 คัน ส่งต่อกันที่จุดพักของ เช่น WH40 คันแรกขนจากต้นทางไปจุดพักของ คันที่สองขนต่อไปปลายทาง',
          'งานเร่งด่วน: กดเพื่อทำเครื่องหมายว่างานนี้เร่งด่วน',
          'สั่งงานล่วงหน้า: งานจบแล้วระบบจะยังไม่ส่ง Interface ไป WMS จนกว่าจะกดส่งเอง (ตั้งได้เฉพาะสถานะ Pending หรือ WH Approved)',
          'งานสั่งล่วงหน้าที่จบแล้ว: ปุ่มส่ง Interface ขึ้นแทนปุ่มสั่งงานล่วงหน้า กดเพื่อส่งไป WMS',
        ],
      },
      {
        target: 'grade-lot-item',
        icon: 'inventory_2',
        title: 'รายการเคลื่อนย้ายสินค้า',
        text: [
          'แต่ละแถวแสดง DO, Grade, Lot และจำนวนของรายการ',
          'กดที่แถวเพื่อเปิด/ปิดรายละเอียดตำแหน่งของรายการนั้น',
          'ถ้ามีปุ่ม DO Preparing ให้กดเพื่อกรอกข้อมูลเตรียม DO ของรายการนั้น',
        ],
      },
      {
        target: 'src-location',
        icon: 'logout',
        title: '3. Location ต้นทาง (GET)',
        text: [
          'จุดที่โฟร์คลิฟท์ไปรับสินค้า',
          'กด "เพิ่ม" แล้วเลือก Location จากหน้าต่างที่เปิดขึ้น',
        ],
      },
      {
        target: 'dest-location',
        icon: 'login',
        title: '4. Location ปลายทาง (PUT)',
        text: [
          'จุดที่โฟร์คลิฟท์ไปวางสินค้า',
          'กด "เพิ่ม" แล้วเลือก Location จากหน้าต่างที่เปิดขึ้น',
          'Manual Warehouse: ใส่จำนวนให้ครบตาม QTY ของรายการ และห้ามเกิน',
        ],
        note: 'ทุกรายการต้องมี Location ทั้งต้นทางและปลายทาง',
      },
      {
        target: 'forklift',
        icon: 'local_shipping',
        title: '5. เลือกโฟร์คลิฟท์',
        text: [
          'กด "เพิ่ม" แล้วเลือกโฟร์คลิฟท์อย่างน้อย 1 คัน',
          'ดู "คิว" เพื่อเลือกคันที่งานค้างน้อย',
          'กดไอคอนถังขยะเพื่อเอาโฟร์คลิฟท์ออก',
        ],
      },
      {
        target: 'approve',
        icon: 'check_circle',
        title: '6. อนุมัติ / บันทึก',
        text: [
          'งานสถานะ Pending: กด "อนุมัติ" เพื่อส่งงานให้โฟร์คลิฟท์',
          'งานที่อนุมัติแล้ว: ปุ่มเป็น "บันทึก" ใช้บันทึกการแก้ไข',
          'ถ้าปุ่มกดไม่ได้ ให้ตรวจขั้นตอน 1, 3, 4 และ 5 อีกครั้ง',
        ],
      },
      {
        target: 'page-help',
        icon: 'help_outline',
        title: 'ดูคู่มืออีกครั้ง',
        text: ['กดปุ่มนี้เมื่อไหร่ก็ได้ เพื่อดูขั้นตอนเหล่านี้อีกครั้ง'],
      },
    ],
  },

  'pallet-adjustment': {
    title: 'วิธีใช้หน้า Pallet Adjustment',
    steps: [
      {
        icon: 'menu_book',
        title: 'วิธีใช้หน้า Pallet Adjustment',
        text: [
          'หน้านี้ใช้ตรวจสอบและปรับปรุงข้อมูลถุงในพาเลท สำหรับกรณีฉุกเฉิน',
          'กด "ถัดไป" เพื่อดูทีละขั้นตอน กด Esc เพื่อปิด',
        ],
        orderedList: {
          title: 'ขั้นตอนการใช้งาน',
          items: [
            'ใส่ตัวกรองแล้วกดค้นหา',
            'กดหัวกลุ่มเพื่อขยาย แล้วเลือกพาเลท',
            'เลือกถุงหรือช่องว่างใน Bag List',
            'กดปุ่มใน Quick Actions แล้วยืนยัน',
          ],
        },
        note: 'ขั้นตอนเกี่ยวกับถุงจะแสดงเมื่อเลือกพาเลทแล้วเท่านั้น ให้เลือกพาเลทก่อนกดปุ่มนี้เพื่อดูคู่มือครบทุกขั้นตอน',
      },
      {
        target: 'search-filter',
        icon: 'search',
        title: '1. ค้นหาพาเลท',
        text: [
          'กรอกวันที่พิมพ์, Plant Cost Center, Grade หรือ Lot แล้วกดปุ่มแว่นขยาย',
          'กดปุ่มล้างเพื่อล้างตัวกรอง',
        ],
      },
      {
        target: 'summary',
        icon: 'analytics',
        title: 'สรุปภาพรวม',
        text: [
          'จำนวนพาเลทแยกตามสถานะ และจำนวนถุงทั้งหมดตามเงื่อนไขที่ค้นหา',
          'จำนวนถุงที่ยังไม่ผูกพาเลท และถุงที่ถูก Reject',
        ],
      },
      {
        target: 'overview-tools',
        icon: 'dashboard',
        title: 'รูปแบบการแสดงผล',
        text: [
          'Board / Table: สลับการแสดงพาเลทเป็นการ์ดหรือตาราง',
          'Group by: จัดกลุ่มพาเลทตาม Grade, Lot หรือ Location',
        ],
      },
      {
        target: 'pallet-group',
        firstOnly: true,
        icon: 'touch_app',
        title: '2. เลือกพาเลท',
        text: [
          'ทุกกลุ่มจะถูกย่อไว้ กดหัวกลุ่มเพื่อเปิด/ปิดรายการพาเลท',
          'กดที่พาเลทเพื่อดูรายละเอียดและรายการถุงทางด้านขวา',
        ],
      },
      {
        target: 'selected-pallet',
        icon: 'inventory_2',
        title: 'พาเลทที่เลือก',
        text: [
          'เลขพาเลท, Grade, Lot, สถานะ และจำนวนถุงเทียบกับความจุ',
          'แท็บ Bag List: รายการถุง และจำนวนช่องที่ขาด',
          'แท็บ Pallet Info: ข้อมูลพาเลท เช่น ประเภท, Location และวันที่สร้าง',
        ],
      },
      {
        target: 'bag-toolbar',
        icon: 'manage_search',
        title: 'ค้นหาและมุมมองถุง',
        text: [
          'พิมพ์ Bag No. หรือ QR ในช่องค้นหา',
          'Board / Table: สลับการแสดงถุงเป็นช่องหรือตาราง',
        ],
      },
      {
        target: 'bag-list',
        icon: 'grid_view',
        title: '3. เลือกถุงหรือช่องว่าง',
        text: [
          'กดที่ถุงหรือช่องว่างเพื่อเลือก (กดซ้ำเพื่อยกเลิก) เลือกได้หลายรายการ',
          'สีของช่องบอกสถานะตามคำอธิบายด้านล่าง: จับคู่แล้ว, ถุงที่สร้างเอง, กำลังดำเนินการ, หายไป/ว่าง',
          'ช่องว่างที่รู้ QR เท่านั้นจึงจะเลือกได้ ดู QR เต็มได้โดยวางเมาส์บนช่อง หรือสลับเป็น Table',
        ],
      },
      {
        target: 'quick-actions',
        icon: 'bolt',
        title: '4. Quick Actions',
        text: [
          'ถุง Reject: ปลดถุงหรือช่องว่างที่เลือกออกจากพาเลทและตั้งเป็นถุง Reject (ทำได้แม้พาเลทปิดแล้ว)',
          'เพิ่มข้อมูล: เพิ่มข้อมูลถุงให้ช่องว่าง ต้องเลือกเฉพาะช่องว่างเท่านั้น',
          'ดึงถุงออกจากพาเลท: ย้ายถุงที่เลือกไปเป็นถุงที่ยังไม่ผูกพาเลท และเรียงหมายเลขถุงที่เหลือใหม่',
          'ขึ้นพาเลทใหม่: เลือก 1 ถุง ระบบจะย้ายถุงนั้นถึงถุงสุดท้ายไปพาเลทใหม่ เริ่มนับถุงที่ 1',
          'จบพาเลท: ยืนยันพาเลทที่ยังไม่เต็มเป็นพาเลทเศษ (ปุ่มขึ้นเฉพาะพาเลทที่ยังไม่เต็มและมีถุงแล้ว)',
        ],
        note: 'ทุกปุ่มจะมีหน้าต่างให้ยืนยันก่อนทำรายการ กรุณาตรวจสอบถุงที่เลือกให้ถูกต้อง',
      },
      {
        target: 'orphan-bags',
        icon: 'link_off',
        title: 'ถุงที่ยังไม่ผูกพาเลท',
        text: [
          'กดหัวข้อเพื่อเปิด/ปิดรายการ',
          'เพิ่มเข้าพาเลท: เพิ่มถุงเข้าพาเลทที่เลือกอยู่ Grade และ Lot ต้องตรงกัน',
          'สร้างพาเลทใหม่: ตรวจสอบหรือกรอกข้อมูล Package Ratio แล้วสร้างพาเลทจากถุงนี้',
        ],
      },
      {
        target: 'rejected-bags',
        icon: 'block',
        title: 'ถุงที่ถูก Reject',
        text: [
          'กดหัวข้อเพื่อเปิด/ปิดรายการ แล้วกดที่ถุงเพื่อแสดงปุ่มจัดการ',
          'กลับคืนพาเลทเดิม: คืนถุงเข้าพาเลทที่เคยอยู่',
          'สร้างพาเลทใหม่: สร้างพาเลทใหม่จากถุงนี้',
        ],
      },
      {
        target: 'page-help',
        icon: 'help_outline',
        title: 'ดูคู่มืออีกครั้ง',
        text: ['กดปุ่มนี้เมื่อไหร่ก็ได้ เพื่อดูขั้นตอนเหล่านี้อีกครั้ง'],
      },
    ],
  },

  'job-list': {
    title: 'วิธีใช้หน้า Job List',
    steps: [
      {
        icon: 'menu_book',
        title: 'วิธีใช้หน้า Job List',
        text: [
          'หน้านี้แสดงรายการงานทั้งหมด ใช้ค้นหางาน ดูความคืบหน้า และเข้าไปจัดการงานแต่ละงาน',
          'กด "ถัดไป" เพื่อดูทีละขั้นตอน กด Esc เพื่อปิด',
        ],
        orderedList: {
          title: 'ขั้นตอนการใช้งาน',
          items: [
            'ใส่ตัวกรองแล้วกดค้นหา',
            'กรองต่อด้วยประเภทงาน / Product CC (ถ้าต้องการ)',
            'ดูสถานะและความคืบหน้าจากการ์ดงาน',
            'กด "รายละเอียด" เพื่อเข้าไปจัดการงาน',
          ],
        },
      },
      {
        target: 'header-actions',
        icon: 'local_shipping',
        title: 'รายการงานขาย และอัปโหลด',
        text: [
          'รายการงานขาย: ดูรายการ Shipment จาก WMS และทำ Map DO Shipment, Map DO Special หรือ Create Picking',
          'อัปโหลด: เพิ่มแผน Shipment เอง หรืออัปโหลดจากไฟล์ Excel',
        ],
      },
      {
        target: 'search-filter',
        icon: 'search',
        title: '1. ค้นหางาน',
        text: [
          'กรอกเลขใบงาน, วันที่, ต้นทาง/ปลายทาง หรือสถานะ แล้วกดปุ่มแว่นขยาย',
          'ช่องต้นทาง/ปลายทาง และสถานะ เลือกได้หลายค่า',
          'ตำแหน่งต้นทาง/ปลายทาง (บางหน้า): พิมพ์ค้นหาได้ เลือกหัวข้อประเภทเพื่อเลือกทุก Location ในประเภทนั้น',
          'กดปุ่มล้างเพื่อล้างตัวกรองทั้งหมดและค้นหาใหม่',
        ],
      },
      {
        target: 'list-filters',
        icon: 'filter_list',
        title: '2. กรองประเภทงาน',
        text: [
          'ตัวเลขข้าง "รายการใบงาน" คือจำนวนงานที่ค้นเจอ',
          'กดประเภทงานเพื่อกรอง (เลือกได้หลายประเภท) กด "ทั้งหมด" เพื่อแสดงทุกประเภท',
          'Product CC (บางหน้า): เลือกได้หลายค่า ระบบค้นหาใหม่เมื่อปิดเมนู',
        ],
      },
      {
        target: 'job-card-info',
        firstOnly: true,
        icon: 'badge',
        title: '3. ข้อมูลและสถานะงาน',
        text: [
          'เลขที่งาน, เลข WMS และวันที่สร้างงาน',
          'ป้ายสถานะ: สถานะงาน, 2 Step, ด่วน และ "ยังไม่ส่ง WMS" (งานสั่งล่วงหน้าที่จบแล้ว)',
          'เลข WMS ไอคอนเขียว = ส่งสำเร็จ, ไอคอนแดง = ส่งไม่สำเร็จ กดเพื่อดู Interface Log ถ้าส่งไม่สำเร็จ กดปุ่ม refresh ข้างเลขเพื่อส่งซ้ำ',
        ],
      },
      {
        target: 'job-card-progress',
        firstOnly: true,
        icon: 'trending_up',
        title: 'ความคืบหน้า',
        text: [
          'Grade, Lot และจำนวนของรายการแรก กด "+ อีก N รายการ" เพื่อดูทุกรายการ',
          'แถบความคืบหน้า: จำนวนที่ทำเสร็จ / จำนวนทั้งหมด',
          'เวลาเริ่ม - จบงาน และระยะเวลาที่ใช้',
        ],
      },
      {
        target: 'job-card-location',
        firstOnly: true,
        icon: 'swap_horiz',
        title: 'Location ต้นทาง → ปลายทาง',
        text: [
          'GET = จุดรับสินค้า, PUT = จุดวางสินค้า',
          'ป้ายข้าง GET/PUT คือ CC Code และชื่อ Plant/Warehouse',
          'กด "+ อีก N รายการ" เพื่อดู Location ทั้งหมด',
        ],
      },
      {
        target: 'job-card-inspect',
        firstOnly: true,
        icon: 'touch_app',
        title: '4. รายละเอียด',
        text: [
          'ป้าย CC และประเภทสินค้า คือ Product Cost Center และ Product Type ของงาน',
          'กด "รายละเอียด" เพื่อเปิดหน้า Job Detail: เลือก Location, Forklift และอนุมัติงาน',
        ],
      },
      {
        target: 'source-changed',
        firstOnly: true,
        icon: 'warning',
        title: 'ข้อมูลต้นทางเปลี่ยน',
        text: [
          'แถบนี้ขึ้นเมื่อข้อมูลต้นทางเปลี่ยนหลังอนุมัติ',
          'กด "รายละเอียด" แล้วกด "บันทึก" เพื่อคำนวณจำนวนพาเลทใหม่',
        ],
      },
      {
        target: 'pagination',
        icon: 'last_page',
        title: 'เปลี่ยนหน้า',
        text: ['เลือกจำนวนงานต่อหน้า และเลื่อนไปหน้าถัดไป/ก่อนหน้า'],
      },
      {
        target: 'page-help',
        icon: 'help_outline',
        title: 'ดูคู่มืออีกครั้ง',
        text: ['กดปุ่มนี้เมื่อไหร่ก็ได้ เพื่อดูขั้นตอนเหล่านี้อีกครั้ง'],
      },
    ],
  },
};
