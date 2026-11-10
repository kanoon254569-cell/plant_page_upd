import { AfterViewInit, Component, ElementRef, HostListener, OnDestroy, ViewChild } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import { JwtTokenService } from '../../services/jwt-token.service';
import * as Type from '../../../models/variables-type';
import Swal from 'sweetalert2';
import { MonoTypeOperatorFunction, defer, finalize } from 'rxjs';

//  ค่าแนะนำใน pop-up "สร้างพาเลทใหม่" เมื่อ grade ยังไม่มีใน ct_grade_package_ratio
const PALLET_RATIO_DEFAULT = { unitRatio: 25, unitPallet: 40, unitCode: 'BG' } as const;

//  Reused by rebuildGroups() sorting (see comment there)
const THAI_COLLATOR = new Intl.Collator('th');
const THAI_NUMERIC_COLLATOR = new Intl.Collator('th', { numeric: true });

/**
 * Pallet Adjustment
 * -----------------
 * Maintenance screen for emergency bag <-> pallet re-matching (a bag lost from
 * a pallet, pulling a bag out, adding a bag in, or re-ordering bag numbers on
 * a pallet). This is a NEW screen, separate from pallet-management /
 * pallet-information, so operators can see and fix bag-level data without
 * drilling into each pallet one by one.
 *
 * NOTE: Backend endpoints for this screen (overview / adjust / shift /
 * re-order) do not exist yet. Data below is mock/placeholder so the UI/UX can
 * be reviewed first. Real wiring only needs the fetch/on-confirm methods
 * below to be swapped for the (already-stubbed) CrudService calls -- see
 * `crud.service.ts` PalletAdjustment section.
 */
@Component({
  selector: 'app-pallet-adjustment',
  standalone: false,
  templateUrl: './pallet-adjustment.html',
  styleUrl: './pallet-adjustment.css',
})
export class PalletAdjustment implements AfterViewInit, OnDestroy {
  constructor(
    private crudService: CrudService,
    private jwtService: JwtTokenService,
  ) {}

  //  Current user id (used as userId payload on every mutation call)
  get currentUserId(): number {
    return Number(this.jwtService.getUserId() ?? 0);
  }

  //  ===================================================================
  //  Loading state แยกตามส่วน -- ใช้ .pipe(this.loading('<area>')) กับทุก request
  //    overview : ภาพรวม (summary + Pallet Overview) -> แสดง skeleton
  //    bagList  : รายการถุงของพาเลทที่เลือก -> แสดง skeleton ในช่องถุง
  //    action   : แก้ไขข้อมูล (reject / ดึงออก / สร้างพาเลท ฯลฯ) -> ปิดปุ่ม action
  //  นับเป็น counter เพราะหลัง action จะยิง refresh ต่อซ้อนกัน
  //  ===================================================================
  loadingCounts: Record<LoadingArea, number> = { overview: 0, bagList: 0, action: 0 };

  get isOverviewLoading(): boolean {
    return this.loadingCounts.overview > 0;
  }

  get isBagListLoading(): boolean {
    return this.loadingCounts.bagList > 0;
  }

  get isActionLoading(): boolean {
    return this.loadingCounts.action > 0;
  }

  //  จำนวนการ์ด / ช่องถุง skeleton ที่แสดงระหว่างโหลด
  //  2 กลุ่ม (6 และ 3 การ์ด) ให้ดูเหมือนรายการจริงที่มีหลาย Grade
  readonly skeletonGroups = [Array.from({ length: 6 }), Array.from({ length: 3 })];
  readonly skeletonBagSlots = Array.from({ length: 16 });

  private loading<T>(area: LoadingArea): MonoTypeOperatorFunction<T> {
    return (source) =>
      defer(() => {
        this.loadingCounts[area]++;
        return source;
      }).pipe(finalize(() => (this.loadingCounts[area] = Math.max(0, this.loadingCounts[area] - 1))));
  }

  //  ===================================================================
  //  Search Filter
  //  ===================================================================
  filter: Type.PalletAdjustmentFilter = {
    printDateFrom: new Date(),
    printDateTo: new Date(),
    ccCode: '',
    grade: '',
    lot: '',
  };

  optionSapCcCode: Type.ResultProcessGetOptionsSapCcCode[] = [];

  //  Grade dropdown + autocomplete -- backed by dbo._wmsPlusClient.GetMasterGrade
  //  via GET api/v1/master/grade (crud.service.ts processGetMasterGrade),
  //  same debounced-search pattern pallet-management.ts uses for its
  //  location autocomplete.
  gradeSearchOptions: Type.ResultProcessGetMasterGrade[] = [];
  private gradeSearchTimeout: any;

  async ngOnInit() {
    //  Overview doesn't depend on the cost-center dropdown options -- start
    //  it first so the two requests run in parallel instead of back to back.
    this.restoreFilter();
    this.fetchPalletOverview();

    try {
      this.optionSapCcCode = (await this.fetchOptionSapCcCode()).data;
    } catch {
      //  already logged in fetchOptionSapCcCode; dropdown just stays empty
    }
  }

  //  ===================================================================
  //  Saved filter -- the last searched filter (+ Group by) is kept in
  //  sessionStorage and restored on the next visit, same idea as job-list.
  //  ===================================================================
  private readonly filterStorageKey = 'pallet-adjustment-filter';

  private saveFilter() {
    const saved = {
      printDateFrom: this.formatDateYmd(this.filter.printDateFrom),
      printDateTo: this.formatDateYmd(this.filter.printDateTo),
      ccCode: this.filter.ccCode ?? '',
      grade: this.filter.grade ?? '',
      lot: this.filter.lot ?? '',
      groupBy: this.groupByOption,
    };
    try {
      sessionStorage.setItem(this.filterStorageKey, JSON.stringify(saved));
    } catch {
      //  Storage blocked/full -- the filter just isn't remembered.
    }
  }

  private restoreFilter() {
    let saved: any = null;
    try {
      saved = JSON.parse(sessionStorage.getItem(this.filterStorageKey) || 'null');
    } catch {
      saved = null;
    }
    if (!saved || typeof saved !== 'object') return;

    const str = (value: unknown) => (typeof value === 'string' ? value : '');
    const date = (value: unknown): Date | null => {
      const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(str(value));
      return match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : null;
    };

    this.filter = {
      ...this.filter,
      printDateFrom: date(saved.printDateFrom),
      printDateTo: date(saved.printDateTo),
      ccCode: str(saved.ccCode),
      grade: str(saved.grade).toUpperCase(),
      lot: str(saved.lot),
    };
    if (saved.groupBy === 'grade' || saved.groupBy === 'lot' || saved.groupBy === 'location') {
      this.groupByOption = saved.groupBy;
    }
  }

  //  ===================================================================
  //  Pin page title + Search Filter (pa-sticky-top) by bounding everything
  //  below them (pa-scroll-body) to exactly the viewport space that's left,
  //  measured from the real rendered layout instead of a guessed
  //  calc(100vh - Npx) constant -- see pallet-adjustment.css for why
  //  position:sticky alone doesn't work in this app.
  //  ===================================================================
  @ViewChild('scrollBody') scrollBodyRef?: ElementRef<HTMLElement>;
  @ViewChild('stickyTop') stickyTopRef?: ElementRef<HTMLElement>;

