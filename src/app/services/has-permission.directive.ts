import { Directive, Input, OnDestroy, OnInit, TemplateRef, ViewContainerRef } from '@angular/core';
import { Subscription } from 'rxjs';
import { PermissionService } from './permission.service';

//  Renders the element only when the user has the permission key -- or any
//  of the keys when given an array:
//    <button *hasPermission="'user.delete'">
//    <button *hasPermission="['data.export', 'data.user_management']">
//  Hiding is for convenience only; the API enforces the same key.
@Directive({
  selector: '[hasPermission]',
  standalone: false,
})
export class HasPermissionDirective implements OnInit, OnDestroy {
  private keys: string[] = [];
  private isShown = false;
  private subscription?: Subscription;

  @Input() set hasPermission(value: string | string[]) {
    this.keys = Array.isArray(value) ? value : [value];
    this.render();
  }

  constructor(
    private templateRef: TemplateRef<unknown>,
    private viewContainer: ViewContainerRef,
    private permissionService: PermissionService,
  ) {}

  ngOnInit(): void {
    this.subscription = this.permissionService.changes$.subscribe(() => this.render());
  }

  ngOnDestroy(): void {
    this.subscription?.unsubscribe();
  }

  private render(): void {
    const allowed = this.permissionService.hasAny(this.keys);
    if (allowed && !this.isShown) {
      this.viewContainer.createEmbeddedView(this.templateRef);
      this.isShown = true;
    } else if (!allowed && this.isShown) {
      this.viewContainer.clear();
      this.isShown = false;
    }
  }
}
