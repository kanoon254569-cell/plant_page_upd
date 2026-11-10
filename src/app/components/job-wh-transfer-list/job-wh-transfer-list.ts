import { Component, OnDestroy, OnInit } from '@angular/core';
import { Router } from '@angular/router';
import { MatPaginatorIntl, PageEvent } from '@angular/material/paginator';
import { JobListPaginatorIntl } from '../job-list/job-list';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';
import Swal from 'sweetalert2';

//  WH04 Transfer Warehouse -- job type 11 'TW' (IRPC_E_TRANSFER.dbo.
//  VTransferWhForm, sql/46). Own page like WH03 Internal Transfer, own API
//  GET job/transfer-wh (pProcessGetTransferWhJobList, sql/50), which returns
//  the same shape as GET job (one entry per job with items[] / locations /
//  forklifts). Inspect opens job-wh-transfer-detail/:id.
@Component({
  selector: 'app-job-wh-transfer-list',
  standalone: false,
  templateUrl: './job-wh-transfer-list.html',
  styleUrls: ['../job-list/job-list.css', './job-wh-transfer-list.css'],
  providers: [{ provide: MatPaginatorIntl, useClass: JobListPaginatorIntl }],
})
export class JobWhTransferList implements OnInit, OnDestroy {
  readonly skeletonRows = Array.from({ length: 4 }, (_, index) => index);
  jobs: Type.ResultProcessTransferWhJobListData[] = [];
  totalCount = 0;
  isLoading = false;
  jobStatusOptions: Type.ResultProcessGetOptionsJobStatus[] = [];
  //  MWH warehouses (process-cb/location-wh?wh=MWH) -- options for both
  //  WH ต้นทาง (form source) and WH ปลายทาง (form wh_code).
  whOptions: Type.ResultProcessGetOptionsWh[] = [];
  //  Product CC header menu options -- same list as job-list.ts (MWH cc codes).
  productCcOptions: Type.ResultProcessGetOptionsWmsCcCode[] = [];
  //  WH ต้นทาง / ปลายทาง / สถานะ are multi-selects (empty = ทั้งหมด), same
  //  as job-list's filters.
  filter = {
    systemNo: '',
    //  Create-date range (default: today..today).
    dateFrom: new Date() as Date | null,
    dateTo: new Date() as Date | null,
    jobStatuses: [] as number[],
    whFroms: [] as string[],
    whTos: [] as string[],
    //  tr_job_main.product_cc, same header menu as job-list.ts.
    productCcs: [] as string[],
    page: 1,
    pageSize: 25,
  };

  private readonly filterStorageKey = 'job-wh-transfer-list-filter';

  //  Same running-duration ticker as job-wh-internal-transfer-list.ts.
  private _durationNowMs: number = Date.now();
  private _durationTickerId: number | null = null;

  //  WMS+ interface log per job, keyed by job id -- same flow as
  //  job-wh-internal-transfer-list.ts.
  _wmsPlusLogStatusMap: Record<number, Type.ResultProcessWmsPlusLogGroup> = {};
  _wmsPlusDetailLogs: Type.ResultProcessWmsPlusLogStatus[] | null = null;
  _wmsPlusDetailJob: Type.ResultProcessTransferWhJobListData | null = null;
  _wmsPlusDetailPage: number = 1;
  readonly wmsPlusDetailPageSize: number = 1;
  _resendingWmsPlusJobIds: Set<number> = new Set();

  constructor(
    private restService: CrudService,
    private router: Router,
  ) {}

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

