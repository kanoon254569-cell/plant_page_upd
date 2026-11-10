import { Component, Injectable, OnDestroy } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import { MatPaginatorIntl, PageEvent } from '@angular/material/paginator';
import Swal from 'sweetalert2';
import { Router } from '@angular/router';
import * as XLSX from 'xlsx';
import { JwtTokenService } from '../../services/jwt-token.service';
import { environment } from '../../../environments/environment';

//  One row per unique item_id within a Special Job's details[] -- the API
//  can return several detail rows sharing the same item_id (e.g. split
//  across lots/pallets), so these get merged into a single selectable row
//  instead of showing the same item multiple times -- see
//  groupedSpecialItems/selectSpecialItem in job-list.ts.
interface GroupedSpecialItem {
  item_id: number;
  grade: string;
  pallet_nos: number[];
  qty: number;
  bag: number;
  lots: Type.SpecialJobItemLot[];
}

//  Thai labels for this page's mat-paginator. Component-level providers are
//  not inherited, so subclasses that want them must list this provider too.
@Injectable()
export class JobListPaginatorIntl extends MatPaginatorIntl {
  override itemsPerPageLabel = 'จำนวนต่อหน้า:';
  override nextPageLabel = 'หน้าถัดไป';
  override previousPageLabel = 'หน้าก่อนหน้า';
  override firstPageLabel = 'หน้าแรก';
  override lastPageLabel = 'หน้าสุดท้าย';
  override getRangeLabel = (page: number, pageSize: number, length: number) => {
    if (length === 0 || pageSize === 0) return `0 จาก ${length}`;
    const start = page * pageSize;
    const end = Math.min(start + pageSize, length);
    return `${start + 1} – ${end} จาก ${length}`;
  };
}

//  Map DO Special table filter.
interface SpecialFilter {
  docNo: string;
  grades: string[];
  dateFrom: Date | null;
  dateTo: Date | null;
}

//  Map DO Shipment (Excel DDO) table filter.
interface ExcelDoFilter {
  text: string;
  grades: string[];
  loadingFrom: Date | null;
  loadingTo: Date | null;
}

@Component({
  selector: 'app-job-list',
  standalone: false,
  templateUrl: './job-list.html',
  styleUrl: './job-list.css',
  providers: [{ provide: MatPaginatorIntl, useClass: JobListPaginatorIntl }],
})
export class JobList implements OnDestroy {
  //  Page code shown in the header (see job-list.html's "{{ pageCode }} -
  //  ..." title) - overridden per subclass so it matches that page's own
  //  sidebar entry (e.g. JobWhOutboundList sets 'WH02' to match sidebar.html's
  //  "WH02 - Outbound"), since this template is shared across several
  //  differently-coded pages.
  pageCode: string = 'WH01';
  //  Fallback title shown when topicName is '' (both jobInbound/jobOutbound
  //  are true, so there's no single "Inbound"/"Outbound" word to show) -
  //  overridden per subclass to match that page's own sidebar entry (e.g.
  //  JobShippingList sets 'Job Shipping List' to match sidebar.html's
  //  "SP01 - Job Shipping List").
  pageTitle: string = 'Job List';
  typeId: number = 0;
  //  job-wh-list (Inbound) / job-wh-outbound-list (Outbound) each lock
  //  filter.jobInbound/jobOutbound to exactly one topic, so the Job Type
  //  dropdown can meaningfully narrow within that topic -- job-shipping-list
  //  sets BOTH to true (see pageTitle comment above) and pins jobType to 5
  //  itself, so showing this dropdown there would offer every job type
  //  (including ones that don't even belong to Shipping) for a filter the
  //  page already hard-codes. Overridden to false there.
  showJobTypeFilter: boolean = true;
  //  WH01 Inbound (job-wh-list) filters "ปลายทาง" by the job's Product CC
  //  (tr_job_main.product_cc, options from process-cb/wms-cc-code?wh=MWH)
  //  instead of the destination location's WH cc_code. Overridden to true
  //  on job-wh-list and job-wh-outbound-list (shipping keeps it off).
  useProductCcFilter: boolean = false;
  //  "ปลายทาง (CC Code)" filter row item -- WH01 Inbound replaces it with
  //  the Product CC header dropdown; other pages keep it.
  showToCcFilter: boolean = true;
  //  "From Plant (CC Code)" filter -- off on job-wh-outbound-list, whose
  //  jobs all start from MWH 4510, so no plant option ever matches.
  showFromCcFilter: boolean = true;
  //  WH01 Inbound "To Warehouse" filter (ct_location.wh_code of the job's
  //  MWH to-locations, options from process-cb/location-wh?wh=MWH).
  //  Overridden to true in job-wh-list only.
  useToWhFilter: boolean = false;
  //  WH02 Outbound "From Location" / "To Location" filters -- grouped by
  //  location type (options from process-cb/job-location, sql/36).
  //  Overridden to true in job-wh-outbound-list only.
  useLocationFilter: boolean = false;
  skeletonRows = Array.from({ length: 5 }, (_, index) => index);

