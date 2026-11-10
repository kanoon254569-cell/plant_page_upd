import { Component, OnInit } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import Swal from 'sweetalert2';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';
import { confirmOfflineForklift } from '../../services/offline-forklift-confirm';

type InternalTransferForm = {
  sourceRemark: string;
  destinationRemark: string;
  isUrgent: string;
  isMultiForklift: string;
  isAdvanceOrder: string;
};

//  Same shape as job-detail.ts's own ForkliftForm -- copied rather than
//  imported since job-detail's type isn't exported, and this page's
//  forklift picker (search/select/confirm-close modal flow) is otherwise a
//  straight port of job-detail's own working implementation.
type ForkliftForm = FormGroup<{
  id: FormControl<number | null>;
  forkliftName: FormControl<string | null>;
  whCode: FormControl<string | null>;
  sectionName: FormControl<string | null>;
  currentUserId: FormControl<number | null>;
  currentUserName: FormControl<string | null>;
  currentThaiName: FormControl<string | null>;
  currentEngName: FormControl<string | null>;
  isOnline: FormControl<boolean | null>;
  jobCount: FormControl<number | null>;
  isChecked: FormControl<boolean | null>;
  isSelected: FormControl<boolean | null>;
  isRead: FormControl<string | null>;
}>;

//  ct_forklift.section_id values -- same mapping as job-detail.ts's
//  FORKLIFT_SECTION_OPTIONS / pProcessGetForkliftAvailable.
const FORKLIFT_SECTION_OPTIONS = [
  { id: '1', name: 'Warehouse' },
  { id: '2', name: 'Loading' },
  { id: '3', name: 'Pallet' },
];

type SelectedTransferPallet = {
  id: number | null;
  palletNo: string;
  grade: string | null;
  lot: string | null;
  qty: number;
  text: string | null;
  scannedQrCode: string | null;
};

type SelectedTransferLocation = {
  index: number;
  locationId: number | null;
  locationType: string | null;
  ccCode: string | null;
  grade: string | null;
  gradeId: number | null;
  lotNo: string | null;
  locationName: string | null;
  availableQty: number | null;
  confirmQty: number | null;
  actualQty: number | null;
  isSelected: boolean | null;
  remark: string | null;
  selectedPallets: SelectedTransferPallet[] | null;
};

//  Reached only from job-wh-internal-transfer-list (Create Transfer / Edit /
//  Inspect), following the same list -> /detail/:id concept as
//  job-list -> job-detail/:id. id=0 means Create; id>0 loads the existing
//  job and, mirroring job-detail's own status-driven behaviour, the page is
//  read-only whenever the job is no longer Drafted (see openEditModal's old
//  guard in job-wh-internal-transfer-list -- editing was already restricted
//  to Drafted jobs server-side, so the page can decide that for itself
//  instead of needing separate Edit/Inspect entry points).
@Component({
  selector: 'app-job-wh-internal-transfer-detail',
  standalone: false,
  templateUrl: './job-wh-internal-transfer-detail.html',
  styleUrls: [
    '../job-detail/job-detail.css',
    '../job-wh-location/job-wh-location.css',
    '../job-wh-internal-transfer-list/job-wh-internal-transfer-list.css',
    './job-wh-internal-transfer-detail.css',
  ],
})
export class JobWhInternalTransferDetail implements OnInit {
  jobMainId = 0;
  isLoading = false;
  submitted = false;
  isSubmitting = false;
  readOnlyMode = false;
  _wmsPlusStatus: Type.ResultProcessWmsPlusLogStatus | null = null;
  //  Full history for this job, newest first -- feeds #wmsPlusDetailModal.
  _wmsPlusLogs: Type.ResultProcessWmsPlusLogStatus[] | null = null;
  _wmsPlusLogPage = 1;
  readonly wmsPlusLogPageSize = 1;
  _isResendingWmsPlus = false;
  skeletonItems = Array.from({ length: 3 }, (_, index) => index);
  //  Same row shape job-wh-internal-transfer-list.ts reads -- GET job/
  //  internal-transfer/{jobId} (the old dedicated detail route) now 405s on
  //  every method but PUT, so this page loads its data the same way the list
  //  page does: GET job/internal-transfer filtered down to this one job.
  header: Type.ResultProcessInternalTransferJobListData | null = null;

  transferForm: InternalTransferForm = this.createEmptyForm();
  sourceLocationRequestId = 0;
  destinationLocationRequestId = 0;
  readonly sourceLocations = new FormArray<FormGroup>([]);
  readonly destinationLocations = new FormArray<FormGroup>([]);

  //  Forklift picker -- always scoped to 'MWH' since both source and
  //  destination locations on this page are always MWH (see sourceItem/
  //  destinationItem's hardcoded warehouseCode below), unlike job-detail
  //  where the search defaults to whatever the job's own destination
  //  locations resolve to.
  whLocationOptions: Type.ResultProcessGetOptionsWh[] | null = [];
  _forkliftAvailableData: Type.ResultProcessForkliftAvailable[] | null = [];
  _searchForklift = new FormGroup({
    forkliftName: new FormControl(''),
    //  Warehouse filter (multi-select), same as job-detail -- empty = all warehouses
    whCodes: new FormControl<string[]>([]),
    currentUser: new FormControl(''),
    //  Section filter (multi-select) -- every section by default, same as job-detail
    sectionIds: new FormControl<string[]>(FORKLIFT_SECTION_OPTIONS.map((section) => section.id)),
  });
  readonly forkliftSectionOptions = FORKLIFT_SECTION_OPTIONS;
  forkliftForm = new FormGroup({
    forklifts: new FormArray<ForkliftForm>([]),
  });
  //  Both pickers share the same "no real job item" stub -- grade/lot are
  //  typed in by hand rather than derived from a job line, same reason
  //  sourceItem has always been a placeholder here (see select-internal-
  //  transfer-location.ts).
  readonly sourceItem: Type.Item = this.createStubItem();
  readonly destinationItem: Type.Item = this.createStubItem();

