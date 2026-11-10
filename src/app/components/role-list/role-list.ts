import { Component } from '@angular/core';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import Swal from 'sweetalert2';
import { PageEvent } from '@angular/material/paginator';
import * as XLSX from 'xlsx';
import { isModuleAllowedForDepartment } from '../../services/menu-access.service';

//  Permission Structure
//  Persisted in dbo.ct_role_permission (one row per role per permission_key),
//  via pWmsPlus_ProcessGetRolePermission / pWmsPlus_ProcessSaveRolePermission.
//  Each leaf below maps 1:1 to a permission_key - see PERMISSION_KEY_MAP.
export interface RolePermissions {
  inbound: {
    transferSlip: boolean;
    receive: boolean;
  };
  outbound: {
    request: boolean;
    picking: boolean;
    shipping: boolean;
    specialPackage: boolean;
    breakageReplacement: boolean;
    internalTransfer: boolean;
  };
  operation: {
    tabletPwa: boolean;
    pcWeb: boolean;
  };
  dataManagement: {
    userManagement: boolean;
    locationManagement: boolean;
    roleManagement: boolean;
    truckManagement: boolean;
    forkliftManagement: boolean;
    auditTransactionLog: boolean;
    palletManagement: boolean;
  };
  onFunction: {
    locationInfo: boolean;
    truckInfo: boolean;
  };
  //  Menu + action keys from EXTRA_PERMISSION_GROUPS, keyed by permission_key.
  extra: Record<string, boolean>;
}

//  Keys added after the fixed groups above -- own menu keys and action
//  (button) keys. Each is a ct_role_permission.permission_key read by the web
//  (*hasPermission / menu-access.service.ts) and enforced by the API
//  ([RequirePermission]). Rendered generically in the modal, so adding a key
//  here is enough for role-list; it MUST be listed here, because saving a
//  role marks every key missing from the payload as deleted.
export const EXTRA_PERMISSION_GROUPS: {
  title: string;
  //  Material icon shown in the group card header.
  icon: string;
  items: { key: string; label: string }[];
}[] = [
  {
    title: 'งาน (Job)',
    icon: 'work',
    items: [
      { key: 'job.approve', label: 'Approve งาน' },
      { key: 'job.map_do', label: 'Map DO / Map Special' },
      { key: 'job.import_shipment', label: 'Import Shipment (Excel)' },
      { key: 'wms.resend', label: 'Resend WMS+' },
    ],
  },
  {
    title: 'User',
    icon: 'person',
    items: [
      { key: 'user.create', label: 'เพิ่ม' },
      { key: 'user.update', label: 'แก้ไข' },
      { key: 'user.delete', label: 'ลบ' },
    ],
  },
  {
    title: 'Role',
    icon: 'admin_panel_settings',
    items: [
      { key: 'role.create', label: 'เพิ่ม' },
      { key: 'role.update', label: 'แก้ไข / กำหนดสิทธิ์' },
      { key: 'role.delete', label: 'ลบ' },
    ],
  },
  {
    title: 'Forklift',
    icon: 'forklift',
    items: [
      { key: 'forklift.create', label: 'เพิ่ม' },
      { key: 'forklift.update', label: 'แก้ไข' },
      { key: 'forklift.delete', label: 'ลบ' },
    ],
  },
  {
    title: 'Location / Pallet',
    icon: 'location_on',
    items: [
      { key: 'location.update', label: 'แก้ไข / Sync Location' },
      { key: 'pallet.bag_edit', label: 'เพิ่ม / แก้ไข / ลบ Bag ในพาเลท' },
      { key: 'pallet.move_to_bagging', label: 'ย้ายพาเลทกลับ Bagging Area' },
      { key: 'pallet.dummy_create', label: 'สร้าง Dummy Pallet' },
      { key: 'pallet.dummy_clear', label: 'ล้าง Dummy Pallet' },
    ],
  },
  {
    title: 'ทั่วไป',
    icon: 'tune',
    items: [
      { key: 'data.export', label: 'Export Excel' },
      { key: 'data.print_qr', label: 'พิมพ์ QR Code' },
    ],
  },
];

