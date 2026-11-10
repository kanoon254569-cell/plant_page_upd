import { Component, OnDestroy, OnInit } from '@angular/core';
import { Router } from '@angular/router';
import { MatPaginatorIntl, PageEvent } from '@angular/material/paginator';
import { JobListPaginatorIntl } from '../job-list/job-list';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';
import { PermissionService } from '../../services/permission.service';
import Swal from 'sweetalert2';

//  List-only, following the same concept as job-list -> job-detail/:id --
//  Create/Edit/Inspect all navigate to job-wh-internal-transfer-detail/:id
//  (see that component) instead of opening an inline modal here.
@Component({
  selector: 'app-job-wh-internal-transfer-list',
  standalone: false,
  templateUrl: './job-wh-internal-transfer-list.html',
  styleUrls: ['../job-list/job-list.css', './job-wh-internal-transfer-list.css'],
  providers: [{ provide: MatPaginatorIntl, useClass: JobListPaginatorIntl }],
})
export class JobWhInternalTransferList implements OnInit, OnDestroy {
  readonly skeletonRows = Array.from({ length: 4 }, (_, index) => index);
  jobs: Type.ResultProcessInternalTransferJobListData[] = [];
  totalCount = 0;
  isLoading = false;
  jobStatusOptions: Type.ResultProcessGetOptionsJobStatus[] = [];
  //  MWH warehouses (process-cb/location-wh?wh=MWH) -- same options as
  //  job-wh-transfer-list.ts for both WH ต้นทาง and WH ปลายทาง.
  whOptions: Type.ResultProcessGetOptionsWh[] = [];
  //  Same filter shape as job-wh-transfer-list.ts: date range + multi-selects
  //  (empty = ทั้งหมด).
  filter = {
    systemNo: '',
    //  Create-date range (default: today..today).
    dateFrom: new Date() as Date | null,
    dateTo: new Date() as Date | null,
    jobStatuses: [] as number[],
    whFroms: [] as string[],
    whTos: [] as string[],
    //  tr_job_main.product_cc, same header menu as job-wh-transfer-list.ts.
    productCcs: [] as string[],
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  //  "เรียงตาม" options -- same as job-list.ts; value is sortBy:sortOrder of
  //  GET job/internal-transfer ('' = default order, newest job first). See
  //  sql/pProcessGetInternalTransferJobList_sort_10.31.1.75.sql in the API repo.
  readonly sortOptions: { value: string; label: string }[] = [
    { value: '', label: 'ค่าเริ่มต้น' },
    { value: 'job_create_datetime:DESC', label: 'วันที่สร้าง ใหม่ - เก่า' },
    { value: 'job_create_datetime:ASC', label: 'วันที่สร้าง เก่า - ใหม่' },
    { value: 'system_no:ASC', label: 'เลขที่ใบงาน A - Z' },
    { value: 'system_no:DESC', label: 'เลขที่ใบงาน Z - A' },
    { value: 'job_status_id:ASC', label: 'สถานะ เริ่มต้น - เสร็จสิ้น' },
    { value: 'job_status_id:DESC', label: 'สถานะ เสร็จสิ้น - เริ่มต้น' },
  ];

  //  Product CC header menu options -- same list as job-wh-transfer-list.ts.
  productCcOptions: Type.ResultProcessGetOptionsWmsCcCode[] = [];

  private readonly filterStorageKey = 'job-wh-internal-transfer-list-filter';

  //  Same running-duration ticker as job-list.ts -- forces formatDuration()
  //  to recompute every second for a job with no end_datetime yet, instead
  //  of freezing at whatever elapsed time happened to render on load.
  private _durationNowMs: number = Date.now();
  private _durationTickerId: number | null = null;

  //  WMS+ interface log per job, keyed by job id -- same shape/flow as
  //  job-list.ts's _wmsPlusLogStatusMap, loaded in one batch call after
  //  each loadJobs() (see loadWmsPlusLogStatus).
  _wmsPlusLogStatusMap: Record<number, Type.ResultProcessWmsPlusLogGroup> = {};
  //  #wmsPlusDetailModal content -- set on badge click.
  _wmsPlusDetailLogs: Type.ResultProcessWmsPlusLogStatus[] | null = null;
  _wmsPlusDetailJob: Type.ResultProcessInternalTransferJobListData | null = null;
  _wmsPlusDetailPage: number = 1;
  readonly wmsPlusDetailPageSize: number = 1;
  _resendingWmsPlusJobIds: Set<number> = new Set();

  constructor(
    private restService: CrudService,
    private router: Router,
    private permissionService: PermissionService,
  ) {}

  //  Empty-state "create" button -- <app-empty-state> takes the label as an
  //  input, so it can't use *hasPermission like the header button does.
  get canCreateTransfer(): boolean {
    return this.permissionService.has('warehouse.internal_transfer');
  }

  ngOnInit(): void {
    this.restoreFilter();
    this.loadJobStatusOptions();
    this.loadWhOptions();
    this.loadProductCcOptions();
    this.loadJobs();
    this._durationNowMs = Date.now();
    this._durationTickerId = window.setInterval(() => {
      this._durationNowMs = Date.now();
    }, 1000);
  }

  ngOnDestroy(): void {
    if (this._durationTickerId !== null) {
      window.clearInterval(this._durationTickerId);
      this._durationTickerId = null;
    }
  }

  goToCreateTransfer(): void {
    this.router.navigate(['/job-wh-internal-transfer-detail', 0]);
  }

  goToTransferDetail(job: Type.ResultProcessInternalTransferJobListData): void {
    this.router.navigate(['/job-wh-internal-transfer-detail', job.id]);
  }

  clearFilter(): void {
    this.filter = {
      systemNo: '',
      dateFrom: new Date(),
      dateTo: new Date(),
      jobStatuses: [],
      whFroms: [],
      whTos: [],
      productCcs: [],
      page: 1,
      pageSize: this.filter.pageSize,
      sortBy: '',
      sortOrder: '',
    };
    this.loadJobs();
  }

  //  Saved filter -- same sessionStorage flow as job-wh-transfer-list.ts.
  saveFilter(): void {
    const saved = {
      systemNo: this.filter.systemNo ?? '',
      dateFrom: this.formatFilterDate(this.filter.dateFrom),
      dateTo: this.formatFilterDate(this.filter.dateTo),
      jobStatuses: this.filter.jobStatuses ?? [],
      whFroms: this.filter.whFroms ?? [],
      whTos: this.filter.whTos ?? [],
      productCcs: this.filter.productCcs ?? [],
      pageSize: this.filter.pageSize ?? 25,
      sortValue: this.sortValue,
    };
    try {
      sessionStorage.setItem(this.filterStorageKey, JSON.stringify(saved));
    } catch {
      //  Storage blocked/full -- the filter just isn't remembered.
    }
  }

  restoreFilter(): void {
    let saved: any = null;
    try {
      saved = JSON.parse(sessionStorage.getItem(this.filterStorageKey) || 'null');
    } catch {
      saved = null;
    }
    if (!saved || typeof saved !== 'object') return;

    const strings = (value: unknown): string[] =>
      Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];

    this.filter = {
      ...this.filter,
      systemNo: typeof saved.systemNo === 'string' ? saved.systemNo : '',
      //  '' = searched without that date; a missing key keeps today.
      dateFrom: saved.dateFrom === '' ? null : (this.fromFilterDate(saved.dateFrom) ?? this.filter.dateFrom),
      dateTo: saved.dateTo === '' ? null : (this.fromFilterDate(saved.dateTo) ?? this.filter.dateTo),
      jobStatuses: Array.isArray(saved.jobStatuses)
        ? saved.jobStatuses.filter((id: unknown): id is number => typeof id === 'number')
        : [],
      whFroms: strings(saved.whFroms),
      whTos: strings(saved.whTos),
      productCcs: strings(saved.productCcs),
      pageSize: typeof saved.pageSize === 'number' && saved.pageSize > 0 ? saved.pageSize : this.filter.pageSize,
      page: 1,
    };
    if (this.sortOptions.some((option) => option.value === saved.sortValue)) {
      this.sortValue = saved.sortValue;
    }
  }

