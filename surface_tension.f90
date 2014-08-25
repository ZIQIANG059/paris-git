!=================================================================================================
!=================================================================================================
! PARIS  Parallel Robust Interface Simulator 
!=================================================================================================
! module_surface_tension: Contains definition of variables for surface tension from
!  Volume of Fluid interface tracking.
!
! Contact: Stephane Zaleski zaleski@dalembert.upmc.fr
! 
! Authors:
! 	  Yue "Stanley" Ling 
!         Leon Malan
!         Ruben Scardovelli  
!         Phil Yecko         
!         Stephane Zaleski   
!
! GPL Licence
!
!     This file is part of PARIS.
!
!     PARIS is free software: you can redistribute it and/or modify
!     it under the terms of the GNU General Public License as published by
!     the Free Software Foundation, either version 3 of the License, or
!     (at your option) any later version.
! 
!     PARIS is distributed in the hope that it will be useful,
!     but WITHOUT ANY WARRANTY; without even the implied warranty of
!     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!     GNU General Public License for more details.
!
!     You should have received a copy of the GNU General Public License
!     along with PARIS.  If not, see <http://www.gnu.org/licenses/>.
!
!-------------------------------------------------------------------------------------------------
module module_surface_tension
  use module_grid
  use module_BC
  use module_IO
!  use module_tmpvar
  use module_2phase
  use module_freesurface
  use module_VOF
  implicit none
  real(8), parameter :: kappamax = 2.d0
  integer, parameter :: nfound_min= 6 ! DO NOT Bypass the mixed height step as tests show it is less accurate

  integer, parameter :: NDEPTH=3
  integer, parameter :: BIGINT=100
  real(8), parameter :: D_HALF_BIGINT = DBLE(BIGINT/2)
  integer, parameter :: MAX_EXT_H = 0
  integer, parameter :: NOR=6 ! number of orientations
  integer, parameter :: NPOS=NOR*27
  real(8), parameter :: EPS_GEOM = 1d-4
  real(8), dimension(:,:,:), allocatable :: n1,n2,n3 ! normals
  real(8), dimension(:,:,:), allocatable :: kappa_fs ! for surface tension on free surface
  real(8), dimension(:,:,:,:), allocatable :: height ! 

  ! 4th index: 1 for normal vector pointing towards positive x "positive height", 
  ! 2 for "negative" height in x
  ! 3 for positive height in y, 4 for negative height in y, 
  !  etc... 
  integer, dimension(:,:,:,:), allocatable :: ixheight ! HF flags for rph (Ruben-Phil) routines
  logical :: st_initialized = .false.
  logical :: recomputenormals = .true.
  logical :: debug_curvature = .false.
  logical :: debug_23 = .false.
  integer :: method_count(3)
  integer, parameter :: ngc=20
  integer :: geom_case_count(ngc)

!  type geom_case
!     character(10) :: name
!     integer :: count
!  end type geom_case
!  type (geom_case) :: geom_case_list(10) = (/ ("mixed",0),("full",0),("empty",1) /)

contains
!=================================================================================================
  subroutine initialize_surface_tension()
    implicit none
    if(.not.recomputenormals .or. FreeSurface) then
       allocate(n1(imin:imax,jmin:jmax,kmin:kmax), n2(imin:imax,jmin:jmax,kmin:kmax),  &
               n3(imin:imax,jmin:jmax,kmin:kmax), kappa_fs(imin:imax,jmin:jmax,kmin:kmax))
       recomputenormals = .false.
    endif
    allocate(height(imin:imax,jmin:jmax,kmin:kmax,6))
    if(nx.ge.500000.or.ny.gt.500000.or.nz.gt.500000) call pariserror("nx too large")
    if(NDEPTH.gt.20) call pariserror("ndepth too large")
    if(NDEPTH>BIGINT/2-2) call pariserror("BIGINT too small")
    if(MAX_EXT_H>BIGINT/2-2) call pariserror("MAX_EXT > BIGINT/2")
    if(MAX_EXT_H>nx/2) call pariserror("MAX_EXT > nx/2")
!    allocate(geom_case_list(10))
    geom_case_count = 0
    height = 2.d6
    st_initialized=.true.
   end subroutine initialize_surface_tension
