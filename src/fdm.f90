!> Type for the Fast Diagonalization connected with the schwarz overlapping solves.
module fdm
  use num_types
  use speclib
  use math
  use space
  use dofmap
  use bc
  use dirichlet
  use gather_scatter
  use fast3d
  use mxm_wrapper
  use tensor
  implicit none  
  type, public :: fdm_t
    real(kind=dp), allocatable :: s(:,:,:,:)
    real(kind=dp), allocatable :: d(:,:)
    real(kind=dp), allocatable :: len_lr(:),len_ls(:),len_lt(:)
    real(kind=dp), allocatable :: len_mr(:),len_ms(:),len_mt(:)
    real(kind=dp), allocatable :: len_rr(:),len_rs(:),len_rt(:)
    real(kind=dp), allocatable :: swplen(:,:,:,:)
    type(space_t), pointer :: Xh
    type(bc_list_t), pointer :: bclst
    type(dofmap_t), pointer :: dof
    type(gs_t), pointer :: gs_h
    type(mesh_t), pointer :: msh
  contains 
    procedure, pass(this) :: init => fdm_init
    procedure, pass(this) :: free => fdm_free
    procedure, pass(this) :: compute => fdm_compute
  end type fdm_t
contains
  subroutine fdm_init(this, Xh, dm, gs_h, bclst)
    class(fdm_t), intent(inout) :: this
    type(space_t), target, intent(inout) :: Xh
    type(dofmap_t), target, intent(inout) :: dm
    type(gs_t), target, intent(inout) :: gs_h
    type(bc_list_t), target, intent(inout):: bclst
    !We only really use ah, bh
    real(kind=dp), dimension((Xh%lx)**2) :: ah, bh, ch, dh, zh, dph, jph, bgl, zglhat, dgl, jgl, wh
    integer :: nl, n, nelv
    n = Xh%lx -1 !Polynomnial degree
    nl = Xh%lx + 2 !Schwarz!
    nelv = dm%msh%nelv
    call fdm_free(this) 
    allocate(this%s(nl*nl,2,dm%msh%gdim, dm%msh%nelv))
    allocate(this%d(nl**3,dm%msh%nelv))
    allocate(this%swplen(Xh%lx, Xh%lx, Xh%lx,dm%msh%nelv))
    allocate(this%len_lr(nelv), this%len_ls(nelv), this%len_lt(nelv))
    allocate(this%len_mr(nelv), this%len_ms(nelv), this%len_mt(nelv))
    allocate(this%len_rr(nelv), this%len_rs(nelv), this%len_rt(nelv))

    call semhat(ah,bh,ch,dh,zh,dph,jph,bgl,zglhat,dgl,jgl,n,wh)
    this%Xh => Xh
    this%bclst => bclst
    this%dof => dm
    this%gs_h => gs_h
    this%msh => dm%msh

    call swap_lengths(this, dm%x, dm%y, dm%z, dm%msh%nelv, dm%msh%gdim)

    call fdm_setup_fast(this, ah, bh, nl, n)

  end subroutine fdm_init

  subroutine swap_lengths(this,x,y,z,nelv,gdim)
    type(fdm_t), intent(inout) :: this
    integer, intent(in) :: gdim, nelv
    real(kind=dp), dimension(this%Xh%lxyz,nelv) , intent(in):: x, y, z
    integer :: i, j, k, e, n2, nz0, nzn, nx, lx1, n
    associate(l => this%swplen, &
              llr => this%len_lr, lls => this%len_ls, llt => this%len_lt, &
              lmr => this%len_mr, lms => this%len_ms, lmt => this%len_mt, &
              lrr => this%len_rr, lrs => this%len_rs, lrt => this%len_rt)
    lx1 = this%Xh%lx
    n2 = lx1-1
    nz0 = 1
    nzn = 1
    nx  = lx1-2
    if (gdim .eq. 3) then
       nz0 = 0
       nzn = n2
    endif
    call plane_space(lmr,lms,lmt,0,n2,this%Xh%wx,x,y,z,nx,n2,nz0,nzn, nelv, gdim)
    n=n2+1
    if (gdim .eq. 3) then
       do e=1,nelv
       do j=2,n2
       do k=2,n2
          l(1,k,j,e) = lmr(e)
          l(n,k,j,e) = lmr(e)
          l(k,1,j,e) = lms(e)
          l(k,n,j,e) = lms(e)
          l(k,j,1,e) = lmt(e)
          l(k,j,n,e) = lmt(e)
       enddo
       enddo
       enddo
       call gs_op_vector(this%gs_h,l,this%dof%n_dofs, GS_OP_ADD)
       do e=1,nelv
          llr(e) = l(1,2,2,e)-lmr(e)
          lrr(e) = l(n,2,2,e)-lmr(e)
          lls(e) = l(2,1,2,e)-lms(e)
          lrs(e) = l(2,n,2,e)-lms(e)
          llt(e) = l(2,2,1,e)-lmt(e)
          lrt(e) = l(2,2,n,e)-lmt(e)
       enddo
    else
       do e=1,nelv
       do j=2,n2
          l(1,j,1,e) = lmr(e)
          l(n,j,1,e) = lmr(e)
          l(j,1,1,e) = lms(e)
          l(j,n,1,e) = lms(e)
       enddo
       enddo
       call gs_op_vector(this%gs_h,l,this%dof%n_dofs, GS_OP_ADD)
       do e=1,nelv
          llr(e) = l(1,2,1,e)-lmr(e)
          lrr(e) = l(n,2,1,e)-lmr(e)
          lls(e) = l(2,1,1,e)-lms(e)
          lrs(e) = l(2,n,1,e)-lms(e)
       enddo
    endif
    end associate
  end subroutine swap_lengths

