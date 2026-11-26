import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ShipmentManagement } from './shipment-management';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatSelectModule } from '@angular/material/select';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatPaginatorModule } from '@angular/material/paginator';
import { NoopAnimationsModule } from '@angular/platform-browser/animations';
import { EmptyState } from '../empty-state/empty-state';

describe('ShipmentManagement', () => {
  let component: ShipmentManagement;
  let fixture: ComponentFixture<ShipmentManagement>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [ShipmentManagement, EmptyState],
      imports: [
        FormsModule,
        MatIconModule,
        MatSelectModule,
        MatFormFieldModule,
        MatInputModule,
        MatPaginatorModule,
        NoopAnimationsModule,
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(ShipmentManagement);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should initialize with mock shipments', () => {
    expect(component.allShipments.length).toBeGreaterThan(0);
    expect(component.totalDosCount).toBeGreaterThan(0);
  });
});
