import { Component, OnInit } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { firstValueFrom } from 'rxjs';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';
import Swal from 'sweetalert2';

interface LoadingLocationDraft {
  id: number | null;
  locationId: number | null;
  locationType: string;
  locationName: string;
  qty: number;
  lotNo: string;
}

interface LoadingItemDraft {
  itemId: number;
  fromLocations: LoadingLocationDraft[];
  toLocations: LoadingLocationDraft[];
}

interface LoadingSelectOption {
  id: number;
  name: string;
}

@Component({
  selector: 'app-job-loading-detail',
  standalone: false,
  templateUrl: './job-loading-detail.html',
  styleUrls: [
    '../job-detail/job-detail.css',
    '../job-dock-location/job-dock-location.css',
    './job-loading-detail.css',
  ],
})
export class JobLoadingDetail implements OnInit {
  job: Type.LoadingJob | null = null;
  isLoading = true;
  loadError = '';
  jobId = 0;
  saleInfoByDo = new Map<string, Type.ResultDoSaleInfo[]>();
  isEditing = false;
  isSaving = false;
  isLoadingEditOptions = false;
  isPalletActionInProgress = false;
  draftUrgent = false;
  draftMultiFl = false;
  editError = '';
  editItems: LoadingItemDraft[] = [];
  dockOptions: Type.ResultProcessDockLocation[] = [];
  vehicleOptions: Type.ResultProcessGetVehicle[] = [];
  palletQrCode = '';
  selectedPalletItemId: number | null = null;
  selectedDockLocationId: number | null = null;

  constructor(
    private route: ActivatedRoute,
    private router: Router,
    private crudService: CrudService,
  ) {}

  ngOnInit(): void {
    const rawId = this.route.snapshot.paramMap.get('id');
    const jobId = Number(rawId);
    if (!rawId || !Number.isSafeInteger(jobId) || jobId <= 0) {
      this.isLoading = false;
      this.loadError = 'ไม่พบเลขที่งาน';
      return;
    }

    this.jobId = jobId;
    void this.loadJob();
  }

  async loadJob(): Promise<void> {
    this.isLoading = true;
    this.loadError = '';
    this.job = null;
    this.saleInfoByDo.clear();

    try {
      const response = await firstValueFrom(this.crudService.processGetLoadingJobList(''));
      if (response.status !== 'success') {
        throw new Error(response.message || 'ไม่สามารถโหลดข้อมูลงานได้');
      }

      this.job = response.data?.find((job) => job.id === this.jobId) ?? null;
      if (!this.job) {
        this.loadError = 'ไม่พบข้อมูลงาน Truck Loading นี้';
      } else {
        this.selectedPalletItemId = this.job.items[0]?.id ?? null;
        this.selectedDockLocationId =
          this.job.items[0]?.locations?.from_locations?.[0]?.location_id ?? null;
        this.loadSaleInfos(this.job.items);
      }
    } catch (error) {
      console.error('Error loading Truck Loading job details:', error);
      this.loadError = 'โหลดรายละเอียดงานไม่สำเร็จ กรุณาลองอีกครั้ง';
    } finally {
      this.isLoading = false;
    }
  }

  saleInfo(item: Type.LoadingJobItem): Type.ResultDoSaleInfo | null | undefined {
    const doNo = item.do_no?.trim();
    if (!doNo) return null;

    const rows = this.saleInfoByDo.get(doNo);
    if (rows === undefined) return undefined;
    const grade = item.grade?.trim();
    return rows.find((row) => !!grade && row.grade?.trim() === grade) ?? rows[0] ?? null;
  }

  saleInfoFields(info: Type.ResultDoSaleInfo): { label: string; value: string; wide?: boolean }[] {
    const value = (text: string | null | undefined) => text?.trim() || '-';
    return [
      { label: 'Customer Batch', value: value(info.customer_batch) },
      { label: 'Delivery Note', value: value(info.delivery_note) },
      { label: 'Packing Remark', value: value(info.packing_remark) },
      { label: 'Marking Remark', value: value(info.marking_remark) },
      { label: 'Other Instructions', value: value(info.other_instructions), wide: true },
    ];
  }

