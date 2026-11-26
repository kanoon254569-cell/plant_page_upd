import { Component } from '@angular/core';
import { Router } from '@angular/router';
import * as Type from '../../../models/variables-type';
import { interval, map, share, Subscription, timer } from 'rxjs';
import { JwtTokenService } from '../../services/jwt-token.service';
import { PermissionService } from '../../services/permission.service';

@Component({
  selector: 'app-header',
  standalone: false,
  templateUrl: './header.html',
  styleUrl: './header.css',
})
export class Header {
  constructor(
    private router: Router,
    private jwtService: JwtTokenService,
    private permissionService: PermissionService,
  ) { }

  _userName: string = 'Unknow User';
  _clock = new Date().toLocaleString();
  _clockHandle: any;

  ngOnInit(): void {
    // this._clockHandle = setInterval(() => {
    //   this._clock = new Date().toLocaleString();
    // }, 1000);
  }
  ngOnDestroy(): void {
    clearInterval(this._clockHandle);
  }
  onClickLogout() {
    this.jwtService.clearTokens();
    //  Next user must not inherit this user's menus/buttons.
    this.permissionService.clear();
    this.router.navigate(['']);
  }
}