  //  Header Cost Center / Product Type selects -- same fields/options/Save
  //  gating as job-detail.ts, but with no default-prefill: job-detail only
  //  defaults these once a job is past status_id 1, and every WH02 job stays
  //  at job_status_id 1 (Drafted) until a real approve/execute workflow
  //  exists (see 23_pProcessGetInternalTransferJobList.sql's header
  //  comment), so that condition never fires here -- the user always picks
  //  both explicitly, same as a brand-new WH01 job would.
  costCenterOptions: Type.ResultProcessGetOptionsWmsCcCode[] | null = [];
  selectedCostCenter = new FormControl<Type.ResultProcessGetOptionsWmsCcCode | null>(null);
  productTypeOptions: Type.ResultProcessGetOptionsProductType[] | null = [];
  selectedProductType = new FormControl<Type.ResultProcessGetOptionsProductType | null>(null);

  //  Edit mode's product_cc/product_type, held here so applyProductSelections
  //  can re-run once costCenterOptions/productTypeOptions actually arrive --
  //  loadJob and the two ProcessGetOptions* subscriptions race, so whichever
  //  finishes last is what makes the select actually show a value.
  private _pendingProductSelection: { cc: string | null; type: string | null } | null = null;

  constructor(
    private route: ActivatedRoute,
    private router: Router,
    private restService: CrudService,
  ) {}

  ngOnInit(): void {
    this.jobMainId = Number(this.route.snapshot.paramMap.get('id') || '0');

    if (this.jobMainId > 0) {
      this.loadJob();
    }

    this.restService.ProcessGetOptionsLocationWh('MWH').subscribe((response) => {
      this.whLocationOptions = response.data;
    });

    //  WH Prod CC -- same list as WMS+'s Transfer WH form for this warehouse.
    this.restService.ProcessGetOptionsWmsProdCcTransferWh('MWH').subscribe((response) => {
      this.costCenterOptions = response.data;
      this.applyPendingProductSelection();
    });

    this.restService.ProcessGetOptionsProductType().subscribe((response) => {
      this.productTypeOptions = response.data;
      this.applyPendingProductSelection();
    });

    //  Forklift list is fetched when the picker opens (openForkliftModal),
    //  not on page load.
    this._searchForklift.controls.forkliftName.valueChanges.subscribe((forkliftName) => {
      this.resetForkliftForm();
      this.loadForkliftAvailable(forkliftName || '');
    });

    this._searchForklift.controls.whCodes.valueChanges.subscribe(() => {
      this.resetForkliftForm();
      this.loadForkliftAvailable(this._searchForklift.controls.forkliftName.value || '');
    });

    this._searchForklift.controls.sectionIds.valueChanges.subscribe(() => {
      this.resetForkliftForm();
      this.loadForkliftAvailable(this._searchForklift.controls.forkliftName.value || '');
    });
  }

  get isEditMode(): boolean {
    return this.jobMainId > 0;
  }

  //  Matches _pendingProductSelection (set by loadJob) against whichever of
  //  costCenterOptions/productTypeOptions has arrived so far, and sets
  //  selectedCostCenter/selectedProductType so canSave doesn't stay blocked
  //  on an Edit whose job.product_cc/product_type predate the option list
  //  loading. A no-op once both selects already hold a value.
  private applyPendingProductSelection(): void {
    const pending = this._pendingProductSelection;
    if (!pending) return;

    if (!this.selectedCostCenter.value && pending.cc) {
      const match = (this.costCenterOptions ?? []).find((option) => option.cc_code === pending.cc);
      if (match) this.selectedCostCenter.setValue(match);
    }

    if (!this.selectedProductType.value && pending.type) {
      const match = (this.productTypeOptions ?? []).find((option) => option.product_type === pending.type);
      if (match) this.selectedProductType.setValue(match);
    }
  }

  //  Mirrors job-detail.ts's canApproveJob hasRequiredSelections/srcIsValid/
  //  destIsValid trio -- non-empty source AND destination, balanced qty, no
  //  overlap, AND (added here to match job-detail requiring a forklift too)
  //  at least one forklift picked. The forklift card already showed a
  //  validation-error style for this once submitted; it just wasn't actually
  //  blocking Save until now.
  get isFormValid(): boolean {
    return (
      this.selectedSourceLocations.length > 0 &&
      this.selectedDestinationLocations.length > 0 &&
      this.totalSourceQty === this.totalDestinationQty &&
      !this.hasOverlappingLocations &&
      !this.isEmptyForklifts
    );
  }

  //  Save button gating -- same shape as job-detail.ts's canApproveJob:
  //  hard-blocked once the job can no longer be edited (job-detail's
  //  status_id >= 5 check, here readOnlyMode) or mid-save, then Cost Center
  //  + Product Type are an always-on precondition exactly like job-detail's
  //  own `!selectedCostCenter.value || !selectedProductType.value` check --
  //  required before the lenient-until-first-Save-attempt stage even
  //  applies. Otherwise lenient until the first Save attempt (submitted
  //  stays false, same as job-detail's validationErrors flags all starting
  //  unset) so a brand-new form isn't disabled before the user has touched
  //  anything, then live-validated against isFormValid from that point on so
  //  it re-enables the moment the picks are fixed.
  get canSave(): boolean {
    if (this.readOnlyMode) return false;
    if (this.isSubmitting) return false;
    if (!this.selectedCostCenter.value || !this.selectedProductType.value) return false;

    if (!this.submitted) return true;

    return this.isFormValid;
  }

  //  Many-to-many: source and destination are two independent pools of
  //  picked locations (1 -> many, many -> 1, many -> many all fall out of
  //  this naturally) -- the only cross-check is that their totals balance,
  //  same principle job-detail already uses for a single item's GET/PUT
  //  locations.
  get totalSourceQty(): number {
    return this.selectedSourceLocations.reduce((sum, loc) => sum + (loc.confirmQty ?? 0), 0);
  }