function emptyPermissions(): RolePermissions {
  return {
    inbound: { transferSlip: false, receive: false },
    outbound: { request: false, picking: false, shipping: false, specialPackage: false, breakageReplacement: false, internalTransfer: false },
    operation: { tabletPwa: false, pcWeb: false },
    dataManagement: {
      userManagement: false,
      locationManagement: false,
      roleManagement: false,
      truckManagement: false,
      forkliftManagement: false,
      auditTransactionLog: false,
      palletManagement: false,
    },
    onFunction: { locationInfo: false, truckInfo: false },
    extra: Object.fromEntries(
      EXTRA_PERMISSION_GROUPS.flatMap((group) => group.items.map((item) => [item.key, false])),
    ),
  };
}

//  Maps every checkbox/toggle in the modal to its dbo.ct_role_permission.permission_key.
//  Keep this in sync with sp_role_permission.sql's header comment.
const PERMISSION_KEY_MAP: {
  key: string;
  get: (p: RolePermissions) => boolean;
  set: (p: RolePermissions, v: boolean) => void;
}[] = [
  {
    key: 'inbound.transfer_slip',
    get: (p) => p.inbound.transferSlip,
    set: (p, v) => (p.inbound.transferSlip = v),
  },
  {
    key: 'inbound.receive',
    get: (p) => p.inbound.receive,
    set: (p, v) => (p.inbound.receive = v),
  },
  {
    key: 'outbound.picking',
    get: (p) => p.outbound.picking,
    set: (p, v) => (p.outbound.picking = v),
  },
  {
    key: 'outbound.shipping',
    get: (p) => p.outbound.shipping,
    set: (p, v) => (p.outbound.shipping = v),
  },
  {
    key: 'outbound.request',
    get: (p) => p.outbound.request,
    set: (p, v) => (p.outbound.request = v),
  },
  {
    key: 'outbound.special_package',
    get: (p) => p.outbound.specialPackage,
    set: (p, v) => (p.outbound.specialPackage = v),
  },
  {
    key: 'outbound.breakage_replacement',
    get: (p) => p.outbound.breakageReplacement,
    set: (p, v) => (p.outbound.breakageReplacement = v),
  },
  {
    //  WH03 menu -- shown in the Outbound column of Module Permissions.
    key: 'warehouse.internal_transfer',
    get: (p) => p.outbound.internalTransfer,
    set: (p, v) => (p.outbound.internalTransfer = v),
  },
  {
    key: 'operation.tablet_pwa',
    get: (p) => p.operation.tabletPwa,
    set: (p, v) => (p.operation.tabletPwa = v),
  },
  {
    key: 'operation.pc_web',
    get: (p) => p.operation.pcWeb,
    set: (p, v) => (p.operation.pcWeb = v),
  },
  {
    key: 'data.pallet_management',
    get: (p) => p.dataManagement.palletManagement,
    set: (p, v) => (p.dataManagement.palletManagement = v),
  },
  {
    key: 'data.location_management',
    get: (p) => p.dataManagement.locationManagement,
    set: (p, v) => (p.dataManagement.locationManagement = v),
  },
  {
    key: 'data.user_management',
    get: (p) => p.dataManagement.userManagement,
    set: (p, v) => (p.dataManagement.userManagement = v),
  },
  {
    key: 'data.audit_transaction_log',
    get: (p) => p.dataManagement.auditTransactionLog,
    set: (p, v) => (p.dataManagement.auditTransactionLog = v),
  },
  {
    key: 'data.role_management',
    get: (p) => p.dataManagement.roleManagement,
    set: (p, v) => (p.dataManagement.roleManagement = v),
  },
  {
    key: 'data.truck_management',
    get: (p) => p.dataManagement.truckManagement,
    set: (p, v) => (p.dataManagement.truckManagement = v),
  },
  {
    key: 'data.forklift_management',
    get: (p) => p.dataManagement.forkliftManagement,
    set: (p, v) => (p.dataManagement.forkliftManagement = v),
  },
  {
    key: 'on_function.location_info',
    get: (p) => p.onFunction.locationInfo,
    set: (p, v) => (p.onFunction.locationInfo = v),
  },
  {
    key: 'on_function.truck_info',
    get: (p) => p.onFunction.truckInfo,
    set: (p, v) => (p.onFunction.truckInfo = v),
  },
  ...EXTRA_PERMISSION_GROUPS.flatMap((group) =>
    group.items.map((item) => ({
      key: item.key,
      get: (p: RolePermissions) => p.extra[item.key] === true,
      set: (p: RolePermissions, v: boolean) => (p.extra[item.key] = v),
    })),
  ),
];