  get sortValue(): string {
    return this.filter.sortBy ? `${this.filter.sortBy}:${this.filter.sortOrder}` : '';
  }

  set sortValue(value: string) {
    const [sortBy = '', sortOrder = ''] = value.split(':');
    this.filter.sortBy = sortBy;
    this.filter.sortOrder = sortOrder;
  }

  get sortLabel(): string {
    return this.sortOptions.find((option) => option.value === this.sortValue)?.label ?? '';
  }

  onSelectSort(value: string): void {
    this.sortValue = value;
    this.search();
  }

  //  Labels of the selected values, for the closed multi-select's trigger.
  whLabels(codes: string[] | null | undefined): string[] {
    return (codes ?? []).map((code) => {
      const name = this.whOptions.find((option) => option.wh_code === code)?.wh_name;
      return name ? `${code} - ${name}` : code;
    });
  }

  jobStatusLabels(): string[] {
    return (this.filter.jobStatuses ?? []).map(
      (id) => {
        const option = this.jobStatusOptions.find((o) => o.id === id);
        return option?.name_th || option?.name || String(id);
      },
    );
  }

  //  Same ct_job_status options as job-wh-transfer-list.ts (userType 5).
  loadJobStatusOptions(): void {
    this.restService.ProcessGetOptionsJobStatus(5).subscribe({
      next: (response) => (this.jobStatusOptions = response.data ?? []),
      error: (error) => {
        this.jobStatusOptions = [];
        console.error('Error fetching job status options:', error);
      },
    });
  }

