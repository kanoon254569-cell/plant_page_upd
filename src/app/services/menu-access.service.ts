import { Injectable } from '@angular/core';
import { JwtTokenService } from './jwt-token.service';
import { PermissionService } from './permission.service';

//  Who may open a page. Both conditions must pass:
//    departments  -- user's department_id must be in the list (omit = any
//                    department). Kept from the old sidebar rules so this
//                    step never shows a menu a user could not see before;
//                    ct_role_permission rows are still ticked too broadly
//                    (e.g. LDL Checker in the shipping department also has
//                    inbound.*) to rely on permissions alone yet.
//    anyPermission -- the user has at least one of these ct_role_permission
//                    keys (PermissionService, GET master/me/permission).
export interface MenuAccess {
  departments?: number[];
  anyPermission: string[];
}

export interface MenuItem {
  path: string;
  label: string;
  icon: string;
  access: MenuAccess;
}

export interface MenuGroup {
  title: string;
  //  main = job menus at the top of the sidebar, admin = "Administration"
  //  block at the bottom.
  section: 'main' | 'admin';
  items: MenuItem[];
}

//  ct_department ids: 1 IT, 2 LDL, 3 PLBG, 4 PLANT, 5 LDL-WH, 6 LDL-SHIPPING,
//  7 LDL-SPECIAL, 8 SPARE.
const WAREHOUSE_DEPARTMENTS = [1, 2, 3, 4, 5, 8, 9];
const SHIPPING_DEPARTMENTS = [1, 6];
const SPECIAL_DEPARTMENTS = [1, 7];

//  Which departments a Module Permission key applies to. role-list only
//  offers (and saves as 'Y') a module on the department tabs listed here.
//  Keys not listed apply to every department.
//  Sidebar menus use the *_DEPARTMENTS lists in ACCESS below, which may be
//  narrower: LDL-WH (5) can hold outbound.special_package (used outside the
//  web menu), but SPC01 still shows only for IT and LDL-SPECIAL.
export const MODULE_DEPARTMENTS: Record<string, number[]> = {
  'inbound.transfer_slip': WAREHOUSE_DEPARTMENTS,
  'inbound.receive': WAREHOUSE_DEPARTMENTS,
  'outbound.picking': WAREHOUSE_DEPARTMENTS,
  'outbound.request': WAREHOUSE_DEPARTMENTS,
  'warehouse.internal_transfer': WAREHOUSE_DEPARTMENTS,
  'outbound.shipping': SHIPPING_DEPARTMENTS,
  'outbound.special_package': [...SPECIAL_DEPARTMENTS, 5],
  //  Every department except LDL-SHIPPING (6) and LDL-SPECIAL (7).
  'outbound.breakage_replacement': [1, 2, 3, 4, 5, 8, 9],
};

export function isModuleAllowedForDepartment(key: string, departmentId: number | null): boolean {
  const departments = MODULE_DEPARTMENTS[key];
  return !departments || (departmentId !== null && departments.includes(departmentId));
}

const ACCESS = {
  inbound: { departments: WAREHOUSE_DEPARTMENTS, anyPermission: ['inbound.transfer_slip', 'inbound.receive'] },
  outbound: { departments: WAREHOUSE_DEPARTMENTS, anyPermission: ['outbound.request', 'outbound.picking'] },
  internalTransfer: { departments: WAREHOUSE_DEPARTMENTS, anyPermission: ['warehouse.internal_transfer'] },
  //  No own key yet -- pProcessGetJobList shows TW jobs to roles with
  //  inbound_receive, so the menu follows the same permission.
  transferWarehouse: { departments: WAREHOUSE_DEPARTMENTS, anyPermission: ['inbound.receive'] },
  shipping: { departments: SHIPPING_DEPARTMENTS, anyPermission: ['outbound.shipping'] },
  special: { departments: SPECIAL_DEPARTMENTS, anyPermission: ['outbound.special_package'] },
  //  No own key -- same permission as Pallet Management.
  palletAdjustment: { anyPermission: ['data.pallet_management'] },
  palletManagement: { anyPermission: ['data.pallet_management'] },
  userManagement: { anyPermission: ['data.user_management'] },
  roleManagement: { anyPermission: ['data.role_management'] },
  forkliftManagement: { anyPermission: ['data.forklift_management'] },
  locationManagement: { anyPermission: ['data.location_management'] },
  truckManagement: { anyPermission: ['data.truck_management'] },
  auditLog: { anyPermission: ['data.audit_transaction_log'] },
} satisfies Record<string, MenuAccess>;