//  RolePermissions -> flat [{key, value}] list (for saving). A module not
//  offered for this department (MODULE_DEPARTMENTS) is always saved 'N', so
//  old ticks from before the mapping can't grant it.
function flattenPermissions(p: RolePermissions, departmentId: number): Type.RolePermissionItem[] {
  return PERMISSION_KEY_MAP.map((m) => ({
    key: m.key,
    value: m.get(p) && isModuleAllowedForDepartment(m.key, departmentId) ? 'Y' : 'N',
  }));
}

//  Module Permissions section of the modal -- rendered from this list so a
//  department tab only shows the modules MODULE_DEPARTMENTS allows for it.
export const MODULE_PERMISSION_GROUPS: { title: string; items: { key: string; label: string }[] }[] = [
  {
    title: 'Inbound',
    items: [
      { key: 'inbound.transfer_slip', label: 'Transfer Slip' },
      { key: 'inbound.receive', label: 'Receive' },
    ],
  },
  {
    title: 'Outbound',
    items: [
      { key: 'outbound.picking', label: 'Picking' },
      { key: 'outbound.shipping', label: 'Shipping' },
      { key: 'outbound.request', label: 'Request Other' },
    ],
  },
  {
    title: 'Outbound',
    items: [
      { key: 'outbound.special_package', label: 'Special Package' },
      { key: 'outbound.breakage_replacement', label: 'Breakage & Replacement' },
      { key: 'warehouse.internal_transfer', label: 'Internal Transfer' },
    ],
  },
];

function findPermission(key: string) {
  return PERMISSION_KEY_MAP.find((m) => m.key === key)!;
}

type PermissionsByDepartment = Record<number, RolePermissions>;

//  Flat rows from the API -> RolePermissions (for populating the modal)
function toRolePermissions(rows: Type.ResultRolePermission[]): RolePermissions {
  const p = emptyPermissions();
  const byKey = new Map(rows.map((r) => [r.permission_key, r.permission_value === 'Y']));
  for (const m of PERMISSION_KEY_MAP) {
    if (byKey.has(m.key)) m.set(p, byKey.get(m.key)!);
  }
  return p;
}

@Component({
  selector: 'app-role-list',
  standalone: false,
  templateUrl: './role-list.html',
  styleUrl: './role-list.css',
})
export class RoleList {
  //  Constructor
  constructor(private crudService: CrudService) {}

  //  Define Column
  displayedColumns: string[] = ['no', 'roleName', 'description', 'userCount', 'status', 'lastUpdate', 'edit', 'delete'];

  activeTab: 'permission' | 'general' = 'permission';
  permissionLoading = false;