  filter: Type.JobFilter = {
    systemNo: '',
    dateFrom: JobList.thaiToday(),
    dateTo: JobList.thaiToday(),
    fromCcCodes: [],
    toCcCodes: [],
    fromLocations: [],
    toLocations: [],
    productCcs: [],
    toWhCodes: [],
    jobStatuses: [],
    jobType: 0,
    jobTypes: [],
    jobInbound: true,
    jobOutbound: true,
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  //  "เรียงตาม" options -- value is sortBy:sortOrder of GET job ('' = default
  //  order, urgent jobs first). See sql/pProcessGetJobList_sort_10.31.1.74.sql in the API repo.
  readonly sortOptions: { value: string; label: string }[] = [
    { value: '', label: 'ค่าเริ่มต้น' },
    { value: 'job_create_datetime:DESC', label: 'วันที่สร้าง ใหม่ - เก่า' },
    { value: 'job_create_datetime:ASC', label: 'วันที่สร้าง เก่า - ใหม่' },
    { value: 'system_no:ASC', label: 'เลขที่ใบงาน A - Z' },
    { value: 'system_no:DESC', label: 'เลขที่ใบงาน Z - A' },
    { value: 'job_status_id:ASC', label: 'สถานะ เริ่มต้น - เสร็จสิ้น' },
    { value: 'job_status_id:DESC', label: 'สถานะ เสร็จสิ้น - เริ่มต้น' },
  ];

  _jobData!: Type.ResultProcessJobListData[] | null;
  _wmsPlusLogStatusMap: Record<number, Type.ResultProcessWmsPlusLogGroup> = {};
  //  Jobs whose source data changed after the approve calculated
  //  total_pallet, keyed by job id -- loaded in one batch call per page.
  _totalPalletSourceChangedMap: Record<number, Type.ResultTotalPalletSourceChangedItem[]> = {};
  //  #wmsPlusDetailModal content -- set on badge click (see job-list.html).
  //  Full history for the clicked job, newest first.
  _wmsPlusDetailLogs: Type.ResultProcessWmsPlusLogStatus[] | null = null;
  _wmsPlusDetailJob: Type.ResultProcessJobListData | null = null;
  _wmsPlusDetailPage: number = 1;
  readonly wmsPlusDetailPageSize: number = 1;
  totalCount: number = 0;
  _isLoading: boolean = false;
  selectedJob: Type.ResultProcessJobListData | null = null;
  _srcLocation: Type.ResultProcessGetOptionsBgPlant[] | null = null;
  _destLocation: Type.ResultProcessGetOptionsWhCcCode[] | null = null;
  _productCcOptions: Type.ResultProcessGetOptionsWmsCcCode[] | null = null;
  _toWhOptions: Type.ResultProcessGetOptionsWh[] | null = null;
  _jobLocationOptions: Type.ResultProcessGetOptionsJobLocation[] = [];
  //  Search box text inside each From / To Location dropdown panel.
  fromLocationSearch: string = '';
  toLocationSearch: string = '';
  _optionJobStatus: Type.ResultProcessGetOptionsJobStatus[] | null = null;
  _optionJobType: any = [];

  _doFromExcelData: Type.ResultProcessGetDoFromExcel[] | null = null;

  //  Map DO Shipment tab -- pairs one Excel DDO with the shipment already
  //  selected from the sidebar (see selectShipmentAction/onSelectExcelDo).
  //  Only ever holds at most one entry now that mapping targets the
  //  shipment directly instead of a separately-picked local DO record.
  _selectedExcelDo: number | null = null;
  _isSavingMapDo: boolean = false;
  _doMappings: {
    excelData: Type.ResultProcessGetDoFromExcel | null;
    doData: Type.ResultProcessJobShipment | null;
  }[] = [];
  private _durationNowMs: number = Date.now();
  private _durationTickerId: number | null = null;

  //  Upload Shipment Modal
  //  _uploadRows.loadingDate holds a Date (for the matDatepicker) while editing,
  //  and is formatted back to a 'dd/mm/yyyy' string when building the API payload.
  _uploadFileName: string = '';
  _uploadRows: any[] = [];
  _isUploading: boolean = false;

  //  ===================================================================
  //  Shipment List modal (GET job/shipment) -- opened via the header's
  //  "Shipment" button. Each row offers 3 actions: Map DO Shipment (reuses
  //  the Map DO modal above, seeded from the shipment's grade instead of a
  //  job's), Map DO Special (link the shipment to an existing Special Job),
  //  and Create Picking (build a brand-new picking job straight from the
  //  shipment).
  //  ===================================================================
  _shipmentFilter: Type.ShipmentFilter = { shipmentNo: '', deliveryNo: '', statusIds: [], page: 1, pageSize: 10 };
  //  Shipment list loading skeleton: one row per row of the current page
  //  size, so the skeleton fills the list like the data does.
  get shipmentSkeletonRows(): number[] {
    return Array.from({ length: this._shipmentFilter.pageSize || 10 }, (_, i) => i);
  }

  //  VsearchStatus.current_status_id values (see sql/98).
  readonly shipmentStatusOptions = [
    { id: 1, name: 'Create Shipment' },
    { id: 2, name: 'Planning' },
    { id: 3, name: 'Estimate Check in' },
  ];

  //  Closed status multi-select text: picked status names.
  shipmentStatusLabels(): string[] {
    const ids = this._shipmentFilter.statusIds ?? [];
    return this.shipmentStatusOptions.filter((s) => ids.includes(s.id)).map((s) => s.name);
  }
  _shipmentData: Type.ResultProcessJobShipment[] | null = null;
  _shipmentTotalCount: number = 0;
  _isLoadingShipment: boolean = false;
  _selectedShipment: Type.ResultProcessJobShipment | null = null;

  //  Which view is showing inside #shipmentListModal -- 'list' is the
  //  shipment card grid; 'mapDo'/'mapSpecial'/'picking' are the 3 shipment
  //  actions, all living in that SAME modal (switched via the tab bar)
  //  instead of separate ones the user has to close/reopen.
  _shipmentActionTab: 'list' | 'mapDo' | 'mapSpecial' | 'picking' = 'list';

  //  Map DO Special ("Map DO Special" tab of #shipmentListModal) -- each
  //  Special Job groups its own grade/pallet detail items; selection is per
  //  ITEM (_selectedSpecialItemId), not per job, since that's what the
  //  shipment actually links to (see selectSpecialItem/confirmMapDoSpecial).
  _specialJobCandidates: Type.ResultProcessSpecialJobListData[] | null = null;
  _selectedSpecialItemId: number | null = null;
  //  Table rows: one per grouped item, flattened from _specialJobCandidates
  //  on load (first = the job's first item row, which shows the doc no).
  _specialRows: { job: Type.ResultProcessSpecialJobListData; item: GroupedSpecialItem; first: boolean }[] = [];
  _isLoadingSpecial = false;
  //  Filters sent to GET job/special (docNo / grades / dateFrom / dateTo).
  //  _specialFilter is what the inputs edit; _specialAppliedFilter is what
  //  the list was last loaded with (search button / Enter / clear).
  _specialFilter: SpecialFilter = { docNo: '', grades: [], dateFrom: null, dateTo: null };
  private _specialAppliedFilter: SpecialFilter = { docNo: '', grades: [], dateFrom: null, dateTo: null };
  //  Grade filter options: grades of the last unfiltered load, so they do
  //  not shrink to whatever the current filter returned.
  _specialGradeOptions: string[] = [];
  private _expandedSpecialItemIds = new Set<number>();
  _isSavingMapDoSpecial: boolean = false;

  //  Create Picking ("สร้างงาน Picking" tab of #shipmentListModal) -- only
  //  creates the job; locations / forklift / approval are done in job-detail.
  _isSavingCreatePicking: boolean = false;

  statusOptions: string[] = ['Drafted', 'Planned', 'Completed'];
  poStatusOptions: string[] = ['In Approval Process2', 'Approved1', 'Approved2'];
  onPalletOptions: string[] = ['-', 'ONPALLET'];

  private uploadHeaderMap: { [normalizedHeader: string]: keyof Type.RequestImportJobShipmentItem } = {
    ddo: 'ddo',
    loadingdate: 'loadingDate',
    postatus: 'poStatus',
    status: 'status',
    grade: 'grade',
    lot: 'lot',
    qty: 'qty',
    seq: 'seq',
    truckl: 'truckL',
    onpallet: 'onPallet',
    godown: 'godown',
    agent: 'agent',
    truck: 'truck',
    owner: 'owner',
    shippinginstruction: 'shippingInstruction',
  };

  constructor(
    private restService: CrudService,
    private router: Router,
    private jwtService: JwtTokenService,
  ) {}

  ngOnDestroy() {
    if (this._durationTickerId !== null) {
      window.clearInterval(this._durationTickerId);
      this._durationTickerId = null;
    }
  }

  jobItem(jobId: number) {
    return this._jobData?.find((job) => job.id === jobId)?.items;
  }

  //  Product CC / Type tags above the card's Inspect button. CC prefers the
  //  job's saved tr_job_main.product_cc (what the Cost Center filter
  //  matches), falling back to the items' pd_cc_code before Approve; Type
  //  comes from the items' pd_type (same source job-detail defaults from),
  //  falling back to the saved tr_job_main.product_type (Picking items
  //  carry no pd_type).
  jobProductCc(job: Type.ResultProcessJobListData): string {
    return job.product_cc || this.distinctItemValues(job, 'pd_cc_code');
  }

  jobProductType(job: Type.ResultProcessJobListData): string {
    return this.distinctItemValues(job, 'pd_type') || job.product_type || '';
  }

  private distinctItemValues(
    job: Type.ResultProcessJobListData,
    field: 'pd_cc_code' | 'pd_type',
  ): string {
    return Array.from(new Set((job.items ?? []).map((item) => item[field]).filter(Boolean))).join(', ');
  }

  documentJob(jobId: number) {
    var documents = this.jobItem(jobId)?.map((item) => item.document_job);
    if (!documents) return null;
    return documents?.length > 1
      ? documents?.[0] + ' + ' + (documents?.length - 1) + ' more'
      : documents?.[0] || null;
  }

  srcLocations(jobId: number): string[] {
    return Array.from(
      new Set(
        this.jobItem(jobId)?.flatMap(
          (item) =>
            item.locations?.from_locations
              .map((location) => location.location_name)
              .filter((locationName): locationName is string => !!locationName) || [],
        ),
      ),
    );
  }

  srcLocation(jobId: number) {
    const srcLocations = this.srcLocations(jobId);
    const job = this._jobData?.find((job) => job.id === jobId);
    const defaultLocation = job
      ? `${job.from_location_cc_code || ''} ${job.from_location_cc_desc || ''}`
      : null;

    return srcLocations[0] || defaultLocation;
  }

  isFromLocation(jobId: number) {
    const fromLocations = this.srcLocations(jobId);
    return fromLocations.length > 0;
  }

  isToLocation(jobId: number) {
    const toLocations = this.destLocations(jobId);
    return toLocations.length > 0;
  }

  destLocations(jobId: number): string[] {
    return Array.from(
      new Set(
        this.jobItem(jobId)?.flatMap(
          (item) =>
            item.locations?.to_locations
              .map((location) => location.location_name)
              .filter((locationName): locationName is string => !!locationName) || [],
        ),
      ),
    );
  }

  destLocation(jobId: number) {
    const destLocations = this.destLocations(jobId);
    const job = this._jobData?.find((job) => job.id === jobId);
    const defaultLocation = job
      ? `${job.to_location_cc_code || ''} ${job.to_location_cc_desc || ''}`
      : null;

    return destLocations[0] || defaultLocation;
  }

  get topicName() {
    return this.filter.jobInbound && this.filter.jobOutbound
      ? ''
      : this.filter.jobInbound
        ? 'Inbound'
        : this.filter.jobOutbound
          ? 'Outbound'
          : 'No Job Type';
  }

  isJobFromExcel(id: number) {
    return Number(this._jobData?.find((job) => job.id === id)?.source_id) === 2;
  }

  movementUnit(job: Type.ResultProcessJobListData) {
    if (!job) return null;

    return job.movement_unit || null;
  }

  //  Taken at GET so far -- the blue part of the progress bar under the green
  //  put-away part. receive_qty is only what is taken and not put yet
  //  (is_received of the fXxxPallets functions), so complete_qty is added back.
  receiveQty(job: Type.ResultProcessJobListData): number {
    if (!job) return 0;
    return (job.receive_qty || 0) + (job.complete_qty || 0);
  }

  receivePercent(job: Type.ResultProcessJobListData): number {
    const total = job?.total_qty || 0;
    if (!total) return 0;
    return Math.min(100, (this.receiveQty(job) / total) * 100);
  }

  selectJobItems(job: Type.ResultProcessJobListData) {
    this.selectedJob = job;
  }

  //  Items modal: actual qty put so far = sum of the item's PUT locations'
  //  actual_qty (pProcessGetJobList actual_qty_to_location). Outbound PUT rows
  //  (RQ-PLANT etc.) have qty 0 and the put-away procs only write actual_qty
  //  when qty <> 0, so they stay NULL -- use the GET locations' actual_qty then.
  itemActualQty(item: Type.Item): number {
    const toLocations = item.locations?.to_locations ?? [];
    const isPutTracked = toLocations.some((location) => location.qty || location.actual_qty);
    const locations = isPutTracked ? toLocations : (item.locations?.from_locations ?? []);
    return locations.reduce((sum, location) => sum + (location.actual_qty || 0), 0);
  }

  //  Finished job (status 5) whose moved qty (PUT actual_qty) is short of
  //  the WMS+ qty -- the card shows a strip telling the user to finish the
  //  rest in WMS+. Null when nothing is short or the job has no WMS+ log,
  //  except advance orders: they send nothing until the user presses send
  //  in job detail, so a missing log must not hide the shortfall.
  jobQtyShortfall(job: Type.ResultProcessJobListData): { actual: number; qty: number; unit: string } | null {
    if (job.status_id !== 5 || !job.items?.length) return null;
    if (job.is_advance_order !== 'Y' && !this.getWmsPlusLogs(job.id).length) return null;

    const qty = job.items.reduce((sum, item) => sum + (item.qty || 0), 0);
    const actual = job.items.reduce((sum, item) => sum + this.itemActualQty(item), 0);
    if (actual >= qty) return null;

    return { actual, qty, unit: job.items[0].qty_unit || 'kg' };
  }

  lotLocations(item: Type.Item | undefined) {
    if (!item) return [];

    const locationLots = item.locations?.from_locations.flatMap((location) =>
      (location.addon_lot ?? [])
        .filter((addonLot) => !!addonLot.lot?.trim())
        .map((addonLot) => ({
          id: item.id,
          grade: item.grade,
          lotNo: addonLot.lot.trim(),
          qty: addonLot.qty,
        })),
    );

    const lots = locationLots?.length
      ? locationLots
      : item.lot_no?.trim()
        ? [{ id: item.id, grade: item.grade, lotNo: item.lot_no.trim(), qty: item.qty }]
        : [];

    return Array.from(
      lots.reduce((map, lot) => {
        const lotNo = lot.lotNo.replace(/\s+/g, '').toUpperCase();
        const key = lotNo;
        const existingLot = map.get(key);

        if (existingLot) {
          existingLot.qty += lot.qty;
        } else {
          map.set(key, { ...lot });
        }

        return map;
      }, new Map<string, { id: number; grade: string; lotNo: string; qty: number }>()),
    ).map(([, lot]) => lot);
  }

  itemLotDisplay(item: Type.Item): string {
    const locationLots = item.locations?.from_locations.flatMap((location) =>
      (location.addon_lot ?? [])
        .filter((addonLot) => !!addonLot.lot?.trim())
        .map((addonLot) => addonLot.lot.trim()),
    );

    const lotNos = locationLots?.length ? locationLots : item.lot_no?.trim() ? [item.lot_no.trim()] : [];

    return Array.from(new Set(lotNos)).join(', ') || '-';
  }

  get _excelDoCandidates() {
    return this._doFromExcelData || [];
  }

  //  Map DO Shipment filters -- sent to the backend (GET do-from-excel,
  //  needs sql/99). _excelDoFilter is what the inputs edit;
  //  _excelDoAppliedFilter is what the list was last loaded with (set by
  //  the search button / Enter / clear).
  _excelDoFilter: ExcelDoFilter = { text: '', grades: [], loadingFrom: null, loadingTo: null };
  private _excelDoAppliedFilter: ExcelDoFilter = { text: '', grades: [], loadingFrom: null, loadingTo: null };
  _excelDoGradeOptions: string[] = [];
  _isLoadingExcelDo = false;

  private isExcelDoFilterSet(f: ExcelDoFilter): boolean {
    return !!(f.text.trim() || f.grades.length || f.loadingFrom || f.loadingTo);
  }

  //  Inputs have something to clear (clear button).
  hasExcelDoFilter(): boolean {
    return this.isExcelDoFilterSet(this._excelDoFilter);
  }

  //  Table is currently filtered (header count shows x / y).
  isExcelDoFiltered(): boolean {
    return this.isExcelDoFilterSet(this._excelDoAppliedFilter);
  }

  applyExcelDoFilter() {
    this._excelDoAppliedFilter = { ...this._excelDoFilter, grades: [...this._excelDoFilter.grades] };
    this.loadDoFromExcelData();
  }

  clearExcelDoFilter() {
    this._excelDoFilter = { text: '', grades: [], loadingFrom: null, loadingTo: null };
    this.applyExcelDoFilter();
  }

  get selectedExcelDoText() {
    if (!this._selectedExcelDo) return null;
    return this._excelDoCandidates.find((item) => item.id === this._selectedExcelDo)?.ddo || null;
  }

  get isMapping() {
    return this._doMappings.some(
      (mapping) => mapping.excelData !== null || mapping.doData !== null,
    );
  }

  get mapDoData(): {
    excelData: Type.ResultProcessGetDoFromExcel;
    doData: Type.ResultProcessJobShipment;
  }[] {
    const data = this._doMappings.filter(
      (
        mapping,
      ): mapping is {
        excelData: Type.ResultProcessGetDoFromExcel;
        doData: Type.ResultProcessJobShipment;
      } => mapping.excelData !== null && mapping.doData !== null,
    );

    return [...data];
  }

  //  Confirm Map DO: Excel DDO vs Shipment values that differ (warned, not
  //  blocked). Lot only counts when both sides have one.
  isMapDoGradeMismatch(item: { excelData: Type.ResultProcessGetDoFromExcel; doData: Type.ResultProcessJobShipment }): boolean {
    const a = (item.excelData.grade || '').trim().toUpperCase();
    const b = (item.doData.fpdgradecode || '').trim().toUpperCase();
    return !!a && !!b && a !== b;
  }

  isMapDoLotMismatch(item: { excelData: Type.ResultProcessGetDoFromExcel; doData: Type.ResultProcessJobShipment }): boolean {
    const a = (item.excelData.lot || '').trim().toUpperCase();
    const b = (item.doData.pdlotno || '').trim().toUpperCase();
    return !!a && !!b && a !== b;
  }

  mapDoMismatches(item: { excelData: Type.ResultProcessGetDoFromExcel; doData: Type.ResultProcessJobShipment }): string[] {
    return [this.isMapDoGradeMismatch(item) ? 'Grade' : '', this.isMapDoLotMismatch(item) ? 'Lot' : ''].filter(Boolean);
  }

  //  Pairs the clicked Excel DDO straight to the shipment already selected
  //  from the sidebar -- there's only ever one pairing at a time now that
  //  mapping targets the shipment directly (matched via SearchStatus on the
  //  backend) instead of a separately-picked local DO record.
  onSelectExcelDo(excelId: number) {
    this._selectedExcelDo = excelId;

    if (this._selectedShipment) {
      this._doMappings = [
        {
          excelData: this._excelDoCandidates.find((item) => item.id === excelId) || null,
          doData: this._selectedShipment,
        },
      ];
    }
  }

  trackByExcelId(index: number, item: Type.ResultProcessGetDoFromExcel) {
    return item.id;
  }

  rowHasLot(row: any) {
    return row.grade && row.lot && row.grade.trim() !== '' && row.lot.trim() !== '';
  }

  //  toISOString() converts to UTC, so between 00:00-06:59 Thailand time
  //  (UTC+7) it would still report yesterday's date -- shifting by 7 hours
  //  first keeps the default filter on today's Thailand calendar date.
  static thaiToday(): Date {
    const [year, month, day] = new Date(Date.now() + 7 * 60 * 60 * 1000)
      .toISOString()
      .split('T')[0]
      .split('-')
      .map(Number);
    return new Date(year, month - 1, day);
  }

  //  yyyy-MM-dd for the API (and the saved filter), '' when not set.
  toApiDate(value?: Date | string | null): string {
    if (!value) return '';

    const date = new Date(value);
    if (isNaN(date.getTime())) return '';
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');

    return `${year}-${month}-${day}`;
  }

  //  Saved yyyy-MM-dd back to a local Date (new Date('yyyy-MM-dd') would be
  //  UTC midnight, not local).
  private fromApiDate(value: unknown): Date | null {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
    const [year, month, day] = value.split('-').map(Number);
    return new Date(year, month - 1, day);
  }

  //  =====================================================================
  //  Saved filter -- the last searched filter is kept per page in
  //  sessionStorage and restored on the next visit. jobInbound/jobOutbound
  //  (and jobType where the page hides the Job Type tabs) stay fixed by
  //  each subclass's ngOnInit.
  //  =====================================================================

  private get filterStorageKey(): string {
    const topic = `${this.filter.jobInbound ? 'in' : ''}${this.filter.jobOutbound ? 'out' : ''}`;
    return `job-list-filter:${this.pageCode}:${topic}`;
  }

  saveFilter() {
    const saved = {
      systemNo: this.filter.systemNo ?? '',
      dateFrom: this.toApiDate(this.filter.dateFrom),
      dateTo: this.toApiDate(this.filter.dateTo),
      fromCcCodes: this.filter.fromCcCodes ?? [],
      toCcCodes: this.filter.toCcCodes ?? [],
      toWhCodes: this.filter.toWhCodes ?? [],
      fromLocations: this.filter.fromLocations ?? [],
      toLocations: this.filter.toLocations ?? [],
      jobStatuses: this.filter.jobStatuses ?? [],
      productCcs: this.filter.productCcs ?? [],
      jobTypes: this.filter.jobTypes ?? [],
      pageSize: this.filter.pageSize ?? 25,
      sortValue: this.sortValue,
    };
    try {
      sessionStorage.setItem(this.filterStorageKey, JSON.stringify(saved));
    } catch {
      //  Storage blocked/full -- the filter just isn't remembered.
    }
  }

  restoreFilter() {
    let saved: any = null;
    try {
      saved = JSON.parse(sessionStorage.getItem(this.filterStorageKey) || 'null');
    } catch {
      saved = null;
    }
    if (!saved || typeof saved !== 'object') return;

    const strings = (value: unknown): string[] =>
      Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
    const locations = (value: unknown): Type.JobLocationFilter[] =>
      Array.isArray(value)
        ? value
            .filter((item) => item && typeof item.type === 'string')
            .map((item) => ({ type: item.type, key: typeof item.key === 'string' ? item.key : null }))
        : [];

    this.filter = {
      ...this.filter,
      systemNo: typeof saved.systemNo === 'string' ? saved.systemNo : '',
      dateFrom: this.fromApiDate(saved.dateFrom),
      dateTo: this.fromApiDate(saved.dateTo),
      fromCcCodes: strings(saved.fromCcCodes),
      toCcCodes: strings(saved.toCcCodes),
      toWhCodes: strings(saved.toWhCodes),
      fromLocations: locations(saved.fromLocations),
      toLocations: locations(saved.toLocations),
      jobStatuses: Array.isArray(saved.jobStatuses)
        ? saved.jobStatuses.filter((id: unknown): id is number => typeof id === 'number')
        : [],
      //  Older saves kept a single productCc string.
      productCcs: Array.isArray(saved.productCcs)
        ? strings(saved.productCcs)
        : typeof saved.productCc === 'string' && saved.productCc
          ? [saved.productCc]
          : [],
      //  Older saves kept a single jobType (0 = ทั้งหมด).
      jobTypes: !this.showJobTypeFilter
        ? []
        : Array.isArray(saved.jobTypes)
          ? saved.jobTypes.filter((id: unknown): id is number => typeof id === 'number')
          : typeof saved.jobType === 'number' && saved.jobType > 0
            ? [saved.jobType]
            : [],
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

  onSelectSort(value: string) {
    this.sortValue = value;
    this.onClickSearch();
  }

  //  Labels of the selected values, for the closed multi-select's trigger
  //  (job-list.html #multiTrigger: first label + a "+N" pill).
  fromCcLabels(): string[] {
    return (this.filter.fromCcCodes ?? []).map((code) => {
      const name = this._srcLocation?.find((option) => option?.bg_plant_code === code)?.bg_plant_location;
      return name ? `${code} - ${name}` : code;
    });
  }

  //  Plant names only (e.g. "HD Plant") for the closed From Plant select.
  fromCcNames(): string[] {
    return (this.filter.fromCcCodes ?? []).map(
      (code) => this._srcLocation?.find((option) => option?.bg_plant_code === code)?.bg_plant_location || code,
    );
  }

  toCcLabels(): string[] {
    return (this.filter.toCcCodes ?? []).map((code) => {
      const name = this._destLocation?.find((option) => option?.cc_code === code)?.cc_desc;
      return name ? `${code} - ${name}` : code;
    });
  }

  toWhLabels(): string[] {
    return (this.filter.toWhCodes ?? []).map(
      (code) => this._toWhOptions?.find((option) => option?.wh_code === code)?.wh_name ?? code,
    );
  }

  jobStatusLabels(): string[] {
    return (this.filter.jobStatuses ?? []).map(
      (id) => {
        const option = this._optionJobStatus?.find((o) => o.id === id);
        return option?.name_th || option?.name || String(id);
      },
    );
  }

  //  API dates come back either as ISO (local/mock backend) or as
  //  d/m/yyyy HH:mm:ss with a Buddhist-Era year (real qas-qtrack backend,
  //  e.g. "28/8/2569 7:52:16" for 2026-08-28) -- `new Date(...)` can't
  //  parse the latter and silently yields Invalid Date, which is why
  //  times/durations render as '-' only once deployed against the real API.
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

  formatDate(date: string | Date | null): string {
    const d = this.parseJobDate(date);
    if (!d) return '-';

    const pad = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  formatDateEnd(dateStart?: string | Date | null, dateEnd?: string | Date | null): string {
    if (!dateStart && !dateEnd) return '-';
    if (dateStart && !dateEnd) return 'Now';
    if (!dateEnd) return '-';

    const endDate = this.parseJobDate(dateEnd);

    if (!endDate) return '-';

    const pad = (n: number) => String(n).padStart(2, '0');

    //  Same dd/MM/yyyy HH:mm:ss format as the start datetime beside it.
    return `${pad(endDate.getDate())}/${pad(endDate.getMonth() + 1)}/${endDate.getFullYear()} ${pad(endDate.getHours())}:${pad(endDate.getMinutes())}:${pad(endDate.getSeconds())}`;
  }

  formatDuration(start?: string | Date | null, end?: string | Date | null): string {
    if (!start) return '-';

    const startDate = this.parseJobDate(start);
    const endDate = end ? this.parseJobDate(end) : new Date(this._durationNowMs);

    if (!startDate || !endDate) {
      return '-';
    }

    const diff = endDate.getTime() - startDate.getTime();
    if (diff < 0) {
      return '-';
    }

    const totalSeconds = Math.floor(diff / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const parts: string[] = [];

    if (hours > 0) {
      parts.push(`${hours} ชม.`);
    }

    if (minutes > 0 || hours > 0) {
      parts.push(`${minutes} นาที`);
    }

    parts.push(`${seconds} วินาที`);
    return parts.join(' ');
  }

  async ngOnInit() {
    this.restoreFilter();
    this._durationNowMs = Date.now();
    this._durationTickerId = window.setInterval(() => {
      this._durationNowMs = Date.now();
    }, 1000);

    //  loadJobData() (the slow one -- hits pProcessGetJobList) and the 3
    //  dropdown-option fetches below don't depend on each other's results
    //  (loadJobData only ever sets this._jobData/totalCount internally,
    //  never returns anything the others need), but used to run one after
    //  another -- 4 sequential round trips stacked on top of the slowest
    //  one. Run them concurrently instead: total wait becomes ~max of the
    //  4 instead of their sum.
    const [, bgPlant, whCcCode, jobStatus, jobType] = await Promise.all([
      this.loadJobData(),
      this.fetchOptionBgPlant(),
      this.fetchWhCcCode(),
      this.fetchOptionJobStatus(this.typeId),
      this.fetchOptionJobType(),
    ]);

    this._srcLocation = bgPlant.data;
    this._destLocation = whCcCode.data;
    this._optionJobStatus = jobStatus.data;
    this._optionJobType = jobType.data;

    if (this.useProductCcFilter) {
      this._productCcOptions = (await this.fetchProductCcOptions()).data;
    }

    if (this.useToWhFilter) {
      this._toWhOptions = (await this.fetchToWhOptions()).data;
    }

    if (this.useLocationFilter) {
      this._jobLocationOptions = (await this.fetchJobLocationOptions()).data ?? [];
    }
  }

  //  ct_job_type rows carry their own topic ('Inbound'/'Outbound') -- narrowed
  //  to whichever side(s) this page's filter.jobInbound/jobOutbound actually
  //  cover, so job-wh-list only offers Transfer Slip/Receive while
  //  job-wh-outbound-list offers Request/Picking/Shipping/etc, instead of
  //  every job type showing on every page regardless of topic.
  get jobTypeOptions(): Type.ResultProcessGetOptionsJobType[] {
    //  is_list = 'N' (Loading / Internal Transfer) -- pProcessGetJobList has
    //  no branch for those types, so their tabs would always be empty.
    //  `!== 'N'` rather than `=== 'Y'` so tabs still show before
    //  sql/33_ct_job_type_is_list.sql adds the column.
    return this._optionJobType.filter(
      (option: Type.ResultProcessGetOptionsJobType) =>
        option.is_list !== 'N' &&
        ((this.filter.jobInbound && option.topic === 'Inbound') ||
          (this.filter.jobOutbound && option.topic === 'Outbound')),
    );
  }

  onClickSearch() {
    this.filter.page = 1;
    this.loadJobData();
  }

  //  Product CC header menu is multi-select: items toggle while the menu
  //  stays open, and the search runs once on close if the picks changed.
  private _productCcsOnOpen: string = '';

  isProductCcSelected(ccCode: string | null | undefined): boolean {
    return !!ccCode && (this.filter.productCcs ?? []).includes(ccCode);
  }

  toggleProductCc(ccCode: string | null | undefined) {
    if (!ccCode) return;
    const selected = this.filter.productCcs ?? [];
    this.filter.productCcs = selected.includes(ccCode)
      ? selected.filter((code) => code !== ccCode)
      : [...selected, ccCode];
  }

  clearProductCcs() {
    this.filter.productCcs = [];
  }

  onProductCcMenuOpened() {
    this._productCcsOnOpen = [...(this.filter.productCcs ?? [])].sort().join(',');
  }

  onProductCcMenuClosed() {
    if ([...(this.filter.productCcs ?? [])].sort().join(',') !== this._productCcsOnOpen) {
      this.onClickSearch();
    }
  }

  //  Job Type tabs are multi-select: a tab toggles its type, ทั้งหมด (0)
  //  clears the picks; each click searches right away.
  onSelectJobType(id: number) {
    const selected = this.filter.jobTypes ?? [];
    this.filter.jobTypes =
      id === 0 ? [] : selected.includes(id) ? selected.filter((typeId) => typeId !== id) : [...selected, id];
    this.onClickSearch();
  }

  isJobTypeSelected(id: number): boolean {
    return (this.filter.jobTypes ?? []).includes(id);
  }

  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadJobData();
  }

  onClickSort() {
    this.filter.sortOrder = this.filter.sortOrder === 'desc' ? 'asc' : 'desc';
    this.loadJobData();
  }

  goToJobDetail(id: number) {
    this.router.navigate(['/job-detail', id]);
  }

  //  WMS+ report of a TS / RC (WH01 Inbound) or RQ (WH02 Outbound) job --
  //  same report names as WMS+ web's crud.service DownLoadPrint*Link. null =
  //  no document button: other job types have no report here, header_id is
  //  0 when the job has no WMS+ header, and the document stays hidden while
  //  the job's latest WMS+ log is an error (a job with no log yet still
  //  shows it). Any job status.
  private static readonly documentReportNames: Record<string, Record<string, string>> = {
    Inbound: { TS: 'TransferSlip', RC: 'ReceiveForm' },
    Outbound: { RQ: 'RequestForm' },
  };

  jobDocumentUrl(job: Type.ResultProcessJobListData): string | null {
    const reportName = JobList.documentReportNames[job.type_topic]?.[job.type_short_name];
    if (!reportName || !job.header_id) return null;
    const latestLog = this.getWmsPlusStatus(job.id);
    if (latestLog && latestLog.is_success !== 'Y') return null;
    return `${environment.wmsReportURL}/${reportName}?headerId=${job.header_id}`;
  }

  //  jobInbound/jobOutbound (and jobType on pages that hide the Job Type
  //  dropdown, e.g. job-shipping-list) are fixed per page by each subclass's
  //  ngOnInit -- keep them on Clear. Resetting them to true/true/0 made
  //  job-wh-list (WH01) and job-wh-outbound-list (WH02) both show inbound +
  //  outbound jobs after Clear, as if the two lists shared one filter.
  resetFilter() {
    this.filter = {
      systemNo: '',
      //  The API falls back to today when no date is sent, so Clear shows
      //  today in the range picker too instead of an empty one.
      dateFrom: JobList.thaiToday(),
      dateTo: JobList.thaiToday(),
      fromCcCodes: [],
      toCcCodes: [],
      productCcs: [],
      toWhCodes: [],
      fromLocations: [],
      toLocations: [],
      jobStatuses: [],
      jobType: this.filter.jobType,
      jobTypes: [],
      jobInbound: this.filter.jobInbound,
      jobOutbound: this.filter.jobOutbound,
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };
  }

  //  =====================================================================
  //  Shipment List (GET job/shipment)
  //  =====================================================================

  openShipmentListModal() {
    this._shipmentActionTab = 'list';
    this._selectedShipment = null;
    this._shipmentFilter = { shipmentNo: '', deliveryNo: '', statusIds: [], page: 1, pageSize: 10 };
    this.loadShipmentData();
  }

  //  Clears the right-hand action panel back to its placeholder -- the
  //  shipment list on the left (and the modal itself) never goes anywhere,
  //  only the right side's content changes.
  backToShipmentList() {
    this._shipmentActionTab = 'list';
    this._selectedShipment = null;
  }

  //  Cancel button on the mapDo/mapSpecial/picking footers -- unlike
  //  backToShipmentList (used after a successful save, which stays on the
  //  shipment list inside the still-open modal), Cancel should actually
  //  close #shipmentListModal.
  onCancelShipmentAction() {
    this.backToShipmentList();
    this.closeModalById('shipmentListModal');
  }

  onClickSearchShipment() {
    this._shipmentFilter.page = 1;
    this.loadShipmentData();
  }

  //  Clear button next to the search -- every shipment filter back to empty.
  onClearShipmentFilter() {
    this._shipmentFilter = { shipmentNo: '', deliveryNo: '', statusIds: [], page: 1, pageSize: this._shipmentFilter.pageSize ?? 10 };
    this.loadShipmentData();
  }

  hasShipmentFilter(): boolean {
    const f = this._shipmentFilter;
    return !!(f.shipmentNo || f.deliveryNo || f.statusIds?.length || f.loadingFrom || f.loadingTo);
  }

  //  Local date (not toISOString, which shifts to UTC and can land on the
  //  day before) as yyyy-MM-dd for the API.
  private toShipmentDateParam(d?: Date | null): string {
    if (!d) return '';
    const p = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  onShipmentPageEvent(event: PageEvent): void {
    this._shipmentFilter.page = event.pageIndex + 1;
    this._shipmentFilter.pageSize = event.pageSize;
    this.loadShipmentData();
  }

  async loadShipmentData() {
    this._isLoadingShipment = true;

    try {
      const result = await this.fetchJobShipmentList(
        this._shipmentFilter.shipmentNo || '',
        this._shipmentFilter.deliveryNo || '',
        this._shipmentFilter.page || 1,
        this._shipmentFilter.pageSize || 10,
        {
          statusIds: this._shipmentFilter.statusIds ?? [],
          loadingFrom: this.toShipmentDateParam(this._shipmentFilter.loadingFrom),
          loadingTo: this.toShipmentDateParam(this._shipmentFilter.loadingTo),
        },
      );
      this._shipmentData = result.data;
      this._shipmentTotalCount = result.total_count;

      //  Auto-select the first row (defaulting to the Map DO Shipment tab)
      //  whenever nothing is selected yet, so the right-hand action panel
      //  and its modal-footer are already showing as soon as the shipment
      //  list has data, instead of staying on the placeholder until the
      //  user clicks a row first.
      if (!this._selectedShipment && this._shipmentData.length > 0) {
        this.selectShipmentAction(this._shipmentData[0], this.currentOrDefaultTab());
      }
    } catch (error) {
      console.error('Error loading shipment list:', error);
      this._shipmentData = [];
      this._shipmentTotalCount = 0;
    } finally {
      this._isLoadingShipment = false;
    }
  }

  trackByShipment(index: number, row: Type.ResultProcessJobShipment) {
    return `${row.shipmentno}-${row.deliveryno}`;
  }

  //  job/shipment returns one row per delivery line -- the same shipmentno
  //  can appear several times with a different deliveryno/grade/qty each
  //  (see the left-pane shipment list, grouped by this). Each delivery line
  //  is still what gets picked for an action (map/picking work against a
  //  specific shipmentNo+deliveryNo pair), so the grouping is purely visual.
  get groupedShipmentData(): { shipmentno: string; rows: Type.ResultProcessJobShipment[] }[] {
    const rows = this._shipmentData || [];
    const groups = new Map<string, Type.ResultProcessJobShipment[]>();
    const order: string[] = [];

    for (const row of rows) {
      const key = row.shipmentno || '-';
      if (!groups.has(key)) {
        groups.set(key, []);
        order.push(key);
      }
      groups.get(key)!.push(row);
    }

    return order.map((shipmentno) => ({ shipmentno, rows: groups.get(shipmentno)! }));
  }

  trackByShipmentGroup(index: number, group: { shipmentno: string }) {
    return group.shipmentno;
  }

  //  Maps the shipment's free-text status (current_status from local
  //  dock/weigh tracking, falling back to WMS's own status) onto the same
  //  pending/in-progress/complete/cancelled badge palette job-list-card
  //  already uses for job status (see .badge .pending/.in-progress/... in
  //  job-list.css) -- keeps shipment cards visually consistent with job cards.
  //  "estimate" is checked before the generic check-in/progress keywords so
  //  an anticipated event ("Estimate Check in") still reads as pending
  //  (amber) rather than in-progress (blue) -- only an event that has
  //  actually started/happened earns the busier colors.
  shipmentStatusClass(row: Type.ResultProcessJobShipment): string {
    const text = (row.current_status || row.status || '').toLowerCase();
    if (!text) return 'pending';
    if (text.includes('cancel') || text.includes('ยกเลิก')) return 'cancelled';
    if (text.includes('complete') || text.includes('out') || text.includes('เสร็จ')) return 'complete';
    if (text.includes('estimate')) return 'pending';
    if (
      text.includes('progress') ||
      text.includes('loading') ||
      text.includes('weight') ||
      text.includes('check in') ||
      text.includes('checkin')
    ) {
      return 'in-progress';
    }
    if (text.includes('create')) return 'created';
    return 'pending';
  }

  //  Shared entrypoint for all 3 shipment actions -- called both by the
  //  shipment card's action buttons (list view) and by the left-pane
  //  shipment list / tab bar once already inside the split "map" view (see
  //  .shipment-map-left / .shipment-action-tabs in job-list.html), so
  //  picking a different shipment or a different tab always re-seeds the
  //  right dataset instead of showing stale data from the previous shipment.
  selectShipmentAction(
    shipment: Type.ResultProcessJobShipment,
    tab: 'mapDo' | 'mapSpecial' | 'picking',
  ) {
    this._selectedShipment = shipment;
    this._shipmentActionTab = tab;

    if (tab === 'mapDo') {
      //  Excel DDO candidates get paired straight to this shipment on click
      //  -- see onSelectExcelDo. No local DO lookup needed anymore; mapping
      //  targets the shipment (shipmentNo/deliveryNo) directly, matched via
      //  SearchStatus on the backend.
      this._selectedExcelDo = null;
      this._doMappings = [];
      this.loadDoFromExcelData();
    } else if (tab === 'mapSpecial') {
      //  A table of Special Job items (filtered on the backend, see
      //  _specialFilter) that links the chosen ITEM to this shipment via
      //  processMapShipmentSpecial.
      this._selectedSpecialItemId = null;
      this._specialJobCandidates = null;
      this.loadSpecialJobCandidates();
    }
  }

  //  Whether two shipment rows refer to the same shipment -- used to
  //  highlight the active row in the split view's left-pane shipment list
  //  (see .shipment-map-item.active in job-list.html). Shipments have no
  //  local id (job/shipment reads live from WMS), so (shipmentno,
  //  deliveryno) is the natural key.
  //  Clicking a shipment row's info area (rather than one of its 3 action
  //  icon buttons) re-seeds whatever action is already showing on the right;
  //  defaults to 'mapDo' before any action has been picked yet.
  currentOrDefaultTab(): 'mapDo' | 'mapSpecial' | 'picking' {
    return this._shipmentActionTab === 'list' ? 'mapDo' : this._shipmentActionTab;
  }

  isSameShipment(
    a: Type.ResultProcessJobShipment,
    b: Type.ResultProcessJobShipment | null,
  ): boolean {
    return !!b && a.shipmentno === b.shipmentno && a.deliveryno === b.deliveryno;
  }

  //  Shipment table "explain" button -- which DO rows have their detail row
  //  (CC/WH, lot, dates, pallets, remark) open, keyed by shipmentno|deliveryno.
  private _expandedShipmentKeys = new Set<string>();

  private shipmentKey(row: Type.ResultProcessJobShipment): string {
    return `${row.shipmentno}|${row.deliveryno}`;
  }

  isShipmentExpanded(row: Type.ResultProcessJobShipment): boolean {
    return this._expandedShipmentKeys.has(this.shipmentKey(row));
  }

  toggleShipmentExpanded(row: Type.ResultProcessJobShipment) {
    const key = this.shipmentKey(row);
    if (!this._expandedShipmentKeys.delete(key)) this._expandedShipmentKeys.add(key);
  }

  //  Same "explain" toggle for the Map DO Shipment (Excel DDO) table, by id.
  private _expandedExcelDoIds = new Set<number>();

  isExcelDoExpanded(id: number): boolean {
    return this._expandedExcelDoIds.has(id);
  }

  toggleExcelDoExpanded(id: number) {
    if (!this._expandedExcelDoIds.delete(id)) this._expandedExcelDoIds.add(id);
  }

  hasSpecialFilter(): boolean {
    const f = this._specialFilter;
    return !!(f.docNo.trim() || f.grades.length || f.dateFrom || f.dateTo);
  }

  applySpecialFilter() {
    this._specialAppliedFilter = { ...this._specialFilter, grades: [...this._specialFilter.grades] };
    this.loadSpecialJobCandidates();
  }

  clearSpecialFilter() {
    this._specialFilter = { docNo: '', grades: [], dateFrom: null, dateTo: null };
    this.applySpecialFilter();
  }

  async loadSpecialJobCandidates() {
    const f = this._specialAppliedFilter;
    this._isLoadingSpecial = true;
    this._specialRows = [];
    try {
      const result = await this.fetchSpecialJobCandidates({
        docNo: f.docNo.trim(),
        grades: f.grades,
        dateFrom: this.toSpecialDateParam(f.dateFrom),
        //  pProcessGetSpecialJobList compares create_datetime <= dateTo
        //  (midnight), so send the next day to include the whole end date.
        dateTo: this.toSpecialDateParam(f.dateTo, 1),
      });
      this._specialJobCandidates = result.data;
      if (!f.grades.length) {
        this._specialGradeOptions = Array.from(
          new Set((result.data || []).flatMap((job) => (job.details || []).map((d) => d.grade)).filter(Boolean)),
        ).sort();
      }
    } catch (error) {
      console.error('Error loading special job candidates:', error);
      this._specialJobCandidates = [];
    } finally {
      this._isLoadingSpecial = false;
    }
    //  The backend keeps jobs that have a picked grade; other-grade items of
    //  those jobs are hidden here too.
    const grades = f.grades;
    this._specialRows = (this._specialJobCandidates || []).flatMap((job) =>
      this.groupedSpecialItems(job)
        .filter((item) => !grades.length || grades.includes(item.grade))
        .map((item, i) => ({ job, item, first: i === 0 })),
    );
  }

  //  dd/MM/yyyy for job/special (TRY_CONVERT(DATE, ..., 103) in the proc).
  private toSpecialDateParam(d: Date | null, addDays = 0): string {
    if (!d) return '';
    const x = new Date(d);
    x.setDate(x.getDate() + addDays);
    const p = (n: number) => String(n).padStart(2, '0');
    return `${p(x.getDate())}/${p(x.getMonth() + 1)}/${x.getFullYear()}`;
  }

  trackBySpecialRow(index: number, r: { item: GroupedSpecialItem }) {
    return r.item.item_id;
  }

  isSpecialExpanded(itemId: number): boolean {
    return this._expandedSpecialItemIds.has(itemId);
  }

  toggleSpecialExpanded(itemId: number) {
    if (!this._expandedSpecialItemIds.delete(itemId)) this._expandedSpecialItemIds.add(itemId);
  }

  //  Lot column: distinct lot numbers of the item (qty per lot is in the
  //  explain row).
  specialItemLotNames(item: GroupedSpecialItem): string {
    return Array.from(new Set(item.lots.map((l) => l.lot).filter(Boolean))).join(', ') || '-';
  }

  specialItemLots(item: GroupedSpecialItem): string {
    return item.lots.map((l) => `${l.lot} (${l.qty})`).join(', ') || '-';
  }

  //  Selection is per detail/pallet item, not per Special Job -- one job can
  //  hold several grade/pallet items, and the backend (pProcessSpecialMapDO,
  //  via @special_item_id) links the shipment to a specific one of those,
  //  not the job as a whole.
  selectSpecialItem(itemId: number) {
    this._selectedSpecialItemId = this._selectedSpecialItemId === itemId ? null : itemId;
  }

  trackBySpecialJob(index: number, job: Type.ResultProcessSpecialJobListData) {
    return job.id;
  }

  //  Merges job.details[] rows that share the same item_id into one row --
  //  summing qty/bag and combining their lots[] -- so the picker shows
  //  exactly one selectable entry per real item instead of one per detail
  //  row (which can repeat an item_id across several lots/pallets).
  groupedSpecialItems(job: Type.ResultProcessSpecialJobListData): GroupedSpecialItem[] {
    const rows = job.details || [];
    const byItemId = new Map<number, GroupedSpecialItem>();
    const order: number[] = [];

    for (const row of rows) {
      if (!byItemId.has(row.item_id)) {
        byItemId.set(row.item_id, {
          item_id: row.item_id,
          grade: row.grade,
          pallet_nos: [],
          qty: 0,
          bag: 0,
          lots: [],
        });
        order.push(row.item_id);
      }

      const group = byItemId.get(row.item_id)!;
      if (!group.pallet_nos.includes(row.pallet_no)) group.pallet_nos.push(row.pallet_no);
      group.qty += row.qty || 0;
      group.bag += row.bag || 0;
      group.lots.push(...(row.lots || []));
    }

    return order.map((itemId) => byItemId.get(itemId)!);
  }

  trackBySpecialItem(index: number, item: GroupedSpecialItem) {
    return item.item_id;
  }

  async confirmMapDoSpecial() {
    if (!this._selectedShipment || !this._selectedSpecialItemId || this._isSavingMapDoSpecial) {
      return;
    }

    this._isSavingMapDoSpecial = true;

    try {
      const payload: Type.RequestMapShipmentSpecial = {
        items: [
          {
            shipmentNo: this._selectedShipment.shipmentno,
            deliveryNo: this._selectedShipment.deliveryno,
            specialJobItemId: this._selectedSpecialItemId,
          },
        ],
      };

      const response = await this.requestMapShipmentSpecial(payload);
      if (response.status === 'success') {
        this.SweetAlert('success', 'จับคู่ Special Job สำเร็จ');
        this._selectedSpecialItemId = null;
        this.backToShipmentList();
        this.loadShipmentData();
      } else {
        this.SweetAlert('error', 'Message : ' + (response?.message ?? ''));
      }
    } catch (error) {
      this.SweetAlert('error', 'Message : Error see in log.');
      console.error(error);
    } finally {
      this._isSavingMapDoSpecial = false;
    }
  }

  get pickingWarehouseCode(): 'A41' | 'A43' | 'MWH' {
    const code = this._selectedShipment?.whcode?.trim().toUpperCase();
    return code === 'A41' || code === 'A43' ? code : 'MWH';
  }

  //  Locations / forklift are set in job-detail now, so only a shipment is
  //  needed to create the job.
  canSubmitCreatePicking(): boolean {
    return !!this._selectedShipment;
  }

  async confirmCreatePicking() {
    if (!this.canSubmitCreatePicking() || this._isSavingCreatePicking) return;

    const shipment = this._selectedShipment!;
    this._isSavingCreatePicking = true;

    try {
      //  Locations / forklift are chosen in job-detail, so none are sent here.
      const payload: Type.RequestCreatePickingJobItem = {
        shipmentNo: shipment.shipmentno,
        deliveryNo: shipment.deliveryno,
        grade: shipment.fpdgradecode,
        lot: shipment.pdlotno,
        qty: shipment.qty,
        ccCode: shipment.cccode,
        whCode: shipment.whcode,
        fromLocations: [],
        toLocations: [],
        forklifts: [],
      };

      const response = await this.requestCreatePickingJob(payload);
      if (response.status === 'success') {
        //  job_main_id comes from sql/100; open the new job in job-detail to
        //  set locations / forklift and approve it there.
        const jobId = Number((response as any)?.data?.job_main_id) || 0;
        this.backToShipmentList();
        if (jobId > 0) {
          this.closeModalImmediately('shipmentListModal');
          this.goToJobDetail(jobId);
        } else {
          this.router.navigate(['/job-detail'], { queryParams: jobId > 0 ? { jobId } : {} });
          this.closeModalById('shipmentListModal');
        }
      } else {
        this.SweetAlert('error', 'Message : ' + (response?.message ?? ''));
      }
    } catch (error) {
      this.SweetAlert('error', 'Message : Error see in log.');
      console.error(error);
    } finally {
      this._isSavingCreatePicking = false;
    }
  }

  async onSubmitMapDo() {
    if (this.mapDoData.length === 0) {
      return;
    }

    //  Shown on top of #shipmentListModal (which stays open underneath) --
    //  see the #mapDoConfirmModal stacking rules in job-list.overlays.css.
    const confirmModalEl = document.getElementById('mapDoConfirmModal');
    if (!confirmModalEl) return;

    //  Bootstrap drops body.modal-open when any modal hides; put it back
    //  while the shipment list is still open behind.
    confirmModalEl.addEventListener(
      'hidden.bs.modal',
      () => {
        if (document.getElementById('shipmentListModal')?.classList.contains('show')) {
          document.body.classList.add('modal-open');
        }
      },
      { once: true },
    );

    const confirmModalInstance =
      (window as any)['bootstrap']?.Modal.getInstance(confirmModalEl) ??
      new (window as any)['bootstrap'].Modal(confirmModalEl);
    confirmModalInstance.show();
  }

  async confirmMapDo() {
    if (this.mapDoData.length === 0 || this._isSavingMapDo) {
      return;
    }

    this._isSavingMapDo = true;

    try {
      const payload = {
        items: this.mapDoData.map((item) => ({
          excelId: item.excelData!.id,
          excelDdo: item.excelData!.ddo,
          shipmentNo: item.doData!.shipmentno,
          deliveryNo: item.doData!.deliveryno,
        })),
      };

      const response = await this.requestMapDo(payload);
      if (response.status === 'success') {
        this.closeModalById('mapDoConfirmModal');
        this._doMappings = [];
        this.backToShipmentList();
        this.loadShipmentData();
      } else {
        this.SweetAlert('error', 'Message : ' + (response?.message ?? ''));
      }
    } catch (error) {
      this.SweetAlert('error', 'Message : Error see in log.');
      console.error(error);
    } finally {
      this._isSavingMapDo = false;
    }
  }

  //  The shipment list stays open under the confirm modal, so just close it.
  cancelMapDoConfirm() {
    this.closeModalById('mapDoConfirmModal');
  }

  trackByMapDoItem(
    index: number,
    item: { excelData: Type.ResultProcessGetDoFromExcel; doData: Type.ResultProcessJobShipment },
  ) {
    return `${item.excelData.id}-${item.doData.shipmentno}-${item.doData.deliveryno}`;
  }

  async loadJobData() {
    this._isLoading = true;
    this.saveFilter();

    try {
      const result = await this.fetchJobData(
        this.filter.systemNo || '',
        '',
        '',
        0,
        this.showJobTypeFilter ? 0 : this.filter.jobType || 0,
        this.topicName || '',
        this.filter.page || 1,
        this.filter.pageSize || 25,
        '',
        '',
        null,
        null,
        {
          dateFrom: this.toApiDate(this.filter.dateFrom),
          dateTo: this.toApiDate(this.filter.dateTo),
          fromCcCodes: this.showFromCcFilter ? this.filter.fromCcCodes ?? [] : [],
          toCcCodes: this.showToCcFilter ? this.filter.toCcCodes ?? [] : [],
          toWhCodes: this.useToWhFilter ? this.filter.toWhCodes ?? [] : [],
          statusIds: this.filter.jobStatuses ?? [],
          fromLocations: this.useLocationFilter ? this.filter.fromLocations ?? [] : [],
          toLocations: this.useLocationFilter ? this.filter.toLocations ?? [] : [],
          productCcs: this.useProductCcFilter ? this.filter.productCcs ?? [] : [],
          typeIds: this.showJobTypeFilter ? this.filter.jobTypes ?? [] : [],
        },
        this.filter.sortBy || '',
        this.filter.sortOrder || '',
      );
      this._jobData = result.data;
      this.totalCount = result.total_count;
      await Promise.all([this.loadWmsPlusLogStatus(), this.loadTotalPalletSourceChanged()]);
    } catch (error) {
      console.error('Error loading job list:', error);
      this._jobData = [];
      this.totalCount = 0;
    } finally {
      this._isLoading = false;
    }
  }

  //  1 batch call for every job id on the current page, not 1 per row --
  //  see processGetWmsPlusLogStatus in crud.service.ts.
  async loadWmsPlusLogStatus() {
    this._wmsPlusLogStatusMap = {};

    const jobIds = (this._jobData ?? []).map((job) => job.id);
    if (jobIds.length === 0) return;

    try {
      const response = await new Promise<Type.ResponseProcessWmsPlusLogStatus>((resolve, reject) => {
        this.restService.processGetWmsPlusLogStatus(jobIds.join(',')).subscribe(
          (res: Type.ResponseProcessWmsPlusLogStatus) => resolve(res),
          (error) => reject(error),
        );
      });

      (response.data ?? []).forEach((group) => {
        this._wmsPlusLogStatusMap[group.job_main_id] = group;
      });
    } catch (error) {
      console.error('Error loading WMS+ interface log status:', error);
    }
  }

  //  Same batch pattern as loadWmsPlusLogStatus. A failure only hides the
  //  badge, never the list.
  async loadTotalPalletSourceChanged() {
    this._totalPalletSourceChangedMap = {};

    const jobIds = (this._jobData ?? []).map((job) => job.id);
    if (jobIds.length === 0) return;

    try {
      const response = await new Promise<Type.ResponseProcessTotalPalletSourceChanged>((resolve, reject) => {
        this.restService.processGetTotalPalletSourceChanged(jobIds.join(',')).subscribe(
          (res: Type.ResponseProcessTotalPalletSourceChanged) => resolve(res),
          (error) => reject(error),
        );
      });

      (response.data ?? []).forEach((group) => {
        this._totalPalletSourceChangedMap[group.job_main_id] = group.items;
      });
    } catch (error) {
      console.error('Error loading total pallet source changes:', error);
    }
  }

  //  Changed items of the job, or null when its source is unchanged.
  getTotalPalletSourceChanged(jobId: number): Type.ResultTotalPalletSourceChangedItem[] | null {
    const items = this._totalPalletSourceChangedMap[jobId];
    return items && items.length > 0 ? items : null;
  }

  //  One changed item as "old -> new".
  private totalPalletSourceChangedLine(item: Type.ResultTotalPalletSourceChangedItem): string {
    const qty = (value: number | null) => (value == null ? '-' : value.toLocaleString('en-US'));
    if (item.change_type === 'removed') return `${item.old_grade ?? '-'} ${qty(item.old_qty)} : ถูกลบ`;
    if (item.change_type === 'added') return `${item.new_grade ?? '-'} ${qty(item.new_qty)} : เพิ่มใหม่`;
    return `${item.old_grade ?? '-'} ${qty(item.old_qty)} (${item.old_cost_center ?? '-'}) → ${item.new_grade ?? '-'} ${qty(item.new_qty)} (${item.new_cost_center ?? '-'})`;
  }

  //  Strip text under the card: every changed item on one line.
  totalPalletSourceChangedSummary(items: Type.ResultTotalPalletSourceChangedItem[]): string {
    return items.map((item) => this.totalPalletSourceChangedLine(item)).join(' · ');
  }

  //  Strip tooltip: one line per changed item, for when the strip text is cut off.
  totalPalletSourceChangedTitle(items: Type.ResultTotalPalletSourceChangedItem[]): string {
    return items.map((item) => this.totalPalletSourceChangedLine(item)).join('\n');
  }

  //  Newest log entry for the job -- drives the badge's success/failed look.
  getWmsPlusStatus(jobId: number): Type.ResultProcessWmsPlusLogStatus | null {
    return this._wmsPlusLogStatusMap[jobId]?.logs?.[0] ?? null;
  }

  //  Full history for the job, newest first -- feeds #wmsPlusDetailModal.
  getWmsPlusLogs(jobId: number): Type.ResultProcessWmsPlusLogStatus[] {
    return this._wmsPlusLogStatusMap[jobId]?.logs ?? [];
  }

  //  WMS+ interfaces QTrack already sent successfully for the job (e.g.
  //  ['WMS211', 'WMS212']), one per mode, in mode order -- shown on the
  //  qty-shortfall strip.
  wmsPlusDoneModes(jobId: number): string[] {
    const modes = this.getWmsPlusLogs(jobId)
      .filter((log) => log.is_success === 'Y' && !!log.mode)
      .map((log) => log.mode as string);
    return Array.from(new Set(modes)).sort();
  }

  //  #wmsPlusDetailModal open -- badge click (see job-list.html). Resets to
  //  page 1 so switching jobs never leaves an earlier job's later page showing.
  openWmsPlusDetail(job: Type.ResultProcessJobListData) {
    this._wmsPlusDetailJob = job;
    this._wmsPlusDetailLogs = this.getWmsPlusLogs(job.id);
    this._wmsPlusDetailPage = 1;
  }

  get pagedWmsPlusDetailLogs(): Type.ResultProcessWmsPlusLogStatus[] {
    const start = (this._wmsPlusDetailPage - 1) * this.wmsPlusDetailPageSize;
    return (this._wmsPlusDetailLogs ?? []).slice(start, start + this.wmsPlusDetailPageSize);
  }

  //  #wmsPlusDetailModal's payload copy button.
  copyToClipboard(text: string | null) {
    if (!text) return;
    navigator.clipboard?.writeText(text).catch((error) => console.error('Copy failed:', error));
  }

  //  #wmsPlusDetailModal's Payload box -- param is stored as a raw one-line
  //  JSON string; pretty-print with indent so items[] etc. are readable.
  //  Falls back to the raw text if it isn't valid JSON.
  formatJsonPayload(text: string | null): string {
    if (!text) return '-';
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }

  //  #wmsPlusDetailModal's Message box -- WMS+'s own reply wraps the real
  //  text in {result, message}; showing that whole envelope (e.g.
  //  {"result":[{"column1":1}],"message":"OK"}) is just noise, so pull the
  //  inner "message" out when present. Falls back to the full pretty-printed
  //  JSON for shapes without that field, or the raw text if not JSON.
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

  _resendingWmsPlusJobIds: Set<number> = new Set();

  isResendingWmsPlus(jobId: number): boolean {
    return this._resendingWmsPlusJobIds.has(jobId);
  }

  //  Re-sends the WMS+ confirm-location notification for one job (see
  //  job-list.html's resend button on a "Failed" WMS+ badge) -- the backend
  //  rebuilds the payload from current DB state, so this just needs the job
  //  id. Re-reads that one job's real log row afterwards (mode/message/
  //  create_datetime) rather than fabricating the badge update from the
  //  resend response, so the badge always reflects what's actually in
  //  tr_wms_plus_interface_log.
  async resendWmsPlus(jobId: number) {
    if (this._resendingWmsPlusJobIds.has(jobId)) return;

    this._resendingWmsPlusJobIds.add(jobId);

    try {
      const response = await new Promise<Type.ResponseProcessResendWmsPlus>((resolve, reject) => {
        this.restService.processResendWmsPlus(jobId).subscribe(
          (res: Type.ResponseProcessResendWmsPlus) => resolve(res),
          (error) => reject(error),
        );
      });

      if (response.wmsPlusStatus === 'not_applicable') {
        this.SweetAlert('info', 'งานนี้ไม่มีขั้นตอนแจ้งเตือน WMS+');
      } else if (response.wmsPlusStatus === 'failed') {
        this.SweetAlert('error', response.wmsPlusMessage || 'ส่งข้อมูลไปยัง WMS+ ไม่สำเร็จ');
      }

      const logResponse = await new Promise<Type.ResponseProcessWmsPlusLogStatus>((resolve, reject) => {
        this.restService.processGetWmsPlusLogStatus(String(jobId)).subscribe(
          (res: Type.ResponseProcessWmsPlusLogStatus) => resolve(res),
          (error) => reject(error),
        );
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

  //  Loads the Excel DDO list with the applied Map DO filters (server-side).
  //  An unfiltered load also refreshes the Grade filter's options, so the
  //  options don't shrink to whatever the current filter returned.
  async loadDoFromExcelData() {
    const f = this._excelDoAppliedFilter;
    this._isLoadingExcelDo = true;
    try {
      this._doFromExcelData = (
        await this.fetchDoFromExcel({
          search: f.text.trim(),
          grades: f.grades,
          loadingFrom: this.toShipmentDateParam(f.loadingFrom),
          loadingTo: this.toShipmentDateParam(f.loadingTo),
        })
      ).data;
      if (!this.isExcelDoFiltered()) {
        this._excelDoGradeOptions = Array.from(
          new Set((this._doFromExcelData || []).map((item) => item.grade).filter(Boolean)),
        ).sort();
      }
    } finally {
      this._isLoadingExcelDo = false;
    }
  }

  requestMapDo(data: any): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.restService.processMapDo(data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error) => {
          console.error('Error mapping DO:', error);
          reject(error);
        },
      );
    });
  }

  fetchJobShipmentList(
    shipmentNo: string,
    deliveryNo: string,
    page: number,
    pageSize: number,
    filters: { statusIds?: number[]; loadingFrom?: string; loadingTo?: string } = {},
  ): Promise<Type.ResponseProcessJobShipmentListData> {
    return new Promise((resolve, reject) => {
      this.restService.processGetJobShipmentList(shipmentNo, deliveryNo, page, pageSize, filters).subscribe(
        (response: Type.ResponseProcessJobShipmentListData) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching job shipment list:', error);
          reject(error);
        },
      );
    });
  }

  //  isApprove='Y' -- Map DO Special should only offer pallets that have
  //  already been approved (tr_special_detail.is_approve), not every pallet
  //  in the job.
  fetchSpecialJobCandidates(f: {
    docNo: string;
    grades: string[];
    dateFrom: string;
    dateTo: string;
  }): Promise<Type.ResponseProcessSpecialJobListData> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetSpecialJobList(0, encodeURIComponent(f.docNo), f.dateFrom, f.dateTo, 0, 0, 1, 50, '', '', 'Y', f.grades)
        .subscribe(
        (response: Type.ResponseProcessSpecialJobListData) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching special job candidates:', error);
          reject(error);
        },
      );
    });
  }