  get totalDestinationQty(): number {
    return this.selectedDestinationLocations.reduce((sum, loc) => sum + (loc.confirmQty ?? 0), 0);
  }

  //  Moved out of the template (was `selectedSourceLocations[0]?.grade`/
  //  `?.lotNo` inline) -- NG8107 flags that `?.` as unnecessary because
  //  TypeScript types array indexing as always-defined without
  //  `noUncheckedIndexedAccess`, but selectedSourceLocations[0] genuinely IS
  //  undefined whenever no source location is picked yet (e.g. a brand-new
  //  transfer), so removing the `?.` would crash. NG8107 is a template-only
  //  diagnostic, so the same safe `?.` here in a plain TS getter doesn't
  //  trigger it at all.
  get defaultDestinationGrade(): string {
    return this.selectedSourceLocations[0]?.grade ?? '';
  }

  get defaultDestinationLotNo(): string {
    return this.selectedSourceLocations[0]?.lotNo ?? '';
  }

  //  Compares by locationId, not locationName -- locationName is a derived
  //  display string built by two different code paths (select-internal-
  //  transfer-location.ts's updateOrAddLocation, for a stock-inquiry match,
  //  vs its loadWhLocationData, for a plain Warehouse/Area/Level browse),
  //  so two rows for the exact same physical location can end up with
  //  differently-formatted name strings and silently dodge a name-based
  //  check. locationId is the actual stable identity of a location.
  get hasOverlappingLocations(): boolean {
    const sourceIds = new Set(
      this.selectedSourceLocations.map((loc) => loc.locationId).filter((id) => id != null),
    );
    return this.selectedDestinationLocations.some(
      (loc) => loc.locationId != null && sourceIds.has(loc.locationId),
    );
  }

  get forklifts(): FormArray<ForkliftForm> {
    return this.forkliftForm.controls.forklifts;
  }

  get selectedForklifts(): ForkliftForm[] {
    return this.forklifts.controls.filter((forklift) => forklift.value.isSelected);
  }

  //  Unselected forklifts for the picker, in the order the API returned them
  //  (pProcessGetForkliftAvailable already sorts) -- no client-side sorting.
  //  Rows kept from an earlier fetch (ticked but not saved) that the latest
  //  response doesn't include go last.
  get currentForklifts(): ForkliftForm[] {
    const order = new Map<number | null | undefined, number>(
      (this._forkliftAvailableData ?? []).map((forklift, index) => [forklift.id, index]),
    );
    return this.forklifts.controls
      .filter((forklift) => !forklift.value.isSelected)
      .sort((a, b) => (order.get(a.value.id) ?? Infinity) - (order.get(b.value.id) ?? Infinity));
  }

  //  "Add" button -- fetches a fresh forklift list every time the picker
  //  opens (drops unticked rows from the previous fetch first), instead of
  //  loading once when the page opens.
  openForkliftModal(): void {
    this.resetForkliftForm();
    this.loadForkliftAvailable(this._searchForklift.controls.forkliftName.value || '');
  }

  get isEmptyForklifts(): boolean {
    return this.selectedForklifts.length === 0;
  }

  get selectedSourceLocations(): SelectedTransferLocation[] {
    return this.selectedLocations(this.sourceLocations);
  }

  get selectedDestinationLocations(): SelectedTransferLocation[] {
    return this.selectedLocations(this.destinationLocations);
  }

  private selectedLocations(locations: FormArray<FormGroup>): SelectedTransferLocation[] {
    return locations.controls
      .filter((location) => location.value['isSelected'] === true)
      .map(
        (location) =>
          ({
            index: locations.controls.indexOf(location),
            ...location.getRawValue(),
          }) as SelectedTransferLocation,
      );
  }

  trackByIndex(_index: number, location: SelectedTransferLocation): number {
    return location.index;
  }

  //  Same ct_job_status.id -> class mapping as job-wh-internal-transfer-
  //  list.ts's own statusClass -- picks up job-wh-internal-transfer-list.css's
  //  pending/wh-approved/in-progress/complete/mapping-do palette (already
  //  loaded via this component's own styleUrls), so both pages render the
  //  same badge colors for the same status. By id, not job_status_name:
  //  that now comes back in Thai (name_th).
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

  //  Same parser as job-wh-internal-transfer-list.ts's own parseJobDate --
  //  job_create_datetime/job_start_datetime/job_end_datetime come back as
  //  "M/D/YYYY h:mm:ss AM/PM", which the regex below doesn't match (no AM/PM
  //  capture) so it falls through to the native `new Date()` parse, which
  //  does understand that format.
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

  goBack(): void {
    this.router.navigate(['/job-wh-internal-transfer-list']);
  }