!>    Here, spacing is based on harmonic mean.  pff 2/10/07
!!    We no longer base this on the finest grid, but rather the dofmap we are working with, Karp 210112
  subroutine plane_space(lr,ls,lt,i1,i2,w,x,y,z,nx,nxn,nz0,nzn, nelv, gdim)
    integer, intent(in) :: nxn, nzn, i1, i2, nelv, gdim, nx, nz0
    real(kind=dp), intent(inout) :: lr(nelv),ls(nelv),lt(nelv)
    real(kind=dp), intent(inout) :: w(nx)
    real(kind=dp), intent(in) :: x(0:nxn,0:nxn,nz0:nzn,nelv)
    real(kind=dp), intent(in) :: y(0:nxn,0:nxn,nz0:nzn,nelv)
    real(kind=dp), intent(in) :: z(0:nxn,0:nxn,nz0:nzn,nelv)
    real(kind=dp) ::  lr2, ls2, lt2, weight, wsum
    integer :: ny, nz, j1, k1, j2, k2, i, j, k, ie
    ny = nx
    nz = nx
    j1 = i1
    k1 = i1
    j2 = i2
    k2 = i2
!   Now, for each element, compute lr,ls,lt between specified planes
    do ie=1,nelv
       if (gdim .eq. 3) then
          lr2  = 0d0
          wsum = 0d0
          do k=1,nz
          do j=1,ny
             weight = w(j)*w(k)
             lr2  = lr2  +   weight /&
                          ( (x(i2,j,k,ie)-x(i1,j,k,ie))**2&
                        +   (y(i2,j,k,ie)-y(i1,j,k,ie))**2&
                        +   (z(i2,j,k,ie)-z(i1,j,k,ie))**2 )
             wsum = wsum + weight
          enddo
          enddo
          lr2     = lr2/wsum
          lr(ie)  = 1d0/dsqrt(lr2)
          ls2 = 0d0
          wsum = 0d0
          do k=1,nz
          do i=1,nx
             weight = w(i)*w(k)
             ls2  = ls2  +   weight / &
                          ( (x(i,j2,k,ie)-x(i,j1,k,ie))**2 &
                        +   (y(i,j2,k,ie)-y(i,j1,k,ie))**2 &
                        +   (z(i,j2,k,ie)-z(i,j1,k,ie))**2 )
             wsum = wsum + weight
          enddo
          enddo
          ls2     = ls2/wsum
          ls(ie)  = 1d0/dsqrt(ls2)
          lt2 = 0d0
          wsum = 0d0
          do j=1,ny
          do i=1,nx
             weight = w(i)*w(j)
             lt2  = lt2  +   weight / &
                          ( (x(i,j,k2,ie)-x(i,j,k1,ie))**2 &
                        +   (y(i,j,k2,ie)-y(i,j,k1,ie))**2 &
                        +   (z(i,j,k2,ie)-z(i,j,k1,ie))**2 )
             wsum = wsum + weight
          enddo
          enddo
          lt2     = lt2/wsum
          lt(ie)  = 1d0/dsqrt(lt2)
       else              ! 2D
          lr2 = 0d0
          wsum = 0d0
          do j=1,ny
             weight = w(j)
             lr2  = lr2  + weight / &
                          ( (x(i2,j,1,ie)-x(i1,j,1,ie))**2 &
                          + (y(i2,j,1,ie)-y(i1,j,1,ie))**2 )
             wsum = wsum + weight
          enddo
          lr2     = lr2/wsum
          lr(ie)  = 1d0/sqrt(lr2)
          ls2 = 0d0
          wsum = 0d0
          do i=1,nx
             weight = w(i)
             ls2  = ls2  + weight / &
                          ( (x(i,j2,1,ie)-x(i,j1,1,ie))**2 &
                        +   (y(i,j2,1,ie)-y(i,j1,1,ie))**2 )
             wsum = wsum + weight
          enddo
          ls2     = ls2/wsum
          ls(ie)  = 1d0/sqrt(ls2)
       endif
    enddo
    ie = 1014
  end subroutine plane_space

  !> Setup the arrays s, d needed for the fast evaluation of the system
  subroutine fdm_setup_fast(this, ah, bh, nl, n)
    integer, intent(in) :: nl, n
    type(fdm_t), intent(inout) :: this
    real(kind=dp), intent(inout) ::  ah(n+1,n+1),bh(n+1)
    real(kind=dp), dimension(2*this%Xh%lx + 4) :: lr,ls,lt
    integer :: i,j,k
    integer :: ie,il,nr,ns,nt
    integer :: lbr,rbr,lbs,rbs,lbt,rbt,two
    real(kind=dp) :: eps,diag
    
    associate(s => this%s, d => this%d, &
              llr => this%len_lr, lls => this%len_ls, llt => this%len_lt, &
              lmr => this%len_mr, lms => this%len_ms, lmt => this%len_mt, &
              lrr => this%len_rr, lrs => this%len_rs, lrt => this%len_rt)
      do ie=1,this%dof%msh%nelv
         call get_fast_bc(lbr,rbr,lbs,rbs,lbt,rbt,ie,&
              this%bclst, this%dof%msh%gdim)
         nr=nl
         ns=nl
         nt=nl
         call fdm_setup_fast1d(s(1,1,1,ie),lr,nr,lbr,rbr, &
              llr(ie),lmr(ie),lrr(ie),ah,bh,n,ie)
         call fdm_setup_fast1d(s(1,1,2,ie),ls,ns,lbs,rbs, &
              lls(ie),lms(ie),lrs(ie),ah,bh,n,ie)
         if(this%dof%msh%gdim .eq. 3) then
            call fdm_setup_fast1d(s(1,1,3,ie),lt,nt,lbt,rbt, &
                 llt(ie),lmt(ie),lrt(ie),ah,bh,n,ie)
         end if

         il=1
         if(.not.this%dof%msh%gdim .eq. 3) then
            eps = 1d-5*(vlmax(lr(2),nr-2) + vlmax(ls(2),ns-2))
            do j=1,ns
               do i=1,nr
                  diag = lr(i)+ls(j)
                  if (diag.gt.eps) then
                     d(il,ie) = 1d0/diag
                  else
                     d(il,ie) = 0d0
                  endif
                  il=il+1
               enddo
            enddo
         else
            eps = 1d-5 * (vlmax(lr(2),nr-2) + &
                 vlmax(ls(2),ns-2) + vlmax(lt(2),nt-2))
            do k=1,nt
               do j=1,ns
                  do i=1,nr
                     diag = lr(i)+ls(j)+lt(k)
                     if (diag.gt.eps) then
                        d(il,ie) = 1d0/diag
                     else
                        d(il,ie) = 0d0
                     endif
                     il=il+1
                  enddo
               enddo
            enddo
         endif
      enddo
    end associate
  end subroutine fdm_setup_fast
  
  subroutine fdm_setup_fast1d(s,lam,nl,lbc,rbc,ll,lm,lr,ah,bh,n,ie)
    integer, intent(in)  :: nl,lbc,rbc,n, ie
    real(kind=dp), intent(inout) :: s(nl,nl,2),lam(nl),ll,lm,lr
    real(kind=dp), intent(inout) ::  ah(0:n,0:n),bh(0:n)
    integer ::  lx1, lxm
    real(kind=dp) :: b(2*(n+3)**2), w(2*(n+3)**2)
    lx1 = n + 1
    lxm = lx1+2
     
    call fdm_setup_fast1d_a(s,lbc,rbc,ll,lm,lr,ah,n)
    call fdm_setup_fast1d_b(b,lbc,rbc,ll,lm,lr,bh,n)
    call generalev(s,b,lam,nl,lx1,w)
    if(lbc.gt.0 .or. ll .eq. 0d0) call row_zero(s,nl,nl,1)
    if(lbc.eq.1) call row_zero(s,nl,nl,2)
    if(rbc.gt.0 .or. lr .eq. 0d0) call row_zero(s,nl,nl,nl)
    if(rbc.eq.1) call row_zero(s,nl,nl,nl-1)
    
    call trsp(s(1,1,2),nl,s,nl)
  end subroutine fdm_setup_fast1d