!
   subroutine print_st_stats()
     use module_BC
     implicit none
     include 'mpif.h'
     integer :: ierr,i
     integer :: glob_count(ngc)
     character(len=85) :: glob_desc(ngc)
     if(st_initialized) then
        call MPI_ALLREDUCE(geom_case_count, glob_count, ngc, MPI_INTEGER, MPI_SUM, MPI_COMM_Cart, ierr)  
        if(rank==0) then
           open(unit=101, file=trim(out_path)//'/st_stats', action='write', iostat=ierr)
           glob_desc(1)="mixed w/less than 3 mixed neighbors (quasi-isolated mixed, unfittable by sphere)"
           glob_desc(2)="mixed w/less than 5 mixed neighbors (quasi-isolated mixed, unfittable by paraboloid)"
           glob_desc(3)="pure cells w/more than 2 other color pure neighbors (grid-aligned interfaces)"
           glob_desc(4)="non-bulk pure cells w 0 valid neighbors"
           glob_desc(5)="                      1  " 
           glob_desc(6)="                      2  " 
           glob_desc(7)="                      3  " 
           glob_desc(8)="                      4  "
           glob_desc(9)="                      5 valid neighbors (unfittable by paraboloid)"
           glob_desc(10)="no fit success with 0 valid centroids "
           glob_desc(11)="                    1  " 
           glob_desc(12)="                    2  " 
           glob_desc(13)="                    3  " 
           glob_desc(14)="                    4  " 
           glob_desc(15)="                    5 valid centroids"
           glob_desc(16)="                    6 or more valid centroids (impossible)"
           glob_desc(17)="large kappa"
           glob_desc(18)="no surface tension force in x direction"
           glob_desc(19)="no surface tension force in y direction"
           glob_desc(20)="no surface tension force in z direction"
           do i=1,ngc
              write(101,'(I10," ",A85)') geom_case_count(i), glob_desc(i)
           enddo
           close(101)
        endif
     endif
   end subroutine print_st_stats
        
!=================================================================================================
! 
!  Put normals in a common array. Absolutely not sure this is efficient
!
!=================================================================================================
   subroutine get_normals()
     implicit none
     real(8) :: stencil3x3(-1:1,-1:1,-1:1)
     integer :: i,j,k
     integer :: i0,j0,k0
     real(8) :: mxyz(3)
     if(.not.st_initialized) call initialize_surface_tension()
     if(recomputenormals) call pariserror("recomputenormals is true, normals not allocated")

     if(ng.lt.2) call pariserror("wrong ng")
      do k=ks-1,ke+1
         do j=js-1,je+1
            do i=is-1,ie+1
               do i0=-1,1; do j0=-1,1; do k0=-1,1
                  stencil3x3(i0,j0,k0) = cvof(i+i0,j+j0,k+k0)
               enddo;enddo;enddo
               call mycs(stencil3x3,mxyz)
               n1(i,j,k) = mxyz(1)
               n2(i,j,k) = mxyz(2)
               n3(i,j,k) = mxyz(3)
            enddo
         enddo
      enddo
   end subroutine get_normals
!=================================================================================================
!
!  Extrapolation of velocities for free surface
!
!=================================================================================================
   subroutine extrapolate_velocities()
     use module_grid
     use module_flow
     use module_2phase
     use module_freesurface
     implicit none
     include 'mpif.h'
     integer :: i,j,k,level,ii,jj,kk
     real(8) :: x_cut, y_cut, xz_cut
     real(8) :: alpha, al3dnew, nr(3), P_a, Src
     real(8) :: a_l, a_rt, a_t, a_b, a_f, a_rr
     real(8) :: x_vel, xcount
     !real(8), dimension(imin:imax,jmin:jmax,kmin:kmax) :: ucmask,vcmask,wcmask

!----OLD MASKS, REMOVE
     !ucmask = 0d0; vcmask = 0d0; wcmask =0d0
     !this loop masks extrapolated velocity locations 
!!$     do k=ks,ke; do j=js,je; do i=is,ie
!!$        if (vof_flag(i,j,k) == 2) then
!!$           nr(1) = n1(i,j,k);         nr(2) = n2(i,j,k);         nr(3) = n3(i,j,k)
!!$           alpha = al3dnew(nr,cvof(i,j,k))
!!$           !=========Set mask for u-velocity in cut-cells          
!!$           if (n_1 < 1d-49) n_1 = 1d-49
!!$           x_cut = (alpha - n_3/2d0)/n_1
!!$           if (x_cut>0.5d0) then
!!$              if (n2(i,j,k)>0d0) then
!!$                 vcmask(i,j-1,k) = 1d0
!!$              else
!!$                 vcmask(i,j,k) = 1d0
!!$              endif
!!$           endif
!!$           x_cut = (alpha - n_2 - n_3/2d0)/n_1
!!$           if (x_cut>0.5d0) then
!!$              if (n2(i,j,k)>0d0) then
!!$                 vcmask(i,j,k) = 1d0
!!$              else
!!$                 vcmask(i,j-1,k) = 1d0
!!$              endif
!!$           endif
!!$           !=========Set mask for v-velocity in cut-cells
!!$           if (n_2 < 1d-49) n_2 = 1d-49
!!$           y_cut = (alpha - n_3/2d0)/n_2
!!$           if (y_cut>0.5d0) then
!!$              if (n1(i,j,k)>0d0) then
!!$                 ucmask(i-1,j,k) = 1d0
!!$              else
!!$                 ucmask(i,j,k) = 1d0
!!$              endif
!!$           endif
!!$           y_cut = (alpha - n_1 - n_3/2d0)/n_2
!!$           if (y_cut>0.5d0) then
!!$              if (n1(i,j,k)>0d0) then
!!$                 ucmask(i,j,k) = 1d0
!!$              else
!!$                 ucmask(i-1,j,k) = 1d0
!!$              endif
!!$           endif
!!$           !=========Set mask for w-velocity in cut-cells
!!$           if (n_1 < 1d-49) n_1 = 1d-49
!!$           xz_cut = (alpha - n_2/2d0)/n_1
!!$           if (xz_cut>0.5d0) then
!!$              if (n3(i,j,k)>0d0) then
!!$                 wcmask(i,j,k-1) = 1d0
!!$              else
!!$                 wcmask(i,j,k) = 1d0
!!$              endif
!!$           endif
!!$           xz_cut = (alpha - n_3 - n_2/2d0)/n_1
!!$           if (xz_cut>0.5d0) then
!!$              if (n3(i,j,k)>0d0) then
!!$                 wcmask(i,j,k) = 1d0
!!$              else
!!$                 wcmask(i,j,k-1) = 1d0
!!$              endif
!!$           endif
!!$        endif
!!$        !=========Set mask for all velocities in cavity cells neighbouring cut cells
!!$        if ((vof_flag(i,j,k) == 1) .and. ((vof_flag(i-1,j,k) == 2) .or. (vof_flag(i+1,j,k) == 2) .or. &
!!$             (vof_flag(i,j-1,k) == 2) .or. (vof_flag(i,j+1,k) == 2) .or. &
!!$             (vof_flag(i,j,k-1) == 2) .or. (vof_flag(i,j,k+1) == 2))) then
!!$           ucmask(i,j,k) = 1d0; ucmask(i-1,j,k) = 1d0
!!$           vcmask(i,j,k) = 1d0; vcmask(i,j-1,k) = 1d0
!!$           wcmask(i,j,k) = 1d0; wcmask(i,j,k-1) = 1d0
!!$        endif
!!$     enddo; enddo; enddo
     do level = 1, X_level
        do k=ks,ke; do j=js,je; do i=is,ie
           if (u_cmask(i,j,k,level) == 1) then
              xcount = 0d0; x_vel = 0d0
              do kk=-1,1; do jj=-1,1; do ii=-1,1
                 if (u_cmask(i+ii,j+jj,k+kk,level-1)==1) then
                    xcount = xcount+1d0
                    x_vel = x_vel + u(i+ii,j+jj,k+kk)
                 endif
              enddo; enddo; enddo
              if (xcount>0d0) then
                 u(i,j,k) = x_vel/xcount
              endif
           endif
           if (v_cmask(i,j,k,level) == 1) then
              xcount = 0d0; x_vel = 0d0
              do kk=-1,1; do jj=-1,1; do ii=-1,1
                 if (v_cmask(i+ii,j+jj,k+kk,level-1)==1) then
                    xcount = xcount+1d0
                    x_vel = x_vel + v(i+ii,j+jj,k+kk)
                 endif
              enddo; enddo; enddo
              if (xcount>0d0) then
                 v(i,j,k) = x_vel/xcount
              endif
           endif
           if (w_cmask(i,j,k,level) == 1) then
              xcount = 0d0; x_vel = 0d0
              do kk=-1,1; do jj=-1,1; do ii=-1,1
                 if (w_cmask(i+ii,j+jj,k+kk,level-1)==1) then
                    xcount = xcount+1d0
                    x_vel = x_vel + w(i+ii,j+jj,k+kk)
                 endif
              enddo; enddo; enddo
              if (xcount>0d0) then
                 w(i,j,k) = x_vel/xcount
              endif
           endif
        enddo; enddo; enddo
     enddo
! Simple volume conservation step after velocities have been extrapolated.
     Src = 0d0
     do level = 1, X_level
        do k=ks,ke; do j=js,je; do i=is,ie
           a_l = 0d0; a_rt = 0d0; a_t = 0d0; a_b = 0d0; a_f = 0d0; a_rr = 0d0    
           Src = (u(i-1,j,k)-u(i,j,k))*dz(k)*dy(j) + (v(i,j-1,k)-v(i,j,k))*dx(i)*dz(k) + (w(i,j,k-1)-w(i,j,k))*dx(i)*dy(j)
           if ((n1(i,j,k) > 0d0) .and. (u_cmask(i-1,j,k,level)==1)) a_l = 1d0
           if ((n1(i,j,k) < 0d0) .and. (u_cmask(i,j,k,level)==1)) a_rt = 1d0
           if ((n2(i,j,k) > 0d0) .and. (v_cmask(i,j-1,k,level)==1)) a_b = 1d0
           if ((n2(i,j,k) < 0d0) .and. (v_cmask(i,j,k,level)==1)) a_t = 1d0
           if ((n3(i,j,k) > 0d0) .and. (w_cmask(i,j,k-1,level)==1)) a_rr = 1d0
           if ((n3(i,j,k) < 0d0) .and. (w_cmask(i,j,k,level)==1)) a_f = 1d0
           P_a = (a_l+a_rt)*abs(n1(i,j,k))*dy(j)*dz(k) + &
                (a_t + a_b)*abs(n2(i,j,k))*dx(i)*dz(k) + &
                (a_f + a_rr)*abs(n3(i,j,k))*dx(i)*dy(j)
           if (P_a .ne. 0) then
              u(i,j,k) = u(i,j,k) + a_rt*Src/P_a*abs(n1(i,j,k)) 
              v(i,j,k) = v(i,j,k) + a_t*Src/P_a*abs(n2(i,j,k))  
              w(i,j,k) = w(i,j,k) + a_f*Src/P_a*abs(n3(i,j,k))
              u(i-1,j,k) = u(i-1,j,k) - a_l*Src/P_a*abs(n1(i,j,k)) 
              v(i,j-1,k) = v(i,j-1,k) - a_b*Src/P_a*abs(n2(i,j,k))  
              w(i,j,k-1) = w(i,j,k-1) - a_rr*Src/P_a*abs(n3(i,j,k))
           endif
        enddo; enddo; enddo
     enddo
   end subroutine extrapolate_velocities
!=================================================================================================
!
! the core of HF computation
!
!=================================================================================================
   subroutine get_all_heights
     use module_timer
     implicit none
     include 'mpif.h'
     integer :: direction, ierr, i
     integer :: req(24),sta(MPI_STATUS_SIZE,24)
     if(.not.st_initialized) call initialize_surface_tension()

     !*** Initialize
     height=2d6

     do direction=1,3
        call get_heights_pass1(direction)
     enddo
     call my_timer(5)

     do i=1,6
        call ghost_x(height(:,:,:,i),2,req(4*(i-1)+1:4*i))
     enddo
     call MPI_WAITALL(24,req(1:24),sta(:,1:24),ierr)
     do i=1,6
        call ghost_y(height(:,:,:,i),2,req(4*(i-1)+1:4*i))
     enddo
     call MPI_WAITALL(24,req(1:24),sta(:,1:24),ierr)
     do i=1,6
        call ghost_z(height(:,:,:,i),2,req(4*(i-1)+1:4*i))
     enddo
     call MPI_WAITALL(24,req(1:24),sta(:,1:24),ierr)
     call my_timer(6)
     do direction=1,3
        call get_heights_pass2(direction)
        call get_heights_pass3(direction)
     enddo
   end subroutine get_all_heights
!=================================================================================================
! 
!   the actual HF
! 
!=================================================================================================
   subroutine get_heights_pass1(d)
     implicit none
     integer, intent(in) :: d
     integer :: index
     logical :: same_flag, limit_not_found, height_found
     real(8) :: height_p     !  partial height 
     integer :: i,j,k,s,c0,c1,c(3)
     integer :: sign, flag_other_end, climitp1, normalsign
     ! NDEPTH is the depth of layers tested above or below the reference cell. 
     ! including the central layer and the empty/full cells
     ! NDEPTH*2 + 1 = 7 means a 7 x 3^2 stencil. 
     !  Note the normal is - grad C

     do k=ks,ke; do j=js,je; do i=is,ie
        if(vof_flag(i,j,k)/2==0) then ! flag is 0 or 1
           ! loop over search directions
           do sign=-1,1,2
              c(1)=i; c(2)=j; c(3)=k
              !  vof_flag=1 and sign = +  positive normal orientation 
              !  vof_flag=1 and sign = -  negative normal orientation 
              !  vof_flag=0 and sign = +  negative normal orientation 
              !  vof_flag=0 and sign = -  positive normal orientation 
              normalsign = (2*vof_flag(i,j,k)-1) * sign
!  index: 2*(d-1) + 1 for normal pointing up (reference phase under the other phase)
!  index: 2*(d-1) + 2 for normal pointing down
              index = 2*(d-1) + 1 + (-normalsign+1)/2
              flag_other_end = 1 - vof_flag(i,j,k)
              climitp1 = coordlimit(d,sign) + sign
              height_p = 0.d0
              s = 0
              c0 = c(d) ! start of stack
              c1 = c0 + sign*ndepth ! middle of stack starting at c0 in direction sign
              limit_not_found=.true.
              !call verify_indices(c(1),c(2),c(3),index,0)
              height_found  = height(c(1),c(2),c(3),index)<D_HALF_BIGINT
              do while (limit_not_found) 
                 !call verify_indices(c(1),c(2),c(3),index,1)
                 !call verify_indices(i,j,k,1,2)
                 same_flag = s>0.and.vof_flag(c(1),c(2),c(3))==vof_flag(i,j,k)
                 height_p = height_p + (cvof(c(1),c(2),c(3)) - 0.5d0)*normalsign
                 limit_not_found = .not.(vof_flag(c(1),c(2),c(3))==flag_other_end &
                      .or.c(d)==climitp1.or.s==2*ndepth.or.same_flag.or.height_found)
                 if(limit_not_found) then
                    s = s + 1
                    c(d) = c(d) + sign ! go forward
                 else
                    if(same_flag) then
                       ! no height, do nothing
                       continue
                    else if(height_found) then
                       ! height already found, do nothing
                       continue
                    else if(vof_flag(c(1),c(2),c(3))==flag_other_end) then ! *found the full height* !
                       ! there may be missing terms in the sum since the top (s=2*ndepth) of the stack was not
                       ! necessarily reached. Add these terms. Here s = c(d) - c0
                       height_p = height_p + (2*ndepth-s)*(cvof(c(1),c(2),c(3))-0.5d0)*normalsign
                       do while (c(d)/=(c0-sign))
                          !call verify_indices(c(1),c(2),c(3),index,3)
                          height(c(1),c(2),c(3),index) = height_p + c1 - c(d)
                          !                    call check_all(c(1),c(2),c(3),index)
                          c(d) = c(d) - sign ! go back down
                       enddo
                       ! reached boundary, save partial height at boundary
                    else if(c(d)==climitp1) then ! reached top but : not full height since checked above
                       height_p = height_p + (- cvof(c(1),c(2),c(3)) + 0.5d0)*normalsign ! remove last addition
                       c(d) = c(d) - sign ! go back one step to climit
                       ! (**) here s = c(d) - c0 + 1 and s=1 for c(d)=c0=climit
                       !call verify_indices(c(1),c(2),c(3),index,4)
                       height(c(1),c(2),c(3),index) = height_p + BIGINT*s 
                       !                call check_all(c(1),c(2),c(3),index)
                    endif        ! last possible case: reached ndepth and no proper height : do nothing
                 endif ! limit_not_found
              enddo ! limit_not_found
           enddo ! sign
        endif ! vof_flag
     enddo; enddo; enddo;  ! i,j,k
!      contains
!        subroutine verify_indices(i,j,k,index,pass)
!          implicit none
!          include 'mpif.h'
!          integer, intent(in) :: i,j,k
!          integer, intent(in) :: index,pass
!          integer :: ierr, MPI_errorcode=1
!          if(i.lt.imin.or.i.gt.imax.or.   &
!               j.lt.jmin.or.j.gt.jmax.or. &
!               k.lt.kmin.or.k.gt.kmax.or. &
!               index.lt.1.or.index.gt.6) then 
!             OPEN(UNIT=88,FILE=TRIM(out_path)//'/error-rank-'//TRIM(int2text(rank,padding))//'.txt')
!             write(88,*) "imin,imax,jmin,jmax,kmin,kmax",imin,imax,jmin,jmax,kmin,kmax
!             write(88,*) "i,j,k,index,pass",i,j,k,index,pass
!             close(88)
!             close(out)
!             if(rank==0) print *, "index error in get_heights"
!             call MPI_ABORT(MPI_COMM_WORLD, MPI_errorcode, ierr)
!             call MPI_finalize(ierr)
!             stop 
!          end if
!        end subroutine verify_indices
   end subroutine get_heights_pass1  
!
!  Enable parallel computation: exchange information accross boundaries. 
!
   subroutine get_heights_pass2(d)
     implicit none
     integer, intent(in) :: d
     integer :: index,i,j,k
     real(8) :: ha,hb
     integer :: l,m,n,c0,c1,cb,c(3),try(3)
     integer :: sign, sabove, sbelow
     ! NDEPTH is the depth of layers tested above or below the reference cell. 
     try(1)=d 
     m=1
     n=2
     do while (m.le.3)
        if(m.ne.d) then
           try(n) = m
           n=n+1
        endif
        m=m+1
     enddo

     do l=coordstart(try(2)),coordend(try(2))
        do m=coordstart(try(3)),coordend(try(3))
           c(try(2)) = l; c(try(3)) = m
           do sign=-1,1,2  ! search in both directions
               do index = 2*(d-1) + 1, 2*(d-1) + 2  ! and for both indexes. 
                  cb = coordlimit(d,sign)   ! coordinate "below" boundary
                  c(d) = cb
                  hb = height(c(1),c(2),c(3),index)
                  if(hb>D_HALF_BIGINT.and.hb<1d6) then ! partial height in cell below
                     c(d) = cb + sign  
                     ha = height(c(1),c(2),c(3),index)
                     c(d) = cb
                     if(ha<D_HALF_BIGINT) then ! height already found above
                        height(c(1),c(2),c(3),index) = ha + sign
                     else if(ha>D_HALF_BIGINT.and.ha<1d6) then ! try to match
                        sbelow = FLOOR(REAL(hb + D_HALF_BIGINT)/REAL(BIGINT)) 
                        hb = hb - BIGINT*sbelow  ! above, below in direction of sign
                        sabove = FLOOR(REAL(ha + D_HALF_BIGINT)/REAL(BIGINT))
                        ha = ha - BIGINT*sabove
                        ! c(d) = c0 bottom of stack
                        !        c2 top of stack
                        !        c2-c0+1 = length of stack
                        ! see (**) in pass 1 :
                        !            |cb-c0|=sbelow-1
                        !            |ca-c0|=sabove-1
                        ! hence
                        ! c2-c0+1 = 2*ndepth+1
                        ! hence
                        !  |cb-c0| +  |ca-c0| + 1 = c2-c0 + 1 = sabove + sbelow - 1
                        if(sabove + sbelow - 1 <= 2*ndepth+1) then  ! 
                           ! bottom is at 
                           c0   = cb - (sbelow-1)*sign  
                           c1   = c0 + ndepth*sign
                           c(d) = cb + 2*sign 
                           do while (c(d)/=(c0-sign)) 
                              height(c(1),c(2),c(3),index) = ha + hb + c1 - c(d)
                              c(d) = c(d) - sign ! go back to c0 
                           enddo
                        endif ! not over stack height
                     endif ! partial height above
                  endif ! partial height in cell below: if not, either full height or no-height, leave as is
               enddo ! index
            enddo ! sign
         enddo ! l
      enddo ! m

      do index = 2*(d-1) + 1, 2*(d-1) + 2  ! for both indexes. 
         do k=kmin,kmax;do j=jmin,jmax;do i=imin,imax
            if(height(i,j,k,index)>D_HALF_BIGINT) height(i,j,k,index)=2d6
         enddo;enddo;enddo
      enddo
         
   end subroutine get_heights_pass2

   subroutine get_heights_pass3(d)
     implicit none
     integer, intent(in) :: d
     integer :: index
     logical :: limit_not_found
     integer :: i,j,k,c0,c(3)
     integer :: sign, climitp2, oppnormalsign
     ! need to extend heights
     ! start from full cells and go the opposite way (towards the opposite interface); 
     do i=is-1,ie+1; do j=js-1,je+1; do k=ks-1,ke+1
        if(vof_flag(i,j,k)/2==0) then
           ! loop over search directions
           do sign=-1,1,2; 
              ! Opposite of search direction in pass 1 so 
              ! negative normal orientation if vof_flag=1 and sign = +, etc...
              oppnormalsign = - (2*vof_flag(i,j,k)-1) * sign
              index = 2*(d-1) + 1 + (-oppnormalsign+1)/2
              if(height(i,j,k,index)<D_HALF_BIGINT) then ! flag is 0 or 1
                 climitp2 = coordlimit(d,sign) + 2*sign
                 c(1) = i; c(2) = j; c(3) = k
                 c0 = c(d)
                 c(d) = c0 + sign ! start of region to be filled
                 limit_not_found=.not.(c0==climitp2) 
                 do while (limit_not_found) 
                    limit_not_found = .not.(vof_flag(c(1),c(2),c(3))==2 &
                         .or.c(d)==climitp2.or.abs(c(d)-c0).ge.MAX_EXT_H)
                    height(c(1),c(2),c(3),index) = height(i,j,k,index) + c0 - c(d)
                    c(d) = c(d) + sign 
                 enddo
              endif
           enddo!; enddo
        endif
     enddo; enddo; enddo
   end subroutine get_heights_pass3
!=======================================================================================================
!   Check if we find nine heights in the neighboring cells, if not collect all heights in all directions
!=======================================================================================================
   subroutine get_local_heights(i1,j1,k1,mxyz,try,nfound,hloc,points,nposit)
      implicit none
      integer, intent(in) :: i1(-1:1,-1:1,3), j1(-1:1,-1:1,3), k1(-1:1,-1:1,3)  
      ! i1(:,:,d) 3x3 plane rotated in direction d
      integer, intent(out) :: nfound
      real(8), intent(in)  :: mxyz(3)
      real(8), intent(out) :: hloc(-1:1,-1:1)   
      real(8), intent(out) :: points(NPOS,3)
      integer, intent(out) :: nposit
      integer, intent(inout) :: try(3)
      !      integer :: i0,j0,k0
      real(8) :: deltax
      integer :: d,s
      integer :: i,j,k,m,n,l
      integer :: index
      logical :: dirnotfound,heightnotfound
      integer :: si,sj,sk


      i = i1(0,0,1)
      j = j1(0,0,1)
      k = k1(0,0,1)
!
!  Loop over directions until an orientation with 9 heights is found. 
! 
      points = 0.d0
      hloc = 2d6
      nposit = 0 
      l=0
      dirnotfound=.true.
      deltax=dx(nx/2)
      do while (l.lt.3.and.dirnotfound)
         l = l+1
         d = try(l)    ! on entry, try(l) should sort the directions , closest to normal first. 
         if(d.eq.1) then
            si=1; sj=0; sk=0
         else if (d.eq.2) then
            si=0; sj=1; sk=0;
         else if (d.eq.3) then
            si=0; sj=0; sk=1
         else
            call pariserror("bad direction")
         endif
         index =  2*(d-1)+2
         if(mxyz(d).gt.0) index = 2*(d-1)+1
         hloc = 2d6
         nfound = 0
         do m=-1,1 
            do n=-1,1
               if(height(i1(m,n,d),j1(m,n,d),k1(m,n,d),index).lt.1d6) then  ! search at same level
                  ! one height found
                  hloc(m,n) = height(i1(m,n,d),j1(m,n,d),k1(m,n,d),index)
                  nfound = nfound + 1
                  nposit = nposit + 1
                  points(nposit,1) = hloc(m,n)*si + i1(m,n,d)-i
                  points(nposit,2) = hloc(m,n)*sj + j1(m,n,d)-j
                  points(nposit,3) = hloc(m,n)*sk + k1(m,n,d)-k
              else
                 s = 1 
                 heightnotfound=.true.
                 do while(s.le.Ng.and.heightnotfound) ! search at other levels
                    if (height(i1(m,n,d)+si*s,j1(m,n,d)+sj*s,k1(m,n,d)+sk*s,index).lt.1d6) then
                       hloc(m,n) = height(i1(m,n,d)+si*s,j1(m,n,d)+sj*s,k1(m,n,d)+sk*s,index) + s
                       nfound = nfound + 1
                       nposit = nposit + 1
                       points(nposit,1) = hloc(m,n)*si + i1(m,n,d)-i
                       points(nposit,2) = hloc(m,n)*sj + j1(m,n,d)-j
                       points(nposit,3) = hloc(m,n)*sk + k1(m,n,d)-k
                       heightnotfound=.false.  ! to exit loop
                    else if  (height(i1(m,n,d)-si*s,j1(m,n,d)-sj*s,k1(m,n,d)-sk*s,index).lt.1d6) then
                       hloc(m,n) = height(i1(m,n,d)-si*s,j1(m,n,d)-sj*s,k1(m,n,d)-sk*s,index) - s
                       nfound = nfound + 1
                       nposit = nposit + 1
                       points(nposit,1) = hloc(m,n)*si + i1(m,n,d)-i
                       points(nposit,2) = hloc(m,n)*sj + j1(m,n,d)-j
                       points(nposit,3) = hloc(m,n)*sk + k1(m,n,d)-k
                       heightnotfound=.false.  ! to exit loop
                    endif
                    s = s + 1
                 end do ! while s lt ndepth 
               end if ! search at same level
            end do ! n
         end do ! m 
         if(nfound.eq.9) then
            dirnotfound = .false.
            ! on exit, redefine try() so that try(1) be the h direction found
            m=1
            n=2
            do while (m.le.3)
               if(m.ne.d) then
                  try(n) = m
                  n=n+1
               endif
               m=m+1
            enddo
            try(1)=d  ! then exit
            return
         end if ! nfound = 9
      end do ! d and dirnotfound
      if(nposit.gt.NPOS) call pariserror("GLH: nposit")
    end subroutine get_local_heights
    !
!=================================================================================================
!
! the core of HF computation
!
!=================================================================================================
    subroutine print_cvof_3x3x3(i0,j0,k0)
      implicit none
      integer, intent(in) :: i0,j0,k0
      integer :: l,m
      print *, "vof 3^3 cube at i j k ", i0,j0,k0
      print *, "                x y z ", x(i0), y(j0), z(k0)
      print *, "cvof()"
      do l=-1,1
         print *, " "
         do  m=-1,1
            print *, cvof(i0-1:i0+1,j0+m,k0+l)
         enddo
      enddo
      print *, " "
      print *, "flags"
      do l=-1,1
         print *, " "
         do  m=-1,1
            print *, vof_flag(i0-1:i0+1,j0+m,k0+l)
         enddo
      enddo
      print *, " "
    end subroutine print_cvof_3x3x3
!
   subroutine get_all_curvatures(kapparray)
     implicit none
     include 'mpif.h'
     real(8), intent(inout) :: kapparray(imin:imax,jmin:jmax,kmin:kmax)
     real(8) :: afit(6), kappa
     integer :: ierr, i,j,k, nfound, nposit
     integer :: req(24),sta(MPI_STATUS_SIZE,24)
     logical :: is_bulk_cell
     if(.not.st_initialized) call initialize_surface_tension()

     !*** Initialize
     kapparray=2d6
     kappa = 0d0

     do k=ks,ke; do j=js,je; do i=is,ie
        is_bulk_cell=.false. 
        if (vof_flag(i,j,k) == 2 ) then  ! mixed cell
           call get_curvature(i,j,k,kappa,nfound,nposit,afit,.false.)
        else if (vof_flag(i,j,k) > 2 ) then
           call pariserror("inconsistent vof_flag > 3")
        else if(.not.bulk_cell(i,j,k)) then !  non-bulk pure cell
           call get_curvature(i,j,k,kappa,nfound,nposit,afit,.true.)
        else
           is_bulk_cell=.true.
        endif
        if(abs(kappa)>kappamax) then
           geom_case_count(17) = geom_case_count(17) + 1
           kappa = sign(1d0,kappa)*kappamax
        endif
        if(.not.is_bulk_cell) kapparray(i,j,k) = kappa
     enddo;enddo;enddo

     call ghost_x(kapparray(:,:,:),2,req(1:4))
     call ghost_y(kapparray(:,:,:),2,req(5:8))
     call ghost_z(kapparray(:,:,:),2,req(9:12))
     call MPI_WAITALL(12,req(1:12),sta(:,1:12),ierr)
     contains
       function bulk_cell(i,j,k)
         implicit none
         integer :: i,j,k, n_mass
         logical :: bulk_cell
         n_mass = vof_flag(i,j,k+1) + vof_flag(i,j,k-1) + &
                 vof_flag(i,j-1,k) + vof_flag(i,j+1,k) + &
                 vof_flag(i-1,j,k) + vof_flag(i+1,j,k) 

         bulk_cell = (vof_flag(i,j,k+1)/2 + vof_flag(i,j,k-1)/2 + &
                 vof_flag(i,j-1,k)/2 + vof_flag(i,j+1,k)/2 + &
                 vof_flag(i-1,j,k)/2 + vof_flag(i+1,j,k)/2 == 0).and. &
                 ((n_mass == 6.and.vof_flag(i,j,k)==1).or. &
                 (n_mass == 0 .and.vof_flag(i,j,k)==0))
       end function bulk_cell

! contains
! count flags if all faces pure
!            sum_flag = (vof_flag(i,j,k+1)/2 + vof_flag(i,j,k-1)/2 + &
!                 vof_flag(i,j-1,k)/2 + vof_flag(i,j+1,k)/2 + &
!                 vof_flag(i-1,j,k)/2 + vof_flag(i+1,j,k)/2)
!            if(vof_flag(i,j,k) == 1) then
!               if(sum_flag==0) then
!                  n_pure_faces = 
!                  if(n_pure_faces/=6) then
!                     ! 6 - n_pure_faces = number of pure faces
!                     call get_curvature(i,j,k,kappa,nfound,nposit,afit,6-n_pure_faces)
!                     kapparray(i,j,k) = kappa
!                  endif
!               endif
!            else if(vof_flag(i,j,k) == 0) then
!               if(sum_flag==0) then
!                  n_pure_faces = vof_flag(i,j,k+1) + vof_flag(i,j,k-1) + &
!                       vof_flag(i,j-1,k) + vof_flag(i,j+1,k) + vof_flag(i-1,j,k) + vof_flag(i+1,j,k)
!                  if(n_pure_faces /= 0 ) then
!                     call get_curvature(i,j,k,kappa,nfound,nposit,afit,n_pure_faces)
!                     kapparray(i,j,k) = kappa
!                  endif
!               endif
!           else
! end count
   end subroutine get_all_curvatures

    subroutine get_curvature(i0,j0,k0,kappa,nfound,nposit,a,pure_non_bulk)
      implicit none
      integer, intent(in) :: i0,j0,k0
      real(8), intent(out) :: kappa,a(6)  
      integer, intent(out) :: nfound
      integer, intent(out) :: nposit
      logical, intent(in) :: pure_non_bulk

      integer :: n_pure_faces
      real(8) :: h(-1:1,-1:1)
      integer :: m,n,l,i,j,k
      logical :: fit_success = .false.
      integer :: i1(-1:1,-1:1,3), j1(-1:1,-1:1,3), k1(-1:1,-1:1,3),try(3)
      integer :: s,c(3),d,central,neighbor,esign
      
      real(8) :: points(NPOS,3),origin(3)
      real(8) :: xfit(NPOS),yfit(NPOS),hfit(NPOS),fit(NPOS,3)
      real(8) :: centroid(3),mxyz(3),stencil3x3(-1:1,-1:1,-1:1)

      central=vof_flag(i0,j0,k0)
      call map3x3in2x2(i1,j1,k1,i0,j0,k0)
!   define in which order directions will be tried 
!   direction closest to normal first
      if(recomputenormals) then
         do m=-1,1; do n=-1,1; do l=-1,1
            stencil3x3(m,n,l) = cvof(i0+m,j0+n,k0+l)
         enddo;enddo;enddo
         call fd32(stencil3x3,mxyz)
      else
         mxyz(1) = n1(i0,j0,k0)      
         mxyz(2) = n2(i0,j0,k0)      
         mxyz(3) = n3(i0,j0,k0)
      endif
      call orientation(mxyz,try)
      call get_local_heights(i1,j1,k1,mxyz,try,nfound,h,points,nposit)

      kappa = 0.d0
      ! if all nine heights found 
      if ( nfound == 9 ) then
#ifdef COUNT
         method_count(1) = method_count(1) + 1
#endif
!
!  h = a6  + a4 x + a5 y + a3 xy + a1 x**2 + a2 y**2
!
         a(1) = (h(1,0)-2.d0*h(0,0)+h(-1,0))/2.d0
         a(2) = (h(0,1)-2.d0*h(0,0)+h(0,-1))/2.d0
         a(3) = (h(1,1)-h(-1,1)-h(1,-1)+h(-1,-1))/4.d0
         a(4) = (h(1,0)-h(-1,0))/2.d0
         a(5) = (h(0,1)-h(0,-1))/2.d0
         kappa = 2.d0*(a(1)*(1.d0+a(5)*a(5)) + a(2)*(1.d0+a(4)*a(4)) - a(3)*a(4)*a(5)) &
               /(1.d0+a(4)*a(4)+a(5)*a(5))**(1.5d0)
         kappa = sign(1.d0,mxyz(try(1)))*kappa
         return
      else 
!          nfound = - 10   ! encode the fact that less than 9 heights in same direction were found. 
!          ! ind_pos(points,nposit) 
!       endif ! nfound == 9
         nfound = - ind_pos(points,nposit) 
      endif ! nfound == 9
      ! *** determine the origin. 
      call FindCutAreaCentroid(i0,j0,k0,centroid)
      do n=1,3
         origin(n) = centroid(n)
      enddo
      ! *** determine curvature from mixed heights 
      if ( (-nfound) > nfound_min )  then  ! more than 6 points to avoid special 2D degeneracy. 
         xfit=points(:,try(2)) - origin(try(2))
         yfit=points(:,try(3)) - origin(try(3))
         hfit=points(:,try(1)) - origin(try(1))
         ! fit over all positions, not only independent ones. 
         call parabola_fit(xfit,yfit,hfit,nposit,a,fit_success) 
         if(fit_success) then
#ifdef COUNT
            method_count(2) = method_count(2) + 1
#endif
            kappa = 2.d0*(a(1)*(1.d0+a(5)*a(5)) + a(2)*(1.d0+a(4)*a(4)) - a(3)*a(4)*a(5)) &
                 /(1.d0+a(4)*a(4)+a(5)*a(5))**(1.5d0)
            kappa = sign(1.d0,mxyz(try(1)))*kappa
            return
         endif
      endif !  (-nfound) > nfound_min  

      ! *** determine curvature from centroids
      ! Find all centroids in 3**3
      ! use direction closest to normal
      nposit=0
      do m=-1,1; do n=-1,1; do l=-1,1
         i=i0+m
         j=j0+n
         k=k0+l
         c(1)=m
         c(2)=n
         c(3)=l
         if(vof_flag(i,j,k) == 2) then
            nposit = nposit + 1
            call FindCutAreaCentroid(i,j,k,centroid)
            do s=1,3 
               fit(nposit,s) = centroid(s) + c(s)
            end do
         endif ! vof_flag
      enddo; enddo; enddo ! do m,n,l
      ! arrange coordinates so height direction is closest to normal
      ! try(:) array contains direction closest to normal first

      xfit=fit(:,try(2)) - origin(try(2))
      yfit=fit(:,try(3)) - origin(try(3))
      hfit=fit(:,try(1)) - origin(try(1))
      if(nposit.gt.NPOS) call pariserror("GLH: nposit")
      if(nposit<6) then
         if(.not.pure_non_bulk) then ! mixed cell
            if(central/=2) call pariserror("unexpected non-mixed central flag")
            if(nposit<4) then
               geom_case_count(1) = geom_case_count(1) + 1
            endif
            geom_case_count(2) = geom_case_count(2) + 1
         else !  pure non-bulk cell with less than 6 control points found. 
            if(central/2/=0) call pariserror("unexpected central flag")
            n_pure_faces = 0
            c(1)=i0
            c(2)=j0
            c(3)=k0
            do d=1,3
               do esign=-1,1,2
                  c(d)=c(d)+esign
                  neighbor = vof_flag(c(1),c(2),c(3))
                  c(d)=c(d)-esign
                  ! test whether neighbor is a pure cell of opposite kind
                  if(neighbor/=2 .and. neighbor+central==1) then  
                     nposit = nposit + 1
                     n_pure_faces = n_pure_faces + 1
                     do s=1,3
                        if(s/=d) then
                           fit(nposit,s) = 0d0
                        endif
                     enddo
                     fit(nposit,d) = dble(esign)*0.5d0
                  endif
               enddo
            enddo
            if(n_pure_faces >= 3) then
               !                  print *, "Warning: ",n_pure_faces, " pure faces at x =",x(i0),&
               !                       ", y = ",y(j0), ", z = ",z(k0)
               geom_case_count(3) = geom_case_count(3) + 1
            endif
            if(nposit <6) then
               !        print *,"WARNING nposit = ",nposit," n_pure_faces = ",n_pure_faces," at",i0,j0,k0
               !        if(nposit==0) then
               !           call print_cvof_3x3x3(i0,j0,k0)
               !           call pariserror("unsufficient nposit")
               !        endif
               geom_case_count(nposit+4) = geom_case_count(nposit+4) + 1
            endif
         endif
      endif
      call parabola_fit(xfit,yfit,hfit,nposit,a,fit_success)
      if(.not.fit_success) then
         if(nposit < 6) then
            geom_case_count(nposit+10) = geom_case_count(nposit+10) + 1
         else
!            call print_cvof_3x3x3(i0,j0,k0)
            geom_case_count(16) = geom_case_count(16) + 1
         endif
      else
         kappa = 2.d0*(a(1)*(1.d0+a(5)*a(5)) + a(2)*(1.d0+a(4)*a(4)) - a(3)*a(4)*a(5)) &
             /sqrt(1.d0+a(4)*a(4)+a(5)*a(5))**3
         kappa = sign(1.d0,mxyz(try(1)))*kappa
      endif
   end subroutine get_curvature

   subroutine parabola_fit(xfit,yfit,hfit,nposit,a,fit_success)
      implicit none
      real(8), intent(in)  :: xfit(nposit),yfit(nposit),hfit(nposit)
      real(8), intent(out) :: a(6)
      logical, intent(out) :: fit_success
      real(8) :: m(6,6), invm(6,6)
      real(8) :: rhs(6)
      integer :: ifit, im,jm, nposit
      logical :: inv_success
      real(8) :: x1,x2,x3,x4,y1,y2,y3,y4

      fit_success=.false.
      a = 0.d0
      ! evaluate the linear system for least-square fit
      m   = 0.d0
      rhs = 0.d0

      do ifit = 1, nposit
            x1 =    xfit(ifit)
            x2 = x1*xfit(ifit)
            x3 = x2*xfit(ifit)
            x4 = x3*xfit(ifit)
            y1 =    yfit(ifit)
            y2 = y1*yfit(ifit)
            y3 = y2*yfit(ifit)
            y4 = y3*yfit(ifit)
            
      ! The matrix is m_ij = sum_n alpha^n_i alpha^n_j
      ! and the "alpha_i" are the factors of the a_i coefficients:
      ! 
      !   x^2, y^2, xy, x^2, y^2, 1

            m(1,1) = m(1,1) + x4
            m(2,2) = m(2,2) + y4
            m(3,3) = m(3,3) + x2*y2
            m(4,4) = m(4,4) + x2
            m(5,5) = m(5,5) + y2
            m(6,6) = m(6,6) + 1.d0

            m(1,3) = m(1,3) + x3*y1
            m(1,4) = m(1,4) + x3
            m(1,5) = m(1,5) + x2*y1
            m(2,3) = m(2,3) + x1*y3
            m(2,4) = m(2,4) + x1*y2
            m(2,5) = m(2,5) + y3
            m(3,6) = m(3,6) + x1*y1
            m(4,6) = m(4,6) + x1
            m(5,6) = m(5,6) + y1

            rhs(1) = rhs(1) + x2   *hfit(ifit)
            rhs(2) = rhs(2) + y2   *hfit(ifit)
            rhs(3) = rhs(3) + x1*y1*hfit(ifit)
            rhs(4) = rhs(4) + x1   *hfit(ifit)
            rhs(5) = rhs(5) + y1   *hfit(ifit)
            rhs(6) = rhs(6) +       hfit(ifit)
      end do ! ifit
      m(1,2) = m(3,3)
      m(1,6) = m(4,4)
      m(2,6) = m(5,5)
      m(3,4) = m(1,5)
      m(3,5) = m(2,4)
      m(4,5) = m(3,6)

      do im = 1,6; do jm = 1,6
         if ( im > jm ) m(im,jm) = m(jm,im)
      end do; end do 

      ! Solve linear system
      call FindInverseMatrix(m,invm,6,inv_success)
      if ( inv_success ) then 
         do im=1,6
            do jm=1,6
               a(im) = a(im) + invm(im,jm)*rhs(jm)
            end do
         end do 
         fit_success = .true.
      end if ! inv_success
   end subroutine parabola_fit
!
!  Subroutine to find the inverse of a square matrix
!  From Stanley's previous code
!
   SUBROUTINE FindInverseMatrix(matrix,inverse,n,inverse_success)
      implicit none
      include 'mpif.h'

         !---Declarations
        INTEGER, INTENT(IN ) :: n
        real(8), INTENT(IN ), DIMENSION(n,n) :: matrix  !Input A matrix
        real(8), INTENT(OUT), DIMENSION(n,n) :: inverse !Inverted matrix
        logical, INTENT(OUT) :: inverse_success 

        integer :: i, j, k, l
        real(8) :: m
        real(8), DIMENSION(n,2*n) :: augmatrix !augmented matrix


        !Augment input matrix with an identity matrix
        DO i = 1,n
          DO j = 1,2*n
            IF (j <= n ) THEN
              augmatrix(i,j) = matrix(i,j)
            ELSE IF ((i+n) == j) THEN
              augmatrix(i,j) = 1.0d0
            Else
              augmatrix(i,j) = 0.0d0
            ENDIF
          END DO
        END DO
                
        !Ensure diagonal elements are non-zero
        DO k = 1,n-1
          DO j = k+1,n
            IF (augmatrix(k,k) == 0) THEN
               DO i = k+1, n
                 IF (augmatrix(i,k) /= 0) THEN
                   DO  l = 1, 2*n
                     augmatrix(k,l) = augmatrix(k,l)+augmatrix(i,l)
                   END DO
                 ENDIF
               END DO
            ENDIF
          END DO
        END DO
                
        !Reduce augmented matrix to upper triangular form
        DO k =1, n-1
          DO j = k+1, n
            m = augmatrix(j,k)/augmatrix(k,k)
            DO i = k, 2*n
              augmatrix(j,i) = augmatrix(j,i) - m*augmatrix(k,i)
            END DO
          END DO
        END DO

        !Test for invertibility
        DO i = 1, n
          IF (augmatrix(i,i) == 0) THEN
!            write(*,*) "ERROR-Matrix is non-invertible"
            inverse = 0.d0
            inverse_success = .false.
!            do i=1,n
!               print *,"rank ",rank,i,matrix(i,1:n)
!            enddo
            return
          ENDIF
        END DO
                
        !Make diagonal elements as 1
        DO i = 1 , n
          m = augmatrix(i,i)
          DO j = i , (2 * n)
            augmatrix(i,j) = (augmatrix(i,j) / m)
          END DO
        END DO
                
        !Reduced right side half of augmented matrix to identity matrix
        DO k = n-1, 1, -1
          DO i =1, k
            m = augmatrix(i,k+1)
            DO j = k, (2*n)
              augmatrix(i,j) = augmatrix(i,j) -augmatrix(k+1,j) * m
            END DO
          END DO
        END DO
                
        !store answer
        DO i =1, n
          DO j = 1, n
            inverse(i,j) = augmatrix(i,j+n)
          END DO
        END DO
        inverse_success = .true.
                
   END SUBROUTINE FindInverseMatrix

   subroutine FindCutAreaCentroid(i,j,k,centroid)
      implicit none

      integer, intent(in)  :: i,j,k
      real(8), intent(out) :: centroid(3)

      integer :: l,m,n
      real(8) :: mxyz(3), nr(3)
      real(8) :: invx,invy,invz
      real(8) :: alpha ! al3dold,  dmx,dmy,dmz,px,py,pz
      real(8) :: stencil3x3(-1:1,-1:1,-1:1)

      ! find cut area centroid 
      !***
      !     (1) normal vector: dmx,dmy,dmz, and |dmx|+|dmy|+|dmz| = 1.
      !     (2) dmx,dmy,dmz>0 and record sign
      !     (3) get alpha;               
      !     (4) compute centroid with dmx,dmy,dmz and alpha;
      !     (5) transfer to local coordinate;
      !*(1)*

      if(recomputenormals) then
         do l=-1,1; do m=-1,1; do n=-1,1
            stencil3x3(l,m,n) = cvof(i+l,j+m,k+n)
         enddo;enddo;enddo
         call youngs(stencil3x3,mxyz)
         nr = mxyz
      else
         nr(1) = n1(i,j,k)      
         nr(2) = n2(i,j,k)      
         nr(3) = n3(i,j,k)
      endif

!      if(oldvof) then
!          dmx = nr(1); dmy = nr(2); dmz = nr(3)
!          !*(2)*  
!          invx = 1.d0
!          invy = 1.d0
!          invz = 1.d0
!          if (dmx .lt. 0.0d0) then
!          dmx = -dmx
!          invx = -1.d0
!       endif
!       if (dmy .lt. 0.0d0) then
!          dmy = -dmy
!          invy = -1.d0
!       endif
!       if (dmz .lt. 0.0d0) then
!          dmz = -dmz
!          invz = -1.d0
!       endif
!       !*(3)*  
!       alpha = al3dold(dmx,dmy,dmz,cvof(i,j,k))
!       !*(4)*  
!       call PlaneAreaCenter(dmx,dmy,dmz,alpha,px,py,pz)
!       !*(5)*
!       ! trap NaNs
! !      if(px.ne.px) call pariserror("FCAC:invalid px")
! !      if(py.ne.py) call pariserror("FCAC:invalid py")
! !      if(pz.ne.pz) call pariserror("FCAC:invalid pz")

!       ! rotate
!       centroid(1) = px*invx
!       centroid(2) = py*invy
!       centroid(3) = pz*invz
!       ! shift to cell-center coordinates
!       centroid(1) = centroid(1) - invx*0.5d0
!       centroid(2) = centroid(2) - invy*0.5d0
!       centroid(3) = centroid(3) - invz*0.5d0
!      else
         call cent3D(nr,cvof(i,j,k),centroid)
         centroid = centroid - 0.5d0
!     endif
   end subroutine FindCutAreaCentroid
! 
!   Computes the centroid as in gerris
! 
! * Fills p with the position of the center of mass of the polygon
! * obtained by interseectiing the plane  (m,alpha).
! * with the reference cell.
!
!  assumptions: dmx,dmy,dmz > 0 and |dmx| + |dmy| + |dmz| = 1
!
!    subroutine PlaneAreaCenter (dmx,dmy,dmz, alpha, px,py,pz)
!      implicit none
!      real(8), intent(in) :: dmx,dmy,dmz,alpha
!      real(8), intent(out) :: px,py,pz
!      real(8) :: nx,ny,qx,qy
!      real(8) :: area,b,amax

!      if(dmx<0.d0.or.dmy<0.d0.or.dmz<0.d0) call pariserror("invalid dmx dmy dmz")
!      if(abs(dmx+dmy+dmz-1d0)>EPS_GEOM) call pariserror("invalid dmx+dmy+dmz")

!      if (dmx < EPS_GEOM) then
!         nx = dmy
!         ny = dmz
!         call LineCenter (nx,ny, alpha, qx,qy)
!         px = 0.5d0
!         py = qx
!         pz = qy
!         return
!      endif
!      if (dmy < EPS_GEOM) then
!         nx = dmz
!         ny = dmx
!         call LineCenter (nx,ny, alpha, qx,qy)
!         px = qy
!         py = 0.5d0
!         pz = qx
!         return
!      endif
!      if (dmz < EPS_GEOM) then
!         call LineCenter (dmx,dmy, alpha, px,py)
!         pz = 0.5
!         return
!      endif

!      if (alpha < 0.d0 .or. alpha > 1.d0) then
!         print *, "alpha =", alpha
!         call pariserror("PAC: invalid alpha")
!      endif

!      area = alpha*alpha
!      px = area*alpha
!      py = area*alpha
!      pz = area*alpha
!      b = alpha - dmx
!      if (b > 0.) then
!         area = area - b*b
!         px = px - b*b*(2.*dmx + alpha)
!         py = py - b*b*b
!         pz = pz - b*b*b
!      endif
!      b = alpha - dmy
!      if (b > 0.) then
!         area = area - b*b
!         py = py - b*b*(2.*dmy + alpha)
!         px = px - b*b*b
!         pz = pz - b*b*b
!      endif
!      b = alpha - dmz
!      if (b > 0.) then
!         area = area - b*b
!         pz = pz - b*b*(2.*dmz + alpha)
!         px = px - b*b*b
!         py = py - b*b*b
!      endif

!      amax = alpha - 1.d0
!      b = amax + dmx
!      if (b > 0.) then
!         area = area + b*b
!         py = py + b*b*(2.*dmy + alpha - dmz)
!         pz = pz + b*b*(2.*dmz + alpha - dmy)
!         px = px + b*b*b
!      endif
!      b = amax + dmy
!      if (b > 0.) then
!         area = area + b*b
!         px = px + b*b*(2.*dmx + alpha - dmz)
!         pz = pz + b*b*(2.*dmz + alpha - dmx)
!         py = py + b*b*b
!      endif
!      b = amax + dmz
!      if (b > 0.) then
!         area = area + b*b
!         px = px + b*b*(2.*dmx + alpha - dmy)
!         py = py + b*b*(2.*dmy + alpha - dmx)
!         pz = pz + b*b*b
!      endif

!      area  = 3.d0*area
!      px = px/(area*dmx)
!      py = py/(area*dmy)
!      pz = pz/(area*dmz)

!      call THRESHOLD (px)
!      call THRESHOLD (py)
!      call THRESHOLD (pz)

!    end subroutine PlaneAreaCenter

!-------------------------------------------------------------------------------------------------------
   subroutine LineCenter (dmx,dmy, alpha, px,py)
     implicit none
     real(8), intent(in) :: dmx,dmy,alpha
     real(8), intent(out) :: px,py
      
     !  if (alpha <= 0.d0 .or. alpha >= 1.d0) 
     ! call pariserror("LC: invalid alpha")

     if (alpha < 0.d0 .or. alpha > 1.d0) then
        print *, "alpha =", alpha
        call pariserror("LC: invalid alpha")
     endif

     if (dmx < EPS_GEOM) then
        px = 0.5
        py = alpha;
        return
     endif

     if (dmy < EPS_GEOM) then
        py = 0.5;
        px = alpha
        return
     endif

     px = 0.; py = 0.

     if (alpha >= dmx) then
        px = px +  1.
        py = py +  (alpha - dmx)/dmy
     else
        px = px +  alpha/dmx
     endif

     if (alpha >= dmy) then
        py = py +  1.
        px = px +  (alpha - dmy)/dmx
     else
        py = py +  alpha/dmy
     endif

     px = px/2.
     py = py/2.

     call THRESHOLD (px)
     call THRESHOLD (py)

 !    if(px.ne.px) call pariserror("LAC:invalid px")
 !    if(py.ne.py) call pariserror("LAC:invalid px")

   end subroutine

!   direction closest to normal first
   subroutine orientation (m,c)
     implicit none
     real(8), intent(in) :: m(3)
     integer, intent(out) :: c(3)
     integer :: i,j,tmp
     do i = 1,3
        c(i) = i 
     enddo
     do i = 1,2
        do j=1,3-i
           if(abs(m(c(j+1))) > abs(m(c(j)))) then
              tmp = c(j)
              c(j) = c(j+1)
              c(j+1) = tmp
           endif
        enddo
     enddo
   end subroutine orientation

   function ind_pos (points, n)
     implicit none
     integer :: ind_pos
     integer, intent(in) :: n
     real(8), intent(in) :: points(NPOS,3)
     integer :: i,j,ni,c
     real(8) :: d2
     logical :: depends
     if (n < 2) then
        ind_pos = n
        return
     endif
     ni=1
     do j=2,n
        depends = .false.
        do i=1,j-1
           if(.not.depends) then
              d2 = 0d0
              do c=1,3
                 d2 = d2 + (points(i,c) - points(j,c))**2
              enddo
              depends = (d2 < 0.5d0**2)
           endif
        enddo
        if(.not.depends) ni = ni + 1
     enddo
     ind_pos = ni
   end function ind_pos
  end module module_surface_tension



