import { Component, ElementRef, OnDestroy, ViewChild } from '@angular/core';
import {
  AbstractControl,
  FormBuilder,
  FormGroup,
  ValidationErrors,
  Validators,
} from '@angular/forms';
import { CrudService } from '../../services/crud.service';
import * as Type from '../../../models/variables-type';
import Swal from 'sweetalert2';
import { PageEvent } from '@angular/material/paginator';
import * as QRCode from 'qrcode';
import * as XLSX from 'xlsx';

function nonZeroValidator(control: AbstractControl): ValidationErrors | null {
  return Number(control.value) !== 0 ? null : { required: true };
}

//  Sentinel value patched into the edit-user form's password/confirmPassword controls while
//  the admin is NOT actively changing a Local user's password (field stays readonly - see
//  handleEditPassword). It only needs to satisfy Validators.required and passwordMatchValidator,
//  so both the ISO 27001 complexity check and the "must not contain the username" check below
//  explicitly skip it rather than blocking a save that doesn't touch the password at all.
export const PASSWORD_UNCHANGED_PLACEHOLDER = 'mock-password';

//  ISO/IEC 27001 Annex A.9.4.3 (Password Management) leaves the exact rules to the
//  organization; these are the client-side complexity rules enforced here. Password
//  history, expiry, and account lockout after failed attempts are account-lifecycle
//  concerns handled server-side, not something a create/edit form can enforce.
export const PASSWORD_MIN_LENGTH = 8;

function passwordMatchValidator(group: AbstractControl): ValidationErrors | null {
  const pw = group.get('password')?.value;
  const cpw = group.get('confirmPassword')?.value;
  // if (!pw && !cpw) return null;
  return pw === cpw ? null : { passwordMismatch: true };
}

function passwordPolicyValidator(control: AbstractControl): ValidationErrors | null {
  const value: string = control.value || '';
  if (!value || value === PASSWORD_UNCHANGED_PLACEHOLDER) return null;

  const errors: ValidationErrors = {};
  if (value.length < PASSWORD_MIN_LENGTH) errors['minLength'] = true;
  if (!/[a-z]/.test(value)) errors['lowercase'] = true;
  if (!/[A-Z]/.test(value)) errors['uppercase'] = true;
  if (!/[0-9]/.test(value)) errors['digit'] = true;
  if (!/[^A-Za-z0-9]/.test(value)) errors['special'] = true;
  if (/\s/.test(value)) errors['whitespace'] = true;
  if (/(.)\1{2,}/.test(value)) errors['repeated'] = true;

  return Object.keys(errors).length ? errors : null;
}

//  Group-level check (needs both the password and userName controls): a password that
//  contains the account's own username defeats the point of the complexity rules above.
function passwordNotUserNameValidator(group: AbstractControl): ValidationErrors | null {
  const pw: string = (group.get('password')?.value || '').toLowerCase();
  const userName: string = (group.get('userName')?.value || '').trim().toLowerCase();
  if (!pw || pw === PASSWORD_UNCHANGED_PLACEHOLDER || !userName) return null;

  return pw.includes(userName) ? { passwordContainsUserName: true } : null;
}

@Component({
  selector: 'app-user-list',
  standalone: false,
  templateUrl: './user-list.html',
  styleUrl: './user-list.css',
})

export class UserList implements OnDestroy {

  //  Constructor
  constructor(
    private crudService: CrudService,
    private fb: FormBuilder,
  ) {}

  //  Direct handle to this instance's own #print-user-area node. Looking it up by
  //  getElementById is ambiguous if a previous instance ever left an orphaned copy
  //  behind (e.g. a print action interrupted before its restore ran) - the browser
  //  silently keeps duplicate ids and getElementById only returns the first, which
  //  can leave a stale copy permanently un-addressable by id. ViewChild always
  //  resolves to this component's own node, so cleanupOrphanedPrintAreas() below can
  //  reliably tell "mine" apart from any leftover duplicate.
  @ViewChild('printUserArea', { static: true }) printUserAreaRef!: ElementRef<HTMLDivElement>;

  //  Define Column
  displayedColumns: string[] = [
  'select',
  'no',
  'userName',
  'thaiName',
  'engName',
  'department',
  'role',
  'lastUpdate',
  // 'isAd',
  'print',
  'edit',
  'delete'
];

