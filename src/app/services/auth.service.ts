import { Injectable } from '@angular/core';
import { CanActivate, Router, ActivatedRouteSnapshot, RouterStateSnapshot } from '@angular/router';
import { JwtTokenService } from './jwt-token.service';
import { MenuAccessService } from './menu-access.service';

@Injectable({
  providedIn: 'root',
})
export class AuthService implements CanActivate {
  constructor(
    private router: Router,
    private jwtService: JwtTokenService,
    private menuAccess: MenuAccessService,
  ) {}

  isLoggedIn(): boolean {
    const token = this.jwtService.getAccessToken();
    return !!token && !this.jwtService.isTokenExpired(token);
  }

  getRole(): string | null {
    return this.jwtService.getUserRole();
  }

  hasRole(allowedRoles: string[]): boolean {
    const currentRole = this.getRole();
    if (!currentRole) {
      return false;
    }

    return allowedRoles.some((role) => role.toLowerCase() === currentRole.toLowerCase());
  }

  async canActivate(route: ActivatedRouteSnapshot, state: RouterStateSnapshot): Promise<boolean> {
    const allowedRoles: string[] = route.data?.['roles'] ?? [];

    if (!this.isLoggedIn()) {
      this.router.navigate(['']);
      return false;
    }

    await this.menuAccess.ensureLoaded();

    const routePath = route.routeConfig?.path ?? '';
    const roleAllowed = allowedRoles.length === 0 || this.hasRole(allowedRoles);

    //  Same rules as the sidebar (see MENU_GROUPS in menu-access.service.ts),
    //  so typing a URL can't open a page whose menu is hidden.
    if (!roleAllowed || !this.menuAccess.canAccessRoute(routePath)) {
      this.redirectToLandingPage();
      return false;
    }

    return true;
  }

  //  First page this user may open; back to login when there is none, so a
  //  blocked user never loops between two forbidden pages.
  redirectToLandingPage(): void {
    const landingPath = this.menuAccess.firstAllowedPath();
    this.router.navigate([landingPath ?? '']);
  }
}