  //  Re-measures whenever pa-sticky-top changes height (fonts loading,
  //  mat-form-field settling, the filter row wrapping) -- a single
  //  measurement right after init could catch the header at a different
  //  height than it ends up, leaving the panels short with a blank strip
  //  below them (or never firing at all while the tab is in the background).
  private stickyTopObserver?: ResizeObserver;

  ngAfterViewInit() {
    this.updateScrollBodyHeight();
    const stickyTop = this.stickyTopRef?.nativeElement;
    if (stickyTop && typeof ResizeObserver !== 'undefined') {
      this.stickyTopObserver = new ResizeObserver(() => this.updateScrollBodyHeight());
      this.stickyTopObserver.observe(stickyTop);
    }
  }

  ngOnDestroy() {
    this.stickyTopObserver?.disconnect();
  }

  //  The outer page should never scroll here (every panel scrolls on its
  //  own) -- if something scrolls it anyway (router scroll restoration,
  //  mouse wheel over a gap), re-fit and snap back to the top.
  @HostListener('window:scroll')
  @HostListener('window:resize')
  onWindowResize() {
    this.updateScrollBodyHeight();
  }

  private updateScrollBodyHeight() {
    const el = this.scrollBodyRef?.nativeElement;
    if (!el) return;

    //  Space consumed above pa-scroll-body (navbar + pa-sticky-top), measured
    //  from the top of the document rather than the viewport: if the outer
    //  page happens to be scrolled when this runs (e.g. scroll position kept
    //  from the previous page), a viewport-relative top comes out too small,
    //  the box too tall, and the page stays scrollable with the header and
    //  filter scrolled out of view. Snap the page back to the top too.
    const top = el.getBoundingClientRect().top + window.scrollY;
    el.style.height = `calc(100vh - ${top}px)`;
    if (window.scrollY !== 0) window.scrollTo(0, 0);
  }