  //  GET job/internal-transfer/{jobId} (processGetInternalTransferJobDetail)
  //  now 405s on GET -- confirmed live, "Allow: PUT" only -- so this loads
  //  the same list endpoint job-wh-internal-transfer-list.ts calls and picks
  //  this one job out of it. The `id` query param is passed through but the
  //  backend doesn't actually filter by it yet, so a wide, high-pageSize
  //  request plus a client-side find() is what actually narrows it down.
  private loadJob(): void {
    this.isLoading = true;

    this.restService
      .processGetInternalTransferJobList('', '2000-01-01', '2099-12-31', 0, 1, 500, this.jobMainId)
      .subscribe({
        next: (response) => {
          this.isLoading = false;

          const job =
            response.status === 'success'
              ? (response.data ?? []).find((row) => row.id === this.jobMainId)
              : null;

          if (!job) {
            this.SwalAlert('error', 'ไม่สามารถโหลดข้อมูลรายการย้ายสินค้าได้');
            this.goBack();
            return;
          }

          this.header = job;
          //  Editable at any status up to Complete (job_status_id 5, per
          //  job-wh-internal-transfer-list.ts's own JOB_STATUS_FILTER_MAP
          //  completed:5) -- only a finished job is locked down; Pending,
          //  WH Approved, etc. can still be changed.
          this.readOnlyMode = job.job_status_id === 5;
          //  [disabled] on a [formControl] select is ignored by reactive forms,
          //  so lock the header selects through the controls themselves.
          if (this.readOnlyMode) {
            this.selectedCostCenter.disable();
            this.selectedProductType.disable();
          }
          this.transferForm = {
            sourceRemark: job.source_remark || '',
            destinationRemark: job.destination_remark || '',
            isUrgent: job.is_urgent || 'N',
            isMultiForklift: job.is_multi_forklift || 'N',
            isAdvanceOrder: job.is_advance_order || 'N',
          };
          this.loadWmsPlusStatus();

          //  canSave requires both selects filled in (see the getter above),
          //  so Edit must pre-select whichever cc_code/product_type this job
          //  was saved with -- options may still be loading when this runs
          //  (separate subscriptions above), so re-apply once each list
          //  arrives too, not just here.
          this._pendingProductSelection = { cc: job.product_cc ?? null, type: job.product_type ?? null };
          this.applyPendingProductSelection();

          this.sourceLocations.clear();
          this.destinationLocations.clear();
          //  The API always sends both from_location and to_location objects,
          //  with id null on the side an item doesn't have -- pProcessCreate/
          //  UpdateInternalTransferJob pair source/destination rows 1:1 by
          //  grade/lot, so an uneven split (1 source -> 2 destinations) leaves
          //  items with only one real side. Skip the empty side, or Edit shows
          //  a blank location row and its qty doubles that panel's total.
          (job.items ?? []).forEach((item) => {
            if (item.locations.from_location?.id != null) {
              this.sourceLocations.push(
                this.buildLocationFormGroup(item.locations.from_location, item, this.sourceItem.id),
              );
            }
            if (item.locations.to_location?.id != null) {
              this.destinationLocations.push(
                this.buildLocationFormGroup(
                  item.locations.to_location,
                  item,
                  this.destinationItem.id,
                ),
              );
            }
          });

          this.forklifts.clear();
          (job.forklifts ?? []).forEach((forklift) => {
            this.addForklift({
              id: forklift.id ?? null,
              forkliftName: forklift.name ?? '',
              whCode: forklift.wh_code ?? '',
              sectionName: this.formatSectionName(forklift.section_name),
              currentUserId: forklift.assignee_user_id ?? null,
              currentUserName: forklift.assignee_user_name ?? null,
              currentThaiName: forklift.assignee_user_thai_name ?? null,
              currentEngName: forklift.assignee_user_eng_name ?? null,
              jobCount: forklift.job_count ?? 0,
              isRead: forklift.is_read ?? null,
              isChecked: true,
              isSelected: true,
            });
          });
        },
        error: (error) => {
          this.isLoading = false;
          console.error('Error fetching internal transfer job detail:', error);
          this.SwalAlert('error', 'ไม่สามารถโหลดข้อมูลรายการย้ายสินค้าได้');
          this.goBack();
        },
      });
  }

  //  location is one leg's from_location or to_location; item is that same
  //  leg's shared grade/lot/qty/confirm_qty/complete_qty -- unlike the old
  //  detail endpoint's flat sourceLocations/destinationLocations rows, the
  //  real items[] pairs one from_location with one to_location per item, so
  //  loadJob() calls this once per side per item.
  private buildLocationFormGroup(
    location: Type.ResultInternalTransferJobListLocation,
    item: Type.ResultInternalTransferJobListItem,
    itemId: number,
  ): FormGroup {
    const pallets = this.parsePalletJson(location.pallet_json);
    //  Each side keeps its own qty (qty_from_location / qty_to_location) --
    //  item.qty is one shared number per pair, which is wrong for the side
    //  of an uneven split and throws the GET/PUT totals out of balance.
    const qty = location.qty ?? item.qty ?? 0;

    return new FormGroup({
      id: new FormControl<number | null>(null),
      itemId: new FormControl<number | null>(itemId),
      whCode: new FormControl<string | null>('MWH'),
      ccCode: new FormControl<string | null>(location.cc_code ?? null),
      grade: new FormControl<string | null>(item.grade ?? null),
      gradeId: new FormControl<number | null>(location.grade_id ?? null),
      lotNo: new FormControl<string | null>(location.lot_no || item.lot_no || null),
      locationId: new FormControl<number | null>(location.id ?? null),
      locationType: new FormControl<string | null>(location.type ?? 'MWH'),
      locationName: new FormControl<string | null>(location.name ?? null),
      qty: new FormControl<number | null>(qty),
      confirmQty: new FormControl<number | null>(qty),
      actualQty: new FormControl<number | null>(location.actual_qty ?? 0),
      availableQty: new FormControl<number | null>(0),
      qtyLock: new FormControl<number | null>(0),
      receivedQty: new FormControl<number | null>(item.receive_qty ?? 0),
      completeQty: new FormControl<number | null>(item.complete_qty ?? 0),
      isChecked: new FormControl<boolean | null>(true),
      isSelected: new FormControl<boolean | null>(true),
      isVisible: new FormControl<boolean | null>(true),
      isPalletMode: new FormControl<boolean | null>(pallets.length > 0),
      remark: new FormControl<string | null>(location.remark ?? item.remark ?? null),
      selectedPallets: new FormControl<SelectedTransferPallet[] | null>(
        pallets.length > 0 ? pallets : null,
      ),
    });
  }

