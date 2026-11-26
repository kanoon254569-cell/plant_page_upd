import { AbstractControl } from '@angular/forms';
import { Component, EventEmitter, Input, Output } from '@angular/core';

type LocationControl = AbstractControl<any, any>;

@Component({
  selector: 'app-job-plant-location',
  standalone: false,
  templateUrl: './job-plant-location.html',
  styleUrls: ['./job-plant-location.css'],
})
export class JobPlantLocation {
  @Input({ required: true }) item!: { id?: number | null };
  @Input() stepStyle: { header_text: string; name: string; color: string } | undefined;
  @Input() validationErrors = false;
  @Input() locations: LocationControl[] = [];
  @Input() isEmptyLocations = false;
  @Input() canModifyLocation = false;
  @Input() modalTarget = '#plantLocationModal';
  @Input() badgeText = '';
  //  Completed job (job-detail's readOnlyMode) -- disables Add so no new
  //  location can be picked once the job can no longer be approved/saved.
  @Input() readOnly = false;
  @Input() plantCcCode = '';
  @Input() showProgress = false;
  //  Bar colour: 'get' indigo (source column), 'put' green (destination).
  @Input() progressStep: 'get' | 'put' = 'get';
  //  job-detail's plantSrcQty / plantDestQty -- the qty its save sends for
  //  this item's only plant location; null = use each row's saved qty.
  @Input() totalQty: number | null = null;
  @Input() qtyUnit: string | null = null;

  @Output() addLocation = new EventEmitter<number>();
  @Output() deleteLocation = new EventEmitter<{
    itemId: number | null;
    location: LocationControl | null;
  }>();

  //  tr_job_from/to_location qty / actual_qty -- the *GetPallet / *PutAway
  //  procs write actual_qty per scan. The total is the qty the next save sends
  //  (totalQty), so it already reads right before that save.
  getTotalQty(location: LocationControl): number {
    return this.totalQty ?? (location.value.qty || 0);
  }

  //  Saved qty differs from what the next save sends (item qty changed
  //  after approve) -- the old value is shown struck through.
  isQtyChanged(location: LocationControl): boolean {
    const savedQty = location.value.qty || 0;
    return savedQty > 0 && savedQty !== this.getTotalQty(location);
  }

  getTakenQty(location: LocationControl): number {
    return location.value.actualQty || 0;
  }

  getProgressWidth(location: LocationControl): number {
    const total = this.getTotalQty(location) || 1;
    const progressPercentage = (this.getTakenQty(location) / total) * 100;
    return Math.max(0, Math.min(progressPercentage, 100));
  }

  onAddLocation() {
    const itemId = Number(this.item?.id);
    if (!Number.isNaN(itemId)) {
      this.addLocation.emit(itemId);
    }
  }

  onDeleteLocation(location: LocationControl) {
    this.deleteLocation.emit({ itemId: this.item?.id ?? null, location: location ?? null });
  }
}
