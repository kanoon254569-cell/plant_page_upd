import { ComponentFixture, TestBed } from '@angular/core/testing';

import { Dialogloading } from './dialogloading';

describe('Dialogloading', () => {
  let component: Dialogloading;
  let fixture: ComponentFixture<Dialogloading>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [Dialogloading]
    })
    .compileComponents();

    fixture = TestBed.createComponent(Dialogloading);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