  userList: Type.ResultProcessGetUser[] = [];
  totalCount: number = 0;
  showAddModal = false;
  showEditModal = false;
  canEditPassword = false;
  isExportingExcel = false;

  //  Skeleton loading -- table shows shimmer rows while the user list loads
  isLoading = false;
  readonly skeletonRows = Array.from({ length: 8 });

  isEditUserAd: boolean = false;
  isChangeAdToOther: boolean = false;

  //  Drives the floating password-rules popover: shown only while the password field has focus.
  passwordFieldFocused = false;

  userForm!: FormGroup;
  get f() {
    return this.userForm.controls;
  }

  readonly passwordMinLength = PASSWORD_MIN_LENGTH;

  //  Live checklist shown under the password field so the admin can see exactly which
  //  ISO/IEC 27001-aligned complexity rules are still unmet as they type.
  get passwordRuleStatus() {
    const value: string = this.f['password'].value || '';
    const minLength = value.length >= PASSWORD_MIN_LENGTH;
    const uppercase = /[A-Z]/.test(value);
    const lowercase = /[a-z]/.test(value);
    const digit = /[0-9]/.test(value);
    const special = /[^A-Za-z0-9]/.test(value);
    const noWhitespace = value.length > 0 && !/\s/.test(value);
    const noRepeated = value.length > 0 && !/(.)\1{2,}/.test(value);

    return {
      minLength,
      uppercase,
      lowercase,
      digit,
      special,
      noWhitespace,
      noRepeated,
      invalid: !(minLength && uppercase && lowercase && digit && special && noWhitespace && noRepeated),
    };
  }

  optionsUserType = [
    { id: 1, name: 'ผู้ใช้งานแบบ AD' },
    { id: 2, name: 'ผู้ใช้งานแบบ Local' },
  ];

  optionsEnableWH = [
    { value: 'Y', name: 'เปิดใช้งาน' },
    { value: 'N', name: 'ปิดใช้งาน' },
  ];

  optionsDepartment: Type.ResultProcessGetOptionsDepartment[] = [];
  optionsRole: Type.ResultProcessGetOptionsRole[] = [];

  private buildForm(): FormGroup {
    const form = this.fb.group(
      {
        id: [0],
        thaiName: ['', Validators.required],
        engName: ['', Validators.required],
        empId: [''],
        departmentId: [0, nonZeroValidator],
        roleId: [0, nonZeroValidator],
        userTypeId: [0, nonZeroValidator],
        enableWH: ['', Validators.required],
        userName: ['', Validators.required],
        password: [''],
        confirmPassword: [''],
      },
      { validators: [passwordMatchValidator, passwordNotUserNameValidator] },
    );
    this.setupUserTypeWatcher(form);
    return form;
  }

  private setupUserTypeWatcher(form: FormGroup): void {
    form.get('userTypeId')!.valueChanges.subscribe((typeId) => {
      const pw = form.get('password')!;
      const cpw = form.get('confirmPassword')!;
      if (Number(typeId) !== 1) {
        pw.setValidators([Validators.required, passwordPolicyValidator]);
        cpw.setValidators(Validators.required);
      } else {
        pw.clearValidators();
        cpw.clearValidators();
        pw.setValue('');
        cpw.setValue('');
      }
      pw.updateValueAndValidity();
      cpw.updateValueAndValidity();

      this.isChangeAdToOther = this.isEditUserAd && Number(typeId) !== 1;
      if (this.isChangeAdToOther) {
        this.canEditPassword = true;
        this.userForm.patchValue({ password: '', confirmPassword: '' });
      } else {
        this.canEditPassword = false;
        this.userForm.patchValue({
          password: PASSWORD_UNCHANGED_PLACEHOLDER,
          confirmPassword: PASSWORD_UNCHANGED_PLACEHOLDER,
        });
      }
    });
  }

  //  Filter Form
  filter: Type.UserFilter = {
    userName: '',
    thaiName: '',
    engName: '',
    departmentId: 0,
    roleId: 0,
    page: 1,
    pageSize: 25,
    sortBy: '',
    sortOrder: '',
  };

