import { Component } from '@angular/core';
import { FormControl } from '@angular/forms';
import { Router } from '@angular/router';
import Swal from 'sweetalert2';
import { CrudService } from '../../services/crud.service';
import { JwtTokenService } from '../../services/jwt-token.service';
import { MenuAccessService } from '../../services/menu-access.service';
import { PermissionService } from '../../services/permission.service';
import { MatDialog } from '@angular/material/dialog';
import { Dialogloading } from '../dialogloading/dialogloading';
import { environment } from '../../../environments/environment';

@Component({
  selector: 'app-login',
  standalone: false,
  templateUrl: './login.html',
  styleUrl: './login.css',
})
export class Login {
  constructor(
    private router: Router,
    private restService: CrudService,
    public dialog: MatDialog,
    public jwtService: JwtTokenService,
    private menuAccess: MenuAccessService,
    private permissionService: PermissionService,
  ) {}

  _mUsername = new FormControl('');
  _mPassword = new FormControl('');
  _showPassword = false;
  readonly _version = environment.version;

  onClickSubmit() {
    if (!this._mUsername.value?.trim()) {
      this.sweetAlert('warning', 'กรุณาใส่ Username ในช่องที่กำหนด');
      return;
    }
    if (!this._mPassword.value?.trim()) {
      this.sweetAlert('warning', 'กรุณาใส่ Password ในช่องที่กำหนด');
      return;
    }

    const screenWidth = window.innerWidth;
    const dialogRef = this.dialog.open(Dialogloading, {
      width: screenWidth < 600 ? '95%' : '60%',
      height: 'auto',
      maxHeight: '90vh',
    });

    const payload = {
      userId: this._mUsername.value,
      isAd: 'N',
      // btoa encodes credentials for transport — not a security layer
      hash: btoa(`${this._mUsername.value}:${this._mPassword.value}`),
    };

    this.restService.Login(payload).subscribe({
      next: async (response) => {
        await this.jwtService.saveTokens(response?.token || '', response?.refreshToken || '');
        //  New user -> reload permissions for this token (menus, guard, buttons).
        await this.menuAccess.ensureLoaded(true);

        if (!this.permissionService.has('operation.pc_web')) {
          setTimeout(() => {
            dialogRef.close();
            this.sweetAlert('warning', 'คุณไม่มีสิทธิ์ใช้งานระบบนี้');
          }, 1000);
          return;
        }

        //  First menu this user may open, in sidebar order (see MENU_GROUPS)
        //  -- shipping-only users land on SP01, special-only on SPC01.
        const landingPath = this.menuAccess.firstAllowedPath();

        setTimeout(() => {
          dialogRef.close();
          if (!landingPath) {
            this.sweetAlert('warning', 'บัญชีนี้ยังไม่ได้รับสิทธิ์เข้าเมนูใด กรุณาติดต่อผู้ดูแลระบบ');
            return;
          }
          this.router.navigate([landingPath]);
        }, 1000);
      },

      error: (err) => {
        setTimeout(() => {
          dialogRef.close();
          console.error('Login failed:', err);
          this.sweetAlert(
            'error',
            err.error?.message?.Message || 'เข้าสู่ระบบไม่สำเร็จ กรุณาลองใหม่อีกครั้ง',
          );
        }, 1000);
      },
    });
  }

  onKeyDown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      this.onClickSubmit();
    }
  }

  private sweetAlert(icon: 'success' | 'warning' | 'error', message: string) {
    Swal.fire({
      position: 'center',
      icon,
      title: '<span style="font-size: 1.4rem; font-weight: 600; color: #0f172a;">ข้อความจากระบบ</span>',
      text: message,
      showConfirmButton: false,
      timer: 2000,
      width: '420px',
      customClass: {
        popup: 'swal2-custom-popup',
      },
      html: undefined,
    });
  }
}