  loadProductCcOptions(): void {
    this.restService.ProcessGetOptionsWmsCcCode('MWH').subscribe({
      next: (response) => (this.productCcOptions = response.data ?? []),
      error: (error) => {
        this.productCcOptions = [];
        console.error('Error fetching wms cc code options:', error);
      },
    });
  }

  //  Product CC header menu is multi-select (same as job-wh-transfer-list.ts):
  //  items toggle while the menu stays open, and the search runs once on
  //  close if the picks changed.
  private _productCcsOnOpen: string = '';

  isProductCcSelected(ccCode: string | null | undefined): boolean {
    return !!ccCode && this.filter.productCcs.includes(ccCode);
  }

  toggleProductCc(ccCode: string | null | undefined): void {
    if (!ccCode) return;
    const selected = this.filter.productCcs;
    this.filter.productCcs = selected.includes(ccCode)
      ? selected.filter((code) => code !== ccCode)
      : [...selected, ccCode];
  }

  clearProductCcs(): void {
    this.filter.productCcs = [];
  }

  onProductCcMenuOpened(): void {
    this._productCcsOnOpen = [...this.filter.productCcs].sort().join(',');
  }

  onProductCcMenuClosed(): void {
    if ([...this.filter.productCcs].sort().join(',') !== this._productCcsOnOpen) {
      this.search();
    }
  }

  loadWhOptions(): void {
    this.restService.ProcessGetOptionsLocationWh('MWH').subscribe({
      next: (response) => (this.whOptions = response.data ?? []),
      error: (error) => {
        this.whOptions = [];
        console.error('Error fetching warehouse options:', error);
      },
    });
  }

  search(): void {
    this.filter.page = 1;
    this.loadJobs();
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadJobs();
  }

