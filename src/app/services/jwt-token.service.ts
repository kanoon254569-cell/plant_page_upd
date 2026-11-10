import { Injectable } from '@angular/core';

interface JwtPayload {
  id?: string | number | null;
  user_id?: string | number | null;
  user_name?: string | null;
  emp_id?: string | number | null;
  department_id?: string | number | null;
  department?: string | null;
  role_id?: string | number | null;
  role?: string | null;
  permission?: string | Record<string, unknown> | null;
  sub?: string | number | null;
  name?: string | null;
  iss?: string | null;
  aud?: string | string[] | null;
  exp?: number | string | null;
  'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'?: string | null;
  'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'?: string | null;
  [key: string]: unknown;
}

@Injectable({
  providedIn: 'root',
})
export class JwtTokenService {
  private readonly accessTokenKey = 'ACCESS_TOKEN';
  private readonly refreshTokenKey = 'REFRESH_TOKEN';

  saveTokens(tokens?: string, refreshToken?: string): void {
    if (!tokens) return;

    if (tokens) {
      sessionStorage.setItem(this.accessTokenKey, tokens);
    }

    if (refreshToken) {
      sessionStorage.setItem(this.refreshTokenKey, refreshToken);
    }
  }

  getAccessToken(): string | null {
    return sessionStorage.getItem(this.accessTokenKey);
  }

  getRefreshToken(): string | null {
    return sessionStorage.getItem(this.refreshTokenKey);
  }

  clearTokens(): void {
    sessionStorage.removeItem(this.accessTokenKey);
    sessionStorage.removeItem(this.refreshTokenKey);
  }

  hasAccessToken(): boolean {
    return !!this.getAccessToken();
  }

  private decodeTokenPayload(token: string | null): JwtPayload | null {
    if (!token) return null;

    try {
      const payloadPart = token.split('.')[1];
      if (!payloadPart) return null;

      const normalized = payloadPart.replace(/-/g, '+').replace(/_/g, '/');
      const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
      const decoded = JSON.parse(atob(padded)) as JwtPayload;
      return decoded;
    } catch {
      return null;
    }
  }

  getTokenPayload(token: string | null = this.getAccessToken()): JwtPayload | null {
    return this.decodeTokenPayload(token);
  }

  getUserId(): string | null {
    const payload = this.getTokenPayload();
    const id = payload?.id ?? payload?.user_id ?? payload?.sub;
    return id == null ? null : String(id);
  }

  getUserName(): string | null {
    const payload = this.getTokenPayload();
    const name =
      payload?.user_name ??
      payload?.name ??
      payload?.['http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'] ??
      payload?.user_id ??
      payload?.sub;
    return name == null ? null : String(name);
  }

  getEmpId(): string | null {
    const payload = this.getTokenPayload();
    const empId = payload?.emp_id;
    return empId == null ? null : String(empId);
  }

  getUserRoleId(): string | null {
    const payload = this.getTokenPayload();
    const roleId = payload?.role_id ?? null;
    return roleId == null ? null : String(roleId);
  }

  getUserRole(): string | null {
    const payload = this.getTokenPayload();
    const role =
      payload?.role ??
      payload?.['http://schemas.microsoft.com/ws/2008/06/identity/claims/role'] ??
      payload?.['role'] ??
      null;
    return role == null ? null : String(role);
  }

  getUserDepartmentId(): string | null {
    const payload = this.getTokenPayload();
    const departmentId = payload?.department_id ?? null;
    return departmentId == null ? null : String(departmentId);
  }

  getUserDepartment(): string | null {
    const payload = this.getTokenPayload();
    const department = payload?.department ?? null;
    return department == null ? null : String(department);
  }

  getPermissions(): Record<string, boolean> | null {
    const payload = this.getTokenPayload();
    const permissionValue = payload?.permission;

    if (!permissionValue) return null;

    try {
      const parsed =
        typeof permissionValue === 'string' ? JSON.parse(permissionValue) : permissionValue;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return null;
      }

      return Object.fromEntries(
        Object.entries(parsed as Record<string, unknown>).map(([key, value]) => {
          const normalized = typeof value === 'string' ? value.trim().toUpperCase() : value;
          const isAllowed =
            normalized === true ||
            normalized === 'Y' ||
            normalized === 'TRUE' ||
            normalized === '1';

          return [key, Boolean(isAllowed)];
        }),
      );
    } catch {
      return null;
    }
  }

  getUserInfo(): {
    id: string | null;
    userId: string | null;
    name: string | null;
    empId: string | null;
    role: string | null;
    exp: number | null;
    issuer: string | null;
    audience: string | string[] | null;
  } {
    const payload = this.getTokenPayload();
    const exp = payload?.exp == null ? null : Number(payload.exp);

    return {
      id: this.getUserId(),
      userId: this.getUserName(),
      name: this.getUserName(),
      empId: this.getEmpId(),
      role: this.getUserRole(),
      exp: Number.isFinite(exp) ? exp : null,
      issuer: payload?.iss ?? null,
      audience: payload?.aud ?? null,
    };
  }

  isTokenExpired(token: string | null): boolean {
    const decoded = this.decodeTokenPayload(token);
    if (!decoded) return true;

    const exp = Number(decoded.exp ?? 0);
    return Number.isFinite(exp) ? Date.now() >= exp * 1000 : true;
  }
}