  //  Component Build Up Event
  async ngOnInit() {
    this.cleanupOrphanedPrintAreas();

    this.userForm = this.buildForm();
    await this.loadUserList();

    this.optionsDepartment = (await this.loadDepartmentOptions()).data;
    this.optionsRole = (await this.loadRoleOptions()).data;
  }

  //  Load User List
  async loadUserList() {
    this.isLoading = true;
    try {
      const result = await this.fetchUserList(this.filter);
      this.userList = result.data;
      this.totalCount = result.total_count;
      this.selectedUserIds = new Set();
    } finally {
      this.isLoading = false;
    }
  }

  //  Search Button Event
  onClickSearch() {
    this.filter.page = 1;
    this.loadUserList();
  }

  //  Export Excel Button Event -- exports every user matching the current
  //  filter (not just the rows on the current page), fetched with the full
  //  result count as the page size. Password is intentionally excluded.
  async exportToExcel(): Promise<void> {
    if (this.isExportingExcel || this.totalCount === 0) return;

    this.isExportingExcel = true;

    try {
      const result = await this.fetchUserList({
        ...this.filter,
        page: 1,
        pageSize: this.totalCount,
      });

      const rows = result.data.map((user, index) => ({
        '#': index + 1,
        'Username': user.user_name || '-',
        'Thai Name': user.thai_name || '-',
        'English Name': user.eng_name || '-',
        'Employee ID': user.emp_id || '-',
        'Department': user.department_name || '-',
        'Role': user.role_name || '-',
        'AD': user.is_ad === 'Y' ? 'Y' : 'N',
        'Last Update': user.last_update_datetime
          ? new Date(user.last_update_datetime).toLocaleString('th-TH')
          : '-',
      }));

      const worksheet = XLSX.utils.json_to_sheet(rows);
      worksheet['!cols'] = [
        { wch: 5 },
        { wch: 18 },
        { wch: 20 },
        { wch: 20 },
        { wch: 16 },
        { wch: 20 },
        { wch: 16 },
        { wch: 6 },
        { wch: 20 },
      ];

      const workbook = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(workbook, worksheet, 'User List');

      const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      XLSX.writeFile(workbook, `user-list_${timestamp}.xlsx`);
    } catch (error) {
      console.error('Error exporting user list to Excel:', error);
    } finally {
      this.isExportingExcel = false;
    }
  }

  //  Clear Button Event
  resetFilter() {
    this.filter = {
      userName: '',
      thaiName: '',
      engName: '',
      departmentId: 0,
      roleId: 0,
      page: 1,
      pageSize: 25,
      sortBy: '',
      sortOrder: '',
    };
    this.loadUserList();
  }

  //  Edit User Password
  handleEditPassword(): void {
    if (!this.canEditPassword) {
      this.userForm.patchValue({ password: '', confirmPassword: '' });
    } else {
      this.userForm.patchValue({
        password: PASSWORD_UNCHANGED_PLACEHOLDER,
        confirmPassword: PASSWORD_UNCHANGED_PLACEHOLDER,
      });
    }
    this.canEditPassword = !this.canEditPassword;
  }

  //  Open Modal Event
  openAddModal(): void {
    this.userForm = this.buildForm();
    this.showAddModal = true;
  }

  //  Close Modal Event
  closeAddModal(): void {
    this.showAddModal = false;
  }

  //  Submit Add User Button Event
  async submitAddUser(): Promise<void> {
    this.userForm.markAllAsTouched();
    if (this.userForm.invalid) return;

    try {
      const v = this.userForm.value;
      const dataRequest: Type.RequestInsertUpdateDeleteUser = {
        thaiName: v.thaiName,
        engName: v.engName,
        roleId: v.roleId,
        departmentId: v.departmentId,
        userName: v.userName,
        password: v.password,
        isAd: Number(v.userTypeId) === 1 ? 'Y' : 'N',
        isLocal: Number(v.userTypeId) === 2 ? 'Y' : 'N',
        isLdl: v.enableWH,
        userId: 0,
      };

      const response = await this.requestAddUser(dataRequest);
      if (response.status === 'success') {
        this.closeAddModal();
        await this.loadUserList();
        this.showAlert('success', response.message || 'เพิ่มผู้ใช้งานสำเร็จ');
      } else {
        this.showAlert('error', response.message || 'เกิดข้อผิดพลาดในการเพิ่มผู้ใช้งาน');
      }
    } catch (error: any) {
      console.error('Error adding user:', error);

      this.showAlert('error', error.message || 'เกิดข้อผิดพลาดในการเพิ่มผู้ใช้งาน');
    }
  }