  private loadSaleInfos(items: Type.LoadingJobItem[]): void {
    const doNos = new Set(items.map((item) => item.do_no?.trim()).filter((doNo): doNo is string => !!doNo));
    doNos.forEach((doNo) => {
      this.crudService.processGetDoSaleInfo({ doNo }).subscribe({
        next: (response) => this.saleInfoByDo.set(doNo, response.data ?? []),
        error: (error) => {
          if (error?.status !== 404) console.error('Error fetching Truck Loading sale info:', error);
          this.saleInfoByDo.set(doNo, []);
        },
      });
    });
  }

  async startEditing(): Promise<void> {
    if (!this.job || this.isLoadingEditOptions || this.isPalletActionInProgress) return;

    this.isLoadingEditOptions = true;
    this.editError = '';
    try {
      const [dockResponse, vehicleResponse] = await Promise.all([
        firstValueFrom(this.crudService.processGetDockLocation('', '', '', '', undefined, undefined, undefined, 'Y')),
        firstValueFrom(this.crudService.ProcessGetVehicle({ isActive: 'Y', page: 1, pageSize: 500 })),
      ]);
      if (dockResponse.status !== 'success') {
        throw new Error(dockResponse.message || 'โหลดรายการ Dock ไม่สำเร็จ');
      }
      if (vehicleResponse.status !== 'success') {
        throw new Error(vehicleResponse.message || 'โหลดรายการรถไม่สำเร็จ');
      }

      this.dockOptions = dockResponse.data ?? [];
      this.vehicleOptions = vehicleResponse.data ?? [];
      const vehicleCount = vehicleResponse.total_count ?? this.vehicleOptions.length;
      for (let page = 2; this.vehicleOptions.length < vehicleCount; page += 1) {
        const pageResponse = await firstValueFrom(
          this.crudService.ProcessGetVehicle({ isActive: 'Y', page, pageSize: 500 }),
        );
        if (pageResponse.status !== 'success') {
          throw new Error(pageResponse.message || `โหลดรายการรถหน้าที่ ${page} ไม่สำเร็จ`);
        }
        if (!pageResponse.data?.length) {
          throw new Error('โหลดรายการรถไม่ครบ กรุณาลองอีกครั้ง');
        }
        this.vehicleOptions.push(...pageResponse.data);
      }
      this.includeCurrentLocationsInOptions();
      this.editItems = this.job.items.map((item) => ({
        itemId: item.id,
        fromLocations: (item.locations?.from_locations ?? []).map((location) =>
          this.toLocationDraft(location, this.job?.from_location_type || 'DOCK', item),
        ),
        toLocations: (item.locations?.to_locations ?? []).map((location) =>
          this.toLocationDraft(location, this.job?.to_location_type || 'VEHICLE', item),
        ),
      }));
      this.draftUrgent = this.job.is_urgent === 'Y';
      this.draftMultiFl = this.job.is_multi_fl === 'Y';
      this.isEditing = true;
    } catch (error) {
      console.error('Error loading Truck Loading edit options:', error);
      this.editError = this.errorMessage(error, 'โหลดตัวเลือกตำแหน่งไม่สำเร็จ');
    } finally {
      this.isLoadingEditOptions = false;
    }
  }

  cancelEditing(): void {
    this.isEditing = false;
    this.editItems = [];
    this.editError = '';
    if (this.job) {
      this.draftUrgent = this.job.is_urgent === 'Y';
      this.draftMultiFl = this.job.is_multi_fl === 'Y';
    }
  }

  draftLocations(itemId: number, side: 'from' | 'to'): LoadingLocationDraft[] {
    const draft = this.editItems.find((item) => item.itemId === itemId);
    return side === 'from' ? draft?.fromLocations ?? [] : draft?.toLocations ?? [];
  }

  addDraftLocation(itemId: number, side: 'from' | 'to'): void {
    const draft = this.editItems.find((item) => item.itemId === itemId);
    const item = this.job?.items.find((value) => value.id === itemId);
    if (!draft || !item) return;
    this.editError = '';

    const locations = side === 'from' ? draft.fromLocations : draft.toLocations;
    const total = Number(item.total_qty || item.qty || 0);
    const allocated = locations.reduce((sum, location) => sum + Number(location.qty || 0), 0);
    locations.push({
      id: null,
      locationId: null,
      locationType: side === 'from' ? this.job?.from_location_type || 'DOCK' : this.job?.to_location_type || 'VEHICLE',
      locationName: '',
      qty: Math.max(0, total - allocated),
      lotNo: '',
    });
  }

