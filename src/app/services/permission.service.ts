import { Injectable } from '@angular/core';
import { BehaviorSubject, firstValueFrom } from 'rxjs';
import { CrudService } from './crud.service';

//  The logged-in user's permission keys (ct_role_permission keys such as
//  "data.user_management" or "user.delete"), loaded from GET master/me/permission.
//  The API checks the very same keys ([RequirePermission] in the C# API), so
//  what the web shows and what the API allows always match.
//
//  Read live instead of from the JWT "permission" claim: that claim only
//  carries the fixed set of columns WMS+ login pivots, so it can't hold the
//  action keys (user.delete, job.approve, ...).
@Injectable({
  providedIn: 'root',
})
export class PermissionService {
  private readonly granted$ = new BehaviorSubject<ReadonlySet<string>>(new Set());
  private loading: Promise<void> | null = null;
  private loaded = false;
  private loadedAt = 0;

  //  Keys are re-fetched on the next navigation once older than this, so a
  //  change saved in role-list reaches users without a re-login.
  private static readonly STALE_AFTER_MS = 30_000;

  //  Emits whenever the key set changes (login, reload, logout) -- the sidebar
  //  and *hasPermission re-render from it.
  readonly changes$ = this.granted$.asObservable();

  constructor(private crudService: CrudService) {}

  //  force = true after a new login. Otherwise a cached set is reused while
  //  fresh; a stale set is still returned immediately and refreshed in the
  //  background (the page doesn't wait on every navigation).
  ensureLoaded(force = false): Promise<void> {
    if (force) {
      this.loaded = false;
      this.loading = null;
    }
    if (this.loaded) {
      const isStale = Date.now() - this.loadedAt > PermissionService.STALE_AFTER_MS;
      if (isStale && !this.loading) this.loading = this.load();
      return Promise.resolve();
    }
    if (!this.loading) this.loading = this.load();
    return this.loading;
  }

  has(key: string): boolean {
    return this.granted$.value.has(key);
  }

  hasAny(keys: readonly string[]): boolean {
    return keys.some((key) => this.granted$.value.has(key));
  }

  clear(): void {
    this.loaded = false;
    this.loading = null;
    this.granted$.next(new Set());
  }

  private async load(): Promise<void> {
    try {
      const response = await firstValueFrom(this.crudService.ProcessGetMyPermission());
      this.granted$.next(new Set(response.status === 'success' ? response.data ?? [] : []));
      this.loaded = true;
      this.loadedAt = Date.now();
    } catch (error) {
      //  First load failing = no permissions (menus/buttons hidden); a failed
      //  background refresh keeps the last known set. Either way the next
      //  ensureLoaded() retries instead of caching the failure.
      console.error('Error loading permissions:', error);
      if (!this.loaded) this.granted$.next(new Set());
    } finally {
      this.loading = null;
    }
  }
}
