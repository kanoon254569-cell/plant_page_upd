import { Component } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { Router } from '@angular/router';
import { PageEvent } from '@angular/material/paginator';
import Swal from 'sweetalert2';
import * as XLSX from 'xlsx';

//  One PALLET == one ตัน (ton). ตัน/คัน/Qty(kg) รวม live on JobBlockVM (the
//  job "header"); the header's ตัน (read from the "รวม" column) is what
//  decides how many pallets get generated -- see syncUploadItemsFromHeader /
//  onSpecialFileSelected below. Each generated pallet carries exactly one
//  bag item weighing that pallet's share of the total (<=1 ตัน, in kg).
//  คัน is still captured (from the "คัน" column) and sent to the backend as
//  metadata, but no longer drives how many pallets/items get created.
interface BagItemVM {
  grade: string;
  lot: string;
  qty: number | null;
  bag: number | null;
}

interface PalletVM {
  bags: BagItemVM[];
}

//  Everything but docNo/pallets mirrors a column of the "Special Package"
//  prep sheet (see onSpecialFileSelected below) -- auto-filled when a job
//  is parsed from an uploaded Excel file, or left at defaults for the user
//  to fill in by hand when a job is added via "+ Add Pallet" (addUploadJob).
//  Both paths share the exact same job-meta-grid/bag-table fields in the
//  template, so the two ways of creating a job stay in sync automatically.
interface JobBlockVM {
  //  Only set when this VM was built FROM an existing tr_special_header row
  //  for editing (see listJobToVM/openInspectJob) -- undefined for brand-new
  //  jobs being created, since they don't have a database id yet.
  id?: number;
  //  JOB No -- a running sequence number FROM THE SYSTEM, starting at 1
  //  (see nextJobNo on the component). Read-only in the UI: assigned right
  //  before the create payload is built, never typed in by hand.
  jobNo: string;
  docNo: string; // เลขที่เอกสาร
  no: string; // NO.
  date: string; // วันที่
  customer: string; // ลูกค้า
  seq: string; // ลำดับ
  palletSize: string; // ขนาดพาเลท
  arranged: boolean; // จัดเรียง
  wrapFilm: boolean; // พันฟิล์ม
  taped: boolean; // รัดเทป
  saleDate: string; // ขายวันที่
  remark: string; // หมายเหตุ
  invoice: string; // INVOICE
  orderedBy: string; // ผู้สั่งงาน
  prepStatus: string; // สถานะการจัดทำสินค้า
  incompleteDetail: string; // รายละเอียดของแต่ละรายการที่ยังทำไม่เสร็จ
  //  จำนวน(ตัน) / จำนวน(คัน) -- header-level totals for this job/document.
  //  ตัน = this job's TOTAL tonnage (sourced from the "รวม" column, not the
  //  "ตัน" sub-column); คัน = how many carts/items to split that total
  //  across. Qty (kg) รวม (= tonPerCart x 1000) is derived for display, not
  //  stored. Changing either regenerates `pallets[0].bags` to have exactly
  //  `cartQty` items, each item's qty = (tonPerCart / cartQty) x 1000 (see
  //  syncUploadItemsFromHeader below).
  tonPerCart: number | null; // ตัน (= รวม, total for this row)
  cartQty: number | null; // คัน
  pallets: PalletVM[];
  //  Cached Date objects mirroring date/saleDate, for MatDatepicker's
  //  [ngModel] binding. IMPORTANT: these must be computed ONCE (on job
  //  creation / on user selection) and read as a plain property in the
  //  template -- NOT recomputed by calling a parse function directly inside
  //  [ngModel]="..."), since that hands the datepicker a brand-new Date
  //  instance on every single change-detection run. MatDatepickerInput
  //  treats each new reference as a real value change, which retriggers CD,
  //  which calls the function again, ... an unbounded synchronous loop that
  //  freezes the tab. (This is what caused job-special-list to hang after
  //  attaching an Excel file with the Upload modal open -- every row's
  //  วันที่/ขายวันที่ picker was doing this on every job row at once.)
  dateObj: Date | null;
  saleDateObj: Date | null;
  //  UI-only: whether this job's card is collapsed (header row visible,
  //  meta-grid/pallets hidden) in the Upload modal's job list. Purely a
  //  view concern -- never read by toPayloadJob(), so it never reaches the
  //  create payload.
  collapsed: boolean;
}

function emptyJobBlock(): JobBlockVM {
  return {
    jobNo: '',
    docNo: '',
    no: '',
    date: '',
    customer: '',
    seq: '',
    palletSize: '',
    arranged: false,
    wrapFilm: false,
    taped: false,
    saleDate: '',
    remark: '',
    invoice: '',
    orderedBy: '',
    prepStatus: '',
    incompleteDetail: '',
    tonPerCart: null,
    cartQty: null,
    pallets: [],
    dateObj: null,
    saleDateObj: null,
    collapsed: false,
  };
}

@Component({
  selector: 'app-job-special-list',
  standalone: false,
  templateUrl: './job-special-list.html',
  styleUrl: './job-special-list.css',
})
export class JobSpecialList {
  skeletonRows = Array.from({ length: 5 }, (_, index) => index);