!>     Solve the generalized eigenvalue problem /$ A x = lam B x/$
!!     A -- symm.
!!     B -- symm., pos. definite
  subroutine generalev(a,b,lam,n,lx,w)
      integer, intent(in) :: n, lx
      real(kind=dp), intent(inout) :: a(n,n),b(n,n),lam(n),w(n,n)
      !Work array, in nek this one is huge, but I dont think that is necessary
      !Maybe if we do it for the whole global system at once, but we dont do that here at least
      integer :: lbw, lw
      real(kind=dp) :: bw(4*(lx+2)**3)
      integer :: info = 0
      lbw = 4*(lx+2)**3
      lw = n*n
      call dsygv(1,'V','U',n,a,n,b,n,lam,bw,lbw,info)

  end subroutine generalev

  subroutine fdm_setup_fast1d_a(a,lbc,rbc,ll,lm,lr,ah,n)
    integer, intent(in) ::lbc,rbc,n
    real(kind=dp), intent(inout) :: a(0:n+2,0:n+2),ll,lm,lr
    real(kind=dp), intent(inout) :: ah(0:n,0:n)
    real(kind=dp) :: fac
    integer :: i,j,i0,i1
    i0=0
    if(lbc.eq.1) i0=1
    i1=n
    if(rbc.eq.1) i1=n-1
    
    call rzero(a,(n+3)*(n+3))
    fac = 2d0/lm
    a(1,1)=1d0
    a(n+1,n+1)=1d0
    do j=i0,i1
       do i=i0,i1
          a(i+1,j+1)=fac*ah(i,j)
       enddo
    enddo
    if(lbc.eq.0 .and. ll .ne. 0d0 ) then
    !if(lbc.eq.0) then
       fac = 2d0/ll
       a(0,0)=fac*ah(n-1,n-1)
       a(1,0)=fac*ah(n  ,n-1)
       a(0,1)=fac*ah(n-1,n  )
       a(1,1)=a(1,1)+fac*ah(n  ,n  )
    else
       a(0,0)=1d0
    endif
    if(rbc.eq.0 .and. lr .ne. 0d0) then
    !if(rbc.eq.0) then
       fac = 2d0/lr
       a(n+1,n+1)=a(n+1,n+1)+fac*ah(0,0)
       a(n+2,n+1)=fac*ah(1,0)
       a(n+1,n+2)=fac*ah(0,1)
       a(n+2,n+2)=fac*ah(1,1)
    else
       a(n+2,n+2)=1d0
    endif
  end subroutine fdm_setup_fast1d_a

  subroutine fdm_setup_fast1d_b(b,lbc,rbc,ll,lm,lr,bh,n)
    integer, intent(in) :: lbc,rbc,n
    real(kind=dp), intent(inout) :: b(0:n+2,0:n+2),ll,lm,lr
    real(kind=dp), intent(inout) :: bh(0:n)
    
    real(kind=dp) :: fac
    integer :: i,j,i0,i1
    i0=0
    if(lbc.eq.1) i0=1
    i1=n
    if(rbc.eq.1) i1=n-1
    
    call rzero(b,(n+3)*(n+3))
    fac = 0.5*lm
    b(1,1)=1.0
    b(n+1,n+1)=1.0
    do i=i0,i1
       b(i+1,i+1)=fac*bh(i)
    enddo
    if(lbc.eq.0 .and. ll .ne. 0d0 ) then
    !if(lbc.eq.0) then
       fac = 0.5*ll
       b(0,0)=fac*bh(n-1)
       b(1,1)=b(1,1)+fac*bh(n  )
    else
       b(0,0)=1.0
    endif
    if(rbc.eq.0 .and. lr .ne. 0d0) then
    !if(rbc.eq.0) then
       fac = 0.5*lr
       b(n+1,n+1)=b(n+1,n+1)+fac*bh(0)
       b(n+2,n+2)=fac*bh(1)
    else
       b(n+2,n+2)=1.0
    endif
  end subroutine fdm_setup_fast1d_b

  !> Get what type of boundary conditions we have in a specific direction.
  !! Can be grouped into three cases:
  !! ibc = 0  <==>  Dirichlet
  !! ibc = 1  <==>  Dirichlet, outflow (no extension)
  !! ibc = 2  <==>  Neumann,   
  !! @note this description does not really make sense, need to be revised

  subroutine get_fast_bc(lbr,rbr,lbs,rbs,lbt,rbt,e,bclst, gdim)
    integer, intent(inout) :: lbr,rbr,lbs,rbs,lbt,rbt
    integer, intent(in) :: e, gdim
    type(bc_list_t), intent(inout) :: bclst
    type(tuple_i4_t), pointer :: bfp(:)
    integer :: fbc(6), ibc, iface, i, j
    !This got to be one of the ugliest hacks I have done. 
    do iface=1,2*gdim
       fbc(iface) = 0
       do i =1, bclst%n
          bfp => bclst%bc(i)%bcp%marked_facet%array()
          do j = 1, bclst%bc(i)%bcp%marked_facet%size()
             if( bfp(j)%x(1) .eq. iface .and. bfp(j)%x(2) .eq. e) then
                 fbc(iface) = 1
             end if
          end do
       end do
    enddo

    lbr = fbc(1)
    rbr = fbc(2)
    lbs = fbc(3)
    rbs = fbc(4)
    lbt = fbc(5)
    rbt = fbc(6)
  end subroutine get_fast_bc

  subroutine fdm_free(this)
    class(fdm_t), intent(inout) :: this
    if(allocated(this%s)) then
      deallocate(this%s)
    end if
    if(allocated(this%d)) deallocate(this%d)
    if(allocated(this%len_lr)) deallocate(this%len_lr)
    if(allocated(this%len_ls)) deallocate(this%len_ls)
    if(allocated(this%len_lt)) deallocate(this%len_lt)
    if(allocated(this%len_mr)) deallocate(this%len_mr)
    if(allocated(this%len_ms)) deallocate(this%len_ms)
    if(allocated(this%len_mt)) deallocate(this%len_mt)
    if(allocated(this%len_rr)) deallocate(this%len_rr)
    if(allocated(this%len_rs)) deallocate(this%len_rs)
    if(allocated(this%len_rt)) deallocate(this%len_rt)
    if(allocated(this%swplen)) deallocate(this%swplen)
    nullify(this%Xh)
    nullify(this%bclst)
    nullify(this%dof)
    nullify(this%gs_h)
    nullify(this%msh)

  end subroutine fdm_free

  subroutine fdm_compute(this, e, r)
    class(fdm_t), intent(inout) :: this
    real(kind=dp), dimension((this%Xh%lx+2)**3, this%msh%nelv), intent(inout) :: e, r
    call fdm_do_fast(e, r, this%s, this%d, this%Xh%lx+2, this%msh%gdim, this%msh%nelv)
  end subroutine fdm_compute
 
  subroutine fdm_do_fast(e,r,s,d,nl,ldim,nelv)
    integer, intent(in) :: nl, nelv, ldim
    real(kind=dp), intent(inout) :: e(nl**ldim,nelv)
    real(kind=dp), intent(inout) :: r(nl**ldim,nelv)
    real(kind=dp), intent(inout) :: s(nl*nl,2,ldim,nelv)
    real(kind=dp), intent(inout) :: d(nl**ldim,nelv)
    
    integer ::  ie,nn,i
    nn=nl**ldim
    if(.not. ldim .eq. 3) then
       do ie=1,nelv
          call tnsr2d_el(e(1,ie),nl,r(1,ie),nl,s(1,2,1,ie),s(1,1,2,ie))
          do i=1,nn
             r(i,ie)=d(i,ie)*e(i,ie)
          enddo
          call tnsr2d_el(e(1,ie),nl,r(1,ie),nl,s(1,1,1,ie),s(1,2,2,ie))
       enddo
    else
       do ie=1,nelv
          call tnsr3d_el(e(1,ie),nl,r(1,ie),nl,s(1,2,1,ie),s(1,1,2,ie),s(1,1,3,ie))
          do i=1,nn
             r(i,ie)=d(i,ie)*e(i,ie)
          enddo
          call tnsr3d_el(e(1,ie),nl,r(1,ie),nl,s(1,1,1,ie),s(1,2,2,ie),s(1,2,3,ie))
       enddo
    endif
  end subroutine fdm_do_fast
end module fdm