  //  Each location's pallet_json is a JSON-encoded array column (dbo.
  //  tr_internal_transfer_detail), e.g. "[]" or null when the location
  //  wasn't picked in pallet mode.
  private parsePalletJson(json: string | null | undefined): SelectedTransferPallet[] {
    if (!json) return [];

    try {
      const parsed = JSON.parse(json);
      if (!Array.isArray(parsed)) return [];

      return parsed.map((pallet: any) => ({
        id: pallet.id ?? null,
        palletNo: pallet.palletNo ?? pallet.pallet_no ?? '',
        grade: pallet.grade ?? null,
        lot: pallet.lot ?? pallet.lot_no ?? null,
        qty: pallet.qty ?? 0,
        text: pallet.text ?? null,
        scannedQrCode: pallet.scannedQrCode ?? pallet.scanned_qr_code ?? null,
      }));
    } catch {
      return [];
    }
  }

  openSourceLocationModal(): void {
    this.sourceLocationRequestId++;
  }

  openDestinationLocationModal(): void {
    this.destinationLocationRequestId++;
  }

  //  Same formula as job-wh-location.ts's own getPalletProgressWidth --
  //  actualQty is real (buildLocationFormGroup seeds it from the backend's
  //  from_location/to_location actual_qty), so this reflects genuine
  //  execution progress once WH02 has moved any of the picked quantity.
  getLocationProgressWidth(location: SelectedTransferLocation): number {
    const qty = location.confirmQty || 1;
    const actualQty = location.actualQty || 0;
    const progressPercentage = (actualQty / qty) * 100;
    return Math.max(0, Math.min(progressPercentage, 100));
  }

  //  Same guard as job-wh-location.ts's own IsPalletComplete -- once a
  //  location has any real actualQty, it's already been moved, so deleting
  //  it outright would desync the form from what actually happened in the
  //  warehouse. The delete button swaps for a "repeat" (fit) button instead.
  isLocationCompleted(location: SelectedTransferLocation): boolean {
    return (location.actualQty ?? 0) > 0;
  }

  onDeleteSourceLocation(location: SelectedTransferLocation): void {
    this.sourceLocations.removeAt(location.index);
  }

  onDeleteDestinationLocation(location: SelectedTransferLocation): void {
    this.destinationLocations.removeAt(location.index);
  }

  onEditSourceQty(location: SelectedTransferLocation): void {
    this.editLocationQty(this.sourceLocations, location);
  }

  onEditDestinationQty(location: SelectedTransferLocation): void {
    this.editLocationQty(this.destinationLocations, location);
  }

  onFitSourceQty(location: SelectedTransferLocation): void {
    this.fitLocationQty(this.sourceLocations, location);
  }

  onFitDestinationQty(location: SelectedTransferLocation): void {
    this.fitLocationQty(this.destinationLocations, location);
  }

  //  Same idea as job-wh-location.ts's own onFitQtyLocation -- snaps the
  //  target qty/confirmQty down (or up) to match what was actually moved,
  //  instead of leaving a picked-but-never-fulfilled target sitting there.
  private fitLocationQty(
    locations: FormArray<FormGroup>,
    location: SelectedTransferLocation,
  ): void {
    const actualQty = location.actualQty ?? 0;
    locations.at(location.index).patchValue({ qty: actualQty, confirmQty: actualQty });
  }