  loadJobs(): void {
    this.isLoading = true;
    this.saveFilter();

    this.restService
      .processGetInternalTransferJobList(
        this.filter.systemNo || '',
        this.formatFilterDate(this.filter.dateFrom),
        this.formatFilterDate(this.filter.dateTo),
        0,
        this.filter.page,
        this.filter.pageSize,
        0,
        {
          statusIds: this.filter.jobStatuses ?? [],
          fromWhCodes: this.filter.whFroms ?? [],
          toWhCodes: this.filter.whTos ?? [],
          productCcs: this.filter.productCcs ?? [],
          sortBy: this.filter.sortBy,
          sortOrder: this.filter.sortOrder,
        },
      )
      .subscribe({
        next: (response) => {
          this.isLoading = false;
          this.jobs = response.status === 'success' ? (response.data ?? []) : [];
          this.totalCount = response.total_count ?? 0;
          this.loadWmsPlusLogStatus();
        },
        error: (error) => {
          this.isLoading = false;
          this.jobs = [];
          this.totalCount = 0;
          this._wmsPlusLogStatusMap = {};
          console.error('Error fetching internal transfer job list:', error);
        },
      });
  }

  //  1 batch call for every job id on the current page, not 1 per row --
  //  same as job-list.ts's loadWmsPlusLogStatus.
  loadWmsPlusLogStatus(): void {
    this._wmsPlusLogStatusMap = {};

    const jobIds = this.jobs.map((job) => job.id);
    if (jobIds.length === 0) return;

    this.restService.processGetWmsPlusLogStatus(jobIds.join(',')).subscribe({
      next: (response) => {
        (response.data ?? []).forEach((group) => {
          this._wmsPlusLogStatusMap[group.job_main_id] = group;
        });
      },
      error: (error) => console.error('Error loading WMS+ interface log status:', error),
    });
  }

  //  Newest log entry for the job -- drives the badge's success/failed look.
  getWmsPlusStatus(jobId: number): Type.ResultProcessWmsPlusLogStatus | null {
    return this._wmsPlusLogStatusMap[jobId]?.logs?.[0] ?? null;
  }

  //  Full history for the job, newest first -- feeds #wmsPlusDetailModal.
  getWmsPlusLogs(jobId: number): Type.ResultProcessWmsPlusLogStatus[] {
    return this._wmsPlusLogStatusMap[jobId]?.logs ?? [];
  }

  //  Resets to page 1 so switching jobs never leaves an earlier job's later
  //  page showing.
  openWmsPlusDetail(job: Type.ResultProcessInternalTransferJobListData): void {
    this._wmsPlusDetailJob = job;
    this._wmsPlusDetailLogs = this.getWmsPlusLogs(job.id);
    this._wmsPlusDetailPage = 1;
  }

  get pagedWmsPlusDetailLogs(): Type.ResultProcessWmsPlusLogStatus[] {
    const start = (this._wmsPlusDetailPage - 1) * this.wmsPlusDetailPageSize;
    return (this._wmsPlusDetailLogs ?? []).slice(start, start + this.wmsPlusDetailPageSize);
  }

  copyToClipboard(text: string | null): void {
    if (!text) return;
    navigator.clipboard?.writeText(text).catch((error) => console.error('Copy failed:', error));
  }

  //  param is stored as a raw one-line JSON string -- pretty-print it, or
  //  fall back to the raw text if it isn't valid JSON.
  formatJsonPayload(text: string | null): string {
    if (!text) return '-';
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }

  //  WMS+'s reply wraps the real text in {result, message} -- show only the
  //  inner "message" when present, same as job-list.ts's formatWmsMessage.
  formatWmsMessage(text: string | null): string {
    if (!text) return '-';
    try {
      const parsed = JSON.parse(text);
      if (parsed && typeof parsed === 'object' && typeof parsed.message === 'string') {
        return parsed.message;
      }
      return JSON.stringify(parsed, null, 2);
    } catch {
      return text;
    }
  }

  isResendingWmsPlus(jobId: number): boolean {
    return this._resendingWmsPlusJobIds.has(jobId);
  }

