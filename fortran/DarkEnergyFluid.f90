
    module DarkEnergyFluid
    use DarkEnergyInterface
    use results
    use constants
    use classes
    implicit none

    type, extends(TDarkEnergyEqnOfState) :: TDarkEnergyFluid
        !comoving sound speed is always exactly 1 for quintessence
        !(otherwise assumed constant, though this is almost certainly unrealistic)
        ! JVR Note: there are added fields in TDarkEnergyModel type
        ! Namely the interaction coupling constant and the flag to use ppf or not
    contains
    procedure :: ReadParams => TDarkEnergyFluid_ReadParams
    procedure, nopass :: PythonClass => TDarkEnergyFluid_PythonClass
    procedure, nopass :: SelfPointer => TDarkEnergyFluid_SelfPointer
    procedure :: Init => TDarkEnergyFluid_Init
    procedure :: PerturbedStressEnergy => TDarkEnergyFluid_PerturbedStressEnergy
    procedure :: PerturbationEvolve => TDarkEnergyFluid_PerturbationEvolve
    procedure :: PerturbationInitial => TDarkEnergyFluid_PerturbationInitial ! JVR Modification
    end type TDarkEnergyFluid

    !Example implementation of fluid model using specific analytic form
    !(approximate effective axion fluid model from arXiv:1806.10608, with c_s^2=1 if n=infinity (w_n=1))
    !This is an example, it's not supposed to be a rigorous model!  (not very well tested)
    type, extends(TDarkEnergyModel) :: TAxionEffectiveFluid
        real(dl) :: w_n = 1._dl !Effective equation of state when oscillating
        real(dl) :: fde_zc = 0._dl ! energy density fraction at a_c (not the same as peak dark energy fraction)
        real(dl) :: zc  !transition redshift (scale factor a_c)
        real(dl) :: theta_i = const_pi/2 !Initial value
        !om is Omega of the early DE component today (assumed to be negligible compared to omega_lambda)
        !omL is the lambda component of the total dark energy omega
        real(dl), private :: a_c, pow, om, omL, acpow, freq, n !cached internally
    contains
    procedure :: ReadParams =>  TAxionEffectiveFluid_ReadParams
    procedure, nopass :: PythonClass => TAxionEffectiveFluid_PythonClass
    procedure, nopass :: SelfPointer => TAxionEffectiveFluid_SelfPointer
    procedure :: Init => TAxionEffectiveFluid_Init
    procedure :: w_de => TAxionEffectiveFluid_w_de
    procedure :: grho_de => TAxionEffectiveFluid_grho_de
    procedure :: PerturbedStressEnergy => TAxionEffectiveFluid_PerturbedStressEnergy
    procedure :: PerturbationEvolve => TAxionEffectiveFluid_PerturbationEvolve
    end type TAxionEffectiveFluid

    contains

    ! JVR Modification Begins
    subroutine TDarkEnergyFluid_PerturbationInitial(this, y, a, tau, k, w_ix, photon_density_initial_condition)
    class(TDarkEnergyFluid), intent(in)  :: this
    real(dl),                intent(inout) :: y(:)
    real(dl),                intent(in)  :: a, tau, k, photon_density_initial_condition
    real(dl)                             :: w, xi, factor
    integer,                 intent(in)  :: w_ix
    !Get initial values for perturbations at a (or tau)
    !For standard adiabatic perturbations can usually just set to zero to good accuracy

    xi = this%xi_interaction
    if (xi == 0d0) then
        y(w_ix) = 0
        y(w_ix + 1) = 0
    else
        ! TODO: initial perturbations for PPF
        w = this%w_lam
        factor = -(1._dl + w + xi/3._dl) / &
        (12._dl*w*w - 2._dl*w - 3._dl*w*xi + 7._dl*xi - 14._dl) * &
        1.5_dl * photon_density_initial_condition
        y(w_ix) = (1._dl + w - 2._dl*xi) * factor
        y(w_ix + 1) = k * tau * factor
    end if
    end subroutine TDarkEnergyFluid_PerturbationInitial
    ! JVR Modification Ends


    subroutine TDarkEnergyFluid_ReadParams(this, Ini)
    use IniObjects
    class(TDarkEnergyFluid) :: this
    class(TIniFile), intent(in) :: Ini

    call this%TDarkEnergyEqnOfState%ReadParams(Ini)
    this%cs2_lam = Ini%Read_Double('cs2_lam', 1.d0)

    end subroutine TDarkEnergyFluid_ReadParams


    function TDarkEnergyFluid_PythonClass()
    character(LEN=:), allocatable :: TDarkEnergyFluid_PythonClass

    TDarkEnergyFluid_PythonClass = 'DarkEnergyFluid'

    end function TDarkEnergyFluid_PythonClass

    subroutine TDarkEnergyFluid_SelfPointer(cptr,P)
    use iso_c_binding
    Type(c_ptr) :: cptr
    Type (TDarkEnergyFluid), pointer :: PType
    class (TPythonInterfacedClass), pointer :: P

    call c_f_pointer(cptr, PType)
    P => PType

    end subroutine TDarkEnergyFluid_SelfPointer

    subroutine TDarkEnergyFluid_Init(this, State)
    use classes
    class(TDarkEnergyFluid), intent(inout) :: this
    class(TCAMBdata), intent(in), target :: State

    call this%TDarkEnergyEqnOfState%Init(State)

    if (this%xi_interaction /= 0) then
        this%is_cosmological_constant = .false.
        if (this%use_ppf_interaction) then
            this%num_perturb_equations = 2
        else
            this%num_perturb_equations = 1
        end if
        this%cs2_lam = 1._dl
    end if

    if (this%is_cosmological_constant) then
        this%num_perturb_equations = 0
    else
        if (this%use_tabulated_w) then
            if (any(this%equation_of_state%F<-1)) &
                error stop 'Fluid dark energy model does not allow w crossing -1'
        elseif (this%wa/=0 .and. &
            ((1+this%w_lam < -1.e-6_dl) .or. 1+this%w_lam + this%wa < -1.e-6_dl)) then
            error stop 'Fluid dark energy model does not allow w crossing -1'
        end if
        this%num_perturb_equations = 2
    end if

    end subroutine TDarkEnergyFluid_Init


    subroutine TDarkEnergyFluid_PerturbedStressEnergy(this, dgrhoe, dgqe, &
        a, dgq, dgrho, grho, grhov_t, w, gpres_noDE, etak, adotoa, k, kf1, ay, ayprime, w_ix)
    class(TDarkEnergyFluid), intent(inout) :: this
    real(dl), intent(out) :: dgrhoe, dgqe
    real(dl), intent(in) ::  a, dgq, dgrho, grho, grhov_t, w, gpres_noDE, etak, adotoa, k, kf1
    real(dl), intent(in) :: ay(*)
    real(dl), intent(inout) :: ayprime(*)
    integer, intent(in) :: w_ix

    ! JVR Modification: calling PPF perturbations
    if (this%use_ppf_interaction) then
        call PPF_Perturbations(this, dgrhoe, dgqe, &
        a, dgq, dgrho, grho, grhov_t, w, gpres_noDE, &
        etak, adotoa, k, kf1, ay, ayprime, w_ix)
    else
        if (this%no_perturbations) then
            dgrhoe=0
            dgqe=0
        else
            dgrhoe = ay(w_ix) * grhov_t
            dgqe   = ay(w_ix + 1) * grhov_t * (1._dl + w)
        end if
    end if    
    end subroutine TDarkEnergyFluid_PerturbedStressEnergy


    subroutine TDarkEnergyFluid_PerturbationEvolve(this, ayprime, w, w_ix, &
        a, adotoa, k, z, y)
    class(TDarkEnergyFluid), intent(in)    :: this
    integer,                 intent(in)    :: w_ix
    real(dl),                intent(inout) :: ayprime(:)
    real(dl),                intent(in)    :: a, adotoa, w, k, z, y(:)
    real(dl)                               :: Hv3_over_k, loga, delta_de, vel_de, w_de_plus_one, xi
    ! Computes the derivatives delta_de' and v_de',
    ! where primes are derivatives w.r.t. conformal time

    ! JVR Modification: the PPF equations are set in the PerturbedStressEnergy subroutine
    if (this%use_ppf_interaction) then
        return
    end if

    Hv3_over_k    = 3._dl * adotoa * y(w_ix + 1) / k
    delta_de      = y(w_ix)
    vel_de        = y(w_ix + 1)
    w_de_plus_one = w + 1._dl
    xi = this%xi_interaction
    
    ! Density perturbation equation
    ! JVR Modification Begins
    ayprime(w_ix) = - w_de_plus_one * k * (vel_de + z) - 3._dl * adotoa * (1._dl - w) &
                    * (delta_de + (adotoa * vel_de / k) * (3._dl * w_de_plus_one + xi)) &
                    - xi * k * z / 3._dl
    ! JVR Modification Ends
    if (this%use_tabulated_w) then
        !account for derivatives of w
        loga = log(a)
        if (loga > this%equation_of_state%Xmin_interp .and. loga < this%equation_of_state%Xmax_interp) then
            ayprime(w_ix) = ayprime(w_ix) - adotoa*this%equation_of_state%Derivative(loga)* Hv3_over_k
        end if
    elseif (this%wa/=0) then
        ayprime(w_ix) = ayprime(w_ix) + Hv3_over_k*this%wa*adotoa*a
    end if
    ! Velocity equation
    if (abs(w + 1._dl) > 1e-6) then
        ! JVR Modification Begins
        ayprime(w_ix + 1) = 2._dl * adotoa * vel_de * (1._dl + xi / w_de_plus_one) + &
                            k * delta_de / w_de_plus_one
        ! JVR Modification Ends
    else
        ayprime(w_ix + 1) = 0
    end if
    end subroutine TDarkEnergyFluid_PerturbationEvolve

    subroutine TAxionEffectiveFluid_ReadParams(this, Ini)
    use IniObjects
    class(TAxionEffectiveFluid) :: this
    class(TIniFile), intent(in) :: Ini

    call this%TDarkEnergyModel%ReadParams(Ini)
    if (Ini%HasKey('AxionEffectiveFluid_a_c')) then
        error stop 'AxionEffectiveFluid inputs changed to AxionEffectiveFluid_fde_zc and AxionEffectiveFluid_zc'
    end if
    this%w_n  = Ini%Read_Double('AxionEffectiveFluid_w_n')
    this%fde_zc  = Ini%Read_Double('AxionEffectiveFluid_fde_zc')
    this%zc  = Ini%Read_Double('AxionEffectiveFluid_zc')
    call Ini%Read('AxionEffectiveFluid_theta_i', this%theta_i)

    end subroutine TAxionEffectiveFluid_ReadParams


    function TAxionEffectiveFluid_PythonClass()
    character(LEN=:), allocatable :: TAxionEffectiveFluid_PythonClass

    TAxionEffectiveFluid_PythonClass = 'AxionEffectiveFluid'
    end function TAxionEffectiveFluid_PythonClass

    subroutine TAxionEffectiveFluid_SelfPointer(cptr,P)
    use iso_c_binding
    Type(c_ptr) :: cptr
    Type (TAxionEffectiveFluid), pointer :: PType
    class (TPythonInterfacedClass), pointer :: P

    call c_f_pointer(cptr, PType)
    P => PType

    end subroutine TAxionEffectiveFluid_SelfPointer

    subroutine TAxionEffectiveFluid_Init(this, State)
    use classes
    class(TAxionEffectiveFluid), intent(inout) :: this
    class(TCAMBdata), intent(in), target :: State
    real(dl) :: grho_rad, F, p, mu, xc, n

    select type(State)
    class is (CAMBdata)
        this%is_cosmological_constant = this%fde_zc==0
        this%pow = 3*(1+this%w_n)
        this%a_c = 1/(1+this%zc)
        this%acpow = this%a_c**this%pow
        !Omega in early de at z=0
        this%om = 2*this%fde_zc/(1-this%fde_zc)*&
            (State%grho_no_de(this%a_c)/this%a_c**4/State%grhocrit + State%Omega_de)/(1 + 1/this%acpow)
        this%omL = State%Omega_de - this%om !Omega_de is total dark energy density today
        this%num_perturb_equations = 2
        if (this%w_n < 0.9999) then
            ! n <> infinity
            !get (very) approximate result for sound speed parameter; arXiv:1806.10608  Eq 30 (but mu may not exactly agree with what they used)
            n = nint((1+this%w_n)/(1-this%w_n))
            !Assume radiation domination, standard neutrino model; H0 factors cancel
            grho_rad = (kappa/c**2*4*sigma_boltz/c**3*State%CP%tcmb**4*Mpc**2*(1+3.046*7._dl/8*(4._dl/11)**(4._dl/3)))
            xc = this%a_c**2/2/sqrt(grho_rad/3)
            F=7./8
            p=1./2
            mu = 1/xc*(1-cos(this%theta_i))**((1-n)/2.)*sqrt((1-F)*(6*p+2)*this%theta_i/n/sin(this%theta_i))
            this%freq =  mu*(1-cos(this%theta_i))**((n-1)/2.)* &
                sqrt(const_pi)*Gamma((n+1)/(2.*n))/Gamma(1+0.5/n)*2.**(-(n**2+1)/(2.*n))*3.**((1./n-1)/2)*this%a_c**(-6./(n+1)+3) &
                *( this%a_c**(6*n/(n+1.))+1)**(0.5*(1./n-1))
            this%n = n
        end if
    end select

    end subroutine TAxionEffectiveFluid_Init


    function TAxionEffectiveFluid_w_de(this, a)
    class(TAxionEffectiveFluid) :: this
    real(dl) :: TAxionEffectiveFluid_w_de
    real(dl), intent(IN) :: a
    real(dl) :: rho, apow, acpow

    apow = a**this%pow
    acpow = this%acpow
    rho = this%omL+ this%om*(1+acpow)/(apow+acpow)
    TAxionEffectiveFluid_w_de = this%om*(1+acpow)/(apow+acpow)**2*(1+this%w_n)*apow/rho - 1

    end function TAxionEffectiveFluid_w_de

    function TAxionEffectiveFluid_grho_de(this, a)  !relative density (8 pi G a^4 rho_de /grhov)
    class(TAxionEffectiveFluid) :: this
    real(dl) :: TAxionEffectiveFluid_grho_de, apow
    real(dl), intent(IN) :: a

    if(a == 0.d0)then
        TAxionEffectiveFluid_grho_de = 0.d0
    else
        apow = a**this%pow
        TAxionEffectiveFluid_grho_de = (this%omL*(apow+this%acpow)+this%om*(1+this%acpow))*a**4 &
            /((apow+this%acpow)*(this%omL+this%om))
    endif

    end function TAxionEffectiveFluid_grho_de

    subroutine TAxionEffectiveFluid_PerturbationEvolve(this, ayprime, w, w_ix, &
        a, adotoa, k, z, y)
    class(TAxionEffectiveFluid), intent(in) :: this
    real(dl), intent(inout) :: ayprime(:)
    real(dl), intent(in) :: a, adotoa, w, k, z, y(:)
    integer, intent(in) :: w_ix
    real(dl) Hv3_over_k, deriv, apow, acpow, cs2, fac

    if (this%w_n < 0.9999) then
        fac = 2*a**(2-6*this%w_n)*this%freq**2
        cs2 = (fac*(this%n-1) + k**2)/(fac*(this%n+1) + k**2)
    else
        cs2 = 1
    end if
    apow = a**this%pow
    acpow = this%acpow
    Hv3_over_k =  3*adotoa* y(w_ix + 1) / k
    ! dw/dlog a/(1+w)
    deriv  = (acpow**2*(this%om+this%omL)+this%om*acpow-apow**2*this%omL)*this%pow &
        /((apow+acpow)*(this%omL*(apow+acpow)+this%om*(1+acpow)))
    !density perturbation
    ayprime(w_ix) = -3 * adotoa * (cs2 - w) *  (y(w_ix) + Hv3_over_k) &
        -   k * y(w_ix + 1) - (1 + w) * k * z  - adotoa*deriv* Hv3_over_k
    !(1+w)v
    ayprime(w_ix + 1) = -adotoa * (1 - 3 * cs2 - deriv) * y(w_ix + 1) + &
        k * cs2 * y(w_ix)

    end subroutine TAxionEffectiveFluid_PerturbationEvolve


    subroutine TAxionEffectiveFluid_PerturbedStressEnergy(this, dgrhoe, dgqe, &
        a, dgq, dgrho, grho, grhov_t, w, gpres_noDE, etak, adotoa, k, kf1, ay, ayprime, w_ix)
    class(TAxionEffectiveFluid), intent(inout) :: this
    real(dl), intent(out) :: dgrhoe, dgqe
    real(dl), intent(in) :: a, dgq, dgrho, grho, grhov_t, w, gpres_noDE, etak, adotoa, k, kf1
    real(dl), intent(in) :: ay(*)
    real(dl), intent(inout) :: ayprime(*)
    integer, intent(in) :: w_ix

    dgrhoe = ay(w_ix) * grhov_t
    dgqe = ay(w_ix + 1) * grhov_t

    end subroutine TAxionEffectiveFluid_PerturbedStressEnergy

    ! JVR Modification: add PPF perturbations
    subroutine PPF_Perturbations(this, dgrhoe, dgqe, &
        a, dgq, dgrho, grho, grhov_t, w, gpres_noDE, etak, adotoa, k, kf1, ay, ayprime, w_ix)
        class(TDarkEnergyFluid), intent(inout) :: this
        real(dl), intent(out) :: dgrhoe, dgqe
        real(dl), intent(in) :: grhov_t
        real(dl), intent(in) :: w
        real(dl), intent(in) :: a, dgq, dgrho, grho, gpres_noDE, etak, adotoa, k, kf1
        real(dl), intent(in) :: ay(*)
        real(dl), intent(inout) :: ayprime(*)
        integer, intent(in) :: w_ix
        real(dl) :: grhoT, vT, k2, sigma, S_Gamma, ckH, Gamma, Gammadot, Fa, c_Gamma_ppf, kH, Q, v_c, xi_0
    
        k2 = k**2
        grhoT = grho - grhov_t
        vT = dgq / (grhoT + gpres_noDE)
        Gamma = ay(w_ix)
        c_Gamma_ppf = 0.4_dl
        Q = this%xi_interaction * adotoa * grhov_t / a / a ! TODO: check if this is correct (factors of a)
        ! Note: for the remainder of the equations, there is no need to multiply a * Q
    
        ! Original implementation of sigma
        ! sigma = (etak + (dgrho + 3 * adotoa / k * dgq) / 2._dl / k) / kf1 - k * Gamma
        ! sigma = sigma / adotoa

        ! JVR Modification: sigma according to Eq. 5.17 from https://arxiv.org/pdf/2306.01593.pdf
        ! We can see that if Q = 0, Eq. 5.17 is equivalent to the original code
        ! So just add another term for the Q
        ! TODO: check how to get total energy density and pressure to add in the denominator of Q
        kH = k / adotoa
        sigma = (etak + (dgrho + 3 * adotoa / k * dgq * (1 + Q / (3 * adotoa * (grho + gpres_noDE + grhov_t * w)))) / 2._dl / k) / kf1 - k * Gamma
        sigma = sigma / adotoa
    
        ckH = c_Gamma_ppf * k / adotoa
        ! Original implementation of S_Gamma:
        !S_Gamma = grhov_t * (1 + w) * (vT + sigma) * k / adotoa / 2._dl / k2
        
        ! TODO: how to get v_c from ay?
        S_Gamma = grhov_t * (1 + w) * (vT + sigma) * k / adotoa / 2._dl / k2 + (kappa * a * a / 2._dl / k2) * (3 * a * Q) / ckH * (v_c - vT) - Q * xi_0


        ! TODO: how to get xi_0?
        ! See equations 5.19 and 4.13
        xi_0 = 0.d0
        v_c = 0.d0

        if (ckH * ckH .gt. 3.d1) then ! ckH^2 > 30 ?????????
            Gamma = 0
            Gammadot = 0.d0
        else
            ! JVR Modification: adding a term to S_0 (Eq. 4.17)
            ! Original implementation of Gammadot:
            ! Gammadot = S_Gamma / (1 + ckH * ckH) - Gamma - ckH * ckH * Gamma
            Gammadot = (S_Gamma + a * Q * Gamma / grhov_t) / (1 + ckH * ckH) - Gamma - ckH * ckH * Gamma

            Gammadot = Gammadot * adotoa
        endif
        ayprime(w_ix) = Gammadot ! Set this here, and don't use PerturbationEvolve
    
        Fa = 1 + 3 * (grhoT + gpres_noDE) / 2._dl / k2 / kf1
        dgqe = S_Gamma - Gammadot / adotoa - Gamma
        dgqe = -dgqe / Fa * 2._dl * k * adotoa + vT * grhov_t * (1 + w) ! No need to change this equation
        dgrhoe = -2 * k2 * kf1 * Gamma - 3 / k * adotoa * dgqe + Q * vT / k ! Added a new term
    end subroutine PPF_Perturbations

    end module DarkEnergyFluid
