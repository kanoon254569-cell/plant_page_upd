import { ComponentFixture, TestBed } from '@angular/core/testing';

import { PalletManagement } from './pallet-management';

describe('PalletManagement', () => {
  let component: PalletManagement;
  let fixture: ComponentFixture<PalletManagement>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [PalletManagement]
    })
    .compileComponents();

    fixture = TestBed.createComponent(PalletManagement);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
