import { ComponentFixture, TestBed } from '@angular/core/testing';

import { PalletInformation } from './pallet-information';

describe('PalletInformation', () => {
  let component: PalletInformation;
  let fixture: ComponentFixture<PalletInformation>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [PalletInformation]
    })
    .compileComponents();

    fixture = TestBed.createComponent(PalletInformation);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