  fetchOptionSapCcCode(): Promise<Type.ResponseProcessGetOptionsSapCcCode> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetOptionsSapCcCode().subscribe(
        (response) => resolve(response),
        (error) => {
          console.error('Error fetching cost center options:', error);
          reject(error);
        },
      );
    });
  }

  //  Force grade textbox to always be uppercase while typing, and debounce
  //  a WMS+ master grade search to populate the autocomplete dropdown.
  onGradeInput(value: string | Event) {
    const rawValue = typeof value === 'string' ? value : (value.target as HTMLInputElement)?.value;
    const upper = (rawValue ?? '').toUpperCase();
    this.filter.grade = upper;

    clearTimeout(this.gradeSearchTimeout);

    if (!upper) {
      this.gradeSearchOptions = [];
      return;
    }

    this.gradeSearchTimeout = setTimeout(() => {
      this.crudService.processGetMasterGrade(upper, '', '', '', '', 1, 20).subscribe({
        next: (response) => {
          this.gradeSearchOptions = response?.data ?? [];
        },
        error: (error) => {
          console.error('Error fetching grade options:', error);
          this.gradeSearchOptions = [];
        },
      });
    }, 300);
  }

  //  Grade Autocomplete Option Select Event
  onSelectGrade(gradeCode: string) {
    clearTimeout(this.gradeSearchTimeout);
    this.filter.grade = gradeCode;
    this.gradeSearchOptions = [];
  }

  onClickSearch() {
    this.saveFilter();
    this.resetSelectedPalletPanel();
    this.fetchPalletOverview();
  }

  resetFilter() {
    this.filter = {
      printDateFrom: new Date(),
      printDateTo: new Date(),
      ccCode: '',
      grade: '',
      lot: '',
    };
    this.gradeSearchOptions = [];
    this.saveFilter();

    this.resetSelectedPalletPanel();
    this.fetchPalletOverview();
  }

  //  ล้างข้อมูลฝั่ง Pallet Info (ขวา) ทุกครั้งที่ค้นหาใหม่ -- กันเคสพาเลท/ถุง
  //  ที่เลือกไว้เดิมไม่ตรงกับผลลัพธ์ชุดใหม่ (เช่นถูกกรองออกไปแล้ว)
  private resetSelectedPalletPanel() {
    //  เงื่อนไขใหม่ -> ข้อมูลเดิมใช้แทนไม่ได้ ถ้าโหลดไม่ได้ต้องโชว์ error เต็ม ไม่ใช่ "ข้อมูลเก่า"
    this.overviewLoaded = false;
    this.selectedPallet = null;
    this.bagList = [];
    this.bagListError = null;
    this.bagListTab = 'bagList';
    this.bagSearchText = '';
    this.clearBagSelection();
  }

  //  ===================================================================
  //  Summary Cards (populated by fetchPalletOverview())
  //  ===================================================================
  //  Timestamp of the last successful fetchPalletOverview() call -- shown next
  //  to "Pallet Overview" as "อัปเดตล่าสุด" (was a hardcoded "10:30:25" before).
  lastUpdated: Date | null = null;

  summary = {
    totalPallets: 0,
    inProgress: 0,
    complete: 0,
    totalBags: 0,
    orphanBags: 0,
    confirmedRemainder: 0,
  };

  //  ===================================================================
  //  Pallet Overview -- flat list from fetchPalletOverview(), re-grouped
  //  client-side into `groups` by grade / lot / location (see rebuildGroups())
  //  whenever groupByOption changes, no re-fetch needed.
  //  ===================================================================
  allPallets: PalletCardInfo[] = [];
  groups: PalletOverviewGroup[] = [];
  //  Board/Table toggle for THIS panel only -- separate from the Bag List's
  //  own bagViewMode below, so switching one no longer silently changes the other.
  overviewViewMode: 'card' | 'table' = 'card';

  //  Orphan bags: printed but not (yet, or no longer) matched to any pallet
  orphanBags: PalletAdjustmentBag[] = [];
  orphanExpanded = false;

  //  Rejected bags (tr_bag.is_active = 'R') -- shown read-only below Orphan Bags
  rejectedBags: PalletAdjustmentRejectedBag[] = [];
  rejectedExpanded = false;

  //  Clicking a rejected bag row reveals its "คืนค่า" (restore) button
  selectedRejectedBagId: number | null = null;

  toggleRejectedBagSelect(bag: PalletAdjustmentRejectedBag) {
    this.selectedRejectedBagId = this.selectedRejectedBagId === bag.id ? null : bag.id;
  }

  //  ===================================================================
  //  Selected Pallet + Bag List (right-hand panel)
  //  ===================================================================
  selectedPallet: PalletCardInfo | null = null;

  bagListTab: 'bagList' | 'palletInfo' = 'bagList';
  bagSearchText: string = '';
  //  Board/Table toggle for the Bag List only -- see overviewViewMode above
  //  for the (separate) Pallet Overview panel's own toggle.
  bagViewMode: 'card' | 'table' = 'card';
  groupByOption: 'grade' | 'lot' | 'location' = 'grade';
  bagList: PalletAdjustmentBag[] = [];

  //  Multi-select (checkbox) for quick actions
  selectedBagIds = new Set<number>();

  toggleBagSelect(bag: PalletAdjustmentBag) {
    if (this.selectedBagIds.has(bag.id)) {
      this.selectedBagIds.delete(bag.id);
    } else {
      this.selectedBagIds.add(bag.id);
    }
  }

  isBagSelected(bag: PalletAdjustmentBag): boolean {
    return this.selectedBagIds.has(bag.id);
  }

  //  ช่องว่างที่ไม่มีข้อมูลการพิมพ์ (QR ของช่อง) -- เลือกได้เฉพาะเพื่อ "ถุง Reject"
  //  (ช่องที่ API ไม่ส่ง missing_slots มาให้ ยังกดเลือกไม่ได้เหมือนเดิม)
  missingSlots: Type.ResultPalletAdjustmentMissingSlot[] = [];
  selectedMissingQrs = new Set<string>();

  toggleMissingSelect(qr: string | null | undefined) {
    if (!qr) return;
    if (this.selectedMissingQrs.has(qr)) {
      this.selectedMissingQrs.delete(qr);
    } else {
      this.selectedMissingQrs.add(qr);
    }
  }

  isMissingSelected(qr: string | null | undefined): boolean {
    return !!qr && this.selectedMissingQrs.has(qr);
  }

  //  "เพิ่มข้อมูล" ใช้ได้เฉพาะถุงที่ไม่มีข้อมูล : เลือกช่องว่าง และไม่มีถุงปกติปนอยู่
  get canAddMissingBag(): boolean {
    return this.selectedMissingQrs.size > 0 && this.selectedBagIds.size === 0;
  }

  get selectedCount(): number {
    return this.selectedBagIds.size + this.selectedMissingQrs.size;
  }

  clearBagSelection() {
    this.selectedBagIds.clear();
    this.selectedMissingQrs.clear();
  }

  //  "จบพาเลท" ใช้ได้เฉพาะพาเลทที่ยังไม่เต็ม (status === 'wh_process') และมีถุงอยู่แล้ว
  //  อย่างน้อย 1 ใบ -- กรณีพาเลทสุดท้ายของ lot ที่ผลิตไม่ครบจำนวนถุง/พาเลท ไม่เช็คว่ามี
  //  current_job_id (งาน WMS) ผูกอยู่หรือไม่ -- โชว์ได้เสมอตราบใดที่ยังไม่ครบ
  //  (ไม่ใช่ !== 'complete' เฉย ๆ เพราะตอนนี้ 'confirmed' เป็น status แยกออกมาแล้ว --
  //  พาเลทที่ confirmed ไปแล้วไม่ควรกด "จบพาเลท" ซ้ำได้อีก)
  get canFinishSelectedPallet(): boolean {
    return this.selectedPallet?.status === 'wh_process' && (this.selectedPallet?.bagCount ?? 0) > 0;
  }

  //  Thai label for the pallet status chip -- shared by the card grid, table
  //  view, and the selected-pallet header (3 places) so the 3-way branch
  //  doesn't get re-typed at each call site.
  getPalletStatusLabel(status: PalletCardInfo['status']): string {
    switch (status) {
      case 'complete':
        return 'เสร็จสมบูรณ์';
      case 'confirmed':
        return 'พาเลทเศษ (ยืนยันแล้ว)';
      default:
        return 'กำลังดำเนินการ';
    }
  }

  get filteredBagList(): PalletAdjustmentBag[] {
    const keyword = (this.bagSearchText ?? '').trim().toLowerCase();
    if (!keyword) return this.bagList;
    return this.bagList.filter(
      (b) =>
        String(b.bagNo).includes(keyword) ||
        (b.qrTextData ?? '').toLowerCase().includes(keyword),
    );
  }

  //  Bag List ที่แสดงจริง (Board/Table) -- เลขช่อง = เลขถุงใน QR (cc|grade|lot|bag|ตัน)
  //  เพราะ bag_no ถูก renumber 1..k ไม่เว้นช่อง (13_ step 3.3) ทำให้บอกไม่ได้ว่าใบไหนขาด
  //  พาเลทที่ถุงไม่ครบ unit_pallet -> เติมช่องว่างสีแดง "ไม่มีถุง" ตรงเลข QR ที่ขาด
  //  (เช่น มี 01-05, 09-40 -> แดงที่ 06, 07, 08) ; ใช้เลข QR ได้เฉพาะเมื่อถุงทั้งพาเลทเป็น
  //  ตันเดียวกัน + ton_no (ตันที่ระบบจัดให้) ตรงกับตันใน QR ทุกใบ + เลข QR ไม่ซ้ำและอยู่ใน
  //  1..unit_pallet ไม่งั้น fallback เป็น bag_no + ช่องว่างต่อท้าย ; ระหว่างค้นหาไม่เติมช่องว่าง
  //  (เช็ค ton_no เพราะ reject เลื่อนถุงข้ามตัน: พาเลทถัดไปอาจเหลือแต่ QR ตัน 002 ถุง 02-40
  //  ซึ่งผ่านเงื่อนไขอื่นหมด แต่ถุง 01 ไม่ได้หาย -- ย้ายไปพาเลทก่อนหน้า ; bag_no จริงคือ 1-39)
  //  + ต้องไม่มีถุงใบไหนมี reject อยู่ก่อนหน้า (rejectBefore) -- reject ถุง 15 ของตันที่ตันถัดไป
  //  ยังไม่มีถุง: ทุกใบยังเป็นตัน 001 และ ton_no ตรง แต่ถุง 16-40 เลื่อนขึ้นเป็น bag_no 15-39
  //  แล้ว ต้องแสดงตาม bag_no (ช่องว่างไปท้ายสุด) ไม่ใช่โชว์ช่องแดงที่ 15
  //  cache ไว้ตาม input เพราะ getter ถูกเรียกทุกรอบ change detection
  private bagSlotsCache: {
    key: string;
    list: PalletAdjustmentBag[];
    missing: Type.ResultPalletAdjustmentMissingSlot[];
    slots: BagSlot[];
  } | null = null;

  //  true = ใช้เลขถุงใน QR เป็นเลขช่องได้ (ดูเงื่อนไขด้านบน)
  get useQrSlot(): boolean {
    const unitPallet = this.selectedPallet?.unitPallet ?? 0;
    if (this.bagList.length === 0 || unitPallet <= 0) return false;
    const tons = new Set(this.bagList.map((b) => b.qrTon));
    const nos = this.bagList.map((b) => b.qrBagNo);
    return (
      tons.size === 1 &&
      !tons.has(null) &&
      this.bagList.every((b) => b.tonNo != null && b.tonNo === b.qrTon && !b.rejectBefore) &&
      nos.every((n) => n != null && n >= 1 && n <= unitPallet) &&
      new Set(nos).size === nos.length
    );
  }

  slotNoOf(bag: PalletAdjustmentBag): number | null {
    return (this.useQrSlot ? bag.qrBagNo : bag.bagNo) ?? null;
  }

  get bagSlots(): BagSlot[] {
    const list = this.filteredBagList;
    const unitPallet = this.selectedPallet?.unitPallet ?? 0;
    const searching = !!(this.bagSearchText ?? '').trim();
    const useQr = this.useQrSlot;
    const key = `${unitPallet}|${searching}|${useQr}`;
    if (
      this.bagSlotsCache &&
      this.bagSlotsCache.list === list &&
      this.bagSlotsCache.missing === this.missingSlots &&
      this.bagSlotsCache.key === key
    ) {
      return this.bagSlotsCache.slots;
    }

    const slots: BagSlot[] = list.map((bag) => ({ slotNo: this.slotNoOf(bag), bag }));
    const emptyCount = searching ? 0 : Math.max(0, unitPallet - this.bagList.length);
    if (emptyCount > 0) {
      const used = new Set(this.bagList.map((b) => this.slotNoOf(b)));
      for (let no = 1, added = 0; added < emptyCount; no++) {
        if (used.has(no)) continue;
        slots.push({ slotNo: no, bag: null });
        added++;
      }
    }
    slots.sort((a, b) => (a.slotNo ?? Number.MAX_SAFE_INTEGER) - (b.slotNo ?? Number.MAX_SAFE_INTEGER));

    //  ผูกช่องว่างกับ QR ของช่องที่ไม่มีข้อมูลการพิมพ์ ตามลำดับ (ช่องว่างเรียงตามเลขช่อง ,
    //  missing_slots เรียงตามตำแหน่ง QR) -- โหมดเลข QR ช่องว่างคือเลขถุงใน QR ที่ขาดอยู่แล้ว
    //  จึงตรงกันพอดี ; โหมด bag_no ช่องว่างต่อท้ายจึงรับ QR ที่ขาดตามลำดับ
    const missing = [...this.missingSlots].sort((a, b) => a.planned_pos - b.planned_pos);
    slots.filter((s) => !s.bag).forEach((s, i) => (s.missing = missing[i] ?? null));

    this.bagSlotsCache = { key, list, missing: this.missingSlots, slots };
    return slots;
  }

  //  จำนวนช่องที่ขาด (ใช้แสดงบนแท็บ Bag List)
  get missingSlotCount(): number {
    return Math.max(0, (this.selectedPallet?.unitPallet ?? 0) - this.bagList.length);
  }

  trackBagSlot(_: number, s: BagSlot): string {
    return s.bag ? `b${s.bag.id}` : `e${s.slotNo}`;
  }

  selectPallet(pallet: PalletCardInfo) {
    this.selectedPallet = pallet;
    this.clearBagSelection();
    this.fetchBagListByPallet(pallet.id);
  }

  fetchBagListByPallet(palletId: number) {
    this.bagListError = null;
    this.crudService.processGetPalletAdjustmentBagList(palletId).pipe(this.loading('bagList')).subscribe({
      next: (response) => {
        this.bagList = (response.data ?? []).map((b) => ({
          id: b.id,
          bagNo: b.bag_no,
          tonNo: b.ton_no ?? null,
          rejectBefore: !!b.reject_before,
          isManualAdded: !!b.is_manual_added,
          qrTextData: b.qr_text_data,
          grade: b.grade,
          lot: b.lot,
          status: b.status,
          ...parseQrBag(b.qr_text_data),
        }));
        this.missingSlots = response.missing_slots ?? [];
      },
      error: (error) => {
        console.error('Error fetching bag list:', error);
        //  แสดง error ในพื้นที่ช่องถุง (ไม่ใช้ pop-up) -- ดู bagListError ใน template
        this.bagList = [];
        this.missingSlots = [];
        this.bagListError = this.toLoadError(error, 'โหลดรายการถุงไม่สำเร็จ');
      },
    });
  }

  toggleGroup(group: PalletOverviewGroup) {
    group.expanded = !group.expanded;
  }

  //  Group-by dropdown changed -- re-group the already-fetched pallets
  //  client-side, no need to hit the API again.
  onGroupByChange(value: 'grade' | 'lot' | 'location') {
    this.groupByOption = value;
    this.saveFilter();
    this.rebuildGroups();
  }

  //  Re-derive `groups` from `allPallets` according to groupByOption.
  private rebuildGroups() {
    const keyOf = (p: PalletCardInfo): { key: string; title: string; hint?: string } => {
      if (this.groupByOption === 'lot') {
        const lot = p.lot || 'ไม่ระบุ Lot';
        return { key: lot, title: `Lot: ${lot}` };
      }
      if (this.groupByOption === 'location') {
        const location = p.location || 'ไม่ระบุตำแหน่ง';
        return { key: location, title: `Location: ${location}` };
      }
      const grade = p.grade || 'ไม่ระบุ Grade';
      return {
        key: grade,
        title: `Grade: ${grade}`,
        hint: `(Unit Pallet: ${p.gradeUnitPallet ?? p.unitPallet} ถุง/พาเลท)`,
      };
    };

    const groupByKey = new Map<string, PalletOverviewGroup>();
    for (const pallet of this.allPallets) {
      const { key, title, hint } = keyOf(pallet);
      let group = groupByKey.get(key);
      if (!group) {
        group = { key, title, hint, expanded: false, pallets: [] };
        groupByKey.set(key, group);
      }
      group.pallets.push(pallet);
    }

    //  เรียงพาเลทในแต่ละ group ตาม Lot แล้วตามเลขตัน (palletRunningNo) แบบตัวเลข
    //  -- ไม่มีเลขตันไว้ท้าย Lot นั้น
    //  Same ordering as localeCompare(x, 'th', opts), but with the collators
    //  built once -- localeCompare with a locale argument builds a new
    //  collator on every comparison, which is slow across ~1-2k pallets.
    const tonOf = (p: PalletCardInfo) => {
      const s = (p.palletRunningNo ?? '').trim();
      return /^\d+$/.test(s) ? Number(s) : Number.MAX_SAFE_INTEGER;
    };
    for (const group of groupByKey.values()) {
      group.pallets.sort(
        (a, b) =>
          THAI_NUMERIC_COLLATOR.compare(a.lot ?? '', b.lot ?? '') ||
          tonOf(a) - tonOf(b) ||
          THAI_COLLATOR.compare(a.palletNo ?? '', b.palletNo ?? ''),
      );
    }

    this.groups = Array.from(groupByKey.values()).sort((a, b) => THAI_COLLATOR.compare(a.key, b.key));
  }

  //  ===================================================================
  //  Quick Actions (4 flows) -- confirm via SweetAlert before calling API
  //  ===================================================================

  //  1) ถุงหาย -> Shift ทุกถุงที่อยู่ใต้ถุงที่หาย ขึ้น pallet ใหม่
  async onClickShiftMissingBag() {
    if (!this.selectedPallet) {
      this.SweetAlert('warning', 'กรุณาเลือกพาเลทก่อนทำการ Shift');
      return;
    }

    if (this.selectedBagIds.size !== 1) {
      this.SweetAlert('warning', 'กรุณาเลือกถุงที่หายไป 1 ถุง ก่อนทำรายการ Shift');
      return;
    }

    const missingBagId = Array.from(this.selectedBagIds)[0];
    const missingBag = this.bagList.find((b) => b.id === missingBagId);

    const confirm = await Swal.fire({
      icon: 'warning',
      title: 'ยืนยันการขึ้นพาเลทใหม่',
      html: `ระบบจะย้ายถุงหมายเลข <b>${missingBag?.bagNo}</b> ถึงถุงสุดท้ายของพาเลทนี้<br/>ไปขึ้นพาเลทใหม่ (running number เริ่มที่ 1) เนื่องจากถุงหมายเลขนี้สูญหาย`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    });

    if (!confirm.isConfirmed) return;

    this.crudService
      .processShiftMissingBag({
        palletId: this.selectedPallet!.id,
        missingBagNo: missingBag?.bagNo ?? 0,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'Shift ถุงขึ้นพาเลทใหม่สำเร็จ');
          this.clearBagSelection();
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error shifting missing bag:', error);
          this.SweetAlert('error', error?.error?.message || 'Shift ถุงไม่สำเร็จ');
        },
      });
  }

  //  2) ดึงถุงออกจากพาเลท -> ถุงจะกลายเป็น Orphan Bag
  async onClickPullBagOut() {
    if (this.selectedBagIds.size === 0) {
      this.SweetAlert('warning', 'กรุณาเลือกอย่างน้อย 1 ถุง ที่ต้องการดึงออกจากพาเลท');
      return;
    }

    const confirm = await Swal.fire({
      icon: 'question',
      title: 'ยืนยันการดึงถุงออกจากพาเลท',
      text: `ต้องการดึงถุงจำนวน ${this.selectedBagIds.size} ถุง ออกจากพาเลท ${this.selectedPallet?.palletNo} หรือไม่? ถุงจะถูกย้ายไปเป็นถุงที่ยังไม่ผูกพาเลท`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    });

    if (!confirm.isConfirmed) return;

    this.crudService
      .processPullBagOut({
        bagIds: Array.from(this.selectedBagIds),
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'ดึงถุงออกจากพาเลทสำเร็จ');
          this.clearBagSelection();
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error pulling bag out:', error);
          this.SweetAlert('error', error?.error?.message || 'ดึงถุงออกจากพาเลทไม่สำเร็จ');
        },
      });
  }

  //  3) เพิ่มถุงเข้าพาเลท (จาก orphan bag หรือพาเลทหมดอายุ)
  async onClickAddBagIn(bag: PalletAdjustmentBag) {
    if (!this.selectedPallet) {
      this.SweetAlert('warning', 'กรุณาเลือกพาเลทปลายทางก่อน');
      return;
    }

    if (!this.isBagCompatibleWithSelectedPallet(bag)) return;

    const confirm = await Swal.fire({
      icon: 'question',
      title: 'ยืนยันการเพิ่มถุงเข้าพาเลท',
      html: `ต้องการเพิ่มถุง <b>${bag.qrTextData}</b> เข้าพาเลท <b>${this.selectedPallet.palletNo}</b> หรือไม่?`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    });

    if (!confirm.isConfirmed) return;

    this.crudService
      .processAddBagIn({
        bagId: bag.id,
        palletId: this.selectedPallet.id,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'เพิ่มถุงเข้าพาเลทสำเร็จ');
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error adding bag in:', error);
          this.SweetAlert('error', error?.error?.message || 'เพิ่มถุงเข้าพาเลทไม่สำเร็จ');
        },
      });
  }

  //  3.1) สร้างพาเลทใหม่ให้ orphan bag -- pop-up แสดง ct_grade_package_ratio ของ grade
  //  ให้ตรวจ/แก้ก่อน (ไม่มีข้อมูล -> ผู้ใช้คีย์เอง) แล้ว sp_PalletAdjustment_CreatePallet
  //  บันทึก ratio + สร้างพาเลทใส่ถุงนี้เป็นถุงที่ 1
  //  ใช้กับถุงที่ถูก Reject ด้วย (SP จะปรับถุงกลับเป็นปกติแล้วใส่พาเลทใหม่)
  onClickCreatePallet(bag: CreatePalletBag) {
    this.crudService.processGetGradeRatio(bag.grade).pipe(this.loading('action')).subscribe({
      next: (response) => this.openCreatePalletDialog(bag, response.result),
      error: (error) => {
        console.error('Error fetching grade ratio:', error);
        this.SweetAlert('error', error?.error?.message || 'ไม่สามารถดึงข้อมูล Package Ratio ได้');
      },
    });
  }

  private async openCreatePalletDialog(
    bag: CreatePalletBag,
    ratio: Type.ResultPalletAdjustmentGradeRatio | null,
  ) {
    const found = !!ratio?.found;
    const esc = (v: unknown) =>
      String(v ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
    //  ค่าแนะนำ (ใช้เมื่อยังไม่มีข้อมูลใน ct_grade_package_ratio หรือช่องนั้นว่าง)
    const unitRatio = ratio?.unit_ratio ?? PALLET_RATIO_DEFAULT.unitRatio;
    const unitPallet = ratio?.unit_pallet ?? PALLET_RATIO_DEFAULT.unitPallet;
    const unitCode = ratio?.unit_code || PALLET_RATIO_DEFAULT.unitCode;

    const { value: form, isConfirmed } = await Swal.fire({
      icon: found ? 'question' : 'warning',
      title: 'สร้างพาเลทใหม่',
      //  Swal render นอก component -> ใช้ inline style (CSS ของ component ไม่ถึง)
      html: `
        <div style="text-align:left;font-size:14px">
          <p style="margin:0 0 6px;word-break:break-all">ถุง <b>${esc(bag.qrTextData)}</b></p>
          <p style="margin:0 0 10px;color:${found ? '#475569' : '#b45309'}">
            ${
              found
                ? 'ข้อมูล Package Ratio ของ Grade นี้ กรุณาตรวจสอบหรือแก้ไขก่อนสร้างพาเลท'
                : 'ไม่พบข้อมูล Grade นี้ใน Package Ratio กรุณาตรวจสอบค่าแนะนำหรือกรอกข้อมูลก่อนสร้างพาเลท'
            }
          </p>
          <label style="display:block;margin-top:8px">Grade</label>
          <input id="cp-grade" class="swal2-input" style="width:100%;margin:4px 0 0" value="${esc(ratio?.grade || bag.grade)}" disabled />
          <label style="display:block;margin-top:8px">Unit Ratio (kg/ถุง) *</label>
          <input id="cp-unit-ratio" class="swal2-input" style="width:100%;margin:4px 0 0" type="number" min="1" step="1" placeholder="${PALLET_RATIO_DEFAULT.unitRatio}" value="${esc(unitRatio)}" />
          <label style="display:block;margin-top:8px">Unit Pallet (ถุง/พาเลท) *</label>
          <input id="cp-unit-pallet" class="swal2-input" style="width:100%;margin:4px 0 0" type="number" min="1" step="1" placeholder="${PALLET_RATIO_DEFAULT.unitPallet}" value="${esc(unitPallet)}" />
          <label style="display:block;margin-top:8px">Unit Code (หน่วย)</label>
          <input id="cp-unit-code" class="swal2-input" style="width:100%;margin:4px 0 0" maxlength="20" placeholder="${PALLET_RATIO_DEFAULT.unitCode}" value="${esc(unitCode)}" />
          <p style="margin:6px 0 0;font-size:12px;color:#94a3b8">
            ค่าแนะนำ: Unit Ratio ${PALLET_RATIO_DEFAULT.unitRatio} · Unit Pallet ${PALLET_RATIO_DEFAULT.unitPallet} · หน่วย ${PALLET_RATIO_DEFAULT.unitCode}
          </p>
        </div>`,
      focusConfirm: false,
      showCancelButton: true,
      confirmButtonText: found ? 'สร้างพาเลท' : 'บันทึกและสร้างพาเลท',
      cancelButtonText: 'ยกเลิก',
      preConfirm: () => {
        const val = (id: string) => (document.getElementById(id) as HTMLInputElement).value.trim();
        const unitRatio = Number(val('cp-unit-ratio'));
        const unitPallet = Number(val('cp-unit-pallet'));
        if (!Number.isInteger(unitRatio) || unitRatio <= 0 || !Number.isInteger(unitPallet) || unitPallet <= 0) {
          Swal.showValidationMessage('กรุณากรอก Unit Ratio และ Unit Pallet เป็นจำนวนเต็มมากกว่า 0');
          return false;
        }
        return { unitRatio, unitPallet, unitCode: val('cp-unit-code') || undefined };
      },
    });

    if (!isConfirmed || !form) return;

    this.crudService
      .processCreatePallet({
        bagId: bag.id,
        unitRatio: form.unitRatio,
        unitPallet: form.unitPallet,
        unitCode: form.unitCode,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'สร้างพาเลทใหม่สำเร็จ');
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error creating pallet:', error);
          this.SweetAlert('error', error?.error?.message || 'สร้างพาเลทใหม่ไม่สำเร็จ');
        },
      });
  }

  private isBagCompatibleWithSelectedPallet(bag: PalletAdjustmentBag): boolean {
    if (!this.selectedPallet) return false;

    const palletGrades = [
      this.selectedPallet.grade,
      ...this.bagList.map((existingBag) => existingBag.grade),
    ]
      .map((value) => this.normalizePalletAttribute(value))
      .filter(Boolean);
    const palletLots = [
      this.selectedPallet.lot,
      ...this.bagList.map((existingBag) => existingBag.lot),
    ]
      .map((value) => this.normalizePalletAttribute(value))
      .filter(Boolean);
    const bagGrade = this.normalizePalletAttribute(bag.grade);
    const bagLot = this.normalizePalletAttribute(bag.lot);

    if (palletGrades.some((grade) => grade !== bagGrade)) {
      this.SweetAlert(
        'warning',
        `ไม่สามารถเพิ่มถุงได้: Grade ของถุง (${bag.grade || '-'}) ไม่ตรงกับ Grade ของพาเลท (${this.selectedPallet.grade || '-'})`,
      );
      return false;
    }

    if (palletLots.some((lot) => lot !== bagLot)) {
      this.SweetAlert(
        'warning',
        `ไม่สามารถเพิ่มถุงได้: Lot ของถุง (${bag.lot || '-'}) ไม่ตรงกับ Lot ของพาเลท (${this.selectedPallet.lot || '-'})`,
      );
      return false;
    }

    return true;
  }

  private normalizePalletAttribute(value: string | null | undefined): string {
    return (value ?? '').trim().toUpperCase();
  }

  //  4) Re-order ถุงในพาเลททั้งหมด (จัดเรียงลำดับถุงใหม่ ไม่ให้มีเลขกระโดด/ซ้ำ)
  async onClickReorderPallet() {
    if (!this.selectedPallet) {
      this.SweetAlert('warning', 'กรุณาเลือกพาเลทก่อนทำการ Re-order');
      return;
    }

    const confirm = await Swal.fire({
      icon: 'warning',
      title: 'ยืนยันการ Re-order ถุงใหม่',
      html: `ระบบจะจัดเรียงหมายเลขถุงในพาเลท <b>${this.selectedPallet.palletNo}</b> ใหม่ทั้งหมด<br/>ตามลำดับ QR ที่พิมพ์ก่อน-หลัง การกระทำนี้ไม่สามารถย้อนกลับได้`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน Re-order',
      cancelButtonText: 'ยกเลิก',
    });

    if (!confirm.isConfirmed) return;

    this.crudService
      .processReorderPallet({
        palletId: this.selectedPallet.id,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'Re-order ถุงในพาเลทสำเร็จ');
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error reordering pallet:', error);
          this.SweetAlert('error', error?.error?.message || 'Re-order ถุงในพาเลทไม่สำเร็จ');
        },
      });
  }

  //  4.5) จบพาเลท -> ใช้กับพาเลทสุดท้ายของ Lot ที่ผลิตไม่ครบจำนวนถุง/พาเลท
  //  Backed by dbo.sp_PalletAdjustment_FinishPallet ซึ่ง set pallet_status_id = 3
  //  (CONFIRMED, dbo.ct_pallet_status) ให้พาเลทใบนี้ -- ทำให้ระบบถือว่าพาเลทนี้
  //  ครบ/เสร็จสมบูรณ์ทันที โดยไม่ต้องรอถุงมาเติม ไม่ย้ายถุงใด ๆ และไม่แก้ unit_pallet
  async onClickFinishPallet() {
    if (!this.selectedPallet) {
      this.SweetAlert('warning', 'กรุณาเลือกพาเลทก่อนทำการจบพาเลท');
      return;
    }

    if (!this.canFinishSelectedPallet) {
      this.SweetAlert('warning', 'จบพาเลทได้เฉพาะพาเลทที่ยังไม่เต็มและมีถุงอยู่แล้วเท่านั้น');
      return;
    }

    const confirm = await Swal.fire({
      icon: 'warning',
      title: 'ยืนยันการจบพาเลท',
      html: `ระบบจะยืนยันพาเลท <b>${this.selectedPallet.palletNo}</b> เป็น "พาเลทเศษ" (CONFIRMED)<br/>
             ด้วยจำนวนถุงปัจจุบัน (${this.selectedPallet.bagCount}/${this.selectedPallet.unitPallet} ถุง)
             ทันที โดยไม่ต้องรอถุงมาเติมอีก<br/>
             ใช้สำหรับกรณีเป็นพาเลทสุดท้ายของ Lot ที่ผลิตไม่ครบจำนวนถุง/พาเลท`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน จบพาเลท',
      cancelButtonText: 'ยกเลิก',
    });

    if (!confirm.isConfirmed) return;

    this.crudService
      .processFinishPallet({
        palletId: this.selectedPallet.id,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'จบพาเลทสำเร็จ');
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error finishing pallet:', error);
          this.SweetAlert('error', error?.error?.message || 'จบพาเลทไม่สำเร็จ');
        },
      });
  }

  //  5) ถุง Reject -> ปลดถุงออกจากพาเลททันที (ทำได้แม้พาเลทจะปิด/WH Process แล้ว)
  //  ใช้ dbo.pProcessUpdateBagRejectStatus @reject=1 ผ่าน processRejectBag();
  //  reconcile ของพาเลทที่เหลือ (ถ้าเคย match) ยิงต่อทันทีฝั่ง SP เอง
  //  ช่องว่างที่ไม่มีข้อมูลการพิมพ์ (selectedMissingQrs) -> dbo.sp_PalletAdjustment_RejectMissingSlot
  //  สร้างถุง Reject ของช่องนั้น ถุงหลังจากนั้นเลื่อนขึ้นมาแทน ; "คืนค่า" ใน Rejected Bags = ยกเลิก
  async onClickRejectBag() {
    if (this.selectedCount === 0) {
      this.SweetAlert('warning', 'กรุณาเลือกอย่างน้อย 1 ถุง ที่ต้องการ Reject');
      return;
    }

    const parts = [
      this.selectedBagIds.size > 0 ? `ถุงจำนวน ${this.selectedBagIds.size} ถุง` : '',
      this.selectedMissingQrs.size > 0 ? `ช่องที่ไม่มีข้อมูลการพิมพ์ ${this.selectedMissingQrs.size} ช่อง` : '',
    ].filter((p) => p);

    const { value: reason, isConfirmed } = await Swal.fire({
      icon: 'warning',
      title: 'ยืนยันการ Reject ถุง',
      html: `ต้องการ Reject ${parts.join(' และ ')} หรือไม่?<br/>ถุงจะถูกปลดออกจากพาเลท (ทำได้แม้พาเลทจะปิดแล้ว)`,
      input: 'text',
      inputLabel: 'เหตุผล (ไม่บังคับ)',
      inputValue: 'ถุง reject',
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน Reject',
      cancelButtonText: 'ยกเลิก',
    });

    if (!isConfirmed) return;

    this.crudService
      .processRejectBag({
        bagIds: Array.from(this.selectedBagIds),
        palletId: this.selectedPallet?.id,
        missingQrs: Array.from(this.selectedMissingQrs),
        reason: (reason ?? '').trim() || undefined,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert(response.status === 'success' ? 'success' : 'warning', response.message || 'Reject ถุงสำเร็จ');
          this.clearBagSelection();
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error rejecting bag:', error);
          this.SweetAlert('error', error?.error?.message || 'Reject ถุงไม่สำเร็จ');
        },
      });
  }

  //  เพิ่มข้อมูล -> ช่องว่างที่ไม่มีข้อมูลการพิมพ์ (selectedMissingQrs) เพิ่มเป็นถุงใน tr_bag
  //  ด้วย QR format เดิม ผ่าน dbo.sp_PalletAdjustment_AddMissingBag ; SP จับลงพาเลทต่อทันทีเอง
  async onClickAddMissingBag() {
    if (!this.selectedPallet || !this.canAddMissingBag) {
      this.SweetAlert('warning', 'เพิ่มข้อมูลได้เฉพาะช่องว่างที่ไม่มีข้อมูล กรุณาเลือกเฉพาะช่องว่าง');
      return;
    }

    const qrs = Array.from(this.selectedMissingQrs);
    const { isConfirmed } = await Swal.fire({
      icon: 'question',
      title: 'ยืนยันการเพิ่มข้อมูลถุง',
      html: `ต้องการเพิ่มข้อมูลถุง ${qrs.length} ถุง หรือไม่?<br/>${qrs.join('<br/>')}`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยันเพิ่มข้อมูล',
      cancelButtonText: 'ยกเลิก',
    });

    if (!isConfirmed) return;

    this.crudService
      .processAddMissingBag({
        palletId: this.selectedPallet.id,
        missingQrs: qrs,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert(response.status === 'success' ? 'success' : 'warning', response.message || 'เพิ่มข้อมูลสำเร็จ');
          this.clearBagSelection();
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error adding missing bag:', error);
          this.SweetAlert('error', error?.error?.message || 'เพิ่มข้อมูลไม่สำเร็จ');
        },
      });
  }

  //  6) "คืนค่า" ปุ่มบนแถว Rejected Bags -> ปรับถุงจาก reject กลับเป็นปกติ
  //  ใช้ dbo.pProcessUpdateBagRejectStatus @reject=0 ผ่าน processUnrejectBag();
  //  SP จะกู้ bag_no/pallet_running_no จาก qr_text_data และยิง reconcile ต่อทันทีเอง
  async onClickUnrejectBag(bag: PalletAdjustmentRejectedBag) {
    const confirm = await Swal.fire({
      icon: 'question',
      title: 'ยืนยันกลับคืนพาเลทเดิม',
      html: `ต้องการนำถุง <b>${bag.qrTextData}</b> จาก Reject กลับคืนพาเลทเดิมหรือไม่?<br/>ถุงจะกลับเข้าคิวรอจับคู่พาเลทอัตโนมัติตามเลขตันใน QR`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน กลับคืนพาเลทเดิม',
      cancelButtonText: 'ยกเลิก',
    });

    if (!confirm.isConfirmed) return;

    this.crudService
      .processUnrejectBag({
        bagId: bag.id,
        userId: this.currentUserId,
      })
      .pipe(this.loading('action'))
      .subscribe({
        next: (response) => {
          this.SweetAlert('success', response.message || 'คืนค่าถุงสำเร็จ');
          if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
          this.fetchPalletOverview();
        },
        error: (error) => {
          console.error('Error unrejecting bag:', error);
          this.SweetAlert('error', error?.error?.message || 'คืนค่าถุงไม่สำเร็จ');
        },
      });
  }

  //  ===================================================================
  //  Fetch Pallet Overview
  //  ===================================================================
  //  Format a Date (bound to mat-datepicker) into 'yyyy-MM-dd' expected by
  //  the API. Returns '' when empty so the backend treats it as "no filter".
  private formatDateYmd(value: unknown): string {
    if (!value) return '';
    const d = value instanceof Date ? value : new Date(value as string);
    if (isNaN(d.getTime())) return '';
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd}`;
  }

  fetchPalletOverview() {
    const requestFilter: Type.PalletAdjustmentFilter = {
      ...this.filter,
      printDateFrom: this.formatDateYmd(this.filter.printDateFrom),
      printDateTo: this.formatDateYmd(this.filter.printDateTo),
    };

    this.crudService.processGetPalletAdjustmentOverview(requestFilter).pipe(this.loading('overview')).subscribe({
      next: (response) => {
        const data = response.data;

        this.lastUpdated = new Date();
        this.overviewError = null;
        this.overviewLoaded = true;

        this.summary = {
          totalPallets: data.summary?.total_pallets ?? 0,
          inProgress: data.summary?.wh_process ?? 0,
          complete: data.summary?.complete ?? 0,
          totalBags: data.summary?.total_bags ?? 0,
          orphanBags: data.summary?.orphan_bags ?? 0,
          confirmedRemainder: data.summary?.confirmed_remainder ?? 0,
        };

        this.allPallets = (data.grades ?? []).flatMap((g) =>
          (g.pallets ?? []).map((p) => ({
            id: p.id,
            palletNo: p.pallet_no,
            grade: g.grade,
            lot: p.lot,
            palletRunningNo: p.pallet_running_no ?? '',
            palletType: p.pallet_type,
            unitPallet: p.unit_pallet,
            gradeUnitPallet: g.unit_pallet,
            bagCount: p.bag_count,
            location: p.current_location,
            locationType: p.location_type,
            createDateTime: p.create_datetime,
            status: p.status,
          })),
        );
        this.rebuildGroups();

        this.orphanBags = (data.orphan_bags ?? []).map((b) => ({
          id: b.id,
          bagNo: b.bag_no,
          qrTextData: b.qr_text_data,
          grade: b.grade,
          lot: b.lot,
          status: b.status,
        }));

        this.rejectedBags = (data.rejected_bags ?? []).map((b) => ({
          id: b.id,
          bagNo: b.bag_no,
          qrTextData: b.qr_text_data,
          grade: b.grade,
          lot: b.lot,
          rejectReason: b.reject_reason,
          rejectDatetime: b.reject_datetime,
        }));
        //  Drop any stale row selection -- the bag it pointed at may no
        //  longer be in this refreshed list (e.g. just got unrejected).
        this.selectedRejectedBagId = null;
      },
      error: (error) => {
        console.error('Error fetching pallet overview:', error);
        //  แสดง error ในหน้า (ไม่ใช้ pop-up) -- ดู overviewError ใน template
        this.overviewError = this.toLoadError(error, 'โหลดข้อมูลพาเลทไม่สำเร็จ');
        //  ไม่มีข้อมูลของเงื่อนไขนี้ -> ล้างของเงื่อนไขเก่าทิ้ง (orphan / reject ด้านขวาด้วย)
        if (!this.overviewLoaded) {
          this.allPallets = [];
          this.groups = [];
          this.orphanBags = [];
          this.rejectedBags = [];
        }
      },
    });
  }

  //  ===================================================================
  //  Load errors -- แสดงในจุดที่ข้อมูลควรอยู่ แทน pop-up ; แยก "โหลดไม่สำเร็จ"
  //  ออกจาก "ไม่มีข้อมูล" (เดิม error แล้วหน้าโชว์ "ไม่พบข้อมูลพาเลท" ซึ่งผิด)
  //    overviewError + !overviewLoaded : โหลดครั้งแรกของเงื่อนไขนี้ไม่ได้ -> error เต็ม panel, summary เป็น "–"
  //    overviewError +  overviewLoaded : refresh ไม่ได้แต่มีข้อมูลเดิม -> แถบเตือนเหลือง + ข้อมูลเดิม
  //  ===================================================================
  overviewError: LoadError | null = null;
  //  true เมื่อเงื่อนไขค้นหาปัจจุบันเคยโหลดสำเร็จแล้ว (reset ทุกครั้งที่กดค้นหา/ล้าง)
  overviewLoaded = false;
  bagListError: LoadError | null = null;

  get showOverviewError(): boolean {
    return !this.isOverviewLoading && !!this.overviewError && !this.overviewLoaded;
  }

  get showOverviewStale(): boolean {
    return !this.isOverviewLoading && !!this.overviewError && this.overviewLoaded;
  }

  retryOverview() {
    this.fetchPalletOverview();
  }

  retryBagList() {
    if (this.selectedPallet) this.fetchBagListByPallet(this.selectedPallet.id);
  }

  //  แปลง HttpErrorResponse เป็นข้อความที่ผู้ใช้อ่านเข้าใจ ตามชนิด error
  private toLoadError(error: any, defaultTitle: string): LoadError {
    const status = Number(error?.status ?? 0);
    const time = new Date();
    if (status === 0) {
      return { status, time, title: 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้', message: 'ตรวจสอบการเชื่อมต่อเครือข่าย แล้วลองใหม่อีกครั้ง' };
    }
    if (status === 401 || status === 403) {
      return { status, time, title: 'ไม่มีสิทธิ์เข้าถึงข้อมูล', message: 'Session อาจหมดอายุ กรุณาออกจากระบบแล้วเข้าสู่ระบบใหม่' };
    }
    if (status >= 400 && status < 500) {
      return { status, time, title: defaultTitle, message: error?.error?.message || 'เงื่อนไขการค้นหาไม่ถูกต้อง กรุณาตรวจสอบแล้วลองใหม่' };
    }
    return {
      status,
      time,
      title: defaultTitle,
      message: 'ระบบขัดข้องชั่วคราว ลองใหม่อีกครั้ง หากยังไม่ได้กรุณาแจ้ง IT',
    };
  }

  //  Sweet Alert helper (same pattern as pallet-management / pallet-information)
  SweetAlert(icon: any, message: string) {
    Swal.fire({
      position: 'center',
      icon,
      title: 'ข้อความจากระบบ',
      text: message,
      showConfirmButton: true,
    });
  }
}

//  ===================================================================
//  Local view models (kept local to this component until confirmed with
//  backend; safe to move into models/variables-type.ts later.)
//  ===================================================================
//  Generic overview group -- built client-side by rebuildGroups() according
//  to groupByOption ('grade' | 'lot' | 'location'), all from the same flat
//  `allPallets` list so switching the dropdown never needs a re-fetch.
export interface PalletOverviewGroup {
  key: string;
  title: string;
  hint?: string;
  expanded: boolean;
  pallets: PalletCardInfo[];
}

export interface PalletCardInfo {
  id: number;
  palletNo: string;
  grade: string;
  lot: string;
  //  running pallet no จาก QR ถุง (ส่วนสุดท้าย) เช่น '001' -- แสดงเป็น Grade | Lot | 001
  palletRunningNo?: string;
  palletType?: string;
  unitPallet: number;
  //  Grade-level unit pallet (kept separately from the pallet's own
  //  unitPallet) -- only used for the "Group by Grade" hint text.
  gradeUnitPallet?: number;
  bagCount?: number;
  location?: string;
  locationType?: string;
  createDateTime?: string;
  //  'wh_process' = ถุงยังไม่ครบ unit_pallet (pallet_status_id=1) · 'complete' =
  //  เต็มเองตามธรรมชาติ (pallet_status_id=2) · 'confirmed' = ยืนยันเป็นพาเลทเศษ
  //  ผ่านปุ่ม "จบพาเลท" (pallet_status_id=3)
  status: 'complete' | 'wh_process' | 'confirmed';
}

export interface PalletAdjustmentBag {
  id: number;
  bagNo: number;
  //  tr_bag.ton_no -- ตันที่ระบบจัดให้หลังเลื่อน (ไม่ตรงตันใน QR = ถุงถูกเลื่อนข้ามตัน)
  tonNo?: number | null;
  //  มีถุง reject ก่อนถุงนี้ตามลำดับ QR (ถุงถูกเลื่อนขึ้นมาแล้ว)
  rejectBefore?: boolean;
  //  ถุงที่สร้างจากปุ่ม "เพิ่มข้อมูล" -- แสดงอีกสีใน Bag List
  isManualAdded?: boolean;
  qrTextData: string;
  grade: string;
  lot: string;
  status: 'matched' | 'in_progress' | 'missing' | 'orphan';
  //  แกะจาก qr_text_data (cost_center|grade|lot|bag_no|pallet_running_no) -- ใช้เป็นเลขช่องใน
  //  Bag List (มีเฉพาะถุงของ bag list ; orphan bag ไม่ได้ใช้)
  qrBagNo?: number | null;
  qrTon?: number | null;
}

//  แกะเลขถุง/เลขตันจาก QR -- เทียบเท่า dbo.fParseBagQr ฝั่ง SQL
function parseQrBag(qr: string | null | undefined): { qrBagNo: number | null; qrTon: number | null } {
  const parts = (qr ?? '').split('|');
  const toInt = (s: string | undefined) => (s && /^\d+$/.test(s.trim()) ? Number(s.trim()) : null);
  return { qrBagNo: toInt(parts[3]), qrTon: toInt(parts[4]) };
}

//  1 ช่องใน Bag List -- bag = null คือช่องว่างสีแดง "ไม่มีถุง" (พาเลทถุงไม่ครบ)
export interface BagSlot {
  slotNo: number | null;
  bag: PalletAdjustmentBag | null;
  //  ช่องว่าง: QR ของช่องที่ไม่มีข้อมูลการพิมพ์ (Reject ได้) -- null = ไม่รู้ว่าเป็น QR ไหน
  missing?: Type.ResultPalletAdjustmentMissingSlot | null;
}

export interface PalletAdjustmentRejectedBag {
  id: number;
  bagNo: number;
  qrTextData: string;
  grade: string;
  lot: string;
  rejectReason: string | null;
  rejectDatetime: string | null;
}

type LoadingArea = 'overview' | 'bagList' | 'action';

//  Error ตอนโหลดข้อมูล (แสดงในหน้า) -- status 0 = ต่อ server ไม่ได้
interface LoadError {
  status: number;
  title: string;
  message: string;
  time: Date;
}

//  ถุงที่ "สร้างพาเลทใหม่" ได้ -- orphan bag หรือถุงที่ถูก Reject
type CreatePalletBag = Pick<PalletAdjustmentBag, 'id' | 'qrTextData' | 'grade'>;
