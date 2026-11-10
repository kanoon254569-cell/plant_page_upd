import { Component } from '@angular/core';
import * as Type from '../../../models/variables-type';
import { Router } from '@angular/router';
import { JwtTokenService } from '../../services/jwt-token.service';
import { MenuAccessService, MenuGroup, MenuItem } from '../../services/menu-access.service';
import { PermissionService } from '../../services/permission.service';
import { Subscription } from 'rxjs';
import { environment } from '../../../environments/environment';

//  "WH01 - Inbound" -> code "WH01", name "Inbound". Labels without a code
//  (e.g. "User Management") keep code empty.
interface SidebarItem extends MenuItem {
  code: string;
  name: string;
}

interface SidebarGroup extends Omit<MenuGroup, 'items'> {
  items: SidebarItem[];
}

//  Titles of groups the user folded up, remembered per browser.
const COLLAPSED_GROUPS_KEY = 'sidebar.collapsedGroups';
//  AdminLTE PushMenu saves the mini/full sidebar here (header button has
//  data-enable-remember). It only restores on window load, before Angular
//  has drawn the header, so the sidebar restores it itself.
const PUSHMENU_KEY = 'remember.lte.pushmenu';
//  Same breakpoint as PushMenu autoCollapseSize -- below it the sidebar is
//  an overlay and AdminLTE decides the state.
const PUSHMENU_MIN_WIDTH = 992;

const CODE_LABEL =/^([A-Z]+\d+)\s*-\s*(.+)$/;

function toSidebarGroups(groups: MenuGroup[]): SidebarGroup[] {
  return groups.map((group) => ({
    ...group,
    items: group.items.map((item) => {
      const match = CODE_LABEL.exec(item.label);
      return { ...item, code: match ? match[1] : '', name: match ? match[2] : item.label };
    }),
  }));
}

@Component({
  selector: 'app-sidebar',
  standalone: false,
  templateUrl: './sidebar.html',
  styleUrl: './sidebar.css',
})

export class Sidebar {
  constructor(
    private router: Router,
    private jwtService: JwtTokenService,
    private menuAccess: MenuAccessService,
    private permissionService: PermissionService,
  ) { }

  private permissionSubscription?: Subscription;

  _name: string = 'Unknown User';
  _department: string = 'Unknown Department';
  _roleName: string = 'Unknown Role';
  readonly _version = environment.version;
  //  Menus come from MENU_GROUPS (menu-access.service.ts) -- the same rules
  //  the route guard checks, already filtered for this user.
  _mainGroups: SidebarGroup[] = [];
  _adminGroups: SidebarGroup[] = [];
  private collapsedGroups = new Set<string>(this.loadCollapsedGroups());

  isCollapsed(title: string): boolean {
    return this.collapsedGroups.has(title);
  }

  toggleGroup(title: string): void {
    if (!this.collapsedGroups.delete(title)) this.collapsedGroups.add(title);
    try {
      localStorage.setItem(COLLAPSED_GROUPS_KEY, JSON.stringify([...this.collapsedGroups]));
    } catch {
      //  Storage blocked -- the state just won't survive a reload.
    }
  }

  private restoreSidebarState(): void {
    if (window.innerWidth <= PUSHMENU_MIN_WIDTH) return;
    try {
      const state = localStorage.getItem(PUSHMENU_KEY);
      if (state === 'sidebar-collapse') document.body.classList.add('sidebar-collapse');
      else if (state === 'sidebar-open') document.body.classList.remove('sidebar-collapse');
    } catch {
      //  Storage blocked -- keep the default layout.
    }
  }

  private loadCollapsedGroups(): string[] {
    try {
      const saved = JSON.parse(localStorage.getItem(COLLAPSED_GROUPS_KEY) || '[]');
      return Array.isArray(saved) ? saved : [];
    } catch {
      return [];
    }
  }

  ngOnInit(): void {
    this.restoreSidebarState();
    this._name = this.jwtService.getUserName() || 'Unknown User';
    this._department = this.jwtService.getUserDepartment() || 'Unknown Department';
    this._roleName = this.jwtService.getUserRole() || 'Unknown Role';

    //  Permissions load from the API -- rebuild the menu whenever they
    //  (re)load, e.g. right after login.
    this.permissionSubscription = this.permissionService.changes$.subscribe(() => {
      this._mainGroups = toSidebarGroups(this.menuAccess.visibleGroups('main'));
      this._adminGroups = toSidebarGroups(this.menuAccess.visibleGroups('admin'));
    });
    this.menuAccess.ensureLoaded();
  }

  ngOnDestroy(): void {
    this.permissionSubscription?.unsubscribe();
  }
}