  removeDraftLocation(itemId: number, side: 'from' | 'to', index: number): void {
    const draft = this.editItems.find((item) => item.itemId === itemId);
    const locations = side === 'from' ? draft?.fromLocations : draft?.toLocations;
    locations?.splice(index, 1);
    this.editError = '';
  }

  updateDraftLocation(draft: LoadingLocationDraft, side: 'from' | 'to', locationId: number | null): void {
    this.editError = '';
    const id = Number(locationId);
    draft.locationId = null;
    draft.locationName = '';
    if (side === 'from') {
      const location = this.dockOptions.find((option) => option.id === id);
      if (!location) return;
      draft.locationId = id;
      draft.locationType = this.job?.from_location_type || 'DOCK';
      draft.locationName = location.location_desc;
      return;
    }

    const vehicle = this.vehicleOptions.find((option) => option.vehicle_id === id);
    if (!vehicle) return;
    draft.locationId = id;
    draft.locationType = this.job?.to_location_type || 'VEHICLE';
    draft.locationName = vehicle.vehicle_text || vehicle.license_plate;
  }

  async saveEdits(): Promise<void> {
    const job = this.job;
    if (!job || !this.isEditing || this.isSaving || this.isPalletActionInProgress) return;

    const invalidItem = this.editItems.find((draft) => {
      const item = job.items.find((value) => value.id === draft.itemId);
      if (!item) return true;
      const requiredQty = Number(item.total_qty || item.qty || 0);
      const isValid = (locations: LoadingLocationDraft[]) =>
        locations.length > 0 &&
        locations.every((location) =>
          Number.isInteger(location.locationId) &&
          (location.locationId ?? 0) > 0 &&
          !!location.locationName.trim() &&
          Number.isFinite(location.qty) &&
          location.qty > 0,
        ) &&
        locations.reduce((sum, location) => sum + location.qty, 0) === requiredQty;
      return !isValid(draft.fromLocations) || !isValid(draft.toLocations);
    });

    if (invalidItem) {
      this.editError = 'กรุณาเลือกตำแหน่ง GET/PUT และจัดสรรจำนวนให้ครบตามจำนวนของแต่ละรายการ';
      return;
    }

    this.isSaving = true;
    this.editError = '';
    try {
      const response = await firstValueFrom(
        this.crudService.processApproveJob(job.id, {
          items: this.editItems.map((draft) => ({
            id: draft.itemId,
            locations: {
              fromLocations: draft.fromLocations.map((location) => ({
                id: location.id ?? 0,
                locationId: location.locationId,
                locationType: location.locationType,
                locationName: location.locationName,
                lotNo: location.lotNo,
                qty: location.qty,
              })),
              toLocations: draft.toLocations.map((location) => ({
                id: location.id ?? 0,
                locationId: location.locationId,
                locationType: location.locationType,
                locationName: location.locationName,
                lotNo: location.lotNo,
                qty: location.qty,
              })),
            },
          })),
          forklifts: [],
          isUrgent: this.draftUrgent ? 'Y' : 'N',
          isMultiForklift: this.draftMultiFl ? 'Y' : 'N',
          isAdvanceOrder: null,
          productType: null,
          productCostCenter: null,
          updateBy: 0,
        }),
      );
      if (response.status !== 'success') {
        throw new Error(response.message || 'บันทึกตำแหน่งงานไม่สำเร็จ');
      }

      this.isEditing = false;
      await this.loadJob();
      await Swal.fire({
        icon: 'success',
        title: 'บันทึกงานสำเร็จ',
        text: job.system_no ? `งาน ${job.system_no}` : undefined,
      });
    } catch (error) {
      console.error('Error saving Truck Loading changes:', error);
      this.editError = this.errorMessage(error, 'บันทึกตำแหน่งงานไม่สำเร็จ');
      await Swal.fire({ icon: 'error', title: 'บันทึกไม่สำเร็จ', text: this.editError });
    } finally {
      this.isSaving = false;
    }
  }

  onPalletItemChange(itemId: number | null): void {
    this.selectedPalletItemId = itemId;
    this.editError = '';
    const firstDock = this.job?.items
      .find((item) => item.id === itemId)
      ?.locations?.from_locations?.find((location) => (location.location_id ?? 0) > 0);
    this.selectedDockLocationId = firstDock?.location_id ?? null;
  }

