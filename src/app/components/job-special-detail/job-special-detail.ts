import { ChangeDetectorRef, Component, ElementRef, OnDestroy, ViewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import Swal from 'sweetalert2';
import * as QRCode from 'qrcode';

interface BagItemVM {
  grade: string;
  lot: string;
  qty: number | null;
  bag: number | null;
}

interface PalletVM {
  bags: BagItemVM[];
}

//  One row per distinct grade+lot across every pallet/bag in the job -- what
//  WH actually needs to pull is this total per grade+lot, not the individual
//  bag rows (the same grade+lot can be split across several pallets/bags,
//  e.g. by buildPalletsForGroup's leftover-combining or a multi-lot detail
//  from toVM's lot expansion).
interface WhWithdrawalRow {
  grade: string;
  lot: string;
  qty: number;
  bag: number;
}

interface JobDetailVM {
  id: number;
  jobNo: string;
  docNo: string;
  no: string;
  date: string;
  customer: string;
  seq: string;
  palletSize: string;
  arranged: boolean;
  wrapFilm: boolean;
  taped: boolean;
  saleDate: string;
  remark: string;
  invoice: string;
  orderedBy: string;
  prepStatus: string;
  incompleteDetail: string;
  tonPerCart: number | null;
  cartQty: number | null;
  pallets: PalletVM[];
  dateObj: Date | null;
  saleDateObj: Date | null;
  statusName: string;
  //  Once the job's shipment has started arriving at the warehouse
  //  (is_arriving on the API row), its pallet/bag makeup is already in
  //  motion physically -- editing it here would drift the printed labels
  //  and QR codes out of sync with what's actually on the truck, so the
  //  whole form locks read-only instead of just staying save-disabled.
  isArriving: boolean;
}

@Component({
  selector: 'app-job-special-detail',
  standalone: false,
  templateUrl: './job-special-detail.html',
  styleUrl: './job-special-detail.css',
})
export class JobSpecialDetail implements OnDestroy {
  _jobId: number | null = null;
  _job: JobDetailVM | null = null;
  _isLoading = true;
  _isSaving = false;

  //  Direct handle to this instance's own #print-special-area node -- see
  //  the identical fix (and full explanation) on user-list.ts's
  //  printUserAreaRef. printCards() reparents this node to document.body
  //  for printing; if "afterprint" never fires (print dialog cancelled in
  //  an unusual way, or the user navigates away first), a plain
  //  getElementById('print-special-area') can no longer reliably find
  //  "this" instance's copy once a duplicate id is sitting under <body>,
  //  leaving it stuck there -- unstyled and visible -- on whatever page
  //  loads next (e.g. job-special-list) once this component is destroyed.
  @ViewChild('printSpecialArea', { static: true }) printSpecialAreaRef!: ElementRef<HTMLDivElement>;
  private printAreaPlaceholder: HTMLElement | null = null;

  constructor(
    private route: ActivatedRoute,
    private router: Router,
    private restService: CrudService,
    private cdr: ChangeDetectorRef,
  ) {}

  async ngOnInit() {
    this.cleanupOrphanedPrintAreas();

    const idStr = this.route.snapshot.paramMap.get('id');
    this._jobId = idStr ? parseInt(idStr, 10) : null;
    if (this._jobId) {
      await this.loadJob();
    } else {
      this._isLoading = false;
    }
  }

  //  Self-heal safety net: if a previous instance's print area was ever
  //  left orphaned under <body> (afterprint never fired), it still carries
  //  the same id as this fresh instance's own node, so it's otherwise
  //  unreachable by id. Sweeps every match and drops whichever isn't
  //  printSpecialAreaRef -- see user-list.ts's identical
  //  cleanupOrphanedPrintAreas() for the full reasoning.
  private cleanupOrphanedPrintAreas(): void {
    document.querySelectorAll('#print-special-area, #print-special-area-placeholder').forEach((el) => {
      if (el !== this.printSpecialAreaRef.nativeElement) {
        el.remove();
      }
    });
  }

  //  Moves #print-special-area back to its original spot in the template
  //  if printCards() left it detached under <body>. Called both from the
  //  normal "afterprint" handler and from ngOnDestroy (in case the user
  //  navigates away before "afterprint" ever fires) -- see
  //  user-list.ts's restorePrintUserArea for the same pattern.
  private restorePrintSpecialArea = (): void => {
    const printArea = this.printSpecialAreaRef?.nativeElement;
    if (printArea && this.printAreaPlaceholder && this.printAreaPlaceholder.parentNode) {
      this.printAreaPlaceholder.parentNode.insertBefore(printArea, this.printAreaPlaceholder);
      this.printAreaPlaceholder.remove();
    }
    this.printAreaPlaceholder = null;
  };

  ngOnDestroy(): void {
    window.removeEventListener('afterprint', this.restorePrintSpecialArea);
    this.restorePrintSpecialArea();
  }

  async loadJob() {
    this._isLoading = true;
    try {
      const response = await new Promise<Type.ResponseProcessSpecialJobListData>(
        (resolve, reject) => {
          this.restService.processGetSpecialJobList(Number(this._jobId), '', '', '', 0, 0, 1, 9999, '', '').subscribe(
            (res) => resolve(res),
            (err) => reject(err),
          );
        },
      );
      const found = response.data?.find((j) => j.id === this._jobId);
      this._job = found ? this.toVM(found) : null;
    } catch (e) {
      console.error(e);
      this._job = null;
    } finally {
      this._isLoading = false;

      //  The date/sale-date mat-datepicker inputs are bound via [ngModel] and
      //  only get created once _job resolves (behind the *ngIf on this async
      //  data). Without an explicit detectChanges here, MatDatepickerInput's
      //  writeValue() can run before the surrounding *ngIf finishes stamping
      //  out the DOM, so the picker's native input is left blank until some
      //  later change detection pass (e.g. clicking into the field) syncs it.
      this.cdr.detectChanges();
    }
  }

  private toVM(job: Type.ResultProcessSpecialJobListData): JobDetailVM {
    const byPallet = new Map<number, BagItemVM[]>();
    for (const item of job.details ?? []) {
      const key = item.pallet_no || 1;
      if (!byPallet.has(key)) byPallet.set(key, []);
      //  item.lot no longer exists on the API's flat item row - each detail
      //  now carries its lot breakdown under lots[] instead (a single detail
      //  can span more than one lot, e.g. qty 1500 = lot A 1000 + lot B 500).
      //  This UI's bag table only has room for one lot per row (matches
      //  RequestSpecialJobBagRow, which also carries a single lot), so
      //  expand every lot into its own row rather than keeping just the
      //  first and silently dropping the rest. bag count is split
      //  proportionally to each lot's qty share, with the remainder folded
      //  into the last lot so the rows still sum to item.bag exactly.
      const lots = item.lots?.length ? item.lots : [{ lot: '', qty: item.qty }];
      const totalLotQty = lots.reduce((s, l) => s + (l.qty ?? 0), 0) || item.qty || 0;
      let bagAssigned = 0;
      lots.forEach((l, i) => {
        const isLast = i === lots.length - 1;
        const bag = isLast
          ? (item.bag ?? 0) - bagAssigned
          : Math.round((item.bag ?? 0) * ((l.qty ?? 0) / (totalLotQty || 1)));
        bagAssigned += bag;
        byPallet.get(key)!.push({
          grade: item.grade,
          lot: l.lot ?? '',
          qty: l.qty,
          bag,
        });
      });
    }
    const pallets: PalletVM[] = Array.from(byPallet.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([, bags]) => ({ bags }));
    if (pallets.length === 0) pallets.push({ bags: [] });

    const dateObj = job.job_date ? new Date(job.job_date) : null;
    const saleDateObj = job.sale_date ? new Date(job.sale_date) : null;

    return {
      id: job.id,
      jobNo: job.system_no || '',
      docNo: job.doc_no || '',
      no: job.no || '',
      date: dateObj ? this.fmt(dateObj) : '',
      customer: job.customer || '',
      seq: job.seq || '',
      palletSize: job.pallet_size || '',
      arranged: !!job.is_arranged,
      wrapFilm: !!job.is_wrap_film,
      taped: !!job.is_taped,
      saleDate: saleDateObj ? this.fmt(saleDateObj) : '',
      remark: job.remark || '',
      invoice: job.invoice || '',
      orderedBy: job.ordered_by || '',
      prepStatus: job.prep_status || '',
      incompleteDetail: job.incomplete_detail || '',
      tonPerCart: job.total_ton,
      cartQty: job.cart_qty,
      pallets,
      dateObj,
      saleDateObj,
      statusName: job.status_name || '',
      isArriving: !!job.is_arriving,
    };
  }

  private fmt(d: Date | null): string {
    if (!d) return '';
    return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`;
  }

  //  dd/mm/yyyy for the API payload, built straight from the Date object
  //  rather than reusing job.date/job.saleDate. pProcessUpdateSpecialJob
  //  parses @job_date/@sale_date with TRY_CONVERT(DATE, ..., 103), and SQL
  //  Server style 103 is specifically dd/mm/yyyy - both yyyy-MM-dd and
  //  whatever locale-short-date format was producing values like "1-7-69"/
  //  "7/1/25" fail that TRY_CONVERT and silently save as NULL.
  private toApiDate(d: Date | null): string {
    if (!d) return '';
    return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`;
  }

  onDateChange(field: 'date' | 'saleDate', value: Date | null) {
    if (!this._job || this._job.isArriving) return;
    this._job[field] = this.fmt(value);
    this._job[field === 'date' ? 'dateObj' : 'saleDateObj'] = value;
  }

  // ── Pallet management ──────────────────────────────────────────────
  //  Every mutator below also guards on isArriving even though the buttons
  //  that call them are disabled in the template while arriving -- belt and
  //  braces against the DOM state ever getting out of sync with the model.
  addPallet() {
    if (this._job?.isArriving) return;
    this._job?.pallets.push({ bags: [] });
  }

  removePallet(pIdx: number) {
    if (this._job?.isArriving) return;
    this._job?.pallets.splice(pIdx, 1);
  }

  duplicatePallet(pIdx: number) {
    if (!this._job || this._job.isArriving) return;
    const src = this._job.pallets[pIdx];
    this._job.pallets.push({ bags: src.bags.map((b) => ({ ...b })) });
  }

  addBagItem(pIdx: number) {
    if (this._job?.isArriving) return;
    this._job?.pallets[pIdx].bags.push({ grade: '', lot: '', qty: null, bag: null });
  }

  removeBagItem(pIdx: number, iIdx: number) {
    if (this._job?.isArriving) return;
    this._job?.pallets[pIdx].bags.splice(iIdx, 1);
  }

  //  QR content is รหัส Pallet|เกรด|qty per bag, joined with # -- a pallet
  //  mixing several grades (see job-special-list.ts's buildPalletsForGroup
  //  leftover combining) has more than one bag, so each gets its own
  //  segment rather than losing every bag but the first. e.g. for a
  //  4-grade pallet: "S-IREX262737-P8|GA400|462.5#S-IREX262737-P8|
  //  GA800 5229|25#S-IREX262737-P8|GA800 6B28W|462.5#S-IREX262737-P8|SP200|462.5"
  private buildPalletQrContent(palletCode: string, pallet: PalletVM): string {
    if (pallet.bags.length === 0) return palletCode;
    return pallet.bags
      .map((b) => `${palletCode}|${b.grade || ''}|${b.qty ?? ''}`)
      .join('#');
  }

  // ── Print pallet QR ───────────────────────────────────────────────
  async printPallet(pIdx: number) {
    const job = this._job;
    const pallet = job?.pallets[pIdx];
    if (!job || !pallet) return;

    if (this.isBlank(job.docNo)) {
      Swal.fire({
        position: 'center',
        icon: 'warning',
        title: 'ข้อความจากระบบ',
        text: 'กรุณากรอกเลขที่เอกสารก่อนพิมพ์ QR Code',
        showConfirmButton: true,
      });
      return;
    }

    const palletCode = `${job.docNo}-P${pIdx + 1}`;
    let qrDataUrl: string;
    try {
      qrDataUrl = await QRCode.toDataURL(this.buildPalletQrContent(palletCode, pallet), {
        width: 430,
        margin: 1,
      });
    } catch (e) {
      console.error(e);
      Swal.fire({
        position: 'center',
        icon: 'error',
        title: 'ข้อความจากระบบ',
        text: 'สร้าง QR Code ไม่สำเร็จ',
        showConfirmButton: true,
      });
      return;
    }

    this.printCards(job, [{ pallet, pIdx, palletCode, qrDataUrl }]);
  }

  //  Print All: same as printPallet but generates one QR per pallet and lays
  //  every label out as its own printed page.
  async printAllPallets() {
    const job = this._job;
    if (!job) return;

    if (this.isBlank(job.docNo)) {
      Swal.fire({
        position: 'center',
        icon: 'warning',
        title: 'ข้อความจากระบบ',
        text: 'กรุณากรอกเลขที่เอกสารก่อนพิมพ์ QR Code',
        showConfirmButton: true,
      });
      return;
    }
    if (job.pallets.length === 0) return;

    try {
      const cards = await Promise.all(
        job.pallets.map(async (pallet, pIdx) => {
          const palletCode = `${job.docNo}-P${pIdx + 1}`;
          const qrDataUrl = await QRCode.toDataURL(this.buildPalletQrContent(palletCode, pallet), {
            width: 430,
            margin: 1,
          });
          return { pallet, pIdx, palletCode, qrDataUrl };
        }),
      );
      this.printCards(job, cards);
    } catch (e) {
      console.error(e);
      Swal.fire({
        position: 'center',
        icon: 'error',
        title: 'ข้อความจากระบบ',
        text: 'สร้าง QR Code ไม่สำเร็จ',
        showConfirmButton: true,
      });
    }
  }

  //  Renders the label card(s) into the page's hidden #print-special-area and
  //  triggers the browser's own print preview (window.print()), instead of a
  //  separate popup window — same pattern used by location-management.
  private printCards(
    job: JobDetailVM,
    cards: { pallet: PalletVM; pIdx: number; palletCode: string; qrDataUrl: string }[],
  ): void {
    const printArea = this.printSpecialAreaRef.nativeElement;
    printArea.innerHTML = cards
      .map((c) => this.renderLabelCard(job, c.pallet, c.pIdx, c.palletCode, c.qrDataUrl))
      .join('');

    setTimeout(() => {
      if (printArea.parentNode) {
        this.printAreaPlaceholder = document.createElement('div');
        printArea.parentNode.insertBefore(this.printAreaPlaceholder, printArea);
        document.body.appendChild(printArea);
      }

      window.print();

      window.addEventListener('afterprint', this.restorePrintSpecialArea, { once: true });
    }, 50);
  }

  private renderLabelCard(
    job: JobDetailVM,
    pallet: PalletVM,
    pIdx: number,
    palletCode: string,
    qrDataUrl: string,
  ): string {
    const esc = (v: unknown) => this.escapeHtml(v === null || v === undefined ? '' : String(v));
    const rows = pallet.bags
      .map(
        (b, i) => `
        <tr>
          <td>${i + 1}</td>
          <td style="text-align:left">${esc(b.grade)}</td>
          <td style="text-align:left">${esc(b.lot)}</td>
          <td>${b.qty ?? '-'}</td>
          <td>${b.bag ?? '-'}</td>
        </tr>`,
      )
      .join('');

    //  A pallet mixing several grades (see job-special-list.ts's
    //  buildPalletsForGroup leftover combining) has more item rows than a
    //  single-grade pallet ever did -- shrinks the item table's own
    //  font-size/padding (both in em, scaled off this inline font-size) so
    //  more rows means smaller text instead of overflowing onto a second
    //  page. comfortableRowCount=2 (don't shrink below 2 rows) traded
    //  readable size away too aggressively on ordinary few-grade pallets;
    //  raised back to 3, and the floor from 0.4 to 0.5, so common cases
    //  read bigger at the cost of a little more overflow risk on the
    //  heaviest multi-grade pallets.
    const comfortableRowCount = 3;
    const rowCount = Math.max(1, pallet.bags.length);
    const tableScale = Math.max(0.5, Math.min(1, comfortableRowCount / rowCount));
    const tableFontPx = Math.round(23 * tableScale * 100) / 100;
    const palletTotalBags = pallet.bags.reduce((s, b) => s + (b.bag ?? 0), 0);
    const flagChips = [
      job.arranged ? 'จัดเรียง' : '',
      job.wrapFilm ? 'ฟีล่ม' : '',
      job.taped ? 'รัดเทป' : '',
    ]
      .filter(Boolean)
      .map((f) => `<span class="flag-chip">${esc(f)}</span>`)
      .join('');

    return `
    <div class="label-card">

      <div class="label-header">
        <div>
          <div class="brand-name">IRPC WAREHOUSE</div>
          <div class="brand-sub">Special Job · Pallet Label</div>
        </div>
        <div class="label-header-right">
          <div class="print-date-lbl">Print Date</div>
          <div class="print-date-val">${esc(this.fmt(new Date()))}</div>
        </div>
      </div>

      <div class="label-row">
        <div class="label-box label-box--wide">
          <div class="box-title">ข้อมูลใบงาน</div>
          <div class="box-line"><span class="box-line-lbl">JOB No</span>${esc(job.jobNo)}</div>
          <div class="box-line"><span class="box-line-lbl">เลขที่เอกสาร</span>${esc(job.docNo)}</div>
          <div class="box-line"><span class="box-line-lbl">ลูกค้า</span>${esc(job.customer)}</div>
        </div>
        <div class="label-box label-box--narrow">
          <div class="accent-title">PALLET #${pIdx + 1}</div>
          <div class="accent-line">ขนาดพาเลท: ${esc(job.palletSize) || '-'}</div>
          <div class="accent-line">ตัน: ${job.tonPerCart ?? '-'}</div>
          ${flagChips ? `<div class="flag-row">${flagChips}</div>` : ''}
        </div>
      </div>

      <div class="label-row">
        <div class="label-box label-box--wide">
          <div class="box-title">ข้อมูลเพิ่มเติม</div>
          <div class="box-line"><span class="box-line-lbl">วันที่</span>${esc(job.date)}<span class="box-line-lbl" style="margin-left:12px">ลำดับ</span>${esc(job.seq)}</div>
          <div class="box-line"><span class="box-line-lbl">INVOICE</span>${esc(job.invoice)}<span class="box-line-lbl" style="margin-left:12px">ผู้สั่งงาน</span>${esc(job.orderedBy)}</div>
          <div class="box-line"><span class="box-line-lbl">หมายเหตุ</span>${esc(job.remark) || '-'}</div>
        </div>
        <div class="label-box label-box--narrow">
          <div class="box-line-sm">ขายวันที่<strong>${esc(job.saleDate) || '-'}</strong></div>
          <div class="box-line-sm">คัน<strong>${job.cartQty ?? '-'}</strong></div>
        </div>
      </div>

      <div class="label-code-row">
        <div class="code-tag">SP</div>
        <div class="code-main">
          <div class="code-sub">รหัส Pallet</div>
          <div class="code-big">${esc(palletCode)}</div>
        </div>
        <img class="code-qr" src="${qrDataUrl}" alt="QR" />
      </div>

      <div class="cut-line"><span>✂</span></div>

      <div class="item-table-wrap">
        <table class="item-table" style="font-size:${tableFontPx}px">
          <thead><tr><th>#</th><th>Grade</th><th>Lot</th><th>Qty (kg)</th><th>Bag</th></tr></thead>
          <tbody>${rows || '<tr><td colspan="5">-</td></tr>'}</tbody>
        </table>
      </div>

      <div class="label-footer">
        <div>เลขที่เอกสาร <strong>${esc(job.docNo)}</strong></div>
        <div>จำนวนรวม <strong>${palletTotalBags}</strong></div>
      </div>

    </div>`;
  }

  private escapeHtml(str: string): string {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // ── Derived display ────────────────────────────────────────────────
  totalQtyDisplay(): string {
    const t = this._job?.tonPerCart;
    if (t === null || t === undefined) return '-';
    return (Math.round(t * 1000 * 100) / 100).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  totalBags(): number {
    return this._job?.pallets.flatMap((p) => p.bags).reduce((s, b) => s + (b.bag ?? 0), 0) ?? 0;
  }

  //  WH withdrawal summary: collapses every pallet/bag row down to one line
  //  per grade+lot with its combined qty/bag, since that's what a picker
  //  actually needs to pull from stock rather than this page's per-pallet
  //  breakdown.
  whWithdrawalSummary(): WhWithdrawalRow[] {
    const job = this._job;
    if (!job) return [];
    const byGradeLot = new Map<string, WhWithdrawalRow>();
    for (const bag of job.pallets.flatMap((p) => p.bags)) {
      const key = `${bag.grade || ''}||${bag.lot || ''}`;
      const row = byGradeLot.get(key) ?? { grade: bag.grade || '', lot: bag.lot || '', qty: 0, bag: 0 };
      row.qty += bag.qty ?? 0;
      row.bag += bag.bag ?? 0;
      byGradeLot.set(key, row);
    }
    return Array.from(byGradeLot.values()).sort(
      (a, b) => a.grade.localeCompare(b.grade) || a.lot.localeCompare(b.lot),
    );
  }

  //  Matches job-special-list.ts's replaceWhiteSpaceWithDash(), so the same
  //  status_name maps to the same modifier class here too (e.g. "SPC
  //  Approve" -> "spc-approve") and both pages colour the badge the same way.
  replaceWhiteSpaceWithDash(input: string): string {
    return (input || '').replace(/\s+/g, '-').toLowerCase();
  }

  // ── Validation ─────────────────────────────────────────────────────
  isBlank(v: any): boolean {
    return v === null || v === undefined || v.toString().trim() === '';
  }

  isBagGradeMissing(bag: BagItemVM): boolean {
    return this.isBlank(bag.grade);
  }

  isBagQtyMissing(bag: BagItemVM): boolean {
    return bag.qty === null || bag.qty === undefined || bag.qty <= 0;
  }

  isBagBagMissing(bag: BagItemVM): boolean {
    return bag.bag === null || bag.bag === undefined || bag.bag <= 0;
  }

  //  Every field checked here is already marked required in the template
  //  (red *, red border via [class.field-invalid] - see job-special-detail.html)
  //  but several used to only be decorative: Save stayed enabled and silently
  //  saved them blank/zero. Keep this list in sync with the template's
  //  required-mark spans.
  canSave(): boolean {
    const job = this._job;
    if (!job) return false;
    if (job.isArriving) return false;
    if (this.isBlank(job.docNo)) return false;
    if (this.isBlank(job.date)) return false;
    if (this.isBlank(job.customer)) return false;
    if (this.isBlank(job.seq)) return false;
    if (this.isBlank(job.palletSize)) return false;
    const allBags = job.pallets.flatMap((p) => p.bags);
    return (
      allBags.length > 0 &&
      allBags.every(
        (b) => !this.isBagGradeMissing(b) && !this.isBagQtyMissing(b) && !this.isBagBagMissing(b),
      )
    );
  }

  // ── Save ──────────────────────────────────────────────────────────
  onSave() {
    const job = this._job;
    if (!job?.id || !this.canSave() || this._isSaving) return;

    const payload: Type.RequestUpdateSpecialJobItem = {
      id: job.id,
      jobNo: job.jobNo || undefined,
      title: job.docNo || undefined,
      no: job.no || undefined,
      date: this.toApiDate(job.dateObj) || undefined,
      customer: job.customer || undefined,
      seq: job.seq || undefined,
      palletSize: job.palletSize || undefined,
      arranged: job.arranged || undefined,
      wrapFilm: job.wrapFilm || undefined,
      taped: job.taped || undefined,
      saleDate: this.toApiDate(job.saleDateObj) || undefined,
      remark: job.remark || undefined,
      invoice: job.invoice || undefined,
      orderedBy: job.orderedBy || undefined,
      prepStatus: job.prepStatus || undefined,
      incompleteDetail: job.incompleteDetail || undefined,
      tonPerCart: job.tonPerCart ?? undefined,
      cartQty: job.cartQty ?? undefined,
      pallets: job.pallets.map((p) => ({
        bags: p.bags.map((b) => ({ grade: b.grade, lot: b.lot, qty: b.qty ?? 0, bag: b.bag ?? 0 })),
      })),
    };

    this._isSaving = true;
    this.restService.processUpdateSpecialJob(job.id, payload).subscribe(
      (data: Type.ResponseStandard) => {
        this._isSaving = false;
        if (data?.status === 'success') {
          this.goBack();
        } else {
          Swal.fire({
            position: 'center',
            icon: 'error',
            title: 'ข้อความจากระบบ',
            text: 'Message : ' + (data?.message ?? ''),
            showConfirmButton: true,
          });
        }
      },
      (error) => {
        this._isSaving = false;
        Swal.fire({
          position: 'center',
          icon: 'error',
          title: 'ข้อความจากระบบ',
          text: 'ไม่สามารถบันทึกข้อมูลได้',
          showConfirmButton: true,
        });
        console.error(error);
      },
    );
  }

  goBack() {
    this.router.navigate(['/job-special-list']);
  }
}