  goToJobDetail(job: Type.ResultProcessTransferWhJobListData): void {
    this.router.navigate(['/job-wh-transfer-detail', job.id]);
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
    };
    this.loadJobs();
  }

  //  Saved filter -- the last searched filter is kept in sessionStorage and
  //  restored on the next visit (same as job-list.ts saveFilter/restoreFilter).
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

  search(): void {
    this.filter.page = 1;
    this.loadJobs();
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadJobs();
  }

  //  Same ct_job_status options as WH01 (userType 5).
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

  //  Product CC header menu is multi-select (same as job-list.ts): items
  //  toggle while the menu stays open, and the search runs once on close if
  //  the picks changed.
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

  //  Card tags, same sources as job-list.ts: the saved tr_job_main value
  //  first for CC, the items' pd_type first for Product Type.
  jobProductCc(job: Type.ResultProcessTransferWhJobListData): string {
    return job.product_cc || this.distinctItemValues(job, 'pd_cc_code');
  }

  jobProductType(job: Type.ResultProcessTransferWhJobListData): string {
    return this.distinctItemValues(job, 'pd_type') || job.product_type || '';
  }

  private distinctItemValues(
    job: Type.ResultProcessTransferWhJobListData,
    field: 'pd_cc_code' | 'pd_type',
  ): string {
    return Array.from(new Set((job.items ?? []).map((item) => item[field]).filter(Boolean))).join(', ');
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

  loadJobs(): void {
    this.isLoading = true;
    this.saveFilter();

    this.restService
      .processGetTransferWhJobList(
        this.filter.systemNo || '',
        this.formatFilterDate(this.filter.dateFrom),
        0,
        this.filter.page,
        this.filter.pageSize,
        0,
        '',
        '',
        {
          statusIds: this.filter.jobStatuses ?? [],
          fromWhCodes: this.filter.whFroms ?? [],
          toWhCodes: this.filter.whTos ?? [],
          productCcs: this.filter.productCcs ?? [],
          dateTo: this.formatFilterDate(this.filter.dateTo),
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
          console.error('Error fetching transfer warehouse job list:', error);
        },
      });
  }

  //  1 batch call for every job id on the current page, not 1 per row.
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

  getWmsPlusStatus(jobId: number): Type.ResultProcessWmsPlusLogStatus | null {
    return this._wmsPlusLogStatusMap[jobId]?.logs?.[0] ?? null;
  }

  getWmsPlusLogs(jobId: number): Type.ResultProcessWmsPlusLogStatus[] {
    return this._wmsPlusLogStatusMap[jobId]?.logs ?? [];
  }

  openWmsPlusDetail(job: Type.ResultProcessTransferWhJobListData): void {
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

  formatJsonPayload(text: string | null): string {
    if (!text) return '-';
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }

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

  firstItem(job: Type.ResultProcessTransferWhJobListData): Type.Item | null {
    return job.items?.[0] ?? null;
  }

  //  Location block -- same logic as job-list.ts (srcLocations/srcLocation/
  //  isFromLocation, destLocations/destLocation/isToLocation, selectJobItems).
  selectedJob: Type.ResultProcessTransferWhJobListData | null = null;

  srcLocations(job: Type.ResultProcessTransferWhJobListData | null): string[] {
    return Array.from(
      new Set(
        (job?.items ?? []).flatMap(
          (item) =>
            item.locations?.from_locations
              .map((location) => location.location_name)
              .filter((locationName): locationName is string => !!locationName) || [],
        ),
      ),
    );
  }

  srcLocation(job: Type.ResultProcessTransferWhJobListData): string {
    return this.srcLocations(job)[0] || `${job.from_location_cc_code || ''} ${job.from_location_cc_desc || ''}`;
  }

  isFromLocation(job: Type.ResultProcessTransferWhJobListData): boolean {
    return this.srcLocations(job).length > 0;
  }

  destLocations(job: Type.ResultProcessTransferWhJobListData | null): string[] {
    return Array.from(
      new Set(
        (job?.items ?? []).flatMap(
          (item) =>
            item.locations?.to_locations
              .map((location) => location.location_name)
              .filter((locationName): locationName is string => !!locationName) || [],
        ),
      ),
    );
  }

  destLocation(job: Type.ResultProcessTransferWhJobListData): string {
    return this.destLocations(job)[0] || `${job.to_location_cc_code || ''} ${job.to_location_cc_desc || ''}`;
  }

  isToLocation(job: Type.ResultProcessTransferWhJobListData): boolean {
    return this.destLocations(job).length > 0;
  }

  selectJobItems(job: Type.ResultProcessTransferWhJobListData): void {
    this.selectedJob = job;
  }

  //  ct_job_status.id -> badge class suffix, same palette as WH03's status
  //  badge. By id, not status_name: that now comes back in Thai (name_th).
  statusClass(job: Type.ResultProcessTransferWhJobListData): string {
    switch (job.status_id) {
      case 1: return 'pending';
      case 2: return 'wh-approved';
      case 3: return 'sp-approve';
      case 4: return 'in-progress';
      case 5: return 'complete';
      case 6: return 'mapping-do';
      default: return '';
    }
  }

  //  Pallets: complete / total, same measure job-list shows for TS/RC.
  progressPercent(job: Type.ResultProcessTransferWhJobListData): number {
    const total = job.total_qty ?? 0;
    if (!total) return 0;
    return Math.min(100, Math.round(((job.complete_qty ?? 0) / total) * 100));
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

  //  Same parser as job-wh-internal-transfer-list.ts's parseJobDate.
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
