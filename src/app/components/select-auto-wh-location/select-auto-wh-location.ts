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

//  Auto warehouse (A41/A43) location picker -- same flow as
//  select-bg-plant-location, options from ct_auto_warehouse
//  (GET master/location/auto-wh/{whCode}).
@Component({
  selector: 'app-select-auto-wh-location',
  standalone: false,
  templateUrl: './select-auto-wh-location.html',
  styleUrls: ['../select-bg-plant-location/select-bg-plant-location.css', './select-auto-wh-location.css'],
})
export class SelectAutoWhLocation implements OnInit, OnChanges {
  @Input() title = 'Select Location';
  //  Display-only item for the header Grade / Lot chips.
  @Input() headerItem: Type.Item | null = null;
  @Input({ required: true }) locations!: FormArray<locationForm>;
  @Input() selectedItemId: number | null = null;
  @Input() whCode: string = '';
  @Input() locationType: string = '';
  @Input() openRequestId = 0;

  @Output() canModifyChange = new EventEmitter<boolean>();

  _autoWhLocationData!: Type.ResultProcessAutoWhLocation[] | null;

  searchForm = new FormGroup({
    whCode: new FormControl(''),
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
    return this.locations.controls.filter((loc) => loc.value.itemId === this.selectedItemId);
  }

  get canModifySrcLocation(): boolean {
    return (this._autoWhLocationData?.length ?? 0) > 1;
  }

  ngOnInit() {
    this.isInitialized = true;
    this.searchForm.patchValue({ whCode: this.whCode }, { emitEvent: false });
    this.searchForm.controls.whCode.disable({ emitEvent: false });
    this.initializeAutoWhOptions();
  }

  ngOnChanges(changes: SimpleChanges) {
    if (!this.isInitialized) return;

    if (changes['whCode']) {
      this.searchForm.patchValue({ whCode: this.whCode }, { emitEvent: false });
      this.initializeAutoWhOptions();
    }

    if (changes['openRequestId']?.currentValue && this.selectedItemId !== null) {
      this.loadSrcLocationData();
    }
  }

  async initializeAutoWhOptions() {
    if (!this.whCode) {
      this._autoWhLocationData = [];
      this.canModifyChange.emit(false);
      return;
    }

    this._autoWhLocationData = (await this.fetchAutoWhLocation(this.whCode)).data;
    this.canModifyChange.emit(this.canModifySrcLocation);
  }

  onClose() {
    const hasChanges = this.locations.controls.some(
      (loc) => loc.value.isChecked !== loc.value.isSelected,
    );

    if (!hasChanges) {
      if (document.getElementById('autoWhLocationModal')) {
        this.hideAutoWhLocationModal();
        this.hideConfirmModal();
        return;
      }
    }

    this.showConfirmModal();
  }

  onResetSearch() {
    this.searchForm.patchValue({
      whCode: '',
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

    this.hideAutoWhLocationModal();
    this.hideConfirmModal();
  }

  onCancel() {
    this.locations.controls.forEach((loc) => {
      loc.controls.isChecked.setValue(loc.controls.isSelected.value, { emitEvent: true });
    });

    this.hideAutoWhLocationModal();
    this.hideConfirmModal();
  }

  addSrcLocation(location: locationInput) {
    const form: locationForm = new FormGroup({
      id: new FormControl<number | null>(location.id ?? null),
      itemId: new FormControl<number | null>(location.itemId ?? null),
      whCode: new FormControl<string | null>(location.whCode ?? null),
      locationId: new FormControl<number | null>(location.locationId ?? null),
      locationType: new FormControl<string | null>(location.locationType ?? null),
      locationName: new FormControl<string | null>(location.locationName ?? null),
      isChecked: new FormControl<boolean | null>(location.isChecked ?? false),
      isSelected: new FormControl<boolean | null>(location.isSelected ?? false),
    });

    this.locations.push(form);
  }

  hideAutoWhLocationModal() {
    const modalEl = document.getElementById('autoWhLocationModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  hideConfirmModal() {
    const modalEl = document.getElementById('autoWhLocationConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getInstance(modalEl)?.hide();
    }
  }

  showConfirmModal() {
    const modalEl = document.getElementById('autoWhLocationConfirmModal');
    if (modalEl) {
      (window as any).bootstrap?.Modal?.getOrCreateInstance(modalEl)?.show();
    }
  }

  async loadSrcLocationData() {
    const whCode = this.searchForm.controls.whCode.value || this.whCode || '';
    this._autoWhLocationData = (await this.fetchAutoWhLocation(whCode)).data;
    this.canModifyChange.emit(this.canModifySrcLocation);

    this._autoWhLocationData.forEach((location) => {
      const exists = this.locations.controls.some(
        (currentLocation) =>
          currentLocation.value.locationId === location.id &&
          currentLocation.value.itemId === this.selectedItemId,
      );

      if (exists) return;

      this.addSrcLocation({
        id: null,
        itemId: this.selectedItemId,
        whCode: location.wh_code ?? null,
        locationId: location.id ?? null,
        locationType: this.locationType,
        locationName: location.wh_name ?? '',
        isChecked: false,
        isSelected: false,
      });
    });
  }

  fetchAutoWhLocation(whCode: string): Promise<Type.ResponseProcessAutoWhLocation> {
    return new Promise((resolve, reject) => {
      this.restService.processGetAutoWhLocation(whCode).subscribe(
        (response: Type.ResponseProcessAutoWhLocation) => {
          resolve(response);
        },
        (error) => {
          console.error('Error fetching auto warehouse location:', error);
          reject(error);
        },
      );
    });
  }
}