  //  Open Edit Modal Event
  openEditModal(user: Type.ResultProcessGetUser): void {
    this.userForm = this.buildForm();
    this.canEditPassword = false;
    this.isEditUserAd = Number(user.user_type_id) === 1;
    this.userForm.patchValue({
      id: user.id,
      thaiName: user.thai_name,
      engName: user.eng_name,
      empId: user.emp_id,
      roleId: user.role_id,
      departmentId: user.department_id,
      userTypeId: user.user_type_id,
      enableWH: user.is_ldl,
      userName: user.user_name,
      password: PASSWORD_UNCHANGED_PLACEHOLDER,
      confirmPassword: PASSWORD_UNCHANGED_PLACEHOLDER,
    });
    this.showEditModal = true;
  }

  //  Close Edit Modal Event
  closeEditModal(): void {
    this.showEditModal = false;
  }

  //  Submit Edit User Button Event
  async submitEditUser(): Promise<void> {
    this.userForm.markAllAsTouched();
    console.log(this.userForm.value);
    if (this.userForm.invalid) return;

    try {
      const v = this.userForm.value;
      const dataRequest: Type.RequestInsertUpdateDeleteUser = {
        thaiName: v.thaiName,
        engName: v.engName,
        empId: v.empId,
        roleId: v.roleId,
        departmentId: v.departmentId,
        userName: v.userName,
        password: this.canEditPassword ? v.password : '',
        isAd: Number(v.userTypeId) === 1 ? 'Y' : 'N',
        isLocal: Number(v.userTypeId) === 2 ? 'Y' : 'N',
        isLdl: v.enableWH,
        userId: 0,
      };

      const response = await this.requestEditUser(v.id, dataRequest);
      if (response.status === 'success') {
        this.closeEditModal();
        await this.loadUserList();
        this.showAlert('success', response.message || 'แก้ไขผู้ใช้งานสำเร็จ');
      } else {
        this.showAlert('error', response.message || 'เกิดข้อผิดพลาดในการแก้ไขผู้ใช้งาน');
      }
    } catch (error: any) {
      console.error('Error updating user:', error);

      this.showAlert('error', error.message || 'เกิดข้อผิดพลาดในการแก้ไขผู้ใช้งาน');
    }
  }

  //  Submit Delete User Button Event
  async submitDeleteUser(data: any): Promise<void> {
    try {
      Swal.fire({
        title: 'ยืนยันการลบ',
        text: `คุณต้องการลบผู้ใช้งาน "${data.user_name}" หรือไม่?`,
        icon: 'warning',
        showCancelButton: true,
        confirmButtonText: 'ยืนยัน',
        confirmButtonColor: '#dc3545',
        cancelButtonText: 'ยกเลิก',
      }).then(async (result) => {
        if (result.isConfirmed) {
          const dataRequest: Type.RequestInsertUpdateDeleteUser = {
            userId: 0,
          };

          const response = await this.requestDeleteUser(data.id, dataRequest);
          if (response.status === 'success') {
            await this.loadUserList();
            this.showAlert('success', response.message || 'ลบผู้ใช้งานสำเร็จ');
          } else {
            this.showAlert('error', response.message || 'เกิดข้อผิดพลาดในการลบผู้ใช้งาน');
          }
        } else {
          return;
        }
      });
    } catch (error: any) {
      console.error('Error deleting user:', error);
      this.showAlert('error', error.message || 'เกิดข้อผิดพลาดในการลบผู้ใช้งาน');
    }
  }