  //  Re-sends the WMS+ notification for one job (resend button on a
  //  "Failed" WMS+ badge), then re-reads that job's real log row so the
  //  badge reflects what's actually in tr_wms_plus_interface_log.
  async resendWmsPlus(jobId: number): Promise<void> {
    if (this._resendingWmsPlusJobIds.has(jobId)) return;

    this._resendingWmsPlusJobIds.add(jobId);

    try {
      const response = await new Promise<Type.ResponseProcessResendWmsPlus>((resolve, reject) => {
        this.restService.processResendWmsPlus(jobId).subscribe({
          next: (res) => resolve(res),
          error: (error) => reject(error),
        });
      });

      if (response.wmsPlusStatus === 'not_applicable') {
        this.SweetAlert('info', 'งานนี้ไม่มีขั้นตอนแจ้งเตือน WMS+');
      } else if (response.wmsPlusStatus === 'failed') {
        this.SweetAlert('error', response.wmsPlusMessage || 'ส่งข้อมูลไปยัง WMS+ ไม่สำเร็จ');
      }

      const logResponse = await new Promise<Type.ResponseProcessWmsPlusLogStatus>((resolve, reject) => {
        this.restService.processGetWmsPlusLogStatus(String(jobId)).subscribe({
          next: (res) => resolve(res),
          error: (error) => reject(error),
        });
      });
      const updated = (logResponse.data ?? []).find((group) => group.job_main_id === jobId);
      if (updated) this._wmsPlusLogStatusMap[jobId] = updated;
    } catch (error) {
      console.error('Error resending WMS+ notification:', error);
      this.SweetAlert('error', 'เกิดข้อผิดพลาดขณะส่งข้อมูลไปยัง WMS System');
    } finally {
      this._resendingWmsPlusJobIds.delete(jobId);
    }
  }

  SweetAlert(icon: any, alertMessage: string): void {
    Swal.fire({
      position: 'center',
      icon,
      title: 'ข้อความจากระบบ',
      text: alertMessage,
      showConfirmButton: true,
    });
  }

  //  First item's source location name, mirroring job-list's srcLocation()
  //  -- the real endpoint returns a structured items[] array (each item
  //  carrying a locations.from_location/to_location pair), not the
  //  source_summary/destination_summary STRING_AGG text this list used to read.
  firstLocationName(locations: (Type.ResultInternalTransferJobListLocation | null)[]): string {
    return locations[0]?.name || '-';
  }

  //  First item's grade/lot/qty, mirroring job-list's jobItem(job.id)?.[0]
  //  lead line -- reads items[0] directly instead of regex-parsing a summary
  //  string, since the backend now sends grade/lot_no/qty as real fields.
  firstSourceItem(
    job: Type.ResultProcessInternalTransferJobListData,
  ): { grade: string; lot: string; qty: number } | null {
    const item = job.items?.[0];
    if (!item) return null;

    return {
      grade: item.grade || '-',
      lot: item.lot_no || '',
      qty: item.qty ?? 0,
    };
  }

  sourceLocations(
    job: Type.ResultProcessInternalTransferJobListData,
  ): (Type.ResultInternalTransferJobListLocation | null)[] {
    return job.items?.map((item) => item.locations.from_location) ?? [];
  }

  destinationLocations(
    job: Type.ResultProcessInternalTransferJobListData,
  ): (Type.ResultInternalTransferJobListLocation | null)[] {
    return job.items?.map((item) => item.locations.to_location) ?? [];
  }

  //  CSS class suffix for the status badge, by ct_job_status.id -- same
  //  mapping as job-list.ts's jobStatusClass, picking up the
  //  pending/wh-approved/in-progress/complete/mapping-do palette. By id,
  //  not job_status_name: that now comes back in Thai (name_th).
  statusClass(job: Type.ResultProcessInternalTransferJobListData | null): string {
    switch (job?.job_status_id) {
      case 1: return 'pending';
      case 2: return 'wh-approved';
      case 3: return 'sp-approve';
      case 4: return 'in-progress';
      case 5: return 'complete';
      case 6: return 'mapping-do';
      default: return '';
    }
  }