  //  Swal input:'number' prompt -- same pattern job-wh-location.ts's own
  //  onAssignLocationQty uses for editing a picked location's qty.
  private editLocationQty(
    locations: FormArray<FormGroup>,
    location: SelectedTransferLocation,
  ): void {
    Swal.fire({
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (kg) : ${location.locationName}</span>`,
      html: '<span style="font-size: 16px;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</span>',
      input: 'number',
      inputAttributes: { min: '1', step: '1' },
      inputValue: location.confirmQty ?? 0,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (!result.isConfirmed) return;

      const nextQty = Number(result.value);
      if (!Number.isFinite(nextQty) || nextQty <= 0) {
        this.SwalAlert('warning', 'กรุณาระบุจำนวนให้มากกว่า 0');
        return;
      }

      //  Can't plan less than what was already moved from/to this location.
      const actualQty = location.actualQty ?? 0;
      if (nextQty < actualQty) {
        this.SwalAlert('warning', `จำนวนต้องไม่น้อยกว่าที่ย้ายไปแล้ว (${actualQty} kg)`);
        return;
      }

      locations.at(location.index).patchValue({ qty: nextQty, confirmQty: nextQty });
    });
  }

  submitTransfer(): void {
    this.submitted = true;

    if (!this.isFormValid || this.isSubmitting || this.readOnlyMode) {
      return;
    }

    this.isSubmitting = true;

    this.applySourceGradeToDestinations();

    const payload: Type.RequestCreateInternalTransferJobItem = {
      whCode: 'MWH',
      qtyUnit: 'kg',
      sourceRemark: this.transferForm.sourceRemark || null,
      destinationRemark: this.transferForm.destinationRemark || null,
      sourceLocations: this.toRequestLocations(this.selectedSourceLocations),
      destinationLocations: this.toRequestLocations(this.selectedDestinationLocations),
      isUrgent: this.transferForm.isUrgent,
      isMultiForklift: this.transferForm.isMultiForklift,
      isAdvanceOrder: this.transferForm.isAdvanceOrder,
      //  Persisted into dbo.tr_job_assigness by pProcessCreate/UpdateInternalTransferJob's
      //  @forklifts_json (same pattern pProcessCreatePickingJob's @forklifts_json already
      //  uses for WH01) -- see loadJob for the read-back on Edit.
      forklifts: this.selectedForklifts.map((forklift) => ({ id: forklift.value.id ?? 0 })),
      //  canSave already requires both selects to be filled in before Save is
      //  even enabled (see the getter above) -- persisted onto tr_job_main.
      //  product_cc/product_type, the same columns every other job type's
      //  create/update SP already sets.
      productCc: this.selectedCostCenter.value?.cc_code ?? null,
      productType: this.selectedProductType.value?.product_type ?? null,
    };

    const isEdit = this.isEditMode;
    const request$ = isEdit
      ? this.restService.processUpdateInternalTransferJob(this.jobMainId, payload)
      : this.restService.processCreateInternalTransferJob(payload);

    request$.subscribe({
      next: (response) => {
        this.isSubmitting = false;

        if (response.status !== 'success') {
          this.SwalAlert(
            'error',
            response.message ||
              (isEdit ? 'ไม่สามารถแก้ไขรายการย้ายสินค้าได้' : 'ไม่สามารถสร้างรายการย้ายสินค้าได้'),
          );
          return;
        }

        this.goBack();
      },
      error: (error) => {
        this.isSubmitting = false;
        console.error('Error saving internal transfer job:', error);
        this.SwalAlert(
          'error',
          isEdit
            ? 'ไม่สามารถแก้ไขรายการย้ายสินค้าได้ กรุณาลองใหม่อีกครั้ง'
            : 'ไม่สามารถสร้างรายการย้ายสินค้าได้ กรุณาลองใหม่อีกครั้ง',
        );
      },
    });
  }

  //  A transfer moves one product/lot from source to destination -- the
  //  destination picker resolves grade/gradeId/lotNo independently (its own
  //  typed search, not a Stock Inquiry match the way source locations get
  //  theirs), so before saving, force every selected destination location to
  //  carry the exact same grade/gradeId/lotNo as the source stock actually
  //  being moved (its first selected location, since a transfer is one
  //  product/lot), rather than whatever the destination search happened to
  //  resolve on its own. Patches the FormArray directly (not just the
  //  outbound payload) so the panel display and the saved data agree.
  private applySourceGradeToDestinations(): void {
    const primarySource = this.selectedSourceLocations[0];
    if (!primarySource) return;

    this.destinationLocations.controls
      .filter((location) => location.value['isSelected'] === true)
      .forEach((location) => {
        location.patchValue({
          grade: primarySource.grade,
          gradeId: primarySource.gradeId,
          lotNo: primarySource.lotNo,
        });
      });
  }

  private toRequestLocations(
    locations: SelectedTransferLocation[],
  ): Type.RequestCreateInternalTransferJobLocation[] {
    return locations.map((location) => ({
      locationId: location.locationId ?? 0,
      locationType: location.locationType ?? 'MWH',
      locationName: location.locationName,
      ccCode: location.ccCode,
      grade: location.grade,
      gradeId: location.gradeId,
      lot: location.lotNo,
      qty: location.confirmQty ?? 0,
      remark: location.remark,
      pallets: (location.selectedPallets ?? []).map((pallet) => ({
        id: pallet.id,
        palletNo: pallet.palletNo,
        grade: pallet.grade,
        lot: pallet.lot,
        qty: pallet.qty,
        text: pallet.text,
        scannedQrCode: pallet.scannedQrCode,
      })),
    }));
  }

  private SwalAlert(icon: 'success' | 'error' | 'warning' | 'info', message: string): void {
    Swal.fire({
      icon,
      title: icon === 'error' ? 'เกิดข้อผิดพลาด' : 'แจ้งเตือน',
      text: message,
      confirmButtonText: 'รับทราบ',
    });
  }

  private createEmptyForm(): InternalTransferForm {
    return {
      sourceRemark: '',
      destinationRemark: '',
      isUrgent: 'N',
      isMultiForklift: 'N',
      isAdvanceOrder: 'N',
    };
  }

  onToggleUrgent(): void {
    if (this.readOnlyMode) return;
    this.transferForm.isUrgent = this.transferForm.isUrgent === 'Y' ? 'N' : 'Y';
  }

  //  Advance order, same rule as job-detail: completing the job holds back
  //  the WMS+ interface until the user presses "ส่ง Interface". Settable on a
  //  new job or while the job is Pending (1) / WH Approved (2).
  get canSetAdvanceOrder(): boolean {
    if (this.readOnlyMode) return false;
    const statusId = this.header?.job_status_id ?? 1;
    return statusId === 1 || statusId === 2;
  }

  get isAdvanceOrder(): boolean {
    return this.transferForm.isAdvanceOrder === 'Y';
  }

  //  Completed advance-order job whose interface has not gone through yet.
  get canSendAdvanceInterface(): boolean {
    return this.isAdvanceOrder && this.readOnlyMode && this._wmsPlusStatus?.is_success !== 'Y';
  }

  onToggleAdvanceOrder(): void {
    if (!this.canSetAdvanceOrder) return;
    this.transferForm.isAdvanceOrder = this.isAdvanceOrder ? 'N' : 'Y';
  }

  //  WMS+ log rows for this job -- the latest drives the badge and hides
  //  "ส่ง Interface" once it went through. A failed lookup leaves the button showing.
  private loadWmsPlusStatus(): void {
    if (!this.jobMainId) return;

    this.restService.processGetWmsPlusLogStatus(String(this.jobMainId)).subscribe({
      next: (response) => {
        const group = (response.data ?? []).find((row) => row.job_main_id === this.jobMainId);
        this._wmsPlusLogs = group?.logs ?? null;
        this._wmsPlusStatus = group?.logs?.[0] ?? null;
        this._wmsPlusLogPage = 1;
      },
      error: (error) => console.error('Error fetching WMS+ interface log status:', error),
    });
  }

  get pagedWmsPlusLogs(): Type.ResultProcessWmsPlusLogStatus[] {
    const start = (this._wmsPlusLogPage - 1) * this.wmsPlusLogPageSize;
    return (this._wmsPlusLogs ?? []).slice(start, start + this.wmsPlusLogPageSize);
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
  //  inner "message" when present, same as job-detail.ts's formatWmsMessage.
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

  sendAdvanceInterface(): void {
    if (this._isResendingWmsPlus || !this.jobMainId) return;

    this._isResendingWmsPlus = true;

    this.restService.processResendWmsPlus(this.jobMainId).subscribe({
      next: (response) => {
        this._isResendingWmsPlus = false;

        if (response.wmsPlusStatus === 'not_applicable') {
          this.SwalAlert('info', 'งานนี้ไม่มีขั้นตอนแจ้งเตือน WMS+');
        } else if (response.wmsPlusStatus === 'failed') {
          this.SwalAlert('error', response.wmsPlusMessage || 'ส่งข้อมูลไปยัง WMS+ ไม่สำเร็จ');
        } else {
          this.SwalAlert('success', 'ส่งข้อมูลไปยัง WMS+ สำเร็จ');
        }

        this.loadWmsPlusStatus();
      },
      error: (error) => {
        this._isResendingWmsPlus = false;
        console.error('Error sending WMS+ interface:', error);
        this.SwalAlert('error', 'เกิดข้อผิดพลาดขณะส่งข้อมูลไปยัง WMS+');
      },
    });
  }

  //  [compareWith] for the Cost Center mat-select -- copied from job-detail.ts
  //  verbatim (object identity won't match once options are re-fetched).
  compareCostCenter = (
    a: Type.ResultProcessGetOptionsWmsCcCode | null,
    b: Type.ResultProcessGetOptionsWmsCcCode | null,
  ): boolean => {
    return !!a && !!b && a.sap_cc_code === b.sap_cc_code && a.cc_code === b.cc_code;
  };

  //  Sets (not toggles) the step mode, same as job-detail's onSetMultiForklift
  //  -- toggling flipped the mode when the already-active button was clicked.
  onSetMultiForklift(value: 'Y' | 'N'): void {
    if (this.readOnlyMode) return;
    this.transferForm.isMultiForklift = value;
  }

  //  Forklift picker below -- a straight port of job-detail.ts's own working
  //  add/search/select/confirm-close modal flow, adapted to this component's
  //  Observable-based (not Promise-wrapped) service calls. There's no
  //  equivalent of job-detail's defaultForkliftForm (pre-filling from an
  //  already-assigned list on load) because the get-detail endpoint doesn't
  //  return assigned forklifts yet -- see loadJob's NOTE above.
  addForklift(forklift: any): void {
    const form: ForkliftForm = new FormGroup({
      id: new FormControl<number | null>(forklift.id ?? null),
      forkliftName: new FormControl<string | null>(forklift.forkliftName ?? null),
      whCode: new FormControl<string | null>(forklift.whCode ?? null),
      sectionName: new FormControl<string | null>(forklift.sectionName ?? null),
      currentUserId: new FormControl<number | null>(forklift.currentUserId ?? null),
      currentUserName: new FormControl<string | null>(forklift.currentUserName ?? null),
      currentThaiName: new FormControl<string | null>(forklift.currentThaiName ?? null),
      currentEngName: new FormControl<string | null>(forklift.currentEngName ?? null),
      isOnline: new FormControl<boolean | null>(forklift.isOnline ?? false),
      jobCount: new FormControl<number | null>(forklift.jobCount ?? 0),
      isChecked: new FormControl<boolean | null>(forklift.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(forklift.isSelected ?? false),
      isRead: new FormControl<string | null>(forklift.isRead ?? null),
    });

    this.forklifts.push(form);
  }

  onDeleteForklift(forklift: any): void {
    const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
    if (index !== -1) {
      this.forklifts.removeAt(index);
    }
  }

  //  Offline forklifts can be picked too, but only after the user confirms a
  //  warning -- nobody may be logged in on that forklift to take the job yet.
  async onCheckForklift(forklift: any): Promise<void> {
    if (forklift.value.isChecked) return;

    if (!forklift.value.isOnline) {
      const confirmed = await confirmOfflineForklift({
        forkliftName: forklift.value.forkliftName,
        //  Filtered warehouse first, same order as the modal's badge.
        whCode: this.orderedForkliftWhCode(forklift.value.whCode),
        lastUserName: forklift.value.currentThaiName,
        jobCount: forklift.value.jobCount,
      });
      if (!confirmed) return;
    }

    const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
    if (index !== -1) {
      this.forklifts.at(index).patchValue({ isChecked: true });
    }
  }

  onUnCheckForklift(forklift: any): void {
    const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
    if (index !== -1) {
      const currentValue = this.forklifts.at(index).value.isChecked;
      this.forklifts.at(index).patchValue({ isChecked: !currentValue });
    }
  }

  onSaveForklift(): void {
    this.forklifts.controls.forEach((forklift) => {
      forklift.controls.isSelected.setValue(forklift.controls.isChecked.value, { emitEvent: true });
    });

    this.hideForkliftModal();
    this.hideForkliftConfirmModal();
  }

  onNotSaveForklift(): void {
    this.forklifts.controls.forEach((forklift) => {
      forklift.controls.isChecked.setValue(forklift.controls.isSelected.value, { emitEvent: true });
    });

    this.hideForkliftModal();
    this.hideForkliftConfirmModal();
  }

  onCloseForkliftModal(): void {
    const hasChanges = this.forklifts.controls.some(
      (f) => f.value.isChecked !== f.value.isSelected,
    );

    if (!hasChanges) {
      if (document.getElementById('forkliftModal')) {
        this.hideForkliftModal();
        this.hideForkliftConfirmModal();
        return;
      }
    }

    this.showForkliftConfirmModal();
  }

  hideForkliftModal(): void {
    const modalEl = document.getElementById('forkliftModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  hideForkliftConfirmModal(): void {
    const modalEl = document.getElementById('forkliftConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showForkliftConfirmModal(): void {
    const modalEl = document.getElementById('forkliftConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  resetForkliftForm(): void {
    this.forklifts.controls
      .filter((forklift) => !forklift.value.isChecked && !forklift.value.isSelected)
      .forEach((forklift) => {
        const index = this.forklifts.controls.findIndex((f) => f.value.id === forklift.value.id);
        if (index !== -1) {
          this.forklifts.removeAt(index);
        }
      });
  }

  selectAllForkliftSections(): void {
    this._searchForklift.controls.sectionIds.setValue(FORKLIFT_SECTION_OPTIONS.map((section) => section.id));
  }

  //  Trigger text for the modal's multi-selects. Every section picked reads
  //  as "ทั้งหมด"; warehouses show by name (wh_name), falling back to code.
  forkliftSectionLabels(): string[] {
    const ids = this._searchForklift.controls.sectionIds.value ?? [];
    if (ids.length === FORKLIFT_SECTION_OPTIONS.length) return ['ทั้งหมด'];
    return FORKLIFT_SECTION_OPTIONS.filter((section) => ids.includes(section.id)).map((section) => section.name);
  }

  forkliftWhLabels(): string[] {
    return (this._searchForklift.controls.whCodes.value ?? []).map(
      (code) => this.whLocationOptions?.find((wh) => wh.wh_code === code)?.wh_name || code,
    );
  }

  //  'Warehouse,Pallet' -> 'Warehouse, Pallet' for the section chip.
  formatSectionName(sectionName: string | null | undefined): string {
    return (sectionName || '')
      .split(',')
      .map((name) => name.trim())
      .filter((name) => name.length > 0)
      .join(', ');
  }

  //  A forklift's whCode is a comma-joined list of every warehouse it serves.
  //  Show one badge + "+N more" (same as job-detail), the modal's Warehouse
  //  filter first when the forklift serves it. Source/destination here are
  //  MWH location names with no warehouse code, so the filter is the only
  //  job-side warehouse to prefer. Matched by code (M35) or name (WH35).
  forkliftWhBadge(whCode: string | null | undefined): { first: string; rest: string[] } | null {
    const names = (whCode || '')
      .split(',')
      .map((name) => name.trim())
      .filter((name) => name.length > 0);
    if (names.length === 0) return null;

    let firstIndex = 0;
    for (const filterCode of this._searchForklift.controls.whCodes.value ?? []) {
      const whName = this.whLocationOptions?.find((wh) => wh.wh_code === filterCode)?.wh_name;
      const index = names.findIndex((name) => name === filterCode || name === whName);
      if (index >= 0) {
        firstIndex = index;
        break;
      }
    }

    return {
      first: names[firstIndex],
      rest: names.filter((_, index) => index !== firstIndex),
    };
  }

  orderedForkliftWhCode(whCode: string | null | undefined): string {
    const wh = this.forkliftWhBadge(whCode);
    return wh ? [wh.first, ...wh.rest].join(', ') : '';
  }

  //  "Warehouse, Loading, Pallet" -> one chip per section on the forklift card
  //  (same as job-detail).
  splitSections(sectionName: string | null | undefined): string[] {
    return (sectionName ?? '')
      .split(',')
      .map((section) => section.trim())
      .filter((section) => section.length > 0);
  }

  loadForkliftAvailable(forkliftName?: string): void {
    //  Empty whCode = "ทั้งหมด" (all warehouses), matching job-detail's own
    //  loadForkliftAvailable -- forcing a 'MWH' fallback here meant the
    //  picker never showed anything, since no forklift actually carries
    //  that literal wh_code (they're WH40/WH41/WH42, etc).
    const pickedWhCodes = this._searchForklift.controls.whCodes.value ?? [];
    const whCode = pickedWhCodes.join(',');
    const isInnerWh = pickedWhCodes.length > 0 ? 'Y' : 'N';
    const sectionIds = (this._searchForklift.controls.sectionIds.value ?? []).join(',');

    this.restService
      .processGetForkliftAvailable(
        whCode,
        forkliftName || '',
        this._searchForklift.controls.currentUser.value || '',
        isInnerWh,
        sectionIds,
      )
      .subscribe((response) => {
        this._forkliftAvailableData = response.data;

        const forkliftMap = new Map(this.selectedForklifts.map((f) => [f.value.id, f]));

        (this._forkliftAvailableData ?? []).forEach((forklift) => {
          const fl = forkliftMap.get(forklift.id);

          //  Already in the form (e.g. loaded from the saved job, which carries
          //  no online status) -- refresh its live online status/queue from
          //  this response instead of skipping it, so a saved forklift isn't
          //  shown (and warned about) as offline when it is actually online.
          //  The user fields are left alone: for a saved job they hold the
          //  job's assignee, not whoever is logged in on the forklift now.
          const existing = this.forklifts.controls.find((f) => f.value.id === forklift.id);
          if (existing) {
            existing.patchValue({
              isOnline: forklift?.is_online === 'Y',
              jobCount: forklift?.job_count ?? 0,
              sectionName:
                this.formatSectionName(forklift?.section_name) || existing.value.sectionName || null,
            });
            return;
          }

          this.addForklift({
            id: forklift?.id ?? null,
            forkliftName: forklift?.fl_name ?? '',
            whCode: forklift?.wh_code ?? '',
            sectionName: this.formatSectionName(forklift?.section_name),
            currentUserId: forklift?.current_user_id ?? null,
            currentUserName: forklift?.current_user_name ?? '',
            currentThaiName: forklift?.current_user_thai_name ?? '',
            currentEngName: forklift?.current_user_eng_name ?? '',
            isOnline: forklift?.is_online === 'Y',
            jobCount: forklift?.job_count ?? 0,
            isChecked: !!fl,
            isSelected: !!fl,
          });
        });
      });
  }

  private createStubItem(): Type.Item {
    return {
      id: -1,
      do_no: '',
      document_job: '',
      wh_code: '',
      cc_code: '',
      pd_cc_code: '',
      grade: '',
      lot_no: '',
      pd_type: '',
      qty: 0,
      complete_qty: 0,
      qty_unit: 'kg',
      is_expanded: false,
      total_qty: 0,
      locations: { from_locations: [], to_locations: [] },
    };
  }
}
