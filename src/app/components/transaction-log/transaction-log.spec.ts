import { ComponentFixture, TestBed } from '@angular/core/testing';

import { TransactionLog } from './transaction-log';

describe('TransactionLog', () => {
  let component: TransactionLog;
  let fixture: ComponentFixture<TransactionLog>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [TransactionLog]
    })
    .compileComponents();

    fixture = TestBed.createComponent(TransactionLog);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