  //  Real per-item complete_qty is now returned by the backend, so progress
  //  reflects actual completed quantity against total_qty instead of a
  //  guess derived from status.
  progressQty(job: Type.ResultProcessInternalTransferJobListData): number {
    return (job.items ?? []).reduce((sum, item) => sum + (item.complete_qty ?? 0), 0);
  }

  progressPercent(job: Type.ResultProcessInternalTransferJobListData): number {
    const total = job.total_qty ?? 0;
    if (!total) return 0;
    return Math.min(100, Math.round((this.progressQty(job) / total) * 100));
  }

  //  Taken at GET so far -- the blue part of the bar under the green put-away
  //  part. receive_qty is only what is taken and not put yet (fInternalTransferBags
  //  is_received), so the put-away qty is added back.
  receiveQty(job: Type.ResultProcessInternalTransferJobListData): number {
    const received = (job.items ?? []).reduce((sum, item) => sum + (item.receive_qty ?? 0), 0);
    return received + this.progressQty(job);
  }

  receivePercent(job: Type.ResultProcessInternalTransferJobListData): number {
    const total = job.total_qty ?? 0;
    if (!total) return 0;
    return Math.min(100, Math.round((this.receiveQty(job) / total) * 100));
  }

  private formatFilterDate(date: Date | null): string {
    if (!date) return '';

    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  //  Saved yyyy-MM-dd back to a local Date (new Date('yyyy-MM-dd') would be
  //  UTC midnight, not local).
  private fromFilterDate(value: unknown): Date | null {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
    const [year, month, day] = value.split('-').map(Number);
    return new Date(year, month - 1, day);
  }

  //  Same value-display fix as job-list.ts's own parseJobDate. This
  //  endpoint's job_create_datetime comes back as "M/D/YYYY h:mm:ss AM/PM"
  //  (e.g. "9/23/2026 2:18:46 PM") -- the d/m/yyyy regex below doesn't match
  //  that trailing "AM/PM" so it falls through to the native `new Date()`
  //  parse, which does understand that format. Kept as one shared parser
  //  (rather than two) so a d/m/yyyy BE-year string would still work if this
  //  endpoint ever sends one.
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

  //  Ported verbatim from job-list.ts's own formatDateEnd/formatDuration --
  //  same start-end-datetime row, reading job_start_datetime/job_end_datetime
  //  instead of start_datetime/end_datetime.
  formatDateEnd(dateStart?: string | Date | null, dateEnd?: string | Date | null): string {
    if (!dateStart && !dateEnd) return '-';
    if (dateStart && !dateEnd) return 'Now';
    if (!dateEnd) return '-';

    const endDate = this.parseJobDate(dateEnd);
    if (!endDate) return '-';

    const pad = (n: number) => String(n).padStart(2, '0');
    return `${pad(endDate.getDate())}/${pad(endDate.getMonth() + 1)}/${endDate.getFullYear()} ${pad(endDate.getHours())}:${pad(endDate.getMinutes())}:${pad(endDate.getSeconds())}`;
  }

  formatDuration(start?: string | Date | null, end?: string | Date | null): string {
    if (!start) return '-';

    const startDate = this.parseJobDate(start);
    const endDate = end ? this.parseJobDate(end) : new Date(this._durationNowMs);
    if (!startDate || !endDate) return '-';

    const diff = endDate.getTime() - startDate.getTime();
    if (diff < 0) return '-';

    const totalSeconds = Math.floor(diff / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const parts: string[] = [];

    if (hours > 0) parts.push(`${hours} ชม.`);
    if (minutes > 0 || hours > 0) parts.push(`${minutes} นาที`);
    parts.push(`${seconds} วินาที`);
    return parts.join(' ');
  }
}