  requestMapShipmentSpecial(data: Type.RequestMapShipmentSpecial): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.restService.processMapShipmentSpecial(data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error) => {
          console.error('Error mapping shipment to special job:', error);
          reject(error);
        },
      );
    });
  }

  requestCreatePickingJob(
    data: Type.RequestCreatePickingJobItem,
  ): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.restService.processCreatePickingJob(data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error) => {
          console.error('Error creating picking job:', error);
          reject(error);
        },
      );
    });
  }

  private openModalById(modalId: string) {
    const modalEl = document.getElementById(modalId);
    if (!modalEl) return;

    const modalInstance =
      (window as any)['bootstrap']?.Modal.getInstance(modalEl) ??
      new (window as any)['bootstrap'].Modal(modalEl);
    modalInstance.show();
  }

  //  Hides a modal without waiting for its fade-out -- for when the page
  //  navigates away right after (the fade showed this page underneath first).
  //  Bootstrap's backdrop / body lock are cleared by hand because this
  //  component is destroyed before the fade would remove them.
  private closeModalImmediately(modalId: string) {
    this.closeModalById(modalId);
    document.querySelectorAll('.modal-backdrop').forEach((el) => el.remove());
    document.body.classList.remove('modal-open');
    document.body.style.removeProperty('overflow');
    document.body.style.removeProperty('padding-right');
  }

  private closeModalById(modalId: string) {
    const modalEl = document.getElementById(modalId);
    if (!modalEl) return;

    const modalInstance =
      (window as any)['bootstrap']?.Modal.getInstance(modalEl) ??
      new (window as any)['bootstrap'].Modal(modalEl);
    modalInstance.hide();
  }

  fetchJobData(
    systemNo: string,
    fromCcCode: string,
    toCcCode: string,
    jobStatus: number,
    jobType: number,
    topicName: string = '',
    page: number = 1,
    pageSize: number = 25,
    productCc: string = '',
    toWhCode: string = '',
    fromLocation: Type.JobLocationFilter | null = null,
    toLocation: Type.JobLocationFilter | null = null,
    multi: Type.JobListMultiFilter | null = null,
    sortBy: string = '',
    sortOrder: string = '',
  ): Promise<Type.ResponseProcessJobListData> {
    return new Promise((resolve, reject) => {
      this.restService
        .processGetJobList(
          0,
          systemNo,
          fromCcCode,
          toCcCode,
          jobStatus,
          jobType,
          topicName,
          page,
          pageSize,
          sortBy,
          sortOrder,
          productCc,
          toWhCode,
          fromLocation,
          toLocation,
          multi,
        )
        .subscribe(
          (response: Type.ResponseProcessJobListData) => {
            resolve(response);
          },
          (error) => {
            console.error('Error fetching job data:', error);
            reject(error);
          },
        );
    });
  }

  fetchDoFromExcel(
    filters: { search?: string; grades?: string[]; loadingFrom?: string; loadingTo?: string } = {},
  ): Promise<Type.ResponseProcessGetDoFromExcel> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetDoFromExcel('', '', filters).subscribe(
        (response: Type.ResponseProcessGetDoFromExcel) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching do from excel data:', error);
          reject(error);
        },
      );
    });
  }

  fetchWhCcCode(): Promise<Type.ResponseProcessGetOptionsWhCcCode> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsWhCcCode().subscribe(
        (response: Type.ResponseProcessGetOptionsWhCcCode) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching wh cc code options:', error);
          reject(error);
        },
      );
    });
  }

  //  Options for WH01 Inbound's "ปลายทาง (Product CC)" filter.
  fetchProductCcOptions(): Promise<Type.ResponseProcessGetOptionsWmsCcCode> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsWmsCcCode('MWH').subscribe(
        (response: Type.ResponseProcessGetOptionsWmsCcCode) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching wms cc code options:', error);
          reject(error);
        },
      );
    });
  }

  //  Options for WH02 Outbound's "From / To Location" filters.
  fetchJobLocationOptions(): Promise<Type.ResponseProcessGetOptionsJobLocation> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsJobLocation().subscribe(
        (response: Type.ResponseProcessGetOptionsJobLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching job location options:', error);
          reject(error);
        },
      );
    });
  }

  //  Options narrowed by the panel's search box. A group header (key null)
  //  stays when its type matches or any of its locations does; when only
  //  the type matches, the whole group is kept.
  filteredLocationOptions(search: string): Type.ResultProcessGetOptionsJobLocation[] {
    const text = (search || '').trim().toLowerCase();
    if (!text) return this._jobLocationOptions;

    const typeMatches = (option: Type.ResultProcessGetOptionsJobLocation) =>
      option.type_name.toLowerCase().includes(text) || option.location_type.toLowerCase().includes(text);

    return this._jobLocationOptions.filter((option) => {
      if (typeMatches(option)) return true;
      if (option.location_key === null) {
        return this._jobLocationOptions.some(
          (child) =>
            child.location_type === option.location_type &&
            child.location_key !== null &&
            child.label.toLowerCase().includes(text),
        );
      }
      return option.label.toLowerCase().includes(text);
    });
  }

  toLocationFilter(option: Type.ResultProcessGetOptionsJobLocation): Type.JobLocationFilter {
    return { type: option.location_type, key: option.location_key };
  }

  compareLocationFilter = (
    a: Type.JobLocationFilter | null,
    b: Type.JobLocationFilter | null,
  ): boolean => (a?.type ?? null) === (b?.type ?? null) && (a?.key ?? null) === (b?.key ?? null);

  //  Group header icon in the From / To Location dropdown.
  locationTypeIcon(type: string): string {
    const icons: Record<string, string> = {
      MWH: 'warehouse',
      'BG-PLANT': 'factory',
      'RQ-PLANT': 'precision_manufacturing',
      'PRE-ZONE': 'grid_view',
      'SPC-ZONE': 'star',
      DOCK: 'local_shipping',
      'REPLACE-ZONE': 'autorenew',
    };
    return icons[type] ?? 'place';
  }

  locationsFilterLabels(values: Type.JobLocationFilter[] | null | undefined): string[] {
    return (values ?? []).map((value) => this.locationFilterLabel(value));
  }

  //  Text on the closed select: the location alone ("HD Plant"), or the
  //  type name when the whole type is picked ("Request Plant").
  locationFilterLabel(value: Type.JobLocationFilter | null | undefined): string {
    if (!value) return 'ทั้งหมด';
    const header = this._jobLocationOptions.find(
      (option) => option.location_type === value.type && option.location_key === null,
    );
    const typeName = header?.type_name ?? value.type;
    if (value.key === null) return typeName;
    const option = this._jobLocationOptions.find(
      (item) => item.location_type === value.type && item.location_key === value.key,
    );
    return option?.label ?? value.key;
  }

  //  Options for WH01 Inbound's "To Warehouse" filter.
  fetchToWhOptions(): Promise<Type.ResponseProcessGetOptionsWh> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsLocationWh('MWH').subscribe(
        (response: Type.ResponseProcessGetOptionsWh) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching location wh options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionJobStatus(userType: number): Promise<Type.ResponseProcessGetOptionsJobStatus> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsJobStatus(userType).subscribe(
        (response: Type.ResponseProcessGetOptionsJobStatus) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching job status options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionJobType(): Promise<Type.ResponseProcessGetOptionsJobType> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsJobType().subscribe(
        (response: Type.ResponseProcessGetOptionsJobType) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching job type options:', error);
          reject(error);
        },
      );
    });
  }

  fetchOptionBgPlant(): Promise<Type.ResponseProcessGetOptionsBgPlant> {
    return new Promise((resolve, reject) => {
      this.restService.ProcessGetOptionsBgPlant().subscribe(
        (response: Type.ResponseProcessGetOptionsBgPlant) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching bg plant options:', error);
          reject(error);
        },
      );
    });
  }

  //  Status badge modifier class by ct_job_status.id -- status_name now
  //  comes back in Thai (name_th), so it can no longer be kebab-cased into
  //  the .pending/.wh-approved/... classes.
  jobStatusClass(statusId?: number | null): string {
    switch (statusId) {
      case 1: return 'pending';
      case 2: return 'wh-approved';
      case 3: return 'sp-approve';
      case 4: return 'in-progress';
      case 5: return 'complete';
      case 6: return 'mapping-do';
      default: return '';
    }
  }

  replaceWhiteSpaceWithDash(input: string): string {
    return input.replace(/\s+/g, '-').toLowerCase();
  }

  private normalizeHeader(header: string): string {
    return (header || '')
      .toString()
      .replace(/[^a-zA-Z0-9]/g, '')
      .toLowerCase();
  }

  private pad2(value: number): string {
    return String(value).padStart(2, '0');
  }

  //  Spreadsheet-style auto-fit: size an <input> to its current value length
  //  (clamped) so the table's auto column-layout widens/narrows to fit real data.
  inputSize(value: any, min: number = 6, max: number = 40): number {
    const text = value === null || value === undefined ? '' : String(value);
    return Math.min(Math.max(text.length + 2, min), max);
  }

  private formatDateDMY(date: Date): string {
    return `${this.pad2(date.getDate())}/${this.pad2(date.getMonth() + 1)}/${date.getFullYear()}`;
  }

  private excelValueToDate(value: any): Date | null {
    if (value instanceof Date && !isNaN(value.getTime())) {
      return value;
    }

    if (typeof value === 'number') {
      const parsed = XLSX.SSF.parse_date_code(value);
      if (parsed) {
        return new Date(parsed.y, parsed.m - 1, parsed.d);
      }
    }

    if (typeof value === 'string' && value.trim()) {
      const match = value.trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
      if (match) {
        const [, d, m, y] = match;
        return new Date(Number(y), Number(m) - 1, Number(d));
      }

      const parsedDate = new Date(value);
      if (!isNaN(parsedDate.getTime())) {
        return parsedDate;
      }
    }

    return null;
  }

  //  Truck.L must always be displayed/stored with exactly 2 decimal places
  //  (e.g. 1.00, 12.10, 1.30, 2.33). A plain [(ngModel)] on a number input
  //  can't keep trailing zeros, so we keep a formatted text twin (truckLText)
  //  in sync with the numeric value (truckL) used in the API payload.
  private round2(value: any): number {
    const num = typeof value === 'number' ? value : Number(value) || 0;
    return Math.round((num + Number.EPSILON) * 100) / 100;
  }

  formatTruckL(row: any) {
    row.truckL = this.round2(row.truckLText);
    row.truckLText = row.truckL.toFixed(2);
  }

  resetUploadForm() {
    this._uploadFileName = '';
    this._uploadRows = [];
    this._isUploading = false;
  }

  onFileSelected(event: Event) {
    const input = event.target as HTMLInputElement;
    const file = input.files && input.files[0];
    if (!file) return;

    this._uploadFileName = file.name;

    const reader = new FileReader();
    reader.onload = (loadEvent: any) => {
      try {
        const data = new Uint8Array(loadEvent.target.result);
        const workbook = XLSX.read(data, { type: 'array', cellDates: true });
        const sheet = workbook.Sheets[workbook.SheetNames[0]];
        const rawRows: any[] = XLSX.utils.sheet_to_json(sheet, { defval: '' });

        this._uploadRows = rawRows.map((raw) => {
          const row: any = this.emptyUploadRow();

          Object.keys(raw).forEach((key) => {
            const field = this.uploadHeaderMap[this.normalizeHeader(key)];
            if (!field) return;

            const value = raw[key];

            if (field === 'loadingDate') {
              (row as any)[field] = this.excelValueToDate(value);
            } else if (field === 'qty' || field === 'seq' || field === 'truckL') {
              (row as any)[field] = typeof value === 'number' ? value : Number(value) || 0;
            } else if (field === 'status' || field === 'poStatus') {
              const options = field === 'status' ? this.statusOptions : this.poStatusOptions;
              const normalized = (value ?? '').toString().trim();
              (row as any)[field] = options.includes(normalized) ? normalized : '';
            } else if (field === 'onPallet') {
              const normalized = (value ?? '').toString().trim().toUpperCase();
              (row as any)[field] = normalized === 'ONPALLET' ? 'ONPALLET' : '-';
            } else {
              (row as any)[field] = value;
            }
          });

          row.truckL = this.round2(row.truckL);
          row.truckLText = row.truckL.toFixed(2);

          return row;
        });
      } catch (error) {
        console.error('Error parsing excel file:', error);
        this.SweetAlert('error', 'ไม่สามารถอ่านไฟล์ Excel ได้ กรุณาตรวจสอบรูปแบบไฟล์');
      }
    };
    reader.readAsArrayBuffer(file);

    input.value = '';
  }

  //  Shared blank-row shape -- used both as the per-row default when parsing
  //  an Excel file (any column the sheet doesn't map to keeps this value)
  //  and as the row appended by addUploadRow() below.
  private emptyUploadRow(): any {
    return {
      ddo: '',
      loadingDate: null,
      poStatus: '',
      status: '',
      grade: '',
      lot: '',
      qty: 0,
      seq: 0,
      truckL: 0,
      truckLText: '0.00',
      onPallet: '-',
      godown: '',
      agent: '',
      truck: '',
      owner: '',
      shippingInstruction: '',
    };
  }

  //  Lets a row be added by hand (see upload-method-card "เพิ่มด้วยตนเอง" in
  //  the template) instead of only via Excel import, mirroring
  //  job-special-list.ts's addUploadJob().
  addUploadRow() {
    this._uploadRows.push(this.emptyUploadRow());
  }

  removeUploadRow(index: number) {
    this._uploadRows.splice(index, 1);
  }

  //  Totals shown in the upload-summary-row stat boxes (see
  //  job-special-list.ts's totalUploadPallets/totalUploadBags/totalUploadTon
  //  for the equivalent on the Special Job upload modal).
  totalUploadQty(): number {
    return this._uploadRows.reduce((sum, row) => sum + (Number(row.qty) || 0), 0);
  }

  totalUploadTruckL(): number {
    return this._uploadRows.reduce((sum, row) => sum + (Number(row.truckL) || 0), 0);
  }

  onSubmitUploadShipment() {
    if (this._uploadRows.length === 0 || this._isUploading) return;

    this._isUploading = true;

    const payload: Type.RequestImportJobShipmentItem[] = this._uploadRows.map((row) => {
      const { truckLText, ...rest } = row;
      return {
        ...rest,
        loadingDate:
          row.loadingDate instanceof Date
            ? this.formatDateDMY(row.loadingDate)
            : row.loadingDate || '',
        truckL: this.round2(row.truckL),
      };
    });

    this.restService.processImportJobShipment(payload).subscribe(
      (data: Type.ResponseStandard) => {
        this._isUploading = false;

        if (data && data.status === 'success') {
          this.SweetAlert('success', 'นำเข้าข้อมูลสำเร็จ');

          const modalEl = document.getElementById('uploadShipmentModal');
          if (modalEl) {
            const modalInstance =
              (window as any)['bootstrap']?.Modal.getInstance(modalEl) ??
              new (window as any)['bootstrap'].Modal(modalEl);
            modalInstance.hide();
          }

          this.resetUploadForm();
          this.loadJobData();
        } else {
          this.SweetAlert('error', 'Message : ' + (data?.message ?? ''));
        }
      },
      (error) => {
        this._isUploading = false;
        this.SweetAlert('error', error?.error?.message || 'เกิดข้อผิดพลาดในการนำเข้าข้อมูล');
        console.error(error);
      },
    );
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