  dockLocationOptions(): LoadingSelectOption[] {
    const options = new Map<number, string>();
    for (const item of this.job?.items ?? []) {
      for (const location of item.locations?.from_locations ?? []) {
        if (location.location_id && (location.location_name || location.name)) {
          options.set(location.location_id, location.location_name || location.name || '');
        }
      }
    }
    return Array.from(options, ([id, name]) => ({ id, name }));
  }

  async receivePallet(): Promise<void> {
    const job = this.job;
    const qrCode = this.palletQrCode.trim();
    const itemId = this.selectedPalletItemId;
    const locationId = this.selectedDockLocationId;
    if (!job || this.isEditing || this.isPalletActionInProgress || !qrCode || itemId === null || locationId === null) {
      this.editError = 'กรุณาระบุ QR พาเลท รายการสินค้า และ Dock';
      return;
    }

    await this.runPalletAction(
      () => firstValueFrom(this.crudService.processLoadingGetPallet(job.id, {
        qrCodes: [qrCode],
        itemId,
        locationId,
        locationType: job.from_location_type || 'DOCK',
      })),
      'รับพาเลทเข้าจุดโหลดสำเร็จ',
    );
    if (!this.editError) this.palletQrCode = '';
  }

  async putAwayPallet(pallet: Type.LoadingJobPallet): Promise<void> {
    const job = this.job;
    const item = this.itemForPallet(pallet);
    const location = item?.locations?.to_locations?.find((value) => (value.location_id ?? 0) > 0);
    if (!job || this.isEditing || this.isPalletActionInProgress || !item || !location?.location_id ||
      (pallet.pallet_seq == null && !pallet.scanned_qr_code)) {
      this.editError = 'ไม่พบข้อมูลพาเลท รถ หรือตำแหน่ง PUT ที่จำเป็น';
      return;
    }

    await this.runPalletAction(
      () => firstValueFrom(this.crudService.processLoadingPutAway(job.id, {
        qrCode: pallet.scanned_qr_code || undefined,
        itemId: item.id,
        locationId: location.location_id!,
        locationType: job.to_location_type || 'VEHICLE',
        palletSeq: pallet.pallet_seq ?? undefined,
      })),
      'นำพาเลทขึ้นรถสำเร็จ',
    );
  }

  async resetPallet(pallet: Type.LoadingJobPallet): Promise<void> {
    const job = this.job;
    if (!job || this.isEditing || !pallet.scanned_qr_code || this.isPalletActionInProgress) return;

    const confirmation = await Swal.fire({
      icon: 'warning',
      title: 'ยืนยันการคืนพาเลท',
      text: `ต้องการคืนพาเลท ${this.palletLabel(pallet)} หรือไม่`,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    });
    if (!confirmation.isConfirmed) return;

    await this.runPalletAction(
      () => firstValueFrom(this.crudService.processLoadingResetPallet(job.id, {
        qrCode: pallet.scanned_qr_code || undefined,
      })),
      'คืนพาเลทสำเร็จ',
    );
  }

  canResetPallet(pallet: Type.LoadingJobPallet): boolean {
    return !!pallet.scanned_qr_code;
  }

  canPutAwayPallet(pallet: Type.LoadingJobPallet): boolean {
    return (pallet.pallet_seq != null || !!pallet.scanned_qr_code) &&
      !!this.itemForPallet(pallet)?.locations?.to_locations?.some((location) => (location.location_id ?? 0) > 0);
  }

  private async runPalletAction(
    action: () => Promise<Type.ResponseStandard>,
    successText: string,
  ): Promise<void> {
    if (this.isPalletActionInProgress) return;

    this.isPalletActionInProgress = true;
    this.editError = '';
    try {
      const response = await action();
      if (response.status !== 'success') {
        throw new Error(response.message || 'อัปเดตพาเลทไม่สำเร็จ');
      }
      await this.loadJob();
      await Swal.fire({ icon: 'success', title: successText });
    } catch (error) {
      console.error('Error updating Truck Loading pallet:', error);
      this.editError = this.errorMessage(error, 'อัปเดตพาเลทไม่สำเร็จ');
      await Swal.fire({ icon: 'error', title: 'ดำเนินการไม่สำเร็จ', text: this.editError });
    } finally {
      this.isPalletActionInProgress = false;
    }
  }

