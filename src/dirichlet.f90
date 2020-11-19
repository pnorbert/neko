!> Defines a dirichlet boundary condition
module dirichlet
  use num_types
  use bc  
  implicit none
  private

  !> Generic Dirichlet boundary condition
  !! \f$ x = g \f$ on \f$\partial \Omega\f$
  type, public, extends(bc_t) :: dirichlet_t
     real(kind=dp), private :: g
   contains
     procedure, pass(this) :: apply => dirichlet_apply
     procedure, pass(this) :: apply_mult => dirichlet_apply_mult
     procedure, pass(this) :: set_g => dirichlet_set_g
  end type dirichlet_t

contains

  !> Boundary condition apply for a generic Dirichlet condition
  !! to a vector @a x
  subroutine dirichlet_apply(this, x, n)
    class(dirichlet_t), intent(inout) :: this
    integer, intent(in) :: n
    real(kind=dp), intent(inout),  dimension(n) :: x
    integer :: i, m, k

    m = this%msk(0)
    do i = 1, m
       k = this%msk(i)
       x(k) = this%g
    end do
  end subroutine dirichlet_apply

  !> Boundary condition apply for a generic Dirichlet condition
  !! to vectors @a x, @a y and @a z
  subroutine dirichlet_apply_mult(this, x, y, z, n)
    class(dirichlet_t), intent(inout) :: this
    integer, intent(in) :: n
    real(kind=dp), intent(inout),  dimension(n) :: x
    real(kind=dp), intent(inout),  dimension(n) :: y
    real(kind=dp), intent(inout),  dimension(n) :: z
    integer :: i, m, k

    m = this%msk(0)
    do i = 1, m
       k = this%msk(i)
       x(k) = this%g
       y(k) = this%g
       z(k) = this%g
    end do
    
  end subroutine dirichlet_apply_mult

  !> Set value of \f$ g \f$
  subroutine dirichlet_set_g(this, g)
    class(dirichlet_t), intent(inout) :: this
    real(kind=dp), intent(in) :: g

    this%g = g
    
  end subroutine dirichlet_set_g
  
end module dirichlet
