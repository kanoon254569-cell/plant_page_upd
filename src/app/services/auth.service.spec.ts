import { TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { AuthService } from './auth.service';

describe('AuthService', () => {
  let service: AuthService;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [RouterTestingModule],
    });
    service = TestBed.inject(AuthService);
    sessionStorage.clear();
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  it('should detect logged in state and authorize allowed roles', () => {
    const token = [
      btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, ''),
      btoa(
        JSON.stringify({
          user_id: 'user_1',
          'http://schemas.microsoft.com/ws/2008/06/identity/claims/role': 'LAD Forklift',
          exp: Math.floor(Date.now() / 1000) + 3600,
        }),
      )
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, ''),
      'signature',
    ].join('.');

    sessionStorage.setItem('ACCESS_TOKEN', token);

    expect(service.isLoggedIn()).toBeTrue();
    expect(service.hasRole(['LDL Forklift'])).toBeTrue();
    expect(service.hasRole(['Admin'])).toBeFalse();
  });
});
