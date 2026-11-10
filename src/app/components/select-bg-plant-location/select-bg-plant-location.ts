import {
  Component,
  EventEmitter,
  Input,
  OnChanges,
  OnInit,
  Output,
  SimpleChanges,
} from '@angular/core';
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
  whCode: string | null;
  locationId: number | null;
  locationType: string | null;
  locationName: string | null;
  isChecked: boolean;
  isSelected: boolean;
};

@Component({
  selector: 'app-select-bg-plant-location',
  standalone: false,
  templateUrl: './select-bg-plant-location.html',
  styleUrl: './select-bg-plant-location.css',
})
export class SelectBgPlantLocation implements OnInit, OnChanges {
  @Input() title = 'Select Location';
  //  Display-only item for the header Grade / Lot chips.
  @Input() headerItem: Type.Item | null = null;
  @Input({ required: true }) locations!: FormArray<locationForm>;
  @Input() selectedItemId: number | null = null;
  @Input() locationCcCode: string = '';
  @Input() locationType: string = '';
  @Input() openRequestId = 0;

  @Output() canModifyChange = new EventEmitter<boolean>();

  _bgPlantLocationData!: Type.ResultProcessBgPlantLocation[] | null;

  searchForm = new FormGroup({
    ccCode: new FormControl(''),
  });

  private isInitialized = false;

  constructor(private restService: CrudService) {}

  get headerGrade(): string {
    return this.headerItem?.grade?.trim() ?? '';
  }

  get headerLotNo(): string {
    return this.headerItem?.lot_no?.trim() ?? '';
  }

  get currentSrcLocations(): locationForm[] {
    return this.locations.controls.filter(
      (loc) => loc.value.itemId === this.selectedItemId,
    );
  }

  get canModifySrcLocation(): boolean {
    return (this._bgPlantLocationData?.length ?? 0) > 1;
  }

  ngOnInit() {
    this.isInitialized = true;
    this.searchForm.patchValue({ ccCode: this.locationCcCode }, { emitEvent: false });
    this.searchForm.controls.ccCode.disable({ emitEvent: false });
    this.initializeBgPlantOptions();
  }

  ngOnChanges(changes: SimpleChanges) {
    if (!this.isInitialized) return;

    if (changes['locationCcCode']) {
      this.searchForm.patchValue({ ccCode: this.locationCcCode }, { emitEvent: false });
      this.initializeBgPlantOptions();
    }

    if (changes['openRequestId']?.currentValue && this.selectedItemId !== null) {
      this.loadSrcLocationData();
    }
  }

  async initializeBgPlantOptions() {
    if (!this.locationCcCode) {
      this._bgPlantLocationData = [];
      this.canModifyChange.emit(false);
      return;
    }

    this._bgPlantLocationData = (await this.fetchBgPlantLocation(this.locationCcCode)).data;
    this.canModifyChange.emit(this.canModifySrcLocation);
  }

  onClose() {
    const hasChanges = this.locations.controls.some(
      (loc) => loc.value.isChecked !== loc.value.isSelected,
    );

    if (!hasChanges) {
      if (document.getElementById('plantLocationModal')) {
        this.hideplantLocationModal();
        this.hideSrcLocationConfirmModal();
        return;
      }
    }

    this.showSrcLocationConfirmModal();
  }

  onResetSearch() {
    this.searchForm.patchValue({
      ccCode: '',
    });

    this.loadSrcLocationData();
  }

  onToggleCheckLocation(location: locationForm) {
    if (!this.canModifySrcLocation || location.value.isChecked) return;

    const control = this.currentSrcLocations.find(
      (currentLocation) => currentLocation.value.locationId === location.value.locationId,
    );

    if (control) {
      const currentValue = control.value.isChecked;
      control.patchValue({ isChecked: !currentValue });
    }
  }

  onUncheckLocation(location: locationForm, event: MouseEvent) {
    event.stopPropagation();
    if (!this.canModifySrcLocation) return;

    location.patchValue({ isChecked: false });
  }

  onSave() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isSelected.setValue(loc.controls.isChecked.value, { emitEvent: true });
    });

    this.hideplantLocationModal();
    this.hideSrcLocationConfirmModal();
  }

  onCancel() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isChecked.setValue(loc.controls.isSelected.value, { emitEvent: true });
    });

    this.hideplantLocationModal();
    this.hideSrcLocationConfirmModal();
  }

  addSrcLocation(location: locationInput) {
    const form: locationForm = new FormGroup({
      id: new FormControl<number | null>(location.id ?? null),
      itemId: new FormControl<number | null>(location.itemId ?? null),
      whCode: new FormControl<string | null>(null),
      locationId: new FormControl<number | null>(location.locationId ?? null),
      locationType: new FormControl<string | null>(location.locationType ?? null),
      locationName: new FormControl<string | null>(location.locationName ?? null),
      isChecked: new FormControl<boolean | null>(location.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(location.isSelected ?? false),
    });

    this.locations.push(form);
  }

  hideplantLocationModal() {
    const modalEl = document.getElementById('plantLocationModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  hideSrcLocationConfirmModal() {
    const modalEl = document.getElementById('srcLocationConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showSrcLocationConfirmModal() {
    const modalEl = document.getElementById('srcLocationConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  async loadSrcLocationData() {
    const ccCode = this.searchForm.controls.ccCode.value || '';
    this._bgPlantLocationData = (await this.fetchBgPlantLocation(ccCode)).data;
    this.canModifyChange.emit(this.canModifySrcLocation);

    this._bgPlantLocationData.forEach((location) => {
      const exists = this.locations.controls.some(
        (currentLocation) =>
          currentLocation.value.locationId === location.id &&
          currentLocation.value.itemId === this.selectedItemId,
      );

      if (exists) return;

      const selectedLocation = this.currentSrcLocations.find(
        (currentLocation) => currentLocation.value.locationId === location.id,
      );

      this.addSrcLocation({
        id: selectedLocation?.value.id ?? null,
        itemId: this.selectedItemId,
        whCode: null,
        locationId: location.id ?? null,
        locationType: this.locationType,
        locationName:
          location.plant_code && location.plant_location
            ? `${location.plant_code} (${location.plant_location})`
            : '',
        isChecked: !!selectedLocation,
        isSelected: !!selectedLocation,
      });
    });
  }

  fetchBgPlantLocation(bgPlantCode: string): Promise<Type.ResponseProcessBgPlantLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetBgPlantLocation(bgPlantCode).subscribe(
        (response: Type.ResponseProcessBgPlantLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching bg plant location:', error);
          reject(error);
        },
      );
    });
  }
}
