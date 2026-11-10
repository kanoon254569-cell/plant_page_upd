import { AbstractControl } from '@angular/forms';
import { Component, EventEmitter, Input, Output } from '@angular/core';
import Swal, { SweetAlertIcon } from 'sweetalert2';

type LocationControl = AbstractControl<any, any>;

type locationValue = {
  locationId: number | null;
  itemId: number | null;
  locationName: string | null;
  confirmQty: number | null;
  isSelected: boolean | null;
};

@Component({
  selector: 'app-job-special-zone-location',
  standalone: false,
  templateUrl: './job-special-zone-location.html',
  styleUrls: ['./job-special-zone-location.css'],
})
export class JobSpecialZoneLocation {
  @Input({ required: true }) item!: { id?: number | null };
  @Input() itemQty = 0;
  @Input() stepStyle: { header_text: string; name: string; color: string } | undefined;
  @Input() validationErrors = false;
  @Input() enableQty = false;
  @Input() locations: LocationControl[] = [];
  @Input() isEnoughLocations = false;
  @Input() qtyLocations = 0;
  @Input() modalTarget = '#specialZoneLocationModal';
  @Input() badgeText = '';
  //  Completed job (job-detail's readOnlyMode) -- disables Add so no new
  //  location can be picked once the job can no longer be approved/saved.
  @Input() readOnly = false;
  @Input() disableModifyLocation = false;

  @Output() addLocation = new EventEmitter<number>();
  @Output() editLocation = new EventEmitter<LocationControl>();
  @Output() deleteLocation = new EventEmitter<{
    itemId: number | null;
    location: LocationControl | null;
  }>();

  IsLocationComplete(location: LocationControl): boolean {
    return location.value.completeQty >= location.value.totalPallet;
  }

  IsPalletComplete(location: LocationControl): boolean {
    return location.value.completeQty > 0;
  }

  getPalletProgressWidth(location: LocationControl): number {
    const qty = location.value.qty || 1;
    const actualQty = location.value.actualQty || 0;
    const progressPercentage = (actualQty / qty) * 100;
    return Math.max(0, Math.min(progressPercentage, 100));
  }

  onAddLocation() {
    const itemId = Number(this.item?.id);
    if (!Number.isNaN(itemId)) {
      this.addLocation.emit(itemId);
    }
  }

  onEditLocation(location: LocationControl) {
    this.editLocation.emit(location);
  }

  onDeleteLocation(location: LocationControl) {
    this.deleteLocation.emit({ itemId: this.item?.id ?? null, location: location ?? null });
  }

  confirmQtyLocations(): number {
    return this.locations
      .filter((location) => location.value.isSelected)
      .reduce((sum, location) => sum + (Number(location.value.confirmQty) || 0), 0);
  }

  findCompleteQtyLocation(locationId: number): number {
    const location = this.locations.find((loc) => loc.value.locationId === locationId);
    return location ? Number(location.value.actualQty) || 0 : 0;
  }

  onFitQtyLocation(location: LocationControl) {
    const remainingQty = this.findCompleteQtyLocation(location.value.locationId) || 0;
    location.patchValue({
      confirmQty: remainingQty,
      qty: remainingQty,
      isChecked: true,
      isSelected: true,
    });
  }

  async onAssignLocationQty(location: LocationControl) {
    const data = location.value as locationValue;
    if (!data) return;

    Swal.fire({
      title: `<span style="font-size: 22px; font-weight: 500;">จำนวนที่ตำแหน่ง (kg) : ${data.locationName}</span>`,
      html: '<span style="font-size: 16px;">กรุณาระบุจำนวนสำหรับตำแหน่งนี้</span>',
      input: 'number',
      inputAttributes: {
        min: location.value.actualQty === 0 ? '1' : String(location.value.actualQty),
        step: '1',
      },
      inputValue: data.confirmQty === 0 ? '' : data.confirmQty,
      showCancelButton: true,
      confirmButtonText: 'ยืนยัน',
      cancelButtonText: 'ยกเลิก',
    }).then((result) => {
      if (result.isConfirmed) {
        const nextConfirmQty = Number(result.value);
        const currentConfirmQty = Number(data.confirmQty) || 0;
        const totalConfirmQty = this.confirmQtyLocations() - currentConfirmQty + nextConfirmQty;

        if (Number.isNaN(nextConfirmQty) || nextConfirmQty < 0) {
          this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
          return;
        }

        if (totalConfirmQty > this.itemQty) {
          this.SwalAlert('warning', 'จำนวนสินค้ารวมเกินกว่าจำนวนที่ระบุในใบรายการ');
          return;
        }

        location.patchValue({
          confirmQty: nextConfirmQty,
          qty: nextConfirmQty,
          isChecked: true,
          isSelected: true,
        });
      }
    });
  }

  SwalAlert(icon: SweetAlertIcon, message: string) {
    const titles = {
      success: 'Success',
      error: 'Error',
      warning: 'Warning',
      info: 'Information',
      question: 'Confirmation',
    };

    Swal.fire({
      position: 'center',
      icon,
      title: `<span style="font-size:22px;font-weight:600;">${titles[icon] ?? 'Notice'}</span>`,
      html: `<span style="font-size:16px;">${message}</span>`,
      showConfirmButton: true,
    });
  }
}
