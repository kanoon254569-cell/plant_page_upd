import { TestBed } from '@angular/core/testing';

import { JwtTokenService } from './jwt-token.service';

describe('JwtTokenService', () => {
  let service: JwtTokenService;

  const buildJwt = (payload: Record<string, unknown>) => {
    const header = { alg: 'HS256', typ: 'JWT' };
    const encode = (value: unknown) =>
      btoa(JSON.stringify(value))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, '');

    return `${encode(header)}.${encode(payload)}.signature`;
  };

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(JwtTokenService);
    sessionStorage.clear();
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  it('should decode user info from access token', () => {
    const token = buildJwt({
      id: '1',
      user_id: 'user_1',
      'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name': 'user_1',
      emp_id: 'E0002',
      'http://schemas.microsoft.com/ws/2008/06/identity/claims/role': 'LAD Forklift',
      exp: 1787009872,
    });

    service.saveTokens(token, 'refresh-token');

    expect(service.getUserId()).toBe('1');
    expect(service.getUserName()).toBe('user_1');
    expect(service.getEmpId()).toBe('E0002');
    expect(service.getUserRole()).toBe('LAD Forklift');
    expect(service.getUserInfo()).toEqual({
      id: '1',
      userId: 'user_1',
      name: 'user_1',
      empId: 'E0002',
      role: 'LAD Forklift',
      exp: 1787009872,
      issuer: null,
      audience: null,
    });
  });

  it('should decode real token claims from backend payload', () => {
    const token = buildJwt({
      id: '1',
      user_id: '1',
      user_name: 'user_1',
      emp_id: 'E0002',
      department_id: '5',
      department: 'LDL-WH',
      role_id: '5',
      role: 'LAD Forklift',
      permission: '{"transferSlip":"Y","putAway":"Y","picking":"Y"}',
      exp: 1787052035,
      iss: 'QTRACK.API',
      aud: 'QTRACK.CLIENT',
    });

    service.saveTokens(token, 'refresh-token');

    expect(service.getUserId()).toBe('1');
    expect(service.getUserName()).toBe('user_1');
    expect(service.getEmpId()).toBe('E0002');
    expect(service.getUserRole()).toBe('LAD Forklift');
    expect(service.getPermissions()).toEqual({
      transferSlip: true,
      putAway: true,
      picking: true,
    });
    expect(service.getUserInfo()).toEqual({
      id: '1',
      userId: 'user_1',
      name: 'user_1',
      empId: 'E0002',
      role: 'LAD Forklift',
      exp: 1787052035,
      issuer: 'QTRACK.API',
      audience: 'QTRACK.CLIENT',
    });
  });
});