  private itemForPallet(pallet: Type.LoadingJobPallet): Type.LoadingJobItem | undefined {
    const gradeMatches = this.job?.items.filter((item) => item.grade === pallet.grade) ?? [];
    return gradeMatches.find((item) => !pallet.lot || this.itemLots(item).includes(pallet.lot))
      ?? gradeMatches[0]
      ?? this.job?.items[0];
  }

  private toLocationDraft(
    location: Type.LoadingJobLocation,
    locationType: string,
    item: Type.LoadingJobItem,
  ): LoadingLocationDraft {
    return {
      id: location.id ?? null,
      locationId: location.location_id ?? null,
      locationType,
      locationName: location.location_name || location.name || '',
      qty: Number(location.qty ?? item.total_qty ?? item.qty ?? 0),
      lotNo: item.lot_no || '',
    };
  }

  private includeCurrentLocationsInOptions(): void {
    const job = this.job;
    if (!job) return;

    for (const item of job.items) {
      for (const location of item.locations?.from_locations ?? []) {
        if (!location.location_id || this.dockOptions.some((option) => option.id === location.location_id)) continue;
        this.dockOptions.push({
          id: location.location_id,
          wh_code: location.wh_code || '',
          area_code: '',
          level_code: '',
          location_code: location.location_name || location.name || '',
          location_desc: location.location_name || location.name || '',
          is_active: false,
        });
      }
      for (const location of item.locations?.to_locations ?? []) {
        if (!location.location_id || this.vehicleOptions.some((option) => option.vehicle_id === location.location_id)) continue;
        const label = location.location_name || location.name || '';
        this.vehicleOptions.push({
          vehicle_id: location.location_id,
          license_plate: label,
          vehicle_text: label,
          created_date: '',
          changed_date: null,
          valid_plate: '',
          valid_insurance: '',
          rfid_card: '',
          valid_rfid: '',
          is_active: 'N',
          changed_date1: '',
          carrier_id: 0,
          carrier_code: '',
          carrier_name: '',
          vehicle_type_desc: '',
          vehicle_group_desc: '',
        });
      }
    }
  }

  private errorMessage(error: unknown, fallback: string): string {
    if (error instanceof Error && error.message) return error.message;
    if (typeof error === 'object' && error !== null && 'error' in error) {
      const payload = error.error;
      if (typeof payload === 'object' && payload !== null && 'message' in payload) {
        const message = payload.message;
        if (typeof message === 'string' && message.trim()) return message;
      }
    }
    return fallback;
  }

  goBack(): void {
    this.router.navigate(['/job-loading-list']);
  }

  statusClass(statusId: number): string {
    switch (statusId) {
      case 1:
        return 'pending';
      case 2:
        return 'wh-approved';
      case 3:
        return 'sp-approve';
      case 4:
        return 'in-progress';
      case 5:
        return 'complete';
      case 6:
        return 'mapping-do';
      default:
        return '';
    }
  }

  progressPercent(value: number, total: number): number {
    if (total <= 0) return 0;
    return Math.max(0, Math.min(100, (value / total) * 100));
  }

  formatNumber(value: number | null | undefined): string {
    return Number(value ?? 0).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  joinText(values: (string | null | undefined)[]): string {
    return values.map((value) => value?.trim() ?? '').filter(Boolean).join(' · ') || '-';
  }

  formatDateTime(value: string | null | undefined): string {
    if (!value) return '-';
    const date = new Date(value.includes('T') ? value : value.replace(' ', 'T'));
    if (Number.isNaN(date.getTime())) return value;

    const pad = (part: number) => String(part).padStart(2, '0');
    return `${pad(date.getDate())}/${pad(date.getMonth() + 1)}/${date.getFullYear()} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }

  itemLots(item: Type.LoadingJobItem): string[] {
    if (item.lot_no) return [item.lot_no];

    const lots = new Set<string>();
    for (const location of item.locations?.from_locations ?? []) {
      for (const addon of location.addon_lot ?? []) {
        if (addon.lot) lots.add(addon.lot);
      }
    }
    return Array.from(lots);
  }

  palletLabel(pallet: Type.LoadingJobPallet): string {
    return (
      pallet.text ||
      [pallet.grade, pallet.lot, `${this.formatNumber(pallet.qty)} kg`].filter(Boolean).join(' · ')
    );
  }
}
