import { Component } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { Router } from '@angular/router';
import { PageEvent } from '@angular/material/paginator';
import Notify from '../../shared/notify';
import * as XLSX from 'xlsx';
import { firstValueFrom } from 'rxjs';

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
//  One row of the Preparing Zone filter panel (see buildPreZoneOptions).
interface PreZoneOption {
  value: string; // 'none' | 'wh:<code>' | 'id:<n>'
  kind: 'none' | 'group' | 'item';
  label: string;
  wh: string;
  id?: number;
}

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
  //  "ตัน" sub-column); คัน is informational metadata. Qty (kg) รวม
  //  (= tonPerCart x cartQty) is derived for display, not stored. Changing ตัน
  //  regenerates the pallet list (see syncUploadItemsFromHeader below).
  tonPerCart: number | null; // ตัน (= รวม, total for this row)
  cartQty: number | null; // คัน
  //  จำนวนพาเลท from the sheet (column J on the Nov 69+ layout) -- when set,
  //  the job's ตัน is split evenly across exactly this many pallets instead
  //  of the 1 pallet = 1 ตัน fallback (see buildPalletsFromTon). null for
  //  older sheets without that column, and for hand-added/inspected jobs.
  palletCount: number | null;
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
  //  Manual jobs use today's date and keep it read-only in the Upload modal.
  dateLocked?: boolean;
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
    palletCount: null,
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
    statusIds: [],
    prepareZones: [],
    jobType: 0,
    customer: '',
    arrival: '',
    saleDue: '',
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
  _isExportingExcel = false;
  _optionJobStatus: Type.ResultProcessGetOptionsJobStatus[] | null = null;
  _optionCodePallet: Type.ResultProcessGetOptionsCodePallet[] = [];
  _isLoadingCodePalletOptions = false;
  _codePalletOptionsError = false;
  //  Preparing Zone filter options (GET master/location/pre-zone), built
  //  once into WH group rows + zone rows -- see buildPreZoneOptions().
  _preZoneOptions: PreZoneOption[] = [];
  preZoneSearch = '';
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
      this._optionJobStatus = (await this.fetchOptionSpecialStatusList()).data;
    } catch (error) {
      console.error('Error fetching job status options:', error);
      this._optionJobStatus = [];
    }

    await this.loadCodePalletOptions();

    try {
      const res = await firstValueFrom(this.restService.processGetPrezoneLocation('', '', '', '', 1, 1000));
      this._preZoneOptions = this.buildPreZoneOptions(res?.data ?? []);
    } catch (error) {
      console.error('Error fetching pre-zone locations:', error);
      this._preZoneOptions = this.buildPreZoneOptions([]);
    }
  }

  private async loadCodePalletOptions(): Promise<void> {
    this._isLoadingCodePalletOptions = true;
    this._codePalletOptionsError = false;

    try {
      const response = await firstValueFrom(this.restService.ProcessGetOptionsCodePallet());
      if (response.status !== 'success') {
        throw new Error(response.message || 'Failed to load code pallet options');
      }
      this._optionCodePallet = response.data ?? [];
    } catch (error) {
      console.error('Error fetching code pallet options:', error);
      this._codePalletOptionsError = true;
    } finally {
      this._isLoadingCodePalletOptions = false;
    }
  }

  palletSizePlaceholder(): string {
    if (this._isLoadingCodePalletOptions) return 'กำลังโหลดขนาดพาเลท...';
    if (this._codePalletOptionsError) return 'โหลดขนาดพาเลทไม่สำเร็จ';
    if (this._optionCodePallet.length === 0) return 'ไม่พบข้อมูลขนาดพาเลท';
    return 'เลือกขนาดพาเลท';
  }

  hasPalletSizeOption(value: string): boolean {
    return this._optionCodePallet.some((option) => option.code === value);
  }

  //  Preparing Zone options, same shape as WH02's location filter: one
  //  group row per WH (= every pre-zone of that WH), its zones under it,
  //  plus "ยังไม่สแกน location" (to_pre_zone_id IS NULL) on top.
  private buildPreZoneOptions(rows: Type.ResultProcessPreZoneLocation[]): PreZoneOption[] {
    const options: PreZoneOption[] = [{ value: 'none', kind: 'none', label: 'ยังไม่สแกน location', wh: '' }];
    const byWh = new Map<string, Type.ResultProcessPreZoneLocation[]>();
    for (const r of rows) {
      const wh = r.wh_code || '-';
      if (!byWh.has(wh)) byWh.set(wh, []);
      byWh.get(wh)!.push(r);
    }
    for (const wh of Array.from(byWh.keys()).sort()) {
      options.push({ value: `wh:${wh}`, kind: 'group', label: wh, wh });
      for (const r of byWh.get(wh)!.sort((a, b) => (a.location_desc || '').localeCompare(b.location_desc || ''))) {
        options.push({ value: `id:${r.id}`, kind: 'item', label: r.location_desc, wh, id: r.id });
      }
    }
    return options;
  }

  //  Search box inside the panel: zone rows whose name (or WH) matches,
  //  with their WH group row kept on top. Empty search = everything.
  filteredPreZoneOptions(): PreZoneOption[] {
    const q = this.preZoneSearch.trim().toLowerCase();
    if (!q) return this._preZoneOptions;
    const hit = (o: PreZoneOption) => o.label.toLowerCase().includes(q) || o.wh.toLowerCase().includes(q);
    const whs = new Set(this._preZoneOptions.filter((o) => o.kind === 'item' && hit(o)).map((o) => o.wh));
    return this._preZoneOptions.filter(
      (o) => (o.kind === 'none' && hit(o)) || (o.kind === 'group' && whs.has(o.wh)) || (o.kind === 'item' && hit(o)),
    );
  }

  //  Trigger text: "WH40 ทั้งหมด" for a group, zone name for a zone.
  preZoneLabels(): string[] {
    const picked = new Set(this.filter.prepareZones ?? []);
    return this._preZoneOptions
      .filter((o) => picked.has(o.value))
      .map((o) => (o.kind === 'group' ? `${o.label} ทั้งหมด` : o.label));
  }

  //  Picked values -> pre-zone ids for GET job/special (?prepareZoneIds):
  //  a WH group expands to every zone of that WH, 'none' = 0.
  preZoneIds(): number[] {
    const picked = new Set(this.filter.prepareZones ?? []);
    if (!picked.size) return [];
    const ids = new Set<number>();
    for (const o of this._preZoneOptions) {
      if (o.kind === 'none' && picked.has(o.value)) ids.add(0);
      if (o.kind === 'item' && (picked.has(o.value) || picked.has(`wh:${o.wh}`))) ids.add(o.id!);
    }
    return Array.from(ids);
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

  //  Header bar: "ยังไม่สแกน location" toggle is a shortcut for the
  //  Preparing Zone filter set to exactly 'none' (sql/125 id 0) -- on when
  //  that is the only pick; turning it off clears the Preparing Zone pick.
  isUnscannedOnly(): boolean {
    const z = this.filter.prepareZones ?? [];
    return z.length === 1 && z[0] === 'none';
  }

  toggleUnscannedOnly() {
    this.filter.prepareZones = this.isUnscannedOnly() ? [] : ['none'];
    this.onClickSearch();
  }

  //  Header bar menus (same header-filter look as WH01's เรียงตาม):
  //  value '' = ทั้งหมด / default. Picking an option searches right away.
  readonly arrivalOptions: { value: string; label: string }[] = [
    { value: '', label: 'ทั้งหมด' },
    { value: 'not', label: 'ยังไม่ถึง' },
    { value: 'arriving', label: 'กำลังเดินทาง' },
    { value: 'arrived', label: 'ถึงแล้ว' },
  ];
  readonly saleDueOptions: { value: string; label: string }[] = [
    { value: '', label: 'ทั้งหมด' },
    { value: 'today', label: 'ขายวันนี้' },
    { value: 'tomorrow', label: 'ขายพรุ่งนี้' },
    { value: 'overdue', label: 'เลยกำหนด' },
  ];
  //  Same choices as WH02's เรียงตาม (job-list.ts sortOptions), plus วันขาย
  //  and ลำดับ -- values are @sort_by of pProcessGetSpecialJobList
  //  (sql/127 + sql/128); create_desc = the default order.
  readonly sortOptions: { value: string; label: string }[] = [
    { value: '', label: 'ค่าเริ่มต้น' },
    { value: 'create_desc', label: 'วันที่สร้าง ใหม่ - เก่า' },
    { value: 'create_asc', label: 'วันที่สร้าง เก่า - ใหม่' },
    { value: 'doc_asc', label: 'เลขที่เอกสาร A - Z' },
    { value: 'doc_desc', label: 'เลขที่เอกสาร Z - A' },
    { value: 'status_asc', label: 'สถานะ เริ่มต้น - เสร็จสิ้น' },
    { value: 'status_desc', label: 'สถานะ เสร็จสิ้น - เริ่มต้น' },
    { value: 'sale', label: 'วันขาย ใกล้ - ไกล' },
    { value: 'seq', label: 'ลำดับ' },
  ];

  optionLabel(options: { value: string; label: string }[], value: string | undefined): string {
    return options.find((o) => o.value === (value || ''))?.label ?? options[0].label;
  }

  setArrival(value: string) {
    this.filter.arrival = value as Type.SpecialJobFilter['arrival'];
    this.onClickSearch();
  }

  setSaleDue(value: string) {
    this.filter.saleDue = value as Type.SpecialJobFilter['saleDue'];
    this.onClickSearch();
  }

  setSortBy(value: string) {
    this.filter.sortBy = value;
    this.onClickSearch();
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
      statusIds: [],
      prepareZones: [],
      jobType: 0,
      customer: '',
      arrival: '',
      saleDue: '',
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

  //  ส่งออก Excel -- builds the same "Special Package" prep form the team
  //  fills in by hand (SPECIAL_<เดือน> <ปี>.xlsx): one sheet per day that has
  //  jobs, named like "จ.2-11-69", with the 2-row header (จำนวน -> ตัน/คัน),
  //  rows grouped by NO. with a รวม subtotal row after each group, and the
  //  EXPORT/DOMESTIC/total summary block at the bottom. Uses exceljs (loaded
  //  lazily) because SheetJS CE can't write cell styles.
  async exportToExcel(): Promise<void> {
    if (this._isExportingExcel) return;

    const fromDate = this._filterDateFromObj;
    const toDate = this._filterDateToObj;
    if (!fromDate || !toDate || isNaN(fromDate.getTime()) || isNaN(toDate.getTime())) {
      this.SweetAlert('warning', 'กรุณาเลือกวันที่เริ่มต้นและวันที่สิ้นสุด');
      return;
    }

    const startDate = new Date(fromDate.getFullYear(), fromDate.getMonth(), fromDate.getDate());
    const endDate = new Date(toDate.getFullYear(), toDate.getMonth(), toDate.getDate());
    if (startDate > endDate) {
      this.SweetAlert('warning', 'วันที่เริ่มต้นต้องไม่อยู่หลังวันที่สิ้นสุด');
      return;
    }

    this._isExportingExcel = true;
    try {
      const jobs = await this.fetchAllSpecialJobsForExport(startDate, endDate);
      //  Every job the API returns goes into the file. Sheets are keyed by
      //  each job's own วันที่ (falling back to create date, then to the
      //  range start) -- NOT limited to days inside the picked range, since
      //  the API's range filter and job_date don't always agree (e.g. a job
      //  created today for next week's sheet), and dropping those silently
      //  is what made the export come out with fewer jobs than the list.
      const jobsByDate = new Map<string, { date: Date; jobs: Type.ResultProcessSpecialJobListData[] }>();
      for (const job of jobs) {
        const jobDate =
          this.exportDate(job.job_date) ?? this.exportDate(job.create_datetime) ?? startDate;
        const day = new Date(jobDate.getFullYear(), jobDate.getMonth(), jobDate.getDate());
        const dateKey = this.toDateKey(day);
        const entry = jobsByDate.get(dateKey) ?? { date: day, jobs: [] };
        entry.jobs.push(job);
        jobsByDate.set(dateKey, entry);
      }

      const ExcelJS = (await import('exceljs')).default;
      const workbook = new ExcelJS.Workbook();

      const days = Array.from(jobsByDate.values()).sort((a, b) => a.date.getTime() - b.date.getTime());
      for (const { date, jobs: dateJobs } of days) {
        this.buildSpecialFormSheet(workbook, date, dateJobs);
      }

      if (workbook.worksheets.length === 0) {
        this.SweetAlert('warning', 'ไม่พบข้อมูลในช่วงวันที่ที่เลือก');
        return;
      }

      const buffer = await workbook.xlsx.writeBuffer();
      const blob = new Blob([buffer], {
        type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = this.specialExportFileName(startDate, endDate);
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    } catch (error) {
      console.error('Error exporting special job data to Excel:', error);
      this.SweetAlert('error', 'ไม่สามารถส่งออกข้อมูลได้ กรุณาลองใหม่อีกครั้ง');
    } finally {
      this._isExportingExcel = false;
    }
  }

  private static readonly THAI_DAY_ABBR = ['อา', 'จ', 'อ', 'พ', 'พฤ', 'ศ', 'ส'];
  private static readonly THAI_DAY_FULL = ['อาทิตย์', 'จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์', 'เสาร์'];
  private static readonly THAI_MONTH_FULL = [
    'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม', 'มิถุนายน',
    'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม',
  ];
  private static readonly THAI_MONTH_ABBR = [
    'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
    'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.',
  ];

  //  d-m-yy with a 2-digit พ.ศ. year, e.g. 2026-11-03 -> "3-11-69" -- the
  //  format the form uses for sheet names and the ขายวันที่ column.
  //  parseJobDate, plus a พ.ศ. fix-up for the ISO path: some rows were
  //  saved with a Buddhist-Era year already in the DB (e.g. sale_date
  //  "2569-11-13T00:00:00"), which parseJobDate only corrects for the
  //  dd/mm/yyyy form -- left alone, those land in year 2569 (wrong sheet,
  //  and ขายวันที่ printed as "13-11-12").
  private exportDate(value: string | null | undefined): Date | null {
    const date = this.parseJobDate(value);
    if (!date) return null;
    const year = date.getFullYear();
    if (year > 2400) {
      return new Date(year - 543, date.getMonth(), date.getDate());
    }
    //  Rows uploaded before expandTwoDigitYear existed: "19-11-69" was
    //  saved as 2069-11-19 (20yy instead of พ.ศ. 25yy) -- shift back.
    if (year >= 2060 && year < 2100) {
      return new Date(year - 43, date.getMonth(), date.getDate());
    }
    return date;
  }

  private toThaiShortDate(date: Date): string {
    const beYear = (date.getFullYear() + 543) % 100;
    return `${date.getDate()}-${date.getMonth() + 1}-${String(beYear).padStart(2, '0')}`;
  }

  //  "SPECIAL_พ.ย. 69.xlsx" when the range sits inside one month (same as
  //  the hand-made workbook), otherwise "SPECIAL_1-11-69_5-12-69.xlsx".
  private specialExportFileName(startDate: Date, endDate: Date): string {
    if (startDate.getFullYear() === endDate.getFullYear() && startDate.getMonth() === endDate.getMonth()) {
      const beYear = String((startDate.getFullYear() + 543) % 100).padStart(2, '0');
      return `SPECIAL_${JobSpecialList.THAI_MONTH_ABBR[startDate.getMonth()]} ${beYear}.xlsx`;
    }
    return `SPECIAL_${this.toThaiShortDate(startDate)}_${this.toThaiShortDate(endDate)}.xlsx`;
  }

  private buildSpecialFormSheet(
    workbook: import('exceljs').Workbook,
    date: Date,
    jobs: Type.ResultProcessSpecialJobListData[],
  ): void {
    type Cell = import('exceljs').Cell;
    type Border = Partial<import('exceljs').Borders>;

    const sheetName = `${JobSpecialList.THAI_DAY_ABBR[date.getDay()]}.${this.toThaiShortDate(date)}`;
    const ws = workbook.addWorksheet(sheetName, {
      pageSetup: {
        paperSize: 9,
        orientation: 'landscape',
        fitToPage: true,
        fitToWidth: 1,
        fitToHeight: 0,
        horizontalCentered: true,
        margins: { left: 0.25, right: 0.25, top: 0.4, bottom: 0.4, header: 0.2, footer: 0.2 },
      },
      views: [{ state: 'frozen', ySplit: 3 }],
    });

    //  Layout of the Nov 69+ form (A..S): J = จำนวนพาเลท, R = สถานะ,
    //  S = รายละเอียดที่ยังไม่เสร็จ. Column widths copied from that form.
    const widths = [4.5, 14, 12.6, 3.75, 14.1, 4.6, 4.6, 5.1, 17.6, 6.5, 4.6, 5, 5, 8.25, 10.6, 30.6, 8.25, 18.6, 26.4];
    ws.columns = widths.map((width) => ({ width }));

    const thin = { style: 'thin' as const };
    const medium = { style: 'medium' as const };
    const solid = (argb: string) => ({ type: 'pattern' as const, pattern: 'solid' as const, fgColor: { argb } });
    const RED = 'FFFF0000';
    const style = (
      cell: Cell,
      opts: { font?: string; size?: number; bold?: boolean; color?: string; fill?: string; align?: 'left' | 'center'; wrap?: boolean; border?: Border },
    ) => {
      cell.font = { name: opts.font ?? 'Angsana New', size: opts.size ?? 14, bold: !!opts.bold, color: opts.color ? { argb: opts.color } : undefined };
      if (opts.fill) cell.fill = solid(opts.fill);
      cell.alignment = { horizontal: opts.align ?? 'center', vertical: 'middle', wrapText: opts.wrap ?? true };
      if (opts.border) cell.border = opts.border;
    };
    //  A/Q/R/S carry the form's medium outer edges; everything else is thin.
    const gridBorder = (col: number, top: any = thin, bottom: any = thin): Border => ({
      top,
      bottom,
      left: col === 1 || col === 18 || col === 19 ? medium : thin,
      right: col === 17 || col === 18 || col === 19 ? medium : thin,
    });

    // ---- Row 1: title + สถานะ/รายละเอียด headers ----
    const title =
      `เอกสารการจัดเตรียมสินค้าเพื่อทำ Special  Package  ในวัน${JobSpecialList.THAI_DAY_FULL[date.getDay()]}` +
      `ที่ ${date.getDate()} ${JobSpecialList.THAI_MONTH_FULL[date.getMonth()]} ${date.getFullYear() + 543}`;
    ws.mergeCells('A1:P1');
    ws.getCell('A1').value = title;
    style(ws.getCell('A1'), { size: 16, bold: true, fill: 'FF66FFFF', border: { top: medium, left: medium, bottom: thin, right: thin } });
    style(ws.getCell('Q1'), { fill: 'FF5BE8EB', border: { top: medium, right: medium } });

    ws.mergeCells('R1:R3');
    ws.getCell('R1').value = 'สถานะการจัดทำสินค้า';
    style(ws.getCell('R1'), { size: 11, bold: true, fill: 'FF5BE8EB', border: { top: medium, left: medium, right: medium, bottom: thin } });
    ws.mergeCells('S1:S3');
    ws.getCell('S1').value = 'รายละเอียดของแต่ละรายการที่ยังทำไม่เสร็จ';
    style(ws.getCell('S1'), { size: 11, bold: true, fill: 'FF00B050', border: { top: medium, left: medium, right: medium, bottom: thin } });

    // ---- Rows 2-3: column headers (จำนวน spans ตัน/คัน) ----
    const headers: [string, string][] = [
      ['A', 'NO.'], ['B', 'เลขที่เอกสาร'], ['C', 'ลูกค้า'], ['D', 'ลำดับ'], ['E', 'เกรด'],
      ['H', 'รวม'], ['I', 'ขนาดพาเลท'], ['J', 'จำนวนพาเลท'], ['K', 'จัดเรียง'], ['L', 'พันฟิล์ม'],
      ['M', 'รัดเทป'], ['N', 'ขายวันที่'], ['O', 'หมายเหตุ'], ['P', 'INVOICE'], ['Q', 'ผู้สั่งงาน'],
    ];
    for (const [col, label] of headers) {
      ws.mergeCells(`${col}2:${col}3`);
      ws.getCell(`${col}2`).value = label;
    }
    ws.mergeCells('F2:G2');
    ws.getCell('F2').value = 'จำนวน';
    ws.getCell('F3').value = 'ตัน';
    ws.getCell('G3').value = 'คัน';
    for (let col = 1; col <= 17; col++) {
      for (const row of [2, 3]) {
        style(ws.getCell(row, col), { size: col === 14 || col === 15 ? 12 : 11, bold: true, fill: 'FFFFCCFF', border: gridBorder(col) });
      }
    }
    ws.getRow(1).height = 23.25;
    ws.getRow(2).height = 16.5;
    ws.getRow(3).height = 16.5;

    // ---- Data: grouped by NO., one row per job, subtotal after each group ----
    const num = (v: string | null | undefined) => {
      const n = parseFloat(String(v ?? '').replace(/[^\d.]/g, ''));
      return isNaN(n) ? Number.MAX_SAFE_INTEGER : n;
    };
    const sorted = [...jobs].sort(
      (a, b) => num(a.no) - num(b.no) || num(a.seq) - num(b.seq) || (a.id ?? 0) - (b.id ?? 0),
    );
    const groups: Type.ResultProcessSpecialJobListData[][] = [];
    for (const job of sorted) {
      const last = groups[groups.length - 1];
      if (last && (last[0].no ?? '') === (job.no ?? '')) last.push(job);
      else groups.push([job]);
    }

    let totalTon = 0;
    let totalCart = 0;
    //  Pallet totals for the summary block, split by what ขนาดพาเลท says
    //  the pallet is made of ("ไม้" = wood, anything else = plastic).
    let plasticPallets = 0;
    let woodPallets = 0;
    let rowIdx = 4;

    for (const group of groups) {
      const firstRow = rowIdx;
      let groupTon = 0;
      let prev: Type.ResultProcessSpecialJobListData | null = null;

      for (const job of group) {
        const ton = job.total_ton ?? 0;
        const cart = job.cart_qty ?? 0;
        //  จำนวนพาเลท = the job's own planned pallets (distinct pallet_no in
        //  its details -- what the upload built from the sheet's จำนวนพาเลท
        //  column). total_pallet (pallet-progress count) is only a fallback
        //  for a job with no detail rows.
        const plannedPallets = new Set((job.details ?? []).map((d) => d.pallet_no || 1)).size;
        const pallets = plannedPallets || job.total_pallet || 0;
        if ((job.pallet_size ?? '').includes('ไม้')) woodPallets += pallets;
        else plasticPallets += pallets;
        const grades = Array.from(new Set((job.details ?? []).map((d) => d.grade).filter((g) => !!g))).join(', ');
        const saleDate = this.exportDate(job.sale_date);
        //  Like the hand-made form, values repeated from the row above within
        //  the same NO. group (merged-looking cells) are only written once.
        const same = (key: keyof Type.ResultProcessSpecialJobListData) => !!prev && (prev[key] ?? '') === (job[key] ?? '');

        const values: (string | number | null)[] = [
          prev ? null : job.no ? (isNaN(Number(job.no)) ? job.no : Number(job.no)) : null,
          same('doc_no') ? null : job.doc_no || null,
          same('customer') ? null : job.customer || null,
          job.seq ? (isNaN(Number(job.seq)) ? job.seq : Number(job.seq)) : null,
          grades || null,
          cart > 0 ? Math.round((ton / cart) * 1000) / 1000 : ton || null,
          cart || null,
          ton || null,
          same('pallet_size') ? null : job.pallet_size || null,
          pallets || null,
          job.is_arranged ? 'X' : null,
          job.is_wrap_film ? 'X' : null,
          job.is_taped ? 'X' : null,
          saleDate ? this.toThaiShortDate(saleDate) : job.sale_date || null,
          job.remark || null,
          job.invoice || null,
          same('ordered_by') ? null : job.ordered_by || null,
          job.prep_status || null,
          job.incomplete_detail || null,
        ];

        const row = ws.getRow(rowIdx);
        row.height = 21.95;
        values.forEach((value, i) => {
          const col = i + 1;
          const cell = row.getCell(col);
          cell.value = value;
          const top = col <= 17 && !prev ? thin : undefined;
          const border: Border = { ...gridBorder(col, top, undefined) };
          if (!top) delete border.top;
          delete border.bottom;
          if (col === 1) style(cell, { font: 'Tahoma', size: 14, bold: true, color: RED, border });
          else if (col === 4 || col === 14) style(cell, { fill: 'FFFFFF00', border });
          else if (col === 5) style(cell, { size: 16, bold: true, border });
          else if (col === 15) style(cell, { size: 12, color: RED, border });
          else if (col === 16) style(cell, { bold: true, color: RED, border });
          else if (col === 17) style(cell, { size: 11, border });
          else if (col === 18) style(cell, { font: 'Tahoma', size: 10, bold: true, color: 'FF00B050', border });
          else if (col === 19) style(cell, { font: 'Tahoma', size: 10, align: 'left', border });
          else style(cell, { size: col === 2 ? 12 : 14, bold: col === 9, border });
        });

        groupTon += ton;
        totalCart += cart;
        prev = job;
        rowIdx++;
      }

      // Subtotal row: =SUM(H<first>:H<last>)
      const sub = ws.getRow(rowIdx);
      sub.height = 20.1;
      for (let col = 1; col <= 19; col++) {
        style(sub.getCell(col), {
          font: 'AngsanaUPC',
          size: 14,
          border: col <= 18 ? gridBorder(col, medium, medium) : { left: medium, right: medium },
        });
      }
      sub.getCell(8).value = { formula: `SUM(H${firstRow}:H${rowIdx - 1})`, result: groupTon };
      style(sub.getCell(8), { font: 'AngsanaUPC', size: 14, bold: true, color: RED, border: gridBorder(8, medium, medium) });
      totalTon += groupTon;
      rowIdx++;
    }

    // Close the S column's medium frame on the last subtotal row.
    ws.getCell(rowIdx - 1, 19).border = { left: medium, right: medium, bottom: medium };

    // ---- Grand total: "จำนวน X ตัน" ----
    const fmt = (n: number) => (Math.round(n * 1000) / 1000).toLocaleString('en-US');
    ws.getCell(rowIdx, 16).value = `จำนวน ${fmt(totalTon)} ตัน`;
    style(ws.getCell(rowIdx, 16), { font: 'Tahoma', size: 11, bold: true, color: RED });
    rowIdx += 2;

    // ---- Summary block: EXPORT / DOMESTIC / total ----
    //  EXPORT/DOMESTIC isn't tracked per job, so those rows are left blank
    //  for hand-entry like the original form; the total row is pre-filled
    //  with the day's ตัน, คัน and plastic/wood pallet counts.
    const summary: [string, number | null, number | null, number | null, number | null][] = [
      ['EXPORT', null, null, null, null],
      ['DOMESTIC', null, null, null, null],
      ['total', totalTon, totalCart, plasticPallets, woodPallets],
    ];
    for (const [label, ton, cart, plastic, wood] of summary) {
      const row = ws.getRow(rowIdx);
      row.height = 14.25;
      const put = (col: number, value: string | number | null, red = false) => {
        const cell = row.getCell(col);
        cell.value = value;
        style(cell, { font: 'Tahoma', size: col === 2 ? 9 : 11, bold: red || col === 2, color: red ? RED : undefined, align: col === 2 ? 'left' : 'center', wrap: false });
      };
      put(2, label);
      put(3, ton, true);
      put(4, 'ตัน');
      put(5, cart, true);
      put(6, 'คัน');
      put(9, 'พลาสติก');
      put(10, plastic, true);
      put(11, 'ตัว');
      put(12, 'ไม้');
      put(13, wood, true);
      put(14, 'ตัว');
      if (label === 'total') put(16, `รวม  ${(plastic ?? 0) + (wood ?? 0)}  ตัว`);
      rowIdx++;
    }

    ws.pageSetup.printArea = `A1:S${rowIdx - 1}`;
  }

  private async fetchAllSpecialJobsForExport(
    fromDate: Date,
    toDate: Date,
  ): Promise<Type.ResultProcessSpecialJobListData[]> {
    const pageSize = 100;
    const dateFrom = this.formatDateValue(fromDate);
    const dateTo = this.formatDateValue(toDate);
    const fetchPage = (page: number) =>
      firstValueFrom(
        this.restService.processGetSpecialJobList(
          0,
          '',
          dateFrom,
          dateTo,
          0,
          0,
          page,
          pageSize,
          '',
          '',
        ),
      );

    const firstPage = await fetchPage(1);
    if (firstPage.status !== 'success') {
      throw new Error(firstPage.message || 'Failed to load special job export data');
    }

    //  Keyed by job id: if one job's item rows straddle a page boundary the
    //  API returns it on both pages -- merge its details instead of
    //  exporting it twice.
    const byId = new Map<number, Type.ResultProcessSpecialJobListData>();
    const addJobs = (data: Type.ResultProcessSpecialJobListData[] | null | undefined) => {
      for (const job of data ?? []) {
        const existing = byId.get(job.id);
        if (!existing) {
          byId.set(job.id, { ...job, details: [...(job.details ?? [])] });
          continue;
        }
        const seen = new Set(existing.details.map((d) => d.id));
        existing.details.push(...(job.details ?? []).filter((d) => !seen.has(d.id)));
      }
    };

    addJobs(firstPage.data);
    const totalCount = firstPage.total_count ?? 0;
    const totalPages = Math.ceil(totalCount / pageSize);
    for (let page = 2; page <= totalPages; page += 1) {
      const response = await fetchPage(page);
      if (response.status !== 'success') {
        throw new Error(response.message || `Failed to load special job export page ${page}`);
      }
      if (!response.data?.length) break;
      addJobs(response.data);
    }

    return Array.from(byId.values());
  }

  private toDateKey(date: Date): string {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
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
          '',
          [],
          this.filter.statusIds ?? [],
          this.preZoneIds(),
          this.filter.customer || '',
          this.filter.arrival || '',
          this.filter.saleDue || '',
        )
        .subscribe(
          (response: Type.ResponseProcessSpecialJobListData) => resolve(response),
          (error) => reject(error),
        );
    });
  }

  //  ct_special_status via GET process-cb/special-status-list
  //  (pProcessGetSpecialStatusList, sql/135): 1 อนุมัติแล้ว / 2 รอจัดเก็บ /
  //  3 เสร็จสิ้น -- the same ids pProcessGetSpecialJobList's @job_status
  //  filters on. Failures are swallowed in ngOnInit so this never blocks
  //  the page.
  //  Card status badge text in Thai: name_th from the สถานะ options
  //  (ct_special_status) matched by status_id. The badge's color class
  //  still comes from the English status_name (spc-approve /
  //  wait-location / complete), so only the text changes.
  statusNameTh(job: Type.ResultProcessSpecialJobListData | null | undefined): string {
    const option = (this._optionJobStatus ?? []).find((o) => o.id === job?.status_id);
    return option?.name_th || job?.status_name || '-';
  }

  //  Multi-select สถานะ trigger text: picked names, comma-joined
  //  (placeholder "ทั้งหมด" shows when nothing is picked).
  statusLabels(): string[] {
    const ids = this.filter.statusIds ?? [];
    return (this._optionJobStatus ?? [])
      .filter((o) => ids.includes(o.id))
      .map((o) => o.name_th || o.name);
  }

  //  Dot color per ct_special_status id -- same colors as the card's
  //  status badge (.spc-approve / .wait-location / .complete in
  //  job-special-list.css).
  specialStatusColor(statusId: number): string {
    switch (statusId) {
      case 1: return '#6011aa'; // อนุมัติแล้ว (SPC Approve)
      case 2: return '#faad14'; // รอจัดเก็บ (Wait Location)
      case 3: return '#52c41a'; // เสร็จสิ้น (Complete)
      default: return '#94a3b8';
    }
  }

  fetchOptionSpecialStatusList(): Promise<Type.ResponseProcessGetOptionsJobStatus> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsSpecialStatusList().subscribe(
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
      palletCount: null,
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

  async duplicateInspectPallet(palletIndex: number): Promise<void> {
    if (!this._inspectJobVM) return;
    const source = this._inspectJobVM.pallets[palletIndex];
    if (!source) return;

    const count = await this.promptPalletDuplicateCount();
    if (count === null) return;

    const copies = Array.from({ length: count }, () => ({
      bags: source.bags.map((bag) => ({ ...bag })),
    }));
    this._inspectJobVM.pallets.push(...copies);
  }

  private async promptPalletDuplicateCount(): Promise<number | null> {
    const result = await Notify.fire<string>({
      icon: 'question',
      title: 'Duplicate Pallet',
      text: 'ระบุจำนวนสำเนาพาเลทที่ต้องการเพิ่ม (1 - 100)',
      input: 'number',
      inputValue: 1,
      inputAttributes: { min: '1', max: '100', step: '1' },
      showCancelButton: true,
      confirmButtonText: 'Duplicate',
      cancelButtonText: 'ยกเลิก',
      inputValidator: (value) => {
        const count = Number(value);
        return Number.isInteger(count) && count >= 1 && count <= 100
          ? null
          : 'กรุณาระบุจำนวน 1 - 100';
      },
    });

    return result.isConfirmed ? Number(result.value) : null;
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

    Notify.fire({
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

  //  Tooltip for the card's LOT tag -- every lot of the first item.
  lotListText(job: Type.ResultProcessSpecialJobListData): string {
    return this.itemLots(job)
      .map((l) => l.lot)
      .filter((lot) => !!lot)
      .join(', ');
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
  //  Create requires document/customer/sequence/grade/ton/pallet size.
  //  Date is set to today for manually added jobs and is optional; uploaded
  //  jobs retain the date parsed from Excel.

  isBlank(value: string | number | null | undefined): boolean {
    return value === null || value === undefined || value.toString().trim() === '';
  }

  isJobMetaMissing(job: JobBlockVM, field: 'date' | 'docNo' | 'customer' | 'seq' | 'palletSize'): boolean {
    return this.isBlank(job[field]);
  }

  isBagGradeMissing(bag: BagItemVM): boolean {
    return this.isBlank(bag.grade);
  }

  //  Bag (ถุง) is required in the Create modal too -- blank or 0 blocks
  //  Create, same rule as job-special-detail's isBagBagMissing.
  isBagCountMissing(bag: BagItemVM): boolean {
    return bag.bag === null || bag.bag === undefined || bag.bag <= 0;
  }

  //  ตัน is now a job-header field (see JobBlockVM.tonPerCart), not a
  //  per-item one -- every item generated from it shares the same weight.
  isJobTonMissing(job: JobBlockVM): boolean {
    return job.tonPerCart === null || job.tonPerCart === undefined;
  }

  private jobHasAllRequiredFields(job: JobBlockVM): boolean {
    if (
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

    return allBags.every((bag) => !this.isBagGradeMissing(bag) && !this.isBagCountMissing(bag));
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
      if (year < 100) year = this.expandTwoDigitYear(year);
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

  //  2-digit years on the prep sheets are พ.ศ. ("19-11-69" = 2569 = 2026),
  //  not 20yy -- reading them as 2069 is what saved ขายวันที่ decades off.
  //  >= 60 is taken as พ.ศ. 25yy (2560+ = 2017+); anything lower is still
  //  treated as ค.ศ. 20yy for the odd CE-formatted cell.
  private expandTwoDigitYear(yy: number): number {
    return yy >= 60 ? 2500 + yy - 543 : 2000 + yy;
  }

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
      if (year < 100) year = this.expandTwoDigitYear(year);
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
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    this._uploadJobs.push({
      ...emptyJobBlock(),
      date: this.formatDateValue(today),
      dateObj: today,
      dateLocked: true,
      pallets: [{ bags: [] }],
    });
  }

  //  Asks first (a job usually carries parsed data worth keeping).
  async removeUploadJob(jobIndex: number) {
    const job = this._uploadJobs[jobIndex];
    if (!job) return;
    const label = job.docNo ? `JOB No ${this.nextJobNo(jobIndex)} (${job.docNo})` : `JOB No ${this.nextJobNo(jobIndex)}`;
    if (!(await this.confirmUploadDelete(`ลบ ${label}?`))) return;
    this._uploadJobs.splice(jobIndex, 1);
  }

  private async confirmUploadDelete(text: string): Promise<boolean> {
    const result = await Notify.fire({
      position: 'center',
      icon: 'warning',
      title: 'ยืนยันการลบ',
      text,
      showConfirmButton: true,
      showCancelButton: true,
      confirmButtonText: 'ลบ',
      cancelButtonText: 'ยกเลิก',
    });
    return !!result.isConfirmed;
  }

  //  ── Create modal: same helpers as job-special-detail's Pallet List ──
  //  Required here = job meta (date / docNo / customer / seq / palletSize /
  //  ตัน) + Grade on every bag row (see jobHasAllRequiredFields).
  jobMissingCount(job: JobBlockVM): number {
    let n = [job.docNo, job.customer, job.seq, job.palletSize].filter((v) => this.isBlank(v)).length;
    if (this.isJobTonMissing(job)) n++;
    for (const p of job.pallets) n += this.uploadPalletMissingCount(p);
    if (job.pallets.every((p) => p.bags.length === 0)) n++;
    return n;
  }

  uploadPalletMissingCount(pallet: PalletVM): number {
    return pallet.bags.reduce((n, b) => n + (this.isBagGradeMissing(b) ? 1 : 0) + (this.isBagCountMissing(b) ? 1 : 0), 0);
  }

  uploadMissingTotal(): number {
    return this._uploadJobs.reduce((s, j) => s + this.jobMissingCount(j), 0);
  }

  uploadIncompleteJobs(): number {
    return this._uploadJobs.filter((j) => this.isJobIncomplete(j)).length;
  }

  uploadPalletBags(pallet: PalletVM): number {
    return pallet.bags.reduce((s, b) => s + (b.bag ?? 0), 0);
  }

  uploadPalletQty(pallet: PalletVM): number {
    return pallet.bags.reduce((s, b) => s + (b.qty ?? 0), 0);
  }

  uploadPalletGrades(pallet: PalletVM): string {
    return Array.from(new Set(pallet.bags.map((b) => b.grade).filter(Boolean))).join(', ');
  }

  //  Pallet collapse inside a job: a job with more than 3 pallets starts
  //  with its pallets collapsed; clicking a pallet title flips it. A pallet
  //  with a blank Grade always stays open.
  private uploadPalletToggled = new Set<PalletVM>();

  isUploadPalletCollapsed(job: JobBlockVM, pallet: PalletVM): boolean {
    if (this.uploadPalletMissingCount(pallet) > 0) return false;
    const collapsedByDefault = job.pallets.length > 3;
    return collapsedByDefault !== this.uploadPalletToggled.has(pallet);
  }

  toggleUploadPallet(pallet: PalletVM) {
    if (this.uploadPalletToggled.has(pallet)) this.uploadPalletToggled.delete(pallet);
    else this.uploadPalletToggled.add(pallet);
  }

  //  "ไปที่ช่อง": open every job that still has a blank required field,
  //  then scroll to + focus the first .field-invalid inside the modal.
  goToFirstMissingUpload() {
    this._uploadJobs.forEach((j) => {
      if (this.isJobIncomplete(j)) j.collapsed = false;
    });
    setTimeout(() => {
      const el = document.querySelector<HTMLElement>('#createSpecialJobUploadModal .field-invalid, #createSpecialJobUploadModal .bag-no-master');
      if (!el) return;
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      const input = el.matches('input') ? el : el.querySelector<HTMLElement>('input');
      setTimeout(() => input?.focus({ preventScroll: true }), 350);
    });
  }

  //  Keyboard flow in the upload bag tables: Enter -> next cell; Enter on
  //  Bag -> next row's Grade, or a new row after the last one.
  private readonly uploadCellOrder = ['grade', 'lot', 'qty', 'bag'] as const;

  onUploadCellEnter(event: Event, jIdx: number, pIdx: number, iIdx: number, field: 'grade' | 'lot' | 'qty' | 'bag') {
    event.preventDefault();
    const pallet = this._uploadJobs[jIdx]?.pallets[pIdx];
    if (!pallet) return;
    const next = this.uploadCellOrder.indexOf(field) + 1;
    if (next < this.uploadCellOrder.length) {
      this.focusUploadCell(jIdx, pIdx, iIdx, this.uploadCellOrder[next]);
    } else if (iIdx + 1 < pallet.bags.length) {
      this.focusUploadCell(jIdx, pIdx, iIdx + 1, 'grade');
    } else {
      this.addUploadBagItem(jIdx, pIdx);
    }
  }

  addUploadBagItem(jIdx: number, pIdx: number) {
    const pallet = this._uploadJobs[jIdx]?.pallets[pIdx];
    if (!pallet) return;
    pallet.bags.push({ grade: '', lot: '', qty: null, bag: null });
    this.focusUploadCell(jIdx, pIdx, pallet.bags.length - 1, 'grade');
  }

  //  Row delete: asks first only when the row has something typed in.
  async removeUploadItem(jIdx: number, pIdx: number, iIdx: number) {
    const bag = this._uploadJobs[jIdx]?.pallets[pIdx]?.bags[iIdx];
    if (!bag) return;
    const hasData = !!(bag.grade || bag.lot || bag.qty || bag.bag);
    if (hasData && !(await this.confirmUploadDelete(`ลบรายการที่ ${iIdx + 1} ของ Pallet #${pIdx + 1}?`))) return;
    this._uploadJobs[jIdx].pallets[pIdx].bags.splice(iIdx, 1);
  }

  private focusUploadCell(jIdx: number, pIdx: number, iIdx: number, field: string) {
    setTimeout(() => {
      const el = document.getElementById(`ucell_${field}_${jIdx}_${pIdx}_${iIdx}`) as HTMLInputElement | null;
      el?.focus();
      el?.select?.();
    });
  }

  //  Lot suggestions for the upload tables: every lot used in any staged job.
  uploadLotOptions(): string[] {
    const lots = this._uploadJobs.flatMap((j) => j.pallets.flatMap((p) => p.bags.map((b) => (b.lot || '').trim())));
    return Array.from(new Set(lots.filter(Boolean))).sort();
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

  async removeUploadPallet(jobIndex: number, palletIndex: number) {
    const pallet = this._uploadJobs[jobIndex]?.pallets[palletIndex];
    if (!pallet) return;
    if (pallet.bags.length && !(await this.confirmUploadDelete(`ลบ Pallet #${palletIndex + 1} (${pallet.bags.length} รายการ)?`))) return;
    this._uploadJobs[jobIndex].pallets.splice(palletIndex, 1);
  }

  async duplicateUploadPallet(jobIndex: number, palletIndex: number): Promise<void> {
    const job = this._uploadJobs[jobIndex];
    if (!job) return;
    const source = job.pallets[palletIndex];
    if (!source) return;

    const count = await this.promptPalletDuplicateCount();
    if (count === null) return;

    const copies = Array.from({ length: count }, () => ({
      bags: source.bags.map((bag) => ({ ...bag })),
    }));
    job.pallets.push(...copies);
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
  //  ตัน x คัน. คัน is still captured from the sheet and sent to the backend
  //  as metadata (see toPayloadJob), but does not decide the pallet count.
  //  Whenever ตัน changes, regenerate the Pallet List to match -- growing/
  //  shrinking it to ceil(ตัน) pallets (each with exactly one bag item) and
  //  re-stamping every pallet's weight. Grade/Lot/Bag are carried over from
  //  the previous pallet at the same position (falling back to the last
  //  existing bag) so re-typing ตัน doesn't wipe out values already filled in.

  jobTotalQty(job: JobBlockVM): number | null {
    if (job.tonPerCart === null || job.tonPerCart === undefined) return null;
    return Math.round(job.tonPerCart * (job.cartQty ?? 0) * 100) / 100;
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
  //  palletCount (จำนวนพาเลท from the sheet), when given, overrides that:
  //  exactly palletCount pallets, each carrying totalTon / palletCount.
  private buildPalletsFromTon(
    totalTon: number | null | undefined,
    existingPallets?: PalletVM[],
    palletCount?: number | null,
  ): PalletVM[] {
    const hasTon = totalTon !== null && totalTon !== undefined && totalTon > 0;
    const usePalletCount = hasTon && !!palletCount && palletCount > 0;
    const desiredPalletCount = !hasTon ? 0 : usePalletCount ? palletCount! : Math.ceil(totalTon!);
    const tonPerPallet = usePalletCount ? totalTon! / palletCount! : 1;

    if (desiredPalletCount === 0) return [{ bags: [] }];

    const previousBags = (existingPallets ?? []).flatMap((pallet) => pallet.bags);
    const lastBag = previousBags[previousBags.length - 1];

    const pallets: PalletVM[] = [];
    let remainingTon = totalTon as number;

    for (let p = 0; p < desiredPalletCount; p++) {
      //  The last pallet takes whatever is left, so float rounding never
      //  leaves a few kg unassigned.
      const palletTon = p === desiredPalletCount - 1 ? remainingTon : Math.min(tonPerPallet, remainingTon);
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
    job.pallets = this.buildPalletsFromTon(job.tonPerCart, job.pallets, job.palletCount);
    //  Regenerated pallets come back with bag 0 -- fill them from master
    //  grade again (same as right after an Excel upload).
    void this.fillMissingUploadBags([job]);
  }

  //  ── Auto bag count in the Create modal (same idea as
  //  job-special-detail): Bag = round(Qty / master grade unit_ratio). ──
  private uploadRatioCache = new Map<string, Promise<number | null>>();
  private uploadManualBag = new WeakSet<BagItemVM>();
  private uploadAutoBag = new WeakSet<BagItemVM>();

  private uploadUnitRatio(grade: string): Promise<number | null> {
    const key = (grade || '').trim();
    if (!key) return Promise.resolve(null);
    if (!this.uploadRatioCache.has(key)) {
      this.uploadRatioCache.set(
        key,
        this.fetchMasterGradeUnitRatio(key).then((ratio) => {
          if (ratio) this.uploadNoMasterGrades.delete(key.toUpperCase());
          else this.uploadNoMasterGrades.add(key.toUpperCase());
          return ratio;
        }),
      );
    }
    return this.uploadRatioCache.get(key)!;
  }

  //  Grades the master grade lookup has no kg-per-bag for -- their Bag
  //  can't be calculated, so the cell warns "ไม่พบเกรดใน master".
  private uploadNoMasterGrades = new Set<string>();

  isUploadBagNoMaster(bag: BagItemVM): boolean {
    return !!bag.grade && !((bag.bag ?? 0) > 0) && this.uploadNoMasterGrades.has(bag.grade.trim().toUpperCase());
  }

  isUploadAutoBag(bag: BagItemVM): boolean {
    return this.uploadAutoBag.has(bag);
  }

  onUploadBagInput(bag: BagItemVM) {
    this.uploadManualBag.add(bag);
    this.uploadAutoBag.delete(bag);
  }

  //  Grade / Qty edited in a row -> recalc that row's Bag (unless typed by hand).
  async onUploadGradeOrQtyChange(bag: BagItemVM) {
    if (bag.grade) void this.uploadUnitRatio(bag.grade); // refreshes the no-master warning
    if (this.uploadManualBag.has(bag)) return;
    if (!bag.grade || !bag.qty || bag.qty <= 0) return;
    const ratio = await this.uploadUnitRatio(bag.grade);
    if (ratio) {
      bag.bag = Math.round(bag.qty / ratio);
      this.uploadAutoBag.add(bag);
    }
  }

  //  Every row with Bag blank / 0 and a Grade + Qty gets a calculated Bag.
  private async fillMissingUploadBags(jobs: JobBlockVM[]) {
    for (const bag of jobs.flatMap((j) => j.pallets.flatMap((p) => p.bags))) {
      if ((bag.bag ?? 0) > 0 || this.uploadManualBag.has(bag)) continue;
      if (!bag.grade) continue;
      if (!bag.qty || bag.qty <= 0) {
        void this.uploadUnitRatio(bag.grade); // still flag a grade missing from master
        continue;
      }
      const ratio = await this.uploadUnitRatio(bag.grade);
      if (ratio && !((bag.bag ?? 0) > 0)) {
        bag.bag = Math.round(bag.qty / ratio);
        this.uploadAutoBag.add(bag);
      }
    }
  }

  onJobTonInput(job: JobBlockVM, value: number | null) {
    job.tonPerCart = value === null || !Number.isFinite(value) ? null : Math.max(0, value);
    this.syncUploadItemsFromHeader(job);
  }

  onJobCartQtyInput(job: JobBlockVM, value: number | null) {
    //  คัน no longer drives pallet/item generation (1 pallet = 1 ตัน now) --
    //  just record the value; it's still sent to the backend as metadata.
    job.cartQty = value === null || !Number.isFinite(value) ? null : Math.max(0, Math.trunc(value));
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
    //  จำนวนพาเลท (column J on the Nov 69+ layout) -- pallet count per grade
    //  row, summed per job below and used as its target pallet count.
    const colPalletCount = findCol(['จำนวนพาเลท']);

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
      palletCountSum: number;
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
          palletCountSum: 0,
        });
        groupOrder.push(key);
      }
      const group = groups.get(key)!;
      group.grades.push({ grade: gradeVal, ton });
      group.palletCountSum += cellNumber(row, colPalletCount);
    }

    const jobs: JobBlockVM[] = [];

    for (const key of groupOrder) {
      const g = groups.get(key)!;
      const totalTon = g.grades.reduce((sum, x) => sum + x.ton, 0);
      const rawCartQty = parseInt(g.cart, 10);
      //  Target pallet count: "Output Pallet" (older layout) if present,
      //  otherwise the จำนวนพาเลท column; neither -> null (1 pallet/ตัน).
      const outputPalletCount = parseInt(g.outputPallet, 10);
      const palletCount =
        outputPalletCount > 0 ? outputPalletCount : g.palletCountSum > 0 ? Math.round(g.palletCountSum) : null;
      const pallets = this.buildPalletsForGroup(g.grades, palletCount);

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
        palletCount,
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
      //  dateNF: real Excel date cells otherwise come out as US "m/d/yy",
      //  which parseDateValue (d/m) would read with day and month swapped.
      const rows: any[][] = XLSX.utils.sheet_to_json(sheet, {
        header: 1,
        defval: '',
        raw: false,
        dateNF: 'dd/mm/yyyy',
      });
      jobs.push(...this.parseSpecialSheetRows(rows, this.extractDateFromSheetName(sheetName)));
    }

    if (jobs.length === 0) {
      this.SweetAlert('error', 'ไม่พบแถวที่มีทั้งวันที่และเกรดครบถ้วนในชีทที่เลือก');
    }

    this._uploadJobs = jobs;

    this._isCalculatingBags = true;
    try {
      await this.applyMasterGradeBagCounts(jobs);
      //  Mark the calculated rows (blue tint) and catch any row that still
      //  has Bag 0 (e.g. a grade whose first lookup missed).
      for (const bag of jobs.flatMap((j) => j.pallets.flatMap((p) => p.bags))) {
        if ((bag.bag ?? 0) > 0) this.uploadAutoBag.add(bag);
      }
      await this.fillMissingUploadBags(jobs);
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
      this.restService.processGetMasterGrade(gradeCode, '', '', '', '', 1, 20).subscribe(
        (response: Type.ResponseProcessGetMasterGrade) => {
          //  gradeCode is a partial (LIKE) search -- prefer the exact grade
          //  code over the first partial match (same as job-special-detail).
          const rows = response?.data ?? [];
          const key = gradeCode.trim().toUpperCase();
          const row = rows.find((r) => (r.fpd_grade_code || '').trim().toUpperCase() === key);
          const unitRatio = row?.unit_ratio;
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
        'กรุณากรอกข้อมูลที่จำเป็นให้ครบทุก Job (วันที่ / เลขที่เอกสาร / ลูกค้า / ลำดับ / ขนาดพาเลท / เกรด / ถุง / ตัน)',
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
    Notify.fire({
      position: 'center',
      icon: iconn,
      title: 'ข้อความจากระบบ',
      text: alert_message,
      showConfirmButton: true,
    });
  }
}