//  Single source for the sidebar and the route guard -- a page's menu entry
//  and its URL access can no longer drift apart.
export const MENU_GROUPS: MenuGroup[] = [
  {
    title: 'Warehouse',
    section: 'main',
    items: [
      { path: 'job-wh-list', label: 'WH01 - Inbound', icon: 'assets/images/list.png', access: ACCESS.inbound },
      { path: 'job-wh-outbound-list', label: 'WH02 - Outbound', icon: 'assets/images/list.png', access: ACCESS.outbound },
      {
        path: 'job-wh-internal-transfer-list',
        label: 'WH03 - Internal Transfer',
        icon: 'assets/images/list.png',
        access: ACCESS.internalTransfer,
      },
      {
        path: 'job-wh-transfer-list',
        label: 'WH04 - Transfer WH',
        icon: 'assets/images/list.png',
        access: ACCESS.transferWarehouse,
      },
    ],
  },
  {
    title: 'Shipping',
    section: 'main',
    items: [
      { path: 'job-shipping-list', label: 'SP01 - Shipping List', icon: 'assets/images/list.png', access: ACCESS.shipping },
    ],
  },
  {
    title: 'Special',
    section: 'main',
    items: [
      { path: 'job-special-list', label: 'SPC01 - Special List', icon: 'assets/images/list.png', access: ACCESS.special },
    ],
  },
  {
    title: 'Pallet',
    section: 'main',
    items: [
      {
        path: 'pallet-adjustment',
        label: 'BG01 - Pallet Adjustment',
        icon: 'assets/images/pallet.png',
        access: ACCESS.palletAdjustment,
      },
    ],
  },
  {
    title: 'Administration',
    section: 'admin',
    items: [
      { path: 'user-list', label: 'User Management', icon: 'assets/images/user.png', access: ACCESS.userManagement },
      { path: 'role-list', label: 'Role Management', icon: 'assets/images/list.png', access: ACCESS.roleManagement },
      {
        path: 'forklift-management',
        label: 'Forklift Management',
        icon: 'assets/images/forklift.png',
        access: ACCESS.forkliftManagement,
      },
      {
        path: 'pallet-management',
        label: 'Pallet Management',
        icon: 'assets/images/pallet.png',
        access: ACCESS.palletManagement,
      },
      {
        path: 'location-management',
        label: 'Location Management',
        icon: 'assets/images/location.png',
        access: ACCESS.locationManagement,
      },
      { path: 'vehicle-list', label: 'Print Truck QR Code', icon: 'assets/images/truck.png', access: ACCESS.truckManagement },
      { path: 'transaction-log', label: 'Transaction Log', icon: 'assets/images/log.png', access: ACCESS.auditLog },
      { path: 'wms-interface-log', label: 'WMS Interface Log', icon: 'assets/images/log.png', access: ACCESS.auditLog },
    ],
  },
];

//  Pages opened from a list (not in the sidebar) -- allowed when any of the
//  list pages that link to them is allowed.
const DETAIL_ROUTE_ACCESS: Record<string, MenuAccess[]> = {
  'job-detail/:id': [ACCESS.inbound, ACCESS.outbound, ACCESS.shipping],
  'job-wh-transfer-detail/:id': [ACCESS.transferWarehouse],
  'job-wh-internal-transfer-detail/:id': [ACCESS.internalTransfer],
  'job-special-detail/:id': [ACCESS.special],
  'pallet-information/:id': [ACCESS.palletManagement, ACCESS.forkliftManagement],
};

@Injectable({
  providedIn: 'root',
})
export class MenuAccessService {
  constructor(
    private jwtService: JwtTokenService,
    private permissionService: PermissionService,
  ) {}

  //  Permissions come from the API -- callers await this before asking
  //  canAccessRoute / visibleGroups / firstAllowedPath.
  ensureLoaded(force = false): Promise<void> {
    return this.permissionService.ensureLoaded(force);
  }

  //  routePath is the Angular route config path, e.g. 'user-list' or
  //  'job-detail/:id'. Routes not listed anywhere are allowed (login only).
  canAccessRoute(routePath: string): boolean {
    const menuItem = this.findMenuItem(routePath);
    if (menuItem) return this.isAllowed(menuItem.access);

    const detailAccess = DETAIL_ROUTE_ACCESS[routePath];
    if (detailAccess) return detailAccess.some((access) => this.isAllowed(access));

    return true;
  }

  //  Groups with their disallowed items removed; empty groups dropped.
  visibleGroups(section: MenuGroup['section']): MenuGroup[] {
    return MENU_GROUPS.filter((group) => group.section === section)
      .map((group) => ({ ...group, items: group.items.filter((item) => this.isAllowed(item.access)) }))
      .filter((group) => group.items.length > 0);
  }

  //  Landing page after login / after a blocked route. Follows sidebar order,
  //  so shipping-only users land on SP01 and special-only users on SPC01.
  firstAllowedPath(): string | null {
    for (const group of MENU_GROUPS) {
      const item = group.items.find((menuItem) => this.isAllowed(menuItem.access));
      if (item) return item.path;
    }
    return null;
  }

  private findMenuItem(routePath: string): MenuItem | undefined {
    for (const group of MENU_GROUPS) {
      const item = group.items.find((menuItem) => menuItem.path === routePath);
      if (item) return item;
    }
    return undefined;
  }

  private isAllowed(access: MenuAccess): boolean {
    if (access.departments) {
      const departmentId = Number(this.jwtService.getUserDepartmentId());
      if (!access.departments.includes(departmentId)) return false;
    }

    return this.permissionService.hasAny(access.anyPermission);
  }
}
