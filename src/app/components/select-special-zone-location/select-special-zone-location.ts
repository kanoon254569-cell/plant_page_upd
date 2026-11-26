import { Component, Input, OnChanges, OnInit, SimpleChanges } from '@angular/core';
import { FormArray, FormControl, FormGroup } from '@angular/forms';
import * as Type from '../../../models/variables-type';
import { CrudService } from '../../services/crud.service';

type locationForm = FormGroup<{
  id: FormControl<number | null>;
  itemId: FormControl<number | null>;
  whCode: FormControl<string | null>;
  locationId: FormControl<number | null>;
  locationType: FormControl<string | null>;
  locationName: FormControl<string | null>;
  isChecked: FormControl<boolean | null>;
  isSelected: FormControl<boolean | null>;
}>;

type locationInput = {
  id: number | null;
  itemId: number | null;
  locationId: number | null;
  locationType: string | null;
  locationName: string | null;
  isChecked: boolean;
  isSelected: boolean;
};

@Component({
  selector: 'app-select-special-zone-location',
  standalone: false,
  templateUrl: './select-special-zone-location.html',
  styleUrl: './select-special-zone-location.css',
})
export class SelectSpecialZoneLocation implements OnInit, OnChanges {
  @Input() title = 'Select Location';
  //  Display-only item for the header Grade / Lot chips.
  @Input() headerItem: Type.Item | null = null;
  @Input({ required: true }) locations!: FormArray<locationForm>;
  @Input() selectedItemId: number | null = null;
  @Input() currentItemQty = 0;
  @Input() warehouseCode = '';
  @Input({ required: true }) costCenter = '';
  @Input() isRequiredStock = false;
  @Input() enableQty = false;
  @Input() openRequestId = 0;
  @Input() modalId = 'specialZoneDestLocationModal';
  @Input() confirmModalId = 'specialZoneDestLocationConfirmModal';

  _specialZoneLocationData: Type.ResultProcessSpecialLocation[] = [];
  searchForm = new FormGroup({ location: new FormControl('') });
  private isInitialized = false;

  constructor(private restService: CrudService) {}

  get headerGrade(): string {
    return this.headerItem?.grade?.trim() ?? '';
  }

  get headerLotNo(): string {
    return this.headerItem?.lot_no?.trim() ?? '';
  }

  get currentLocations(): locationForm[] {
    const search = (this.searchForm.controls.location.value || '').toLowerCase();
    return this.locations.controls.filter(
      (location) =>
        location.value.itemId === this.selectedItemId &&
        (location.value.locationName || '').toLowerCase().includes(search),
    );
  }

  ngOnInit() {
    this.isInitialized = true;
    this.loadSpecialZoneLocationData();
  }

  ngOnChanges(changes: SimpleChanges) {
    if (!this.isInitialized) return;
    if (changes['costCenter'] || changes['openRequestId'] || changes['selectedItemId']) {
      this.loadSpecialZoneLocationData();
    }
  }

  onClose() {
    const hasChanges = this.locations.controls.some(
      (location) => location.value.isChecked !== location.value.isSelected,
    );

    if (hasChanges) {
      this.showModal(this.confirmModalId);
    } else {
      this.hideModal(this.modalId);
      this.hideModal(this.confirmModalId);
    }
  }

  onResetSearch() {
    this.searchForm.controls.location.setValue('');
  }

  onToggleCheckLocation(location: locationForm) {
    location.patchValue({ isChecked: !location.value.isChecked });
  }

  onSave() {
    this.locations.controls.forEach((location) => {
      location.controls.isSelected.setValue(location.value.isChecked ?? false, { emitEvent: true });
    });
    this.hideModal(this.modalId);
    this.hideModal(this.confirmModalId);
  }

  onCancel() {
    this.locations.controls.forEach((location) => {
      location.controls.isChecked.setValue(location.value.isSelected ?? false, { emitEvent: true });
    });
    this.hideModal(this.modalId);
    this.hideModal(this.confirmModalId);
  }

  private addSpecialZoneLocation(location: locationInput) {
    this.locations.push(
      new FormGroup({
        id: new FormControl<number | null>(location.id),
        itemId: new FormControl<number | null>(location.itemId),
        whCode: new FormControl<string | null>(null),
        locationId: new FormControl<number | null>(location.locationId),
        locationType: new FormControl<string | null>(location.locationType),
        locationName: new FormControl<string | null>(location.locationName),
        isChecked: new FormControl<boolean | null>(location.isChecked),
        isSelected: new FormControl<boolean | null>(location.isSelected),
      }),
    );
  }

  private async loadSpecialZoneLocationData() {
    if (this.selectedItemId === null) return;

    const response = await this.fetchSpecialZoneLocations('');
    this._specialZoneLocationData = response.data || [];

    this._specialZoneLocationData.forEach((location) => {
      const exists = this.locations.controls.some(
        (currentLocation) =>
          currentLocation.value.locationId === location.id &&
          currentLocation.value.itemId === this.selectedItemId,
      );
      if (exists) return;

      this.addSpecialZoneLocation({
        id: null,
        itemId: this.selectedItemId,
        locationId: location.id ?? null,
        locationType: this.warehouseCode,
        locationName:
          location.plant_code && location.plant_location
            ? `${location.plant_code} (${location.plant_location})`
            : '',
        isChecked: false,
        isSelected: false,
      });
    });
  }

  private fetchSpecialZoneLocations(
    locationCode: string,
  ): Promise<Type.ResponseProcessSpecialLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetSpecialLocation(locationCode).subscribe({
        next: (response) => resolve(response),
        error: (error) => {
          console.error('Error fetching special zone locations:', error);
          reject(error);
        },
      });
    });
  }

  private hideModal(id: string) {
    const modal = document.getElementById(id);
    if (modal) (window as any).bootstrap?.Modal?.getInstance(modal)?.hide();
  }

  private showModal(id: string) {
    const modal = document.getElementById(id);
    if (modal) (window as any).bootstrap?.Modal?.getOrCreateInstance(modal)?.show();
  }
}