  filter: Type.SpecialJobFilter = {
    docNo: '',
    dateFrom: '',
    dateTo: '',
    jobStatus: 0,
    jobType: 0,
    customer: '',
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  //  Backing Date objects for the search filter's วันที่ range datepicker --
  //  bound to filter.dateFrom/dateTo via onFilterDateChange (below) instead
  //  of ngModel'ing those strings directly, because MatDatepicker writes
  //  back Date objects, not the dd/mm/yyyy strings filter.dateFrom/dateTo
  //  need to carry so the API/SQL (@date_from/@date_to -> TRY_CONVERT(...,
  //  103)) can parse them -- same reasoning as onJobDateChange/dateObj for
  //  the create/inspect modals.
  _filterDateFromObj: Date | null = null;
  _filterDateToObj: Date | null = null;

  _jobData: Type.ResultProcessSpecialJobListData[] | null = null;
  //  The job whose items are shown in the "Job Items Information" modal --
  //  see jobItem/selectJobItems and #specialJobItemsModal in the template.
  selectedJob: Type.ResultProcessSpecialJobListData | null = null;
  //  The job currently shown in the "Inspect" modal (see openInspectJob) --
  //  converted from the row already in _jobData via listJobToVM, no extra
  //  API call needed to open it; the Inspect modal's inputs bind directly
  //  to this, same as _uploadJobs[i] does for the Create modal, so it can
  //  reuse the exact same markup/methods. Only Save (see
  //  onSaveInspectJob) hits the network.
  _inspectJobVM: JobBlockVM | null = null;
  _isSavingInspect: boolean = false;
  //  Backing count for JOB No (see nextJobNo below) -- taken from the list
  //  endpoint's total_count on each load/reload.
  _specialJobTotalCount: number = 0;
  _isLoading: boolean = false;
  _isCreating: boolean = false;
  _optionJobStatus: Type.ResultProcessGetOptionsJobStatus[] | null = null;
  //  NOTE: mirrors job-list.ts's own _optionJobType, which is likewise never
  //  populated from an API today -- there's no "job type" options endpoint
  //  yet, so this dropdown only ever shows "All" until one exists.
  _optionJobType: any = [];

  //  Create Special Job -- N jobs, either parsed from the uploaded Excel
  //  file (one job per qualifying row) or appended by hand via "+ Add
  //  Pallet" (addUploadJob). Both paths push into the same _uploadJobs
  //  array and render through the same job-meta-grid/bag-table markup, so
  //  a manually-added job exposes exactly the same fields as one parsed
  //  from Excel -- the only difference is who fills them in. Each job here
  //  carries exactly one implicit pallet.
  _uploadFileName: string = '';
  _uploadJobs: JobBlockVM[] = [];

  //  Newer workbooks (Aug 69+) are one sheet per day -- kept around after
  //  file selection so the sheet picker (see onUploadSheetChange) can
  //  re-parse a single sheet without re-reading the file. '' is the "every
  //  sheet" sentinel value, matched by ALL_SHEETS_OPTION in the template.
  readonly ALL_SHEETS_OPTION = '';
  _uploadWorkbook: XLSX.WorkBook | null = null;
  _uploadSheetNames: string[] = [];
  _uploadSelectedSheet: string = '';

  //  True while applyUploadSheetSelection() is awaiting the master-grade
  //  lookups (see applyMasterGradeBagCounts) that fill in ถุง after a sheet
  //  is parsed -- blocks Create so a job can't be submitted with bag counts
  //  still mid-calculation.
  _isCalculatingBags: boolean = false;

  constructor(
    private restService: CrudService,
    private router: Router,
  ) {}

  async ngOnInit() {
    this.resetFilter();
    await this.loadJobData();

    try {
      this._optionJobStatus = (await this.fetchOptionJobStatus(3)).data;
    } catch (error) {
      console.error('Error fetching job status options:', error);
      this._optionJobStatus = [];
    }
  }

  async loadJobData() {
    this._isLoading = true;

    try {
      const response = await this.fetchSpecialJobData();
      this._jobData = response.data;
      this._specialJobTotalCount = response.total_count || 0;
    } catch (error) {
      //  job/special is still a backend stub today (no stored procedure
      //  wired up yet), so failures here are expected until that's built.
      console.error('Error fetching special job data:', error);
      this._jobData = [];
    } finally {
      this._isLoading = false;
    }
  }

  //  JOB No is a running sequence number "from the system" starting at 1 --
  //  there's no real backend counter endpoint yet (job/special is a stub),
  //  so this is a best-effort client-side stand-in: total_count (the total
  //  special-job row count from the last list load) + this job's position
  //  in the current create batch. CAVEAT: total_count reflects whatever
  //  search filter was active on that last load -- if a filter narrowed the
  //  list before a Create modal was opened, this can under-count. Swap this
  //  for a real backend-issued sequence once job/special is fully wired up.
  nextJobNo(offsetIndex: number): string {
    return (this._specialJobTotalCount + offsetIndex + 1).toString();
  }

  onClickSearch() {
    this.filter.page = 1;
    this.loadJobData();
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadJobData();
  }

  //  The วันที่ range defaults to today (both ends) -- on first load and on
  //  every Reset -- so the list opens on today's jobs instead of everything.
  resetFilter() {
    this.filter = {
      docNo: '',
      dateFrom: '',
      dateTo: '',
      jobStatus: 0,
      jobType: 0,
      customer: '',
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    this.onFilterDateChange('from', today);
    this.onFilterDateChange('to', new Date(today));
  }

  //  Keeps filter.dateFrom/dateTo (the dd/mm/yyyy strings sent to the API)
  //  in sync with the range datepicker's Date objects -- see
  //  _filterDateFromObj/_filterDateToObj above.
  onFilterDateChange(field: 'from' | 'to', value: Date | null) {
    if (field === 'from') {
      this._filterDateFromObj = value;
      this.filter.dateFrom = this.formatDateValue(value);
    } else {
      this._filterDateToObj = value;
      this.filter.dateTo = this.formatDateValue(value);
    }
  }

  fetchSpecialJobData(): Promise<Type.ResponseProcessSpecialJobListData> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetSpecialJobList(
          0,
          this.filter.docNo || '',
          this.filter.dateFrom || '',
          this.filter.dateTo || '',
          this.filter.jobStatus || 0,
          this.filter.jobType || 0,
          this.filter.page || 1,
          this.filter.pageSize || 25,
          this.filter.sortBy || '',
          this.filter.sortOrder || '',
        )
        .subscribe(
          (response: Type.ResponseProcessSpecialJobListData) => resolve(response),
          (error) => reject(error),
        );
    });
  }

  //  boardManType=3 is a guess (1=Warehouse / 2=Shipping in job-list.ts, so
  //  3=Special follows that pattern) -- there's no documented mapping, so
  //  this may need correcting once the real status set for Special jobs is
  //  known. Failures are swallowed in ngOnInit so this never blocks the page.
  fetchOptionJobStatus(boardManType: number): Promise<Type.ResponseProcessGetOptionsJobStatus> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsJobStatus(boardManType).subscribe(
        (response: Type.ResponseProcessGetOptionsJobStatus) => resolve(response),
        (error) => reject(error),
      );
    });
  }

  //  Inspect opens an EDITABLE modal built from the exact same job-meta-grid
  //  / bag-table markup the Upload create modal uses (see _inspectJobVM
  //  below), instead of navigating to a job-special-detail page/route
  //  (which doesn't exist yet). The job is already sitting in _jobData from
  //  the list load, so opening it is just a local conversion -- no extra
  //  API call; only Save hits the network.
  openInspectJob(job: Type.ResultProcessSpecialJobListData) {
    this._inspectJobVM = this.listJobToVM(job);
  }

  //  Converts one list row (flat items[] with pallet_no) into the same
  //  JobBlockVM shape the create modals edit, grouping items back into
  //  pallets by pallet_no. job.job_date/sale_date come back as ISO strings
  //  from the API (System.Text.Json's default DateTime serialization), so
  //  `new Date(...)` parses them directly -- unlike parseDateValue, which is
  //  for the dd/mm/yyyy strings the create flows use.
  private listJobToVM(job: Type.ResultProcessSpecialJobListData): JobBlockVM {
    const byPallet = new Map<number, BagItemVM[]>();
    for (const item of job.details ?? []) {
      const palletNo = item.pallet_no || 1;
      if (!byPallet.has(palletNo)) byPallet.set(palletNo, []);
      //  item.lot no longer exists on the API's flat item row - each detail
      //  now carries its lot breakdown under lots[] instead, so take the
      //  first (this UI's bag table only has room for one lot per row).
      byPallet.get(palletNo)!.push({
        grade: item.grade,
        lot: item.lots?.[0]?.lot ?? '',
        qty: item.qty,
        bag: item.bag,
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
      date: dateObj ? this.formatDateValue(dateObj) : '',
      customer: job.customer || '',
      seq: job.seq || '',
      palletSize: job.pallet_size || '',
      arranged: !!job.is_arranged,
      wrapFilm: !!job.is_wrap_film,
      taped: !!job.is_taped,
      saleDate: saleDateObj ? this.formatDateValue(saleDateObj) : '',
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
      collapsed: false,
    };
  }

  addInspectPallet() {
    this._inspectJobVM?.pallets.push({ bags: [] });
  }

  removeInspectPallet(palletIndex: number) {
    this._inspectJobVM?.pallets.splice(palletIndex, 1);
  }

  duplicateInspectPallet(palletIndex: number) {
    if (!this._inspectJobVM) return;
    const source = this._inspectJobVM.pallets[palletIndex];
    this._inspectJobVM.pallets.push({ bags: source.bags.map((bag) => ({ ...bag })) });
  }

  canSaveInspect(): boolean {
    if (!this._inspectJobVM) return false;
    if (this.isBlank(this._inspectJobVM.docNo)) return false;

    const allBags = this._inspectJobVM.pallets.flatMap((pallet) => pallet.bags);
    if (allBags.length === 0) return false;

    return allBags.every((bag) => !this.isBagGradeMissing(bag));
  }

  onSaveInspectJob() {
    const job = this._inspectJobVM;
    if (!job || !job.id || !this.canSaveInspect() || this._isSavingInspect) return;

    const pallets: Type.RequestSpecialJobPallet[] = job.pallets.map((pallet) => ({
      bags: pallet.bags.map((bag) => this.toPayloadBag(bag)),
    }));
    const payload: Type.RequestUpdateSpecialJobItem = {
      id: job.id,
      ...this.toPayloadJob(job, pallets),
    };

    this._isSavingInspect = true;

    this.restService.processUpdateSpecialJob(job.id, payload).subscribe(
      (data: Type.ResponseStandard) => {
        this._isSavingInspect = false;

        if (data && data.status === 'success') {
          this.SweetAlert('success', 'บันทึกข้อมูลสำเร็จ');
          this.closeModal('inspectSpecialJobModal');
          this._inspectJobVM = null;
          this.loadJobData();
        } else {
          this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
        }
      },
      (error) => {
        this._isSavingInspect = false;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.error(error);
      },
    );
  }

  //  Deletes a job straight from the list card's kebab menu (see
  //  job-special-list.html) -- no confirmation needed beyond the SweetAlert2
  //  prompt below, since this only removes the header/detail rows for this
  //  one job, not anything shared with other jobs.
  deleteJob(job: Type.ResultProcessSpecialJobListData) {
    if (!job?.id) return;

    Swal.fire({
      title: 'ยืนยันการลบ?',
      text: `ต้องการลบงาน "${job.doc_no || job.system_no}" ใช่หรือไม่`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonColor: '#d33',
      cancelButtonColor: '#6c757d',
      confirmButtonText: 'ลบ',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (!result.isConfirmed) return;

      this.restService.processDeleteSpecialJob(job.id, 0).subscribe(
        (data: Type.ResponseStandard) => {
          if (data && data.status === 'success') {
            this.SweetAlert('success', 'ลบข้อมูลสำเร็จ');
            this.loadJobData();
          } else {
            this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
          }
        },
        (error) => {
          this.SweetAlert('error', 'Message : Error see in log.');
          console.error(error);
        },
      );
    });
  }

  replaceWhiteSpaceWithDash(input: string): string {
    return (input || '').replace(/\s+/g, '-').toLowerCase();
  }

  //  The job's first item, shown inline in the list card's document-job row
  //  (grade + lot + qty) -- same "just show the first row, +N more opens a
  //  modal" pattern job-list.ts's jobItem()/selectJobItems() use.
  jobItem(job: Type.ResultProcessSpecialJobListData): Type.SpecialJobItem | undefined {
    return job?.details?.[0];
  }

  //  Mirrors job-list.ts's lotLocations(): shows the item's `lots` breakdown
  //  (multiple lot numbers can split across the same item) as chips -- see
  //  the document-job template's #itemLotList.
  itemLots(job: Type.ResultProcessSpecialJobListData): Type.SpecialJobItemLot[] {
    return this.jobItem(job)?.lots ?? [];
  }

  selectJobItems(job: Type.ResultProcessSpecialJobListData) {
    this.selectedJob = job;
  }

  //  "Job Pallets Information" modal: details[] is one row per (pallet_no,
  //  เกรด) -- a pallet built from more than one grade (see
  //  buildPalletsForGroup's leftover-mixing) has several detail rows
  //  sharing the same pallet_no, so this actually groups them by pallet_no
  //  (sorted, in the order each pallet was packed) instead of listing every
  //  detail as its own flat, unrelated row.
  groupedSelectedJobPallets(): { palletNo: number; items: Type.SpecialJobItem[] }[] {
    const byPallet = new Map<number, Type.SpecialJobItem[]>();
    for (const item of this.selectedJob?.details ?? []) {
      if (!byPallet.has(item.pallet_no)) byPallet.set(item.pallet_no, []);
      byPallet.get(item.pallet_no)!.push(item);
    }
    return Array.from(byPallet.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([palletNo, items]) => ({ palletNo, items }));
  }

  //  details.length counts (pallet_no, เกรด) rows, not physical pallets --
  //  a mixed pallet inflates that count. This is the real, distinct pallet
  //  total, matching Output Pallet for a job created via the Excel upload.
  selectedJobPalletCount(): number {
    return new Set((this.selectedJob?.details ?? []).map((item) => item.pallet_no)).size;
  }

  //  =====================================================================
  //  Shared pallet / bag-item helpers (Upload modal: Excel-parsed + hand-
  //  added jobs; Inspect modal)
  //  =====================================================================

  //  'inspect' reuses this for the Inspect modal's single editable job
  //  (_inspectJobVM) -- jobIndex is ignored for that mode.
  private jobFor(mode: 'upload' | 'inspect', jobIndex: number): JobBlockVM {
    if (mode === 'inspect') return this._inspectJobVM!;
    return this._uploadJobs[jobIndex];
  }

  //  Items are edited directly in the bag-item table (each cell is its own
  //  input bound straight to the item) -- there's no more side panel, so
  //  "add" just appends a blank row for the user to fill in in place.
  addBagItem(mode: 'upload' | 'inspect', jobIndex: number, palletIndex: number) {
    const pallet = this.jobFor(mode, jobIndex).pallets[palletIndex];
    pallet.bags.push({ grade: '', lot: '', qty: null, bag: null });
  }

  removeItem(mode: 'upload' | 'inspect', jobIndex: number, palletIndex: number, itemIndex: number) {
    const pallet = this.jobFor(mode, jobIndex).pallets[palletIndex];
    pallet.bags.splice(itemIndex, 1);
  }

  //  Comma-joined list of this job's distinct, non-blank เกรด values across
  //  every pallet/bag -- shown in the collapsed card's summary chips (see
  //  job-summary-chips in the template) since เกรด normally only appears
  //  inside the bag-table, which is hidden while collapsed.
  jobGradesSummary(job: JobBlockVM): string {
    const grades = job.pallets
      .flatMap((pallet) => pallet.bags)
      .map((bag) => (bag.grade || '').trim())
      .filter((grade) => grade !== '');
    return Array.from(new Set(grades)).join(', ');
  }

  //  =====================================================================
  //  Required-field validation (Create Special Job)
  //  =====================================================================
  //  Per the "Special Package" prep sheet (special_upload1.PNG), the column
  //  headers with a GREEN background are: วันที่ / เลขที่เอกสาร / ลูกค้า /
  //  ลำดับ / เกรด / ตัน (จำนวน) / ขนาดพาเลท. Those become required fields --
  //  Create is blocked while any is null/blank. (คัน, รวม, NO., ขายวันที่,
  //  หมายเหตุ, INVOICE, ผู้สั่งงาน, สถานะการจัดทำสินค้า, and the checkboxes
  //  are NOT green, so they stay optional. "รายละเอียดของแต่ละรายการที่ยัง
  //  ทำไม่เสร็จ" is also a green header, but a visually distinct/brighter
  //  shade than the rest -- treated here as NOT part of this rule since it
  //  reads more like a status-tracking note than a data-entry field; flag
  //  if that reading is wrong and it should be required too.)

  isBlank(value: string | number | null | undefined): boolean {
    return value === null || value === undefined || value.toString().trim() === '';
  }

  isJobMetaMissing(job: JobBlockVM, field: 'date' | 'docNo' | 'customer' | 'seq' | 'palletSize'): boolean {
    return this.isBlank(job[field]);
  }

  isBagGradeMissing(bag: BagItemVM): boolean {
    return this.isBlank(bag.grade);
  }

  //  ตัน is now a job-header field (see JobBlockVM.tonPerCart), not a
  //  per-item one -- every item generated from it shares the same weight.
  isJobTonMissing(job: JobBlockVM): boolean {
    return job.tonPerCart === null || job.tonPerCart === undefined;
  }

  private jobHasAllRequiredFields(job: JobBlockVM): boolean {
    if (
      this.isBlank(job.date) ||
      this.isBlank(job.docNo) ||
      this.isBlank(job.customer) ||
      this.isBlank(job.seq) ||
      this.isBlank(job.palletSize) ||
      this.isJobTonMissing(job)
    ) {
      return false;
    }

    const allBags = job.pallets.flatMap((pallet) => pallet.bags);
    if (allBags.length === 0) return false;

    return allBags.every((bag) => !this.isBagGradeMissing(bag));
  }

  canCreateUpload(): boolean {
    if (this._uploadJobs.length === 0 || this._isCalculatingBags) return false;
    return this._uploadJobs.every((job) => this.jobHasAllRequiredFields(job));
  }

  //  Drives a red outline on the COLLAPSED job header (see
  //  .upload-job-header.job-header-invalid) so an incomplete job stands out
  //  without expanding every card to find which one is blocking Create --
  //  the per-field red outlines inside the form only ever mattered while a
  //  card was already expanded.
  isJobIncomplete(job: JobBlockVM): boolean {
    return !this.jobHasAllRequiredFields(job);
  }

  //  API dates come back either as ISO (local/mock backend) or as
  //  d/m/yyyy HH:mm:ss with a Buddhist-Era year (real qas-qtrack backend,
  //  e.g. "28/8/2569 7:52:16" for 2026-08-28) -- Angular's `date` pipe
  //  can't parse the latter and throws NG02100, which is why job.create_datetime
  //  renders as '-'/crashes only once deployed against the real API.
  parseJobDate(value?: string | Date | null): Date | null {
    if (!value) return null;
    if (value instanceof Date) return isNaN(value.getTime()) ? null : value;

    const trimmed = value.trim();
    const m = trimmed.match(
      /^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/,
    );
    if (m) {
      const day = parseInt(m[1], 10);
      const month = parseInt(m[2], 10) - 1;
      let year = parseInt(m[3], 10);
      if (year < 100) year += 2000;
      if (year > 2400) year -= 543;
      const hours = m[4] ? parseInt(m[4], 10) : 0;
      const minutes = m[5] ? parseInt(m[5], 10) : 0;
      const seconds = m[6] ? parseInt(m[6], 10) : 0;
      const d = new Date(year, month, day, hours, minutes, seconds);
      return isNaN(d.getTime()) ? null : d;
    }

    const iso = new Date(trimmed);
    return isNaN(iso.getTime()) ? null : iso;
  }

  //  =====================================================================
  //  วันที่ / ขายวันที่ <-> MatDatepicker bridge
  //  =====================================================================
  //  JobBlockVM keeps date/saleDate as plain strings (that's what the Excel
  //  parser fills them with, and what the create payload sends), but
  //  MatDatepicker (with the app's NativeDateAdapter) works in terms of
  //  Date objects. These helpers convert both ways so the picker can be
  //  bound with [ngModel]/(dateChange) instead of a plain two-way [(ngModel)].

  private parseDateValue(value: string | null | undefined): Date | null {
    const trimmed = (value ?? '').toString().trim();
    if (!trimmed) return null;

    //  dd/mm/yyyy (or dd-mm-yyyy) -- the format both the Excel sheet and
    //  this picker use. A year > 2400 is assumed to be พ.ศ. (Buddhist Era,
    //  common on Thai prep sheets) and converted to ค.ศ. by subtracting 543.
    const m = trimmed.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})$/);
    if (m) {
      const day = parseInt(m[1], 10);
      const month = parseInt(m[2], 10) - 1;
      let year = parseInt(m[3], 10);
      if (year < 100) year += 2000;
      if (year > 2400) year -= 543;
      const d = new Date(year, month, day);
      return isNaN(d.getTime()) ? null : d;
    }

    //  Fall back to native parsing for anything else (e.g. ISO yyyy-mm-dd).
    const iso = new Date(trimmed);
    return isNaN(iso.getTime()) ? null : iso;
  }

  private formatDateValue(value: Date | null): string {
    if (!value) return '';
    const dd = String(value.getDate()).padStart(2, '0');
    const mm = String(value.getMonth() + 1).padStart(2, '0');
    const yyyy = value.getFullYear();
    return `${dd}/${mm}/${yyyy}`;
  }

  //  Fired by the picker's (dateChange) when the user actually selects a
  //  date -- keeps both the string field and the cached Date twin in sync
  //  without ever recomputing dateObj/saleDateObj on every CD cycle.
  onJobDateChange(job: JobBlockVM, field: 'date' | 'saleDate', value: Date | null) {
    job[field] = this.formatDateValue(value);
    job[field === 'date' ? 'dateObj' : 'saleDateObj'] = value;
  }

  //  =====================================================================
  //  Create Special Job (Upload modal: Excel-parsed + hand-added jobs)
  //  =====================================================================

  resetUploadForm() {
    this._uploadFileName = '';
    this._uploadJobs = [];
    this._uploadWorkbook = null;
    this._uploadSheetNames = [];
    this._uploadSelectedSheet = this.ALL_SHEETS_OPTION;
    this._isCalculatingBags = false;
  }

  addUploadJob() {
    this._uploadJobs.push({ ...emptyJobBlock(), pallets: [{ bags: [] }] });
  }

  removeUploadJob(jobIndex: number) {
    this._uploadJobs.splice(jobIndex, 1);
  }

  //  Totals across every job currently staged in _uploadJobs -- shown in
  //  the upload-summary-row next to the "N Job" count.
  totalUploadPallets(): number {
    return this._uploadJobs.reduce((sum, job) => sum + job.pallets.length, 0);
  }

  totalUploadBags(): number {
    return this._uploadJobs.reduce(
      (sum, job) =>
        sum +
        job.pallets.reduce(
          (palletSum, pallet) => palletSum + pallet.bags.reduce((bagSum, bag) => bagSum + (bag.bag || 0), 0),
          0,
        ),
      0,
    );
  }

  totalUploadTon(): number {
    return this._uploadJobs.reduce((sum, job) => sum + (job.tonPerCart || 0), 0);
  }

  //  Collapse/expand a single job card -- header row (JOB No/Delete) stays
  //  visible either way; the form-sections and pallet/item tables underneath
  //  are hidden while collapsed, purely so long job lists are easier to scan.
  toggleJobCollapsed(jobIndex: number) {
    const job = this._uploadJobs[jobIndex];
    job.collapsed = !job.collapsed;
  }

  //  Bulk expand/collapse every staged job at once -- see upload-toolbar-row
  //  in the template, next to the Job/Pallet/Bag/ตัน totals.
  expandAllUploadJobs() {
    this._uploadJobs.forEach((job) => (job.collapsed = false));
  }

  collapseAllUploadJobs() {
    this._uploadJobs.forEach((job) => (job.collapsed = true));
  }

  //  Per-job pallet management -- mirrors addInspectPallet/removeInspectPallet/
  //  duplicateInspectPallet above, just scoped to one job within _uploadJobs
  //  instead of the single _inspectJobVM. A job normally carries exactly one
  //  implicit pallet (see JobBlockVM comment), but both Excel-parsed and
  //  hand-added jobs can grow extra pallets here, same as Inspect allows.
  addUploadPallet(jobIndex: number) {
    this._uploadJobs[jobIndex].pallets.push({ bags: [] });
  }

  removeUploadPallet(jobIndex: number, palletIndex: number) {
    this._uploadJobs[jobIndex].pallets.splice(palletIndex, 1);
  }

  duplicateUploadPallet(jobIndex: number, palletIndex: number) {
    const job = this._uploadJobs[jobIndex];
    const source = job.pallets[palletIndex];
    job.pallets.push({ bags: source.bags.map((bag) => ({ ...bag })) });
  }

  //  =====================================================================
  //  ตัน (job header) -> Pallet List sync
  //  =====================================================================
  //  ตัน (tonPerCart) is the job's TOTAL tonnage for this row (read straight
  //  from the "รวม" column -- see onSpecialFileSelected), NOT a per-pallet
  //  weight. Per spec, 1 pallet = 1 ตัน, so the number of pallets generated
  //  is ceil(ตัน) -- a partial ton (e.g. 3.5 ตัน) still needs its own pallet,
  //  so it rounds UP to 4 pallets, with the last pallet carrying only the
  //  leftover 0.5 ตัน (500 kg). The header's "Qty (kg) รวม" display is
  //  simply ตัน x 1000. คัน is no longer used to decide pallet/item count --
  //  it's still captured from the sheet and sent to the backend as metadata
  //  (see toPayloadJob), but purely informational now.
  //  Whenever ตัน changes, regenerate the Pallet List to match -- growing/
  //  shrinking it to ceil(ตัน) pallets (each with exactly one bag item) and
  //  re-stamping every pallet's weight. Grade/Lot/Bag are carried over from
  //  the previous pallet at the same position (falling back to the last
  //  existing bag) so re-typing ตัน doesn't wipe out values already filled in.

  jobTotalQty(job: JobBlockVM): number | null {
    if (job.tonPerCart === null || job.tonPerCart === undefined) return null;
    return Math.round(job.tonPerCart * 1000 * 100) / 100;
  }

  //  Read-only display string for the header's "Qty (kg) รวม" box.
  jobTotalQtyDisplay(job: JobBlockVM): string {
    const total = this.jobTotalQty(job);
    return total === null ? '-' : total.toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  //  Builds a Pallet List of ceil(totalTon) pallets from a total tonnage,
  //  one bag per pallet, each weighing min(1, remaining ตัน) x 1000 kg.
  //  existingPallets (if provided) supplies Grade/Lot/Bag to carry over at
  //  each position, so regenerating on a ตัน edit doesn't lose hand-entered
  //  values. Returns at least one (possibly empty-bag) pallet.
  private buildPalletsFromTon(totalTon: number | null | undefined, existingPallets?: PalletVM[]): PalletVM[] {
    const desiredPalletCount = totalTon !== null && totalTon !== undefined && totalTon > 0 ? Math.ceil(totalTon) : 0;

    if (desiredPalletCount === 0) return [{ bags: [] }];

    const previousBags = (existingPallets ?? []).flatMap((pallet) => pallet.bags);
    const lastBag = previousBags[previousBags.length - 1];

    const pallets: PalletVM[] = [];
    let remainingTon = totalTon as number;

    for (let p = 0; p < desiredPalletCount; p++) {
      const palletTon = Math.min(1, remainingTon);
      remainingTon -= palletTon;
      const qtyKg = Math.round(palletTon * 1000 * 100) / 100;

      const existing = existingPallets?.[p]?.bags[0];
      const carryOver = existing ?? lastBag;

      pallets.push({
        bags: [
          {
            grade: carryOver ? carryOver.grade : '',
            lot: carryOver ? carryOver.lot : '',
            qty: qtyKg,
            bag: carryOver ? carryOver.bag : 0,
          },
        ],
      });
    }

    return pallets;
  }

  //  Builds the pallet list for a multi-grade upload job. When the sheet's
  //  "Output Pallet" column gave an authoritative count for this NO.+ลำดับ
  //  group, qty-per-pallet = total qty / Output Pallet. Each grade is cut
  //  into as many WHOLE single-grade pallets of that size as it has qty
  //  for, in order; whatever's left over (less than one full pallet) is set
  //  aside rather than mixed in immediately. Only once every grade has been
  //  cut are all the set-aside leftovers combined together, in the same
  //  order, to fill out the final pallet(s) -- so those come last in the
  //  list and are the only ones that ever mix more than one grade. Pallet
  //  COUNT always lands exactly on Output Pallet either way. Without a
  //  target count (older sheets with no Output Pallet column), falls back
  //  to the previous per-grade ceil(ตัน) behavior.
  private buildPalletsForGroup(
    grades: { grade: string; ton: number }[],
    targetPalletCount: number | null,
  ): PalletVM[] {
    if (!targetPalletCount) {
      const pallets: PalletVM[] = [];
      for (const gr of grades) {
        const gradePallets = this.buildPalletsFromTon(gr.ton).map((pallet) => ({
          bags: pallet.bags.map((bag) => ({ ...bag, grade: gr.grade })),
        }));
        pallets.push(...gradePallets);
      }
      return pallets.length > 0 ? pallets : [{ bags: [] }];
    }

    const totalTon = grades.reduce((sum, gr) => sum + gr.ton, 0);
    const qtyPerPallet = (totalTon * 1000) / targetPalletCount;
    //  Floating-point qty comparisons need slack, or a pallet can be left
    //  a fraction of a kg short/over and either spawn a stray extra pallet
    //  or fail to close the current one.
    const epsilonKg = 0.01;

    const fullPallets: PalletVM[] = [];
    const leftovers: { grade: string; qtyKg: number }[] = [];

    for (const gr of grades) {
      let remainingKg = gr.ton * 1000;
      while (remainingKg >= qtyPerPallet - epsilonKg) {
        fullPallets.push({ bags: [{ grade: gr.grade, lot: '', qty: Math.round(qtyPerPallet * 100) / 100, bag: 0 }] });
        remainingKg -= qtyPerPallet;
      }
      if (remainingKg > epsilonKg) leftovers.push({ grade: gr.grade, qtyKg: remainingKg });
    }

    //  Now combine the set-aside leftovers, in the order their grades
    //  appeared, into whichever pallet(s) it takes to use them all up.
    const mixedPallets: PalletVM[] = [];
    let currentBags: BagItemVM[] = [];
    let currentRemainingKg = qtyPerPallet;

    for (const lo of leftovers) {
      let remainingKg = lo.qtyKg;
      while (remainingKg > epsilonKg) {
        const takeKg = Math.min(remainingKg, currentRemainingKg);
        const existingBag = currentBags.find((b) => b.grade === lo.grade);
        if (existingBag) {
          existingBag.qty = Math.round(((existingBag.qty ?? 0) + takeKg) * 100) / 100;
        } else {
          currentBags.push({ grade: lo.grade, lot: '', qty: Math.round(takeKg * 100) / 100, bag: 0 });
        }

        remainingKg -= takeKg;
        currentRemainingKg -= takeKg;

        if (currentRemainingKg <= epsilonKg) {
          mixedPallets.push({ bags: currentBags });
          currentBags = [];
          currentRemainingKg = qtyPerPallet;
        }
      }
    }

    //  Only rounding slack should ever land here (the grades' ตัน are
    //  chosen so the leftovers divide evenly into whole pallets); still
    //  flushed as a final pallet rather than silently dropped.
    if (currentBags.length > 0) mixedPallets.push({ bags: currentBags });

    const pallets = [...fullPallets, ...mixedPallets];
    return pallets.length > 0 ? pallets : [{ bags: [] }];
  }

  private syncUploadItemsFromHeader(job: JobBlockVM) {
    job.pallets = this.buildPalletsFromTon(job.tonPerCart, job.pallets);
  }

  onJobTonInput(job: JobBlockVM, value: number | null) {
    job.tonPerCart = value;
    this.syncUploadItemsFromHeader(job);
  }

  onJobCartQtyInput(job: JobBlockVM, value: number | null) {
    //  คัน no longer drives pallet/item generation (1 pallet = 1 ตัน now) --
    //  just record the value; it's still sent to the backend as metadata.
    job.cartQty = value;
  }

  private normalizeCell(value: any): string {
    return (value ?? '').toString().replace(/\s+/g, '').trim();
  }

  //  Sheet names in the newer (Aug 69+) workbooks are one-sheet-per-day,
  //  named like "จ.3-8-69" (Thai weekday abbreviation . d-m-yy, yy a 2-digit
  //  Buddhist Era year) -- that sheet has no per-row วันที่ column at all,
  //  unlike the July reference file (see parseSpecialSheetRows below), so
  //  the row parser falls back to this when it can't find one. Returns ''
  //  (no usable date) if the name doesn't match the pattern.
  private extractDateFromSheetName(sheetName: string): string {
    const m = sheetName.match(/(\d{1,2})-(\d{1,2})-(\d{2,4})/);
    if (!m) return '';

    const day = parseInt(m[1], 10);
    const month = parseInt(m[2], 10);
    let beYear = parseInt(m[3], 10);
    if (beYear < 100) beYear += 2500;
    const ceYear = beYear - 543;

    return `${String(day).padStart(2, '0')}/${String(month).padStart(2, '0')}/${ceYear}`;
  }

  //  Parses one sheet of the "Special Package" preparation workbook (see
  //  special_upload1 / SPECIAL ก.ค. 69_test.pdf samples). Captures every
  //  column of that sheet:
  //    - the real header spans TWO rows -- NO./วันที่/เลขที่เอกสาร/ลูกค้า/
  //      ลำดับ/เกรด/รวม/ขนาดพาเลท/จัดเรียง/พันฟิล์ม/รัดเทป/ขายวันที่/
  //      หมายเหตุ/INVOICE/ผู้สั่งงาน/สถานะการจัดทำสินค้า/รายละเอียดของแต่ละ
  //      รายการที่ยังทำไม่เสร็จ sit on the row matched by วันที่+เกรด (or
  //      เกรด alone, see sheetDateFallback below), while "จำนวน" is a
  //      horizontally-merged super-header whose ตัน/คัน sub-labels sit one
  //      row below -- both rows are searched for every column, and data
  //      starts after whichever row is actually the header
  //    - a row becomes exactly ONE Special Job when it has its own เกรด
  //      (grade) AND a resolved date (see forward-fill note below); rows
  //      missing either (blank spacer / orange subtotal rows) are skipped
  //    - the job HEADER's ตัน (JobBlockVM.tonPerCart) is read straight from
  //      "รวม" -- NOT the "ตัน" sub-column under "จำนวน" -- and is treated
  //      as this row's TOTAL tonnage. คัน (JobBlockVM.cartQty) comes from
  //      the "คัน" sub-column (falling back to 1 if that column is
  //      missing/blank) and says how many items to split that total across;
  //      the item list is exactly คัน items, each weighing (ตัน / คัน) x
  //      1000 kg (see syncUploadItemsFromHeader)
  //    - NO. / วันที่ / เลขที่เอกสาร / ขนาดพาเลท / ขายวันที่ are visually
  //      merged across a group of rows in the sample (one value covers
  //      several grade lines) -- sheet_to_json only reports a value on the
  //      merge's first row, so a blank cell in these columns carries forward
  //      the last non-blank value seen. Other columns (ลูกค้า, ลำดับ, the
  //      checkboxes, หมายเหตุ, INVOICE, ผู้สั่งงาน, ...) are read literally
  //      per row -- verify this assumption against the real workbook if a
  //      customer's file merges differently than this sample
  //    - Lot has no source column in this sheet -> left blank
  //    - Bag has no source column in this sheet -> left 0, filled in by hand
  //
  //  sheetDateFallback: the date derived from this sheet's name/title
  //  (extractDateFromSheetName), used for every row when the sheet has no
  //  วันที่ column of its own (the Aug 69+ one-sheet-per-day layout).
  private parseSpecialSheetRows(rows: any[][], sheetDateFallback: string): JobBlockVM[] {
    let headerRowIndex = -1;
    let colDate = -1;
    let colGrade = -1;
    let useSheetDateFallback = false;

    for (let r = 0; r < Math.min(rows.length, 20); r++) {
      const row = rows[r] || [];
      const idxDate = row.findIndex((cell) => this.normalizeCell(cell) === 'วันที่');
      const idxGrade = row.findIndex((cell) => this.normalizeCell(cell) === 'เกรด');

      if (idxDate >= 0 && idxGrade >= 0) {
        headerRowIndex = r;
        colDate = idxDate;
        colGrade = idxGrade;
        break;
      }
    }

    //  No per-row วันที่ column found -- fall back to anchoring on เกรด
    //  alone and using the whole sheet's date (from its name) for every row.
    if (headerRowIndex === -1 && sheetDateFallback) {
      for (let r = 0; r < Math.min(rows.length, 20); r++) {
        const row = rows[r] || [];
        const idxGrade = row.findIndex((cell) => this.normalizeCell(cell) === 'เกรด');
        if (idxGrade >= 0) {
          headerRowIndex = r;
          colGrade = idxGrade;
          useSheetDateFallback = true;
          break;
        }
      }
    }

    if (headerRowIndex === -1) return [];

    const headerRow2 = rows[headerRowIndex + 1] || [];
    const hasSubHeaderRow = headerRow2.some((cell) =>
      ['ตัน', 'คัน'].includes(this.normalizeCell(cell)),
    );
    const headerRows = hasSubHeaderRow
      ? [rows[headerRowIndex] || [], headerRow2]
      : [rows[headerRowIndex] || []];
    const dataStartRow = hasSubHeaderRow ? headerRowIndex + 2 : headerRowIndex + 1;

    const findCol = (labels: string[]): number => {
      for (const hRow of headerRows) {
        for (const label of labels) {
          const idx = hRow.findIndex((cell) => this.normalizeCell(cell) === label);
          if (idx >= 0) return idx;
        }
      }
      return -1;
    };

    const colNo = findCol(['NO.', 'NO']);
    const colDocNo = findCol(['เลขที่เอกสาร']);
    const colCustomer = findCol(['ลูกค้า']);
    const colSeq = findCol(['ลำดับ']);
    const colCart = findCol(['คัน']);
    const colTotal = findCol(['รวม']);
    const colPalletSize = findCol(['ขนาดพาเลท']);
    const colArranged = findCol(['จัดเรียง']);
    const colWrapFilm = findCol(['ทันฟีล่ม', 'พันฟีล่ม', 'พันฟิล์ม', 'ทันฟิล์ม']);
    const colTaped = findCol(['รัดเทป']);
    const colSaleDate = findCol(['ขายวันที่']);
    const colRemark = findCol(['หมายเหตุ']);
    const colInvoice = findCol(['INVOICE']);
    const colOrderedBy = findCol(['ผู้สั่งงาน']);
    const colPrepStatus = findCol(['สถานะการจัดทำสินค้า']);
    const colIncompleteDetail = findCol(['รายละเอียดของแต่ละรายการที่ยังทำไม่เสร็จ']);

    //  "Output Pallet" (the authoritative pallet count per NO.+ลำดับ group)
    //  sits in the TITLE row (row 0, alongside "สถานะการจัดทำสินค้า"), not
    //  the NO./เลขที่เอกสาร/... header row(s) findCol searches -- scan every
    //  row up through headerRowIndex to find it.
    let colOutputPallet = -1;
    for (let r = 0; r <= headerRowIndex; r++) {
      const idx = (rows[r] || []).findIndex((cell) => this.normalizeCell(cell) === 'OutputPallet');
      if (idx >= 0) {
        colOutputPallet = idx;
        break;
      }
    }

    const cellText = (row: any[], col: number): string => (col >= 0 ? (row[col] ?? '').toString().trim() : '');
    const cellNumber = (row: any[], col: number): number => {
      if (col < 0) return 0;
      const raw = row[col];
      return typeof raw === 'number' ? raw : parseFloat(String(raw ?? '').replace(/,/g, '')) || 0;
    };
    const cellChecked = (row: any[], col: number): boolean => cellText(row, col) !== '';

    //  A row's เกรด cell sometimes holds a free-text remark instead of a
    //  real grade code (e.g. instructions to warehouse staff that happen to
    //  land in that column because of how the sheet merges rows) -- these
    //  would otherwise become bogus zero-ตัน "jobs". Real grade codes in
    //  this sheet are short alphanumeric codes; a long run of Thai words
    //  with spaces is a dead giveaway it's actually a sentence.
    const looksLikeRealGrade = (g: string): boolean => {
      if (!g) return false;
      if (g.length > 30) return false;
      if (/[ก-๙]{4,}/.test(g) && / /.test(g)) return false;
      return true;
    };

    //  NO./ลำดับ/date carry forward across the WHOLE sheet, same as before.
    //  เลขที่เอกสาร/ลูกค้า/คัน/ขนาดพาเลท/ขายวันที่/หมายเหตุ/INVOICE/ผู้สั่งงาน/
    //  สถานะการจัดทำสินค้า/รายละเอียดที่ยังไม่เสร็จ merge-carry too, but only
    //  *within* the NO.+ลำดับ group they started in -- otherwise a group
    //  with no เลขที่เอกสาร of its own (e.g. one ลำดับ genuinely has none)
    //  would wrongly inherit the previous group's document number instead
    //  of staying blank.
    let lastNo = '';
    let lastSeq = '';
    let lastDate = '';
    let lastDocNo = '';
    let lastCart = '';
    let lastOutputPallet = '';
    let lastPalletSize = '';
    let lastSaleDate = '';
    let lastRemark = '';
    let lastInvoice = '';
    let lastOrderedBy = '';
    let lastPrepStatus = '';
    let lastIncompleteDetail = '';
    let lastGroupKey = '';

    interface GroupAcc {
      no: string;
      docNo: string;
      seq: string;
      date: string;
      cart: string;
      outputPallet: string;
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
      grades: { grade: string; ton: number }[];
    }

    const groups = new Map<string, GroupAcc>();
    const groupOrder: string[] = [];
    //  ลูกค้า is sometimes wrapped across two rows in the sheet (e.g. "REDOX/"
    //  on the grade's own row, "AUSTRALIA" continuing on the very next row,
    //  which usually isn't the group's FIRST row so a plain merge-carry
    //  would only ever keep one half). Collected per group key across every
    //  row (even ones skipped for grade purposes) and joined at the end.
    const customerFragmentsByKey = new Map<string, string[]>();

    for (let r = dataStartRow; r < rows.length; r++) {
      const row = rows[r] || [];

      const noVal = cellText(row, colNo) || lastNo;
      const seqVal = cellText(row, colSeq) || lastSeq;
      const dateVal = useSheetDateFallback ? sheetDateFallback : cellText(row, colDate) || lastDate;

      //  A row becomes exactly ONE Special Job per (NO., ลำดับ, date) --
      //  every เกรด line sharing that combination is one item in that job's
      //  pallet list, not its own separate job.
      const groupKey = `${noVal}|${seqVal}|${dateVal}`;
      if (groupKey !== lastGroupKey) {
        lastDocNo = '';
        lastCart = '';
        lastOutputPallet = '';
        lastPalletSize = '';
        lastSaleDate = '';
        lastRemark = '';
        lastInvoice = '';
        lastOrderedBy = '';
        lastPrepStatus = '';
        lastIncompleteDetail = '';
        lastGroupKey = groupKey;
      }

      const docNoRaw = cellText(row, colDocNo);
      const customerRaw = cellText(row, colCustomer);
      const cartRaw = cellText(row, colCart);
      const outputPalletRaw = cellText(row, colOutputPallet);
      const palletSizeRaw = cellText(row, colPalletSize);
      const saleDateRaw = cellText(row, colSaleDate);
      const remarkRaw = cellText(row, colRemark);
      const invoiceRaw = cellText(row, colInvoice);
      const orderedByRaw = cellText(row, colOrderedBy);
      const prepStatusRaw = cellText(row, colPrepStatus);
      const incompleteDetailRaw = cellText(row, colIncompleteDetail);

      const docNoVal = docNoRaw || lastDocNo;
      const cartVal = cartRaw || lastCart;
      const outputPalletVal = outputPalletRaw || lastOutputPallet;
      const palletSizeVal = palletSizeRaw || lastPalletSize;
      const saleDateVal = saleDateRaw || lastSaleDate;
      const remarkVal = remarkRaw || lastRemark;
      const invoiceVal = invoiceRaw || lastInvoice;
      const orderedByVal = orderedByRaw || lastOrderedBy;
      const prepStatusVal = prepStatusRaw || lastPrepStatus;
      const incompleteDetailVal = incompleteDetailRaw || lastIncompleteDetail;

      lastNo = noVal;
      lastSeq = seqVal;
      lastDate = dateVal;
      if (docNoRaw) lastDocNo = docNoRaw;
      if (cartRaw) lastCart = cartRaw;
      if (outputPalletRaw) lastOutputPallet = outputPalletRaw;
      if (palletSizeRaw) lastPalletSize = palletSizeRaw;
      if (saleDateRaw) lastSaleDate = saleDateRaw;
      if (remarkRaw) lastRemark = remarkRaw;
      if (invoiceRaw) lastInvoice = invoiceRaw;
      if (orderedByRaw) lastOrderedBy = orderedByRaw;
      if (prepStatusRaw) lastPrepStatus = prepStatusRaw;
      if (incompleteDetailRaw) lastIncompleteDetail = incompleteDetailRaw;

      if (dateVal === '') continue;

      const key = `${noVal}|${docNoVal}|${seqVal}|${dateVal}`;
      const gradeVal = cellText(row, colGrade);

      //  Collected even on rows skipped below for grade purposes, but only
      //  a genuinely blank grade (e.g. row4 in the จ.3-8-69 sample -- a pure
      //  continuation row whose ลูกค้า cell carries the second half of the
      //  customer name) or a real grade code counts. A row whose grade cell
      //  is itself a free-text note (fails looksLikeRealGrade but isn't
      //  blank) is junk end-to-end -- its ลูกค้า cell is usually more note
      //  text too (e.g. "รับสินค้าช่วงเช้า"), not a customer-name fragment.
      if (customerRaw && (gradeVal === '' || looksLikeRealGrade(gradeVal))) {
        const fragments = customerFragmentsByKey.get(key) ?? [];
        if (fragments[fragments.length - 1] !== customerRaw) fragments.push(customerRaw);
        customerFragmentsByKey.set(key, fragments);
      }

      if (!looksLikeRealGrade(gradeVal)) continue;

      const ton = cellNumber(row, colTotal);

      if (!groups.has(key)) {
        groups.set(key, {
          no: noVal,
          docNo: docNoVal,
          seq: seqVal,
          date: dateVal,
          cart: cartVal,
          outputPallet: outputPalletVal,
          palletSize: palletSizeVal,
          arranged: cellChecked(row, colArranged),
          wrapFilm: cellChecked(row, colWrapFilm),
          taped: cellChecked(row, colTaped),
          saleDate: saleDateVal,
          remark: remarkVal,
          invoice: invoiceVal,
          orderedBy: orderedByVal,
          prepStatus: prepStatusVal,
          incompleteDetail: incompleteDetailVal,
          grades: [],
        });
        groupOrder.push(key);
      }
      groups.get(key)!.grades.push({ grade: gradeVal, ton });
    }

    const jobs: JobBlockVM[] = [];

    for (const key of groupOrder) {
      const g = groups.get(key)!;
      const totalTon = g.grades.reduce((sum, x) => sum + x.ton, 0);
      const rawCartQty = parseInt(g.cart, 10);
      const outputPalletCount = parseInt(g.outputPallet, 10);
      const pallets = this.buildPalletsForGroup(
        g.grades,
        outputPalletCount > 0 ? outputPalletCount : null,
      );

      //  Computed once here (not in the template -- see the
      //  dateObj/saleDateObj comment on JobBlockVM) so the datepickers
      //  for potentially dozens of imported rows don't all re-parse on
      //  every change-detection cycle.
      const dateObjVal = this.parseDateValue(g.date);
      const saleDateObjVal = this.parseDateValue(g.saleDate);

      jobs.push({
        //  JOB No has no source column in this sheet -> left blank,
        //  filled in by hand (same as Lot/Bag).
        jobNo: '',
        docNo: g.docNo,
        no: g.no,
        //  date/saleDate (sent to the API as-is by toPayloadJob) must be
        //  the formatted dd/mm/yyyy string, not the raw Excel cell text
        //  -- the sheet can hold any format Excel happens to display (e.g.
        //  "7/1/25"), which pProcessCreateSpecialJob's TRY_CONVERT(DATE,
        //  @job_date, 103) can't parse, silently saving job_date as NULL.
        date: this.formatDateValue(dateObjVal),
        customer: (customerFragmentsByKey.get(key) ?? []).join(' '),
        seq: g.seq,
        palletSize: g.palletSize,
        arranged: g.arranged,
        wrapFilm: g.wrapFilm,
        taped: g.taped,
        saleDate: this.formatDateValue(saleDateObjVal),
        remark: g.remark,
        invoice: g.invoice,
        orderedBy: g.orderedBy,
        prepStatus: g.prepStatus,
        incompleteDetail: g.incompleteDetail,
        dateObj: dateObjVal,
        saleDateObj: saleDateObjVal,
        tonPerCart: Math.round(totalTon * 1000) / 1000,
        cartQty: rawCartQty > 0 ? rawCartQty : 1,
        pallets,
        //  Excel imports can produce dozens of jobs at once -- unlike a
        //  manually-added blank job (emptyJobBlock, still expanded so the
        //  empty form is immediately visible), these start collapsed so the
        //  list is scannable instead of one huge wall of expanded forms.
        collapsed: true,
      });
    }

    return jobs;
  }

  onSpecialFileSelected(event: Event) {
    const input = event.target as HTMLInputElement;
    const file = input.files && input.files[0];
    if (!file) return;

    this._uploadFileName = file.name;

    const reader = new FileReader();
    reader.onload = (loadEvent: any) => {
      try {
        const data = new Uint8Array(loadEvent.target.result);
        const workbook = XLSX.read(data, { type: 'array', cellDates: true });

        //  Newer workbooks (Aug 69+) are one sheet per day -- a full import
        //  can produce 200+ jobs at once (25 sheets x ~10 jobs each), which
        //  is unwieldy to review/edit in the modal in one go. Default to
        //  just the FIRST sheet so something manageable shows up right
        //  away; the sheet picker (onUploadSheetChange) lets the user pick
        //  a specific day, or explicitly choose "every sheet" to get the
        //  old all-at-once behavior back.
        this._uploadWorkbook = workbook;
        this._uploadSheetNames = workbook.SheetNames;
        this._uploadSelectedSheet = workbook.SheetNames[0] ?? this.ALL_SHEETS_OPTION;
        this.applyUploadSheetSelection();
      } catch (error) {
        console.error('Error parsing excel file:', error);
        this.SweetAlert('error', 'ไม่สามารถอ่านไฟล์ Excel ได้ กรุณาตรวจสอบรูปแบบไฟล์');
      }
    };
    reader.readAsArrayBuffer(file);

    input.value = '';
  }

  //  Bound to the sheet picker's (change) -- re-parses _uploadJobs from
  //  just the chosen sheet, or every sheet if ALL_SHEETS_OPTION is picked.
  onUploadSheetChange(sheetName: string): void {
    this._uploadSelectedSheet = sheetName;
    this.applyUploadSheetSelection();
  }

  private async applyUploadSheetSelection(): Promise<void> {
    const workbook = this._uploadWorkbook;
    if (!workbook) return;

    const sheetNames =
      this._uploadSelectedSheet === this.ALL_SHEETS_OPTION
        ? workbook.SheetNames
        : [this._uploadSelectedSheet];

    const jobs: JobBlockVM[] = [];
    for (const sheetName of sheetNames) {
      const sheet = workbook.Sheets[sheetName];
      if (!sheet) continue;
      const rows: any[][] = XLSX.utils.sheet_to_json(sheet, { header: 1, defval: '', raw: false });
      jobs.push(...this.parseSpecialSheetRows(rows, this.extractDateFromSheetName(sheetName)));
    }

    if (jobs.length === 0) {
      this.SweetAlert('error', 'ไม่พบแถวที่มีทั้งวันที่และเกรดครบถ้วนในชีทที่เลือก');
    }

    this._uploadJobs = jobs;

    this._isCalculatingBags = true;
    try {
      await this.applyMasterGradeBagCounts(jobs);
    } finally {
      this._isCalculatingBags = false;
    }
  }

  //  ถุง (BagItemVM.bag) has no source column in the sheet -- looks up each
  //  distinct เกรด used across the parsed jobs against the master grade API
  //  (see crud.service.ts's processGetMasterGrade / GradeController in the
  //  API repo) and derives it from qty instead of leaving it for hand-entry.
  //  unit_ratio is that grade's kg-per-bag figure -- the same package-ratio
  //  concept DoController.UpdateDo uses server-side (there,
  //  unit_pallet x unit_ratio = kg-per-pallet; here just unit_ratio alone
  //  converts a bag's qty (kg) into a ถุง count). A grade with no master
  //  data match (or a failed lookup) is left as 0, same as before -- still
  //  hand-editable, just not auto-filled.
  private async applyMasterGradeBagCounts(jobs: JobBlockVM[]): Promise<void> {
    const gradeCodes = new Set<string>();
    for (const job of jobs) {
      for (const pallet of job.pallets) {
        for (const bag of pallet.bags) {
          if (bag.grade) gradeCodes.add(bag.grade);
        }
      }
    }
    if (gradeCodes.size === 0) return;

    const entries = await Promise.all(
      Array.from(gradeCodes).map(
        async (grade) => [grade, await this.fetchMasterGradeUnitRatio(grade)] as const,
      ),
    );
    const unitRatioByGrade = new Map(
      entries.filter((entry): entry is [string, number] => entry[1] !== null),
    );
    if (unitRatioByGrade.size === 0) return;

    for (const job of jobs) {
      for (const pallet of job.pallets) {
        for (const bag of pallet.bags) {
          const unitRatio = bag.grade ? unitRatioByGrade.get(bag.grade) : undefined;
          if (unitRatio) bag.bag = Math.round((bag.qty ?? 0) / unitRatio);
        }
      }
    }
  }

  //  Resolves to that grade's unit_ratio (kg per bag) from the first master
  //  grade match, or null if there's no match / the lookup fails -- callers
  //  treat null as "leave ถุง for hand-entry" rather than surfacing an error
  //  per grade, since an unmapped or misspelled เกรด code isn't unusual in
  //  these sheets.
  private fetchMasterGradeUnitRatio(gradeCode: string): Promise<number | null> {
    return new Promise((resolve) => {
      this.restService.processGetMasterGrade(gradeCode, '', '', '', '', 1, 1).subscribe(
        (response: Type.ResponseProcessGetMasterGrade) => {
          const unitRatio = response?.data?.[0]?.unit_ratio;
          resolve(unitRatio && unitRatio > 0 ? unitRatio : null);
        },
        (error: any) => {
          console.error('Error fetching master grade for', gradeCode, error);
          resolve(null);
        },
      );
    });
  }

  onSubmitCreateUpload() {
    if (this._uploadJobs.length === 0 || this._isCreating) return;

    if (!this.canCreateUpload()) {
      this.SweetAlert(
        'error',
        'กรุณากรอกข้อมูลที่จำเป็นให้ครบทุก Job (วันที่ / เลขที่เอกสาร / ลูกค้า / ลำดับ / ขนาดพาเลท / เกรด / ตัน)',
      );
      return;
    }

    //  Assign JOB No right before building the payload -- see nextJobNo.
    //  Recomputed from each job's current array position, not stored/edited
    //  earlier, so add/remove doesn't leave stale numbers behind.
    this._uploadJobs.forEach((job, idx) => {
      job.jobNo = this.nextJobNo(idx);
    });

    const payload: Type.RequestCreateSpecialJobItem[] = this._uploadJobs
      .map((job) => {
        const pallets = job.pallets
          .map((pallet) => ({ bags: pallet.bags.map((bag) => this.toPayloadBag(bag)) }))
          .filter((pallet) => pallet.bags.length > 0);

        return this.toPayloadJob(job, pallets);
      })
      .filter((job) => job.pallets.length > 0);

    if (payload.length === 0) {
      this.SweetAlert('error', 'กรุณาอัปโหลดไฟล์ หรือเพิ่ม Pallet และกรอกข้อมูล Grade อย่างน้อย 1 รายการ');
      return;
    }

    this.submitCreateSpecialJob(payload, 'createSpecialJobUploadModal', () => this.resetUploadForm());
  }

  //  =====================================================================
  //  Shared
  //  =====================================================================

  private toPayloadBag(bag: BagItemVM): Type.RequestSpecialJobBagRow {
    return {
      grade: bag.grade,
      lot: bag.lot,
      qty: bag.qty ?? 0,
      bag: bag.bag ?? 0,
    };
  }

  private toPayloadJob(
    job: JobBlockVM,
    pallets: Type.RequestSpecialJobPallet[],
  ): Type.RequestCreateSpecialJobItem {
    return {
      jobNo: job.jobNo?.trim() || undefined,
      title: job.docNo?.trim() || undefined,
      no: job.no?.trim() || undefined,
      date: job.date?.trim() || undefined,
      customer: job.customer?.trim() || undefined,
      seq: job.seq?.trim() || undefined,
      palletSize: job.palletSize?.trim() || undefined,
      arranged: job.arranged || undefined,
      wrapFilm: job.wrapFilm || undefined,
      taped: job.taped || undefined,
      saleDate: job.saleDate?.trim() || undefined,
      remark: job.remark?.trim() || undefined,
      invoice: job.invoice?.trim() || undefined,
      orderedBy: job.orderedBy?.trim() || undefined,
      prepStatus: job.prepStatus?.trim() || undefined,
      incompleteDetail: job.incompleteDetail?.trim() || undefined,
      //  ตัน/คัน รวม for the whole job (see JobBlockVM.tonPerCart/cartQty) --
      //  sent alongside the per-item pallets/bags so the backend has the
      //  header total, not just the derived per-item breakdown.
      tonPerCart: job.tonPerCart ?? undefined,
      cartQty: job.cartQty ?? undefined,
      pallets,
    };
  }

  private submitCreateSpecialJob(
    payload: Type.RequestCreateSpecialJobItem[],
    modalId: string,
    onSuccessReset: () => void,
  ) {
    this._isCreating = true;

    this.restService.processCreateSpecialJob(payload).subscribe(
      (data: Type.ResponseStandard) => {
        this._isCreating = false;

        if (data && data.status === 'success') {
          this.SweetAlert('success', 'สร้างงานสำเร็จ');
          this.closeModal(modalId);
          onSuccessReset();
          this.loadJobData();
        } else {
          this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
        }
      },
      (error) => {
        this._isCreating = false;
        this.SweetAlert('error', 'Message : Error see in log.');
        console.error(error);
      },
    );
  }

  private closeModal(modalId: string) {
    const modalEl = document.getElementById(modalId);
    if (modalEl) {
      const modalInstance =
        (window as any)['bootstrap']?.Modal.getInstance(modalEl) ??
        new (window as any)['bootstrap'].Modal(modalEl);
      modalInstance.hide();
    }
  }

  SweetAlert(iconn: any, alert_message: string) {
    Swal.fire({
      position: 'center',
      icon: iconn,
      title: 'ข้อความจากระบบ',
      text: alert_message,
      showConfirmButton: true,
    });
  }
}