  //  Fetch User List API
  fetchUserList(filter: Type.UserFilter): Promise<Type.ResponseProcessGetUser> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetUser(filter).subscribe(
        (response: Type.ResponseProcessGetUser) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error fetching user list:', error);
          reject(error);
        },
      );
    });
  }

  //  Request Add User Event
  requestAddUser(data: Type.RequestInsertUpdateDeleteUser): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessInsertUser(data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error inserting user:', error);
          reject(error);
        },
      );
    });
  }

  //  Request Edit User Event
  requestEditUser(
    id: number,
    data: Type.RequestInsertUpdateDeleteUser,
  ): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessUpdateUser(id, data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error updating user:', error);
          reject(error);
        },
      );
    });
  }

  //  Request Delete User Event
  requestDeleteUser(
    id: number,
    data: Type.RequestInsertUpdateDeleteUser,
  ): Promise<Type.ResponseStandard> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessDeleteUser(id, data).subscribe(
        (response: Type.ResponseStandard) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error deleting user:', error);
          reject(error);
        },
      );
    });
  }

  //  Load Deoartment Dropdown
  loadDepartmentOptions(): Promise<Type.ResponseProcessGetOptionsDepartment> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetOptionsDepartment().subscribe(
        (response: Type.ResponseProcessGetOptionsDepartment) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error fetching department options:', error);
          reject(error);
        },
      );
    });
  }

  //  Load Role Options Dropdown
  loadRoleOptions(): Promise<Type.ResponseProcessGetOptionsRole> {
    return new Promise((resolve, reject) => {
      this.crudService.ProcessGetOptionsRole().subscribe(
        (response: Type.ResponseProcessGetOptionsRole) => {
          resolve(response);
        },
        (error: any) => {
          console.error('Error fetching role options:', error);
          reject(error);
        },
      );
    });
  }

  get totalPages(): number {
    return Math.max(1, Math.ceil(this.totalCount / (this.filter.pageSize ?? 10)));
  }

  get pageNumbers(): number[] {
    const total = this.totalPages;
    const current = this.filter.page ?? 1;
    const delta = 2;
    const range: number[] = [];
    for (let i = Math.max(1, current - delta); i <= Math.min(total, current + delta); i++) {
      range.push(i);
    }
    return range;
  }

  goToPage(page: number): void {
    if (page < 1 || page > this.totalPages) return;
    this.filter.page = page;
    this.loadUserList();
  }

  onPageSizeChange(): void {
    this.filter.page = 1;
    this.loadUserList();
  }

  showAlert(iconn: any, alert_message: string) {
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

  //  Call Load User List
  this.loadUserList();
}

  //  Tracks the placeholder left in the template while #print-user-area is
  //  reparented to <body> for printing (see printUserQr). Kept as a direct
  //  reference rather than looked up by id, for the same reason as
  //  printUserAreaRef below.
  private printAreaPlaceholder: HTMLElement | null = null;

  //  Print QR Code Button Event - encodes the username as base64, embeds that
  //  base64 string as the QR data, and renders it into the hidden
  //  #print-user-area before invoking window.print().
  async printUserQr(user: Type.ResultProcessGetUser): Promise<void> {
    await this.printUsers([user]);
  }

  //  ─── Multi-select print ───────────────────────────────────────────
  //  Selection covers the current page only and is cleared whenever the
  //  list reloads (search, paging, page-size change), so at most pageSize
  //  cards print in one go.
  selectedUserIds = new Set<number>();

  isUserSelected(user: Type.ResultProcessGetUser): boolean {
    return this.selectedUserIds.has(user.id);
  }

  toggleUserSelection(user: Type.ResultProcessGetUser, checked: boolean): void {
    if (checked) this.selectedUserIds.add(user.id);
    else this.selectedUserIds.delete(user.id);
  }

  get isAllUsersSelected(): boolean {
    return this.userList.length > 0 && this.userList.every((user) => this.selectedUserIds.has(user.id));
  }

  get isSomeUsersSelected(): boolean {
    return this.selectedUserIds.size > 0 && !this.isAllUsersSelected;
  }

  toggleAllUsers(checked: boolean): void {
    this.selectedUserIds = new Set(checked ? this.userList.map((user) => user.id) : []);
  }

  async printSelectedUsers(): Promise<void> {
    const users = this.userList.filter((user) => this.selectedUserIds.has(user.id));
    if (users.length === 0) return;
    await this.printUsers(users);
  }

  //  One card (page) per user, in table order.
  private async printUsers(users: Type.ResultProcessGetUser[]): Promise<void> {
    const printable = users.filter((user) => !!user.user_name);
    if (printable.length === 0) return;

    //  The QR is scaled up to fill the card body (see .pcard__qr in
    //  user-list.css), so render it at a high resolution to keep the edges
    //  sharp when printed.
    let cards: string[];
    try {
      cards = await Promise.all(
        printable.map(async (user) => {
          const qrDataUrl = await QRCode.toDataURL(this.toBase64(user.user_name), {
            width: 1200,
            margin: 1,
          });
          return this.renderUserQrCard(user.user_name, user.thai_name || '', qrDataUrl);
        }),
      );
    } catch (error) {
      console.error('Error generating QR code:', error);
      this.showAlert('error', 'สร้าง QR Code ไม่สำเร็จ');
      return;
    }

    const printArea = this.printUserAreaRef.nativeElement;
    printArea.innerHTML = cards.join('');

    setTimeout(() => {
      if (printArea.parentNode) {
        this.printAreaPlaceholder = document.createElement('div');
        printArea.parentNode.insertBefore(this.printAreaPlaceholder, printArea);
        document.body.appendChild(printArea);
      }

      window.print();

      window.addEventListener('afterprint', this.restorePrintUserArea, { once: true });
    }, 50);
  }

  //  Moves #print-user-area (reparented to document.body by printUserQr so
  //  position:fixed reliably covers the page) back to its original spot in
  //  the template. Also called from ngOnDestroy: if the user navigates away
  //  before the browser fires "afterprint" (e.g. print dialog cancelled or
  //  never resolved), the node would otherwise stay orphaned under <body> -
  //  outliving this component and showing up unstyled on whatever page
  //  loads next, since #print-user-area's "display: none" rule is scoped to
  //  this component and goes away once it's destroyed.
  private restorePrintUserArea = (): void => {
    const printArea = this.printUserAreaRef?.nativeElement;
    if (printArea && this.printAreaPlaceholder && this.printAreaPlaceholder.parentNode) {
      this.printAreaPlaceholder.parentNode.insertBefore(printArea, this.printAreaPlaceholder);
      this.printAreaPlaceholder.remove();
    }
    this.printAreaPlaceholder = null;
  };

  ngOnDestroy(): void {
    window.removeEventListener('afterprint', this.restorePrintUserArea);
    this.restorePrintUserArea();
  }

  //  Self-heal safety net: if an earlier visit ever left #print-user-area
  //  orphaned under <body> (the "afterprint" event failed to fire for some
  //  reason), it still carries the same id as this fresh instance's own
  //  node. document.getElementById only ever resolves the first match, so
  //  code addressing the element by id could never reach - and clean up -
  //  the stray duplicate. Sweeping every match by id and dropping whichever
  //  one isn't printUserAreaRef removes it the next time this page loads,
  //  with no manual browser refresh required.
  private cleanupOrphanedPrintAreas(): void {
    document.querySelectorAll('#print-user-area, #print-user-area-placeholder').forEach((el) => {
      if (el !== this.printUserAreaRef.nativeElement) {
        el.remove();
      }
    });
  }

  //  Same card layout as location-management's printed label (.pcard): name
  //  header, QR body, "Installation QR Code System" footer. The header shows
  //  the Thai name so the card can be matched to its owner by eye, falling
  //  back to the username when the user has no Thai name. The name's font
  //  size is fixed in user-list.css (.pcard__plate), not scaled by length.
  private renderUserQrCard(userName: string, thaiName: string, qrDataUrl: string): string {
    const name = thaiName.trim() || userName;
    //  Each space-separated word (first name / surname) is its own
    //  unbreakable span, so a long name wraps only between words -- never
    //  inside a Thai word (the browser's Thai line breaking would otherwise
    //  split e.g. "ปัญญาเหมือง" into "ปัญญา / เหมือง").
    const nameHtml = name
      .split(/\s+/)
      .map((word) => `<span class="pcard__plate-word">${this.escapeHtml(word)}</span>`)
      .join(' ');
    return `
    <div class="pcard-print-page">
      <div class="pcard">
        <header class="pcard__header">
          <div class="pcard__plate">${nameHtml}</div>
        </header>
        <div class="pcard__body">
          <img class="pcard__qr" src="${qrDataUrl}" alt="QR Code" />
        </div>
        <footer class="pcard__footer">Installation QR Code System</footer>
      </div>
    </div>`;
  }

  //  UTF-8 safe base64 encoding (btoa alone only handles Latin1 strings).
  private toBase64(str: string): string {
    return btoa(unescape(encodeURIComponent(str)));
  }

  private escapeHtml(str: string): string {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
}