  //  Skeleton loading -- role table rows, and department tabs / module
  //  columns in the Permission tab while that role's permissions load
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });
  readonly skeletonDepartmentTabs = Array.from({ length: 6 });
  readonly skeletonModuleColumns = [Array.from({ length: 4 }), Array.from({ length: 3 }), Array.from({ length: 4 })];

  roleList: Type.ResultProcessGetRole[] = [];
  totalCount: number = 0;
  departmentOptions: Type.ResultProcessGetOptionsDepartment[] = [];
  selectedDepartmentIds: number[] = [];
  activeDepartmentId: number | null = null;
  permissionsByDepartment: Record<number, RolePermissions> = {};

  //  Filter Form
  filter: Type.RoleFilter = {
    roleName: '',
    details: '',
    isActive: '',
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  showAddModal = false;
  showEditModal = false;
  selectedRole: Type.ResultProcessGetRole | null = null;
  isExportingExcel = false;

  roleNameInput = '';
  departmentInput = '';
  descriptionInput = '';
  statusInput: 'Y' | 'N' = 'Y';
  permissionsInput: RolePermissions = emptyPermissions();

  //  Component Build Up Event
  async ngOnInit() {
    await Promise.all([this.loadRoleList(), this.loadDepartmentOptions()]);
  }

  //  Load Role List
  async loadRoleList() {
    this.isLoading = true;
    try {
      const result = await this.fetchRoleList(this.filter);
      this.roleList = result.data;
      this.totalCount = result.total_count;
    } finally {
      this.isLoading = false;
    }
  }

  //  Search Button Event
  onClickSearch(): void {
    this.filter.page = 1;
    this.loadRoleList();
  }

  //  Clear Button Event
  resetFilter(): void {
    this.filter = {
      roleName: '',
      details: '',
      isActive: '',
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };
    this.loadRoleList();
  }

  //  Export Excel Button Event -- exports every role matching the current
  //  filter (not just the rows on the current page), fetched with the full
  //  result count as the page size.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel || this.totalCount === 0) return;

    this.isExportingExcel = true;

    try {
      const result = await this.fetchRoleList({
        ...this.filter,
        page: 1,
        pageSize: this.totalCount,
      });

      const rows = result.data.map((role, index) => ({
        '#': index + 1,
        'ชื่อบทบาท': role.role_name || '-',
        'คำอธิบาย': role.role_description || '-',
        'จำนวนผู้ใช้งาน': role.user_count ?? 0,
        'สถานะ': role.is_active === 'Y' ? 'ใช้งาน' : 'ไม่ใช้งาน',
        'Last Update': role.last_update_datetime
          ? new Date(role.last_update_datetime).toLocaleString('th-TH')
          : '-',
      }));

      const worksheet = XLSX.utils.json_to_sheet(rows);
      worksheet['!cols'] = [
        { wch: 5 },
        { wch: 20 },
        { wch: 30 },
        { wch: 16 },
        { wch: 12 },
        { wch: 20 },
      ];

      const workbook = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(workbook, worksheet, 'Role List');

      const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      XLSX.writeFile(workbook, `role-list_${timestamp}.xlsx`);
    } catch (error) {
      console.error('Error exporting role list to Excel:', error);
    } finally {
      this.isExportingExcel = false;
    }
  }

  //  Select All Permission Toggle
  get isAllPermissionSelected(): boolean {
    if (this.activeDepartmentId === null) return false;

    const p = this.activePermissions;
    const modulesSelected = MODULE_PERMISSION_GROUPS.every((group) =>
      group.items.every((item) => !this.isModuleAllowed(item.key) || this.getModule(item.key)),
    );
    return (
      modulesSelected &&
      p.operation.tabletPwa &&
      p.operation.pcWeb &&
      p.dataManagement.palletManagement &&
      p.dataManagement.locationManagement &&
      p.dataManagement.userManagement &&
      p.dataManagement.auditTransactionLog &&
      p.dataManagement.roleManagement &&
      p.dataManagement.truckManagement &&
      p.dataManagement.forkliftManagement
    );
  }

  onToggleSelectAll(checked: boolean): void {
    if (this.activeDepartmentId === null) return;

    const p = this.activePermissions;
    for (const group of MODULE_PERMISSION_GROUPS) {
      for (const item of group.items) {
        this.setModule(item.key, checked && this.isModuleAllowed(item.key));
      }
    }
    p.operation.tabletPwa = checked;
    p.operation.pcWeb = checked;
    p.dataManagement.palletManagement = checked;
    p.dataManagement.locationManagement = checked;
    p.dataManagement.userManagement = checked;
    p.dataManagement.auditTransactionLog = checked;
    p.dataManagement.roleManagement = checked;
    p.dataManagement.truckManagement = checked;
    p.dataManagement.forkliftManagement = checked;
  }

  readonly extraPermissionGroups = EXTRA_PERMISSION_GROUPS;

  //  Module Permissions offered on the active department tab only.
  isModuleAllowed(key: string): boolean {
    return isModuleAllowedForDepartment(key, this.activeDepartmentId);
  }

  visibleModuleItems(group: (typeof MODULE_PERMISSION_GROUPS)[number]) {
    return group.items.filter((item) => this.isModuleAllowed(item.key));
  }

  get visibleModuleGroups() {
    return MODULE_PERMISSION_GROUPS.filter((group) => this.visibleModuleItems(group).length > 0);
  }

  getModule(key: string): boolean {
    return findPermission(key).get(this.activePermissions);
  }

  setModule(key: string, value: boolean): void {
    findPermission(key).set(this.activePermissions, value);
  }

  isExtraGroupChecked(group: (typeof EXTRA_PERMISSION_GROUPS)[number]): boolean {
    return group.items.every((item) => this.activePermissions.extra[item.key]);
  }

  extraGroupCheckedCount(group: (typeof EXTRA_PERMISSION_GROUPS)[number]): number {
    return group.items.filter((item) => this.activePermissions.extra[item.key]).length;
  }

  toggleExtraGroup(group: (typeof EXTRA_PERMISSION_GROUPS)[number], checked: boolean): void {
    if (this.activeDepartmentId === null) return;
    for (const item of group.items) this.activePermissions.extra[item.key] = checked;
  }

  get activePermissions(): RolePermissions {
    if (this.activeDepartmentId === null) return this.permissionsInput;

    if (!this.permissionsByDepartment[this.activeDepartmentId]) {
      this.permissionsByDepartment[this.activeDepartmentId] = emptyPermissions();
    }

    return this.permissionsByDepartment[this.activeDepartmentId];
  }

  toggleDepartment(departmentId: number): void {
    const index = this.selectedDepartmentIds.indexOf(departmentId);

    if (index === -1) {
      this.selectedDepartmentIds = [...this.selectedDepartmentIds, departmentId];
      this.permissionsByDepartment[departmentId] = emptyPermissions();
      this.activeDepartmentId = departmentId;
      this.permissionsInput = this.permissionsByDepartment[departmentId];
      return;
    }

    this.selectedDepartmentIds = this.selectedDepartmentIds.filter((id) => id !== departmentId);
    delete this.permissionsByDepartment[departmentId];

    if (this.activeDepartmentId === departmentId) {
      this.activeDepartmentId = this.selectedDepartmentIds[0] ?? null;
      this.permissionsInput =
        this.activeDepartmentId === null
          ? emptyPermissions()
          : this.permissionsByDepartment[this.activeDepartmentId];
    }
  }

  selectDepartment(departmentId: number): void {
    if (!this.selectedDepartmentIds.includes(departmentId)) return;
    this.activeDepartmentId = departmentId;
    this.permissionsInput = this.permissionsByDepartment[departmentId];
  }

  selectDepartmentTab(departmentId: number): void {
    if (!this.selectedDepartmentIds.includes(departmentId)) {
      this.selectedDepartmentIds = [...this.selectedDepartmentIds, departmentId];
      this.permissionsByDepartment[departmentId] = emptyPermissions();
    }

    this.activeDepartmentId = departmentId;
    this.permissionsInput = this.permissionsByDepartment[departmentId];
  }

  departmentLabel(departmentId: number): string {
    const department = this.departmentOptions.find((option) => option.id === departmentId);
    return department ? department.code || department.name : String(departmentId);
  }

  loadDepartmentOptions(): Promise<void> {
    return new Promise((resolve) => {
      this.crudService.ProcessGetOptionsDepartment().subscribe({
        next: (response) => {
          this.departmentOptions = response.data || [];
          resolve();
        },
        error: (error) => {
          console.error('Error fetching department options:', error);
          this.departmentOptions = [];
          resolve();
        },
      });
    });
  }

  //  Open Add Modal Event
  //  (a brand-new role has no permission rows yet - starts blank; saved right after creation)
  openAddModal(): void {
    this.roleNameInput = '';
    this.departmentInput = '';
    this.selectedDepartmentIds = [];
    this.activeDepartmentId = null;
    this.permissionsByDepartment = {};
    this.descriptionInput = '';
    this.statusInput = 'Y';
    this.permissionsInput = emptyPermissions();
    this.activeTab = 'permission';
    this.showAddModal = true;
  }

  //  Close Add Modal Event
  closeAddModal(): void {
    this.showAddModal = false;
  }

  //  Submit Add Role Button Event
  async submitAddRole(): Promise<void> {
    if (!this.roleNameInput.trim()) {
      this.showAlert('error', 'กรุณากรอกชื่อบทบาท');
      return;
    }

    try {
      const dataRequest: Type.RequestInsertUpdateDeleteRole = {
        roleName: this.roleNameInput.trim(),
        roleDescription: this.descriptionInput.trim(),
        isActive: this.statusInput,
      };

      const response = await this.requestAddRole(dataRequest);
      if (response.status === 'success') {
        const newId = (response as any)?.data?.id;
        if (newId) {
          await this.requestSavePermission(newId, this.permissionsByDepartment);
        }
        this.closeAddModal();
        await this.loadRoleList();
        this.showAlert('success', response.message || 'เพิ่มบทบาทสำเร็จ');
      } else {
        this.showAlert('error', response.message || 'เกิดข้อผิดพลาดในการเพิ่มบทบาท');
      }
    } catch (error: any) {
      console.error('Error adding role:', error);
      this.showAlert('error', error.message || 'เกิดข้อผิดพลาดในการเพิ่มบทบาท');
    }
  }

  //  Open Edit Modal Event
  async openEditModal(role: Type.ResultProcessGetRole): Promise<void> {
    this.selectedRole = role;
    this.roleNameInput = role.role_name;
    this.departmentInput =
      (role as Type.ResultProcessGetRole & { department_name?: string }).department_name || '';
    this.selectedDepartmentIds = [];
    this.activeDepartmentId = null;
    this.permissionsByDepartment = {};
    this.descriptionInput = role.role_description || '';
    this.statusInput = role.is_active === 'Y' ? 'Y' : 'N';
    this.permissionsInput = emptyPermissions();
    this.activeTab = 'permission';
    this.showEditModal = true;

    this.permissionLoading = true;
    try {
      const result = await this.fetchRolePermission(role.id);
      const rows = result.data || [];

      // Group rows by department_id then build permissionsByDepartment
      const grouped = new Map<number, Type.ResultRolePermission[]>();
      for (const row of rows) {
        if (!grouped.has(row.department_id)) grouped.set(row.department_id, []);
        grouped.get(row.department_id)!.push(row);
      }

      this.selectedDepartmentIds = [...grouped.keys()];
      this.permissionsByDepartment = {};
      for (const [deptId, deptRows] of grouped.entries()) {
        this.permissionsByDepartment[deptId] = toRolePermissions(deptRows);
      }

      // Sort to match the visual order of departmentOptions tabs
      const deptOrder = new Map(this.departmentOptions.map((d, i) => [d.id, i]));
      this.selectedDepartmentIds = [...grouped.keys()].sort(
        (a, b) => (deptOrder.get(a) ?? 999) - (deptOrder.get(b) ?? 999),
      );

      this.activeDepartmentId = this.selectedDepartmentIds[0] ?? null;
      this.permissionsInput = this.activeDepartmentId !== null
        ? this.permissionsByDepartment[this.activeDepartmentId]
        : emptyPermissions();
    } catch (error: any) {
      console.error('Error fetching role permission:', error);
      this.showAlert('error', 'ไม่สามารถโหลดสิทธิ์การใช้งานของบทบาทนี้ได้');
    } finally {
      this.permissionLoading = false;
    }
  }

  //  Close Edit Modal Event
  closeEditModal(): void {
    this.showEditModal = false;
    this.selectedRole = null;
  }

  //  Submit Edit Role Button Event
  async submitEditRole(): Promise<void> {
    if (!this.selectedRole) return;
    if (!this.roleNameInput.trim()) {
      this.showAlert('error', 'กรุณากรอกชื่อบทบาท');
      return;
    }

    try {
      const dataRequest: Type.RequestInsertUpdateDeleteRole = {
        roleName: this.roleNameInput.trim(),
        roleDescription: this.descriptionInput.trim(),
        isActive: this.statusInput,
      };

      const response = await this.requestEditRole(this.selectedRole.id, dataRequest);
      if (response.status === 'success') {
        const permResponse = await this.requestSavePermission(
          this.selectedRole.id,
          this.permissionsByDepartment,
        );

        this.closeEditModal();
        await this.loadRoleList();

        if (permResponse.status === 'success') {
          this.showAlert('success', response.message || 'บันทึกการเปลี่ยนแปลงสำเร็จ');
        } else {
          this.showAlert(
            'warning',
            'บันทึกข้อมูลบทบาทสำเร็จ แต่บันทึกสิทธิ์การใช้งานไม่สำเร็จ: ' +
              (permResponse.message || ''),
          );
        }
      } else {
        this.showAlert('error', response.message || 'เกิดข้อผิดพลาดในการแก้ไขบทบาท');
      }
    } catch (error: any) {
      console.error('Error updating role:', error);
      this.showAlert('error', error.message || 'เกิดข้อผิดพลาดในการแก้ไขบทบาท');
    }
  }

  //  Submit Delete Role Button Event
  async submitDeleteRole(role: Type.ResultProcessGetRole): Promise<void> {
    try {
      Swal.fire({
        title: 'ยืนยันการลบ',
        text: `คุณต้องการลบบทบาท "${role.role_name}" หรือไม่?`,
        icon: 'warning',
        showCancelButton: true,
        confirmButtonText: 'ยืนยัน',
        confirmButtonColor: '#dc3545',
        cancelButtonText: 'ยกเลิก',
      }).then(async (result) => {
        if (result.isConfirmed) {
          const dataRequest: Type.RequestInsertUpdateDeleteRole = {};

          const response = await this.requestDeleteRole(role.id, dataRequest);
          if (response.status === 'success') {
            await this.loadRoleList();
            this.showAlert('success', response.message || 'ลบบทบาทสำเร็จ');
          } else {
            this.showAlert('error', response.message || 'เกิดข้อผิดพลาดในการลบบทบาท');
          }
        }
      });
    } catch (error: any) {
      console.error('Error deleting role:', error);
      this.showAlert('error', error.message || 'เกิดข้อผิดพลาดในการลบบทบาท');
    }
  }

  //  Fetch Role List API
  fetchRoleList(filter: Type.RoleFilter): Promise<Type.ResponseProcessGetRole> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetRole(filter).subscribe(
        (response: Type.ResponseProcessGetRole) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error fetching role list:', error);
          reject(error);
        },
      );
    });
  }

  //  Request Add Role Event
  requestAddRole(data: Type.RequestInsertUpdateDeleteRole): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessInsertRole(data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error inserting role:', error);
          reject(error);
        },
      );
    });
  }

  //  Request Edit Role Event
  requestEditRole(
    id: number,
    data: Type.RequestInsertUpdateDeleteRole,
  ): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessUpdateRole(id, data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error updating role:', error);
          reject(error);
        },
      );
    });
  }

  //  Request Delete Role Event
  requestDeleteRole(
    id: number,
    data: Type.RequestInsertUpdateDeleteRole,
  ): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessDeleteRole(id, data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error deleting role:', error);
          reject(error);
        },
      );
    });
  }

  //  Fetch Role Permission API
  fetchRolePermission(roleId: number): Promise<Type.ResponseProcessGetRolePermission> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetRolePermission(roleId).subscribe(
        (response: Type.ResponseProcessGetRolePermission) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error fetching role permission:', error);
          reject(error);
        },
      );
    });
  }

  //  Save Role Permission Event
  requestSavePermission(
    roleId: number,
    permissions: PermissionsByDepartment,
  ): Promise<Type.ResponseStandard> {
    const data: Type.RequestSaveRolePermission = {
      permissions: Object.entries(permissions).flatMap(([departmentId, departmentPermissions]) =>
        flattenPermissions(departmentPermissions, Number(departmentId)).map((permission) => ({
          ...permission,
          departmentId: Number(departmentId),
        })),
      ),
    };
    return new Promise((resolve, reject) => {
      this.crudService.ProcessSaveRolePermission(roleId, data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error saving role permission:', error);
          reject(error);
        },
      );
    });
  }

  showAlert(iconn: any, alert_message: string): void {
    Swal.fire({
      position: 'center',
      icon: iconn,
      title: 'ข้อความจากระบบ',
      text: alert_message,
      showConfirmButton: true,
    });
  }

  //  mat-paginator Event
  onPageEvent(event: PageEvent): void {
    this.filter.page = event.pageIndex + 1;
    this.filter.pageSize = event.pageSize;
    this.loadRoleList();
  }

  //  Role Icon Helper (cosmetic - no icon/color column on ct_role yet)
  getRoleIcon(roleName: string): string {
    const n = (roleName || '').toLowerCase();
    if (n.includes('admin')) return 'admin_panel_settings';
    if (n.includes('supervisor') || n.includes('boardman')) return 'supervisor_account';
    if (n.includes('forklift') || n.includes('operator')) return 'forklift';
    if (n.includes('checker')) return 'fact_check';
    if (n.includes('viewer')) return 'visibility';
    return 'badge';
  }

  getRoleColor(roleName: string): string {
    const n = (roleName || '').toLowerCase();
    if (n.includes('admin')) return '#283278';
    if (n.includes('supervisor') || n.includes('boardman')) return '#7c3aed';
    if (n.includes('forklift') || n.includes('operator')) return '#ea580c';
    if (n.includes('checker')) return '#0d9488';
    if (n.includes('viewer')) return '#6b7280';
    return '#2563eb';
  }
}
