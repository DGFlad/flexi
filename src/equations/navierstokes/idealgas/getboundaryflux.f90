!=================================================================================================================================
! Copyright (c) 2010-2016  Prof. Claus-Dieter Munz 
! This file is part of FLEXI, a high-order accurate framework for numerically solving PDEs with discontinuous Galerkin methods.
! For more information see https://www.flexi-project.org and https://nrg.iag.uni-stuttgart.de/
!
! FLEXI is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License 
! as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!
! FLEXI is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
! of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License v3.0 for more details.
!
! You should have received a copy of the GNU General Public License along with FLEXI. If not, see <http://www.gnu.org/licenses/>.
!=================================================================================================================================
#include "flexi.h"
#include "eos.h"

!==================================================================================================================================
!> Routines to provide boundary conditions for the domain. Fills the boundary part of the fluxes list.
!==================================================================================================================================
MODULE MOD_GetBoundaryFlux
! MODULES
IMPLICIT NONE
PRIVATE
!----------------------------------------------------------------------------------------------------------------------------------
! GLOBAL VARIABLES
!----------------------------------------------------------------------------------------------------------------------------------

INTERFACE InitBC
  MODULE PROCEDURE InitBC
END INTERFACE

INTERFACE GetBoundaryFlux
  MODULE PROCEDURE GetBoundaryFlux
END INTERFACE

INTERFACE FinalizeBC
  MODULE PROCEDURE FinalizeBC
END INTERFACE

#if FV_ENABLED
#if FV_RECONSTRUCT
INTERFACE GetBoundaryFVgradient
  MODULE PROCEDURE GetBoundaryFVgradient
END INTERFACE
#endif
#endif

#if PARABOLIC
INTERFACE Lifting_GetBoundaryFlux
  MODULE PROCEDURE Lifting_GetBoundaryFlux
END INTERFACE
PUBLIC :: Lifting_GetBoundaryFlux
#endif /*PARABOLIC*/

PUBLIC :: InitBC
PUBLIC :: GetBoundaryFlux
PUBLIC :: FinalizeBC
#if FV_ENABLED
#if FV_RECONSTRUCT
PUBLIC :: GetBoundaryFVgradient
#endif
#endif
!==================================================================================================================================

CONTAINS


!==================================================================================================================================
!> Initialize boundary conditions. Read parameters and sort boundary conditions by types.
!> Call boundary condition specific init routines.
!==================================================================================================================================
SUBROUTINE InitBC()
! MODULES
USE MOD_Preproc
USE MOD_Globals
USE MOD_Viscosity
USE MOD_Equation_Vars     ,ONLY: EquationInitIsDone
USE MOD_Equation_Vars     ,ONLY: nRefState,BCData,BCDataPrim,nBCByType,BCSideID
USE MOD_Equation_Vars     ,ONLY: BCStateFile,RefStatePrim
USE MOD_Interpolation_Vars,ONLY: InterpolationInitIsDone
USE MOD_Mesh_Vars         ,ONLY: MeshInitIsDone,nBCSides,BC,BoundaryType,nBCs
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT / OUTPUT VARIABLES
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER :: i,iSide
INTEGER :: locType,locState
INTEGER :: MaxBCState,MaxBCStateGlobal
LOGICAL :: readBCdone
REAL    :: talpha,tbeta
!==================================================================================================================================
IF((.NOT.InterpolationInitIsDone).AND.(.NOT.MeshInitIsDone).AND.(.NOT.EquationInitIsDone))THEN
   CALL CollectiveStop(__STAMP__,&
     "InitBC not ready to be called or already called.")
END IF
! determine globally max MaxBCState
MaxBCState = 0
DO iSide=1,nBCSides
  locType =BoundaryType(BC(iSide),BC_TYPE)
  locState=BoundaryType(BC(iSide),BC_STATE)
  IF((locType.NE.22).AND.locType.NE.3) MaxBCState = MAX(MaxBCState,locState)
  IF((locType.EQ.4).AND.(locState.LT.1))&
    CALL abort(__STAMP__,&
               'No temperature (refstate) defined for BC_TYPE',locType)
  IF((locType.EQ.23).AND.(locState.LT.1))&
    CALL abort(__STAMP__,&
               'No outflow Mach number in refstate (x,Ma,x,x,x) defined for BC_TYPE',locType)
  IF((locType.EQ.24).AND.(locState.LT.1))&
    CALL abort(__STAMP__,&
               'No outflow pressure in refstate defined for BC_TYPE',locType)
  IF((locType.EQ.25).AND.(locState.LT.1))&
    CALL abort(__STAMP__,&
               'No outflow pressure in refstate defined for BC_TYPE',locType)
  IF((locType.EQ.27).AND.(locState.LT.1))&
    CALL abort(__STAMP__,&
               'No inflow refstate (Tt,alpha,beta,empty,pT) in refstate defined for BC_TYPE',locType)
#if FV_RECONSTRUCT
  IF((locType.EQ.3).OR.(locType.EQ.4))THEN
    ASSOCIATE(prim => RefStatePrim(:,locState))
#if PARABOLIC
    IF(VISCOSITY_PRIM(prim).LE.0.) &
#endif
    CALL abort(__STAMP__,'No-slip BCs cannot be used without viscosity in case of FV-reconstruction!')
    END ASSOCIATE
  END IF
#endif
END DO
MaxBCStateGLobal=MaxBCState
#if USE_MPI
CALL MPI_ALLREDUCE(MPI_IN_PLACE,MaxBCStateGlobal,1,MPI_INTEGER,MPI_MAX,MPI_COMM_WORLD,iError)
#endif /*USE_MPI*/

! Sanity check for BCs
IF(MaxBCState.GT.nRefState)THEN
  CALL abort(__STAMP__,&
    'ERROR: Boundary RefState not defined! (MaxBCState,nRefState):',MaxBCState,REAL(nRefState))
END IF

! Allocate buffer array to store temp data for all BC sides
ALLOCATE(BCData(    PP_nVar,    0:PP_N,0:PP_N,nBCSides))
ALLOCATE(BCDataPrim(PP_nVarPrim,0:PP_N,0:PP_N,nBCSides))
BCData=0.
BCDataPrim=0.

! Initialize boundary conditions
readBCdone=.FALSE.
DO i=1,nBCs
  locType =BoundaryType(i,BC_TYPE)
  locState=BoundaryType(i,BC_STATE)
  SELECT CASE (locType)
  CASE(12) ! State File Boundary condition
    IF(.NOT.readBCdone) CALL ReadBCFlow(BCStateFile)
    readBCdone=.TRUE. 
  CASE(27) ! Subsonic inflow 
    talpha=TAN(ACOS(-1.)/180.*RefStatePrim(2,locState))
    tbeta =TAN(ACOS(-1.)/180.*RefStatePrim(3,locState))
    ! Compute vector a(1:3) from paper, the projection of the direction normal to the face normal
    ! Multiplication of velocity magnitude by NORM2(a) gives contribution in face normal dir         
    RefStatePrim(2,locState)=1.    /SQRT((1.+talpha**2+tbeta**2))
    RefStatePrim(3,locState)=talpha/SQRT((1.+talpha**2+tbeta**2))
    RefStatePrim(4,locState)=tbeta /SQRT((1.+talpha**2+tbeta**2))
  END SELECT
END DO


! Count number of sides of each boundary
ALLOCATE(nBCByType(nBCs))
nBCByType=0
DO iSide=1,nBCSides
  DO i=1,nBCs
    IF(BC(iSide).EQ.i) nBCByType(i)=nBCByType(i)+1
  END DO
END DO

! Sort BCs by type, store SideIDs
ALLOCATE(BCSideID(nBCs,MAXVAL(nBCByType)))
nBCByType=0
DO iSide=1,nBCSides
  DO i=1,nBCs
    IF(BC(iSide).EQ.i)THEN
      nBCByType(i)=nBCByType(i)+1
      BCSideID(i,nBCByType(i))=iSide
    END IF
  END DO
END DO

END SUBROUTINE InitBC


!==================================================================================================================================
!> Computes the boundary state for the different boundary conditions.
!==================================================================================================================================
SUBROUTINE GetBoundaryState(SideID,t,Nloc,UPrim_boundary,UPrim_master,NormVec,TangVec1,TangVec2,Face_xGP)
!----------------------------------------------------------------------------------------------------------------------------------!
! MODULES                                                                                                                          !
USE MOD_PreProc
USE MOD_Globals      ,ONLY: Abort
USE MOD_Mesh_Vars    ,ONLY: BoundaryType,BC
USE MOD_EOS          ,ONLY: ConsToPrim,PrimtoCons
USE MOD_EOS          ,ONLY: PRESSURE_RIEMANN
USE MOD_EOS_Vars     ,ONLY: sKappaM1,Kappa,KappaM1,R
USE MOD_ExactFunc    ,ONLY: ExactFunc
USE MOD_Equation_Vars,ONLY: IniExactFunc,BCDataPrim,RefStatePrim,nRefState
!----------------------------------------------------------------------------------------------------------------------------------!
! insert modules here
!----------------------------------------------------------------------------------------------------------------------------------!
IMPLICIT NONE
! INPUT / OUTPUT VARIABLES
INTEGER,INTENT(IN)      :: SideID
REAL,INTENT(IN)         :: t       !< current time (provided by time integration scheme)
INTEGER,INTENT(IN)      :: Nloc    !< polynomial degree
REAL,INTENT(IN)         :: UPrim_master(  PP_nVarPrim,0:Nloc,0:Nloc) !< inner surface solution
REAL,INTENT(IN)         :: NormVec(                 3,0:Nloc,0:Nloc) !< normal surface vectors
REAL,INTENT(IN)         :: TangVec1(                3,0:Nloc,0:Nloc) !< tangent surface vectors 1
REAL,INTENT(IN)         :: TangVec2(                3,0:Nloc,0:Nloc) !< tangent surface vectors 2
REAL,INTENT(IN)         :: Face_xGP(                3,0:Nloc,0:Nloc) !< positions of surface flux points
REAL,INTENT(OUT)        :: UPrim_boundary(PP_nVarPrim,0:Nloc,0:Nloc) !< resulting boundary state

! INPUT / OUTPUT VARIABLES 
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                 :: p,q
REAL                    :: absdiff(1:nRefState)
INTEGER                 :: BCType,BCState
REAL,DIMENSION(PP_nVar) :: Cons
REAL                    :: MaOut
REAL                    :: c,vmag,Ma,cb,pt,pb ! for BCType==23,24,25
REAL                    :: U,Tb,Tt,tmp1,tmp2,tmp3,A,Rminus,nv(3) ! for BCType==27
!===================================================================================================================================
BCType  = Boundarytype(BC(SideID),BC_TYPE)
BCState = Boundarytype(BC(SideID),BC_STATE)
SELECT CASE(BCType)
CASE(2) !Exact function or refstate
  IF(BCState.EQ.0)THEN
    DO q=0,Nloc; DO p=0,Nloc
      CALL ExactFunc(IniExactFunc,t,Face_xGP(:,p,q),Cons)
      CALL ConsToPrim(UPrim_boundary(:,p,q),Cons)
    END DO; END DO
  ELSE
    DO q=0,Nloc; DO p=0,Nloc
      UPrim_boundary(:,p,q) = RefStatePrim(:,BCState)
    END DO; END DO
  END IF
CASE(12) ! exact BC = Dirichlet BC !!
  ! SPECIAL BC: BCState uses readin state
  ! Dirichlet means that we use the gradients from inside the grid cell
  UPrim_boundary(:,:,:) = BCDataPrim(:,:,:,SideID)
CASE(22) ! exact BC = Dirichlet BC !!
  ! SPECIAL BC: BCState specifies exactfunc to be used!!
  DO q=0,Nloc; DO p=0,Nloc
    CALL ExactFunc(BCState,t,Face_xGP(:,p,q),Cons)
    CALL ConsToPrim(UPrim_boundary(:,p,q),Cons)
  END DO; END DO


CASE(3,4,9,23,24,25,27)
  ! Initialize boundary state with rotated inner state
  DO q=0,Nloc; DO p=0,Nloc
    ! transform state into normal system
    UPrim_boundary(1,p,q)= UPrim_master(1,p,q)
    UPrim_boundary(2,p,q)= SUM(UPrim_master(2:4,p,q)*NormVec( :,p,q))
    UPrim_boundary(3,p,q)= SUM(UPrim_master(2:4,p,q)*TangVec1(:,p,q))
    UPrim_boundary(4,p,q)= SUM(UPrim_master(2:4,p,q)*TangVec2(:,p,q))
    UPrim_boundary(5:PP_nVarPrim,p,q)= UPrim_master(5:PP_nVarPrim,p,q)
  END DO; END DO !p,q


  SELECT CASE(BCType)
  CASE(3) ! Adiabatic wall
    ! Diffusion: density=inside, velocity=0 (see below, after rotating back to physical space), rhoE=inside
    ! For adiabatic wall all gradients are 0
    ! We reconstruct the BC State, rho=rho_L, velocity=0, rhoE_wall = p_Riemann/(Kappa-1)
    DO q=0,Nloc; DO p=0,Nloc
      ! Set pressure by solving local Riemann problem
      UPrim_boundary(5,p,q) = PRESSURE_RIEMANN(UPrim_boundary(:,p,q))
      UPrim_boundary(2:4,p,q)= 0. ! no slip
      UPrim_boundary(6,p,q) = UPrim_master(6,p,q) ! adiabatic => temperature from the inside
      ! set density via ideal gas equation, consistent to pressure and temperature
      UPrim_boundary(1,p,q) = UPrim_boundary(5,p,q) / (UPrim_boundary(6,p,q) * R) 
    END DO; END DO ! q,p
  CASE(4) ! Isothermal wall
    ! For isothermal wall, all gradients are from interior
    ! We reconstruct the BC State, rho=rho_L, velocity=0, rhoE_wall =  rho_L*C_v*Twall
    DO q=0,Nloc; DO p=0,Nloc
      ! Set pressure by solving local Riemann problem
      UPrim_boundary(5,p,q) = PRESSURE_RIEMANN(UPrim_boundary(:,p,q))
      UPrim_boundary(2:4,p,q)= 0. ! no slip
      UPrim_boundary(6,p,q) = RefStatePrim(6,BCState) ! temperature from RefState
      ! set density via ideal gas equation, consistent to pressure and temperature
      UPrim_boundary(1,p,q) = UPrim_boundary(5,p,q) / (UPrim_boundary(6,p,q) * R)
    END DO; END DO ! q,p
  CASE(9) ! Euler (slip) wall
    ! vel=(0,v_in,w_in)
    ! NOTE: from this state ONLY the velocities should actually be used for the diffusive flux
    DO q=0,Nloc; DO p=0,Nloc
      ! Set pressure by solving local Riemann problem
      UPrim_boundary(5,p,q) = PRESSURE_RIEMANN(UPrim_boundary(:,p,q))
      UPrim_boundary(2,p,q) = 0. ! slip in tangential directions
      UPrim_boundary(6,p,q) = UPrim_master(6,p,q) ! temperature from the inside
      ! set density via ideal gas equation, consistent to pressure and temperature
      UPrim_boundary(1,p,q) = UPrim_boundary(5,p,q) / (UPrim_boundary(6,p,q) * R) 
    END DO; END DO ! q,p

  ! Cases 21-29 are taken from NASA report "Inflow/Outflow Boundary Conditions with Application to FUN3D" Jan-Reneé Carlson
  ! and correspond to case BCs 2.1 - 2.9
  ! NOTE: quantities in paper are non-dimensional e.g. T=c^2
  CASE(23) ! Outflow mach number BC
    ! NOTE: Should not be used with adjacent walls (destroys boundary layer profile, like exact function)
    ! Refstate for this case is special, VelocityX specifies outlet mach number
    ! State: (/dummy,Ma,dummy,dummy,dummy/)
    MaOut=RefStatePrim(2,BCState)
    DO q=0,Nloc; DO p=0,Nloc
      c=SQRT(kappa*UPrim_boundary(5,p,q)/UPrim_boundary(1,p,q))
      vmag=NORM2(UPrim_boundary(2:4,p,q))
      Ma=vmag/c
      cb=vmag/MaOut
      IF(Ma<1)THEN
        ! use total pressure
        pt=UPrim_boundary(5,p,q)*((1+0.5*(kappa-1)*Ma   *Ma)   **( kappa*sKappaM1))  ! adiabatic/isentropic => unstable
        !pt=prim(5)+0.5*prim(1)*vmag*vmag
        pb=pt     *(1+0.5*(kappa-1)*MaOut*MaOut)**(-kappa*sKappaM1)
      ELSE
        ! use total pressure for supersonic
        pb=UPrim_boundary(5,p,q)+0.5*UPrim_boundary(1,p,q)*vmag*vmag
      END IF
      UPrim_boundary(1,p,q)=kappa*pb/(cb*cb)
      UPrim_boundary(2:4,p,q)=UPrim_boundary(2:4,p,q)
      UPrim_boundary(5,p,q)=pb
      UPrim_boundary(6,p,q)=UPrim_boundary(5,p,q)/(R*UPrim_boundary(1,p,q))
    END DO; END DO !p,q
  CASE(24) ! Pressure outflow BC
    DO q=0,Nloc; DO p=0,Nloc
      ! check if sub / supersonic (squared quantities)
      c=kappa*UPrim_boundary(5,p,q)/UPrim_boundary(1,p,q)
      vmag=SUM(UPrim_boundary(2:4,p,q)*UPrim_boundary(2:4,p,q))
      ! if subsonic use specified pressure, else use solution from the inside
      IF(vmag<c)THEN
        IF (BCState.GT.0) THEN
          pb = RefStatePrim(5,BCState)
        ELSE
          absdiff = ABS(RefStatePrim(5,:) - UPrim_boundary(5,p,q))
          pb = RefStatePrim(5,MINLOC(absdiff,1))
        END IF
        UPrim_boundary(1,p,q)=kappa*pb/c
        UPrim_boundary(5,p,q)=pb
        UPrim_boundary(6,p,q)=UPrim_boundary(5,p,q)/(R*UPrim_boundary(1,p,q))
      ENDIF
    END DO; END DO !p,q
  CASE(25) ! Subsonic outflow BC
    DO q=0,Nloc; DO p=0,Nloc
      ! check if sub / supersonic (squared quantities)
      c=kappa*UPrim_boundary(5,p,q)/UPrim_boundary(1,p,q)
      vmag=SUM(UPrim_boundary(2:4,p,q)*UPrim_boundary(2:4,p,q))
      ! if supersonic use total pressure to compute density
      pb        = MERGE(UPrim_boundary(5,p,q)+0.5*UPrim_boundary(1,p,q)*vmag,RefStatePrim(5,BCState),vmag>=c)
      UPrim_boundary(1,p,q)   = kappa*pb/c
      ! ensure outflow
      UPrim_boundary(2:4,p,q) = MERGE(UPrim_boundary(2:4,p,q),SQRT(vmag)*NormVec(:,p,q),UPrim_boundary(2,p,q)>=0.)
      UPrim_boundary(5,p,q)   = RefStatePrim(5,BCState) ! always outflow pressure
      UPrim_boundary(6,p,q)   = UPrim_boundary(5,p,q)/(R*UPrim_boundary(1,p,q))
    END DO; END DO !p,q
  CASE(27) ! Subsonic inflow BC
    ! Refstate for this case is special
    ! State: (/Density,nv1,nv2,nv3,Pressure/)
    ! Compute temperature from density and pressure
    ! Nv specifies inflow direction of inflow:
    ! if ABS(nv)=0  then inflow vel is always in side normal direction
    ! if ABS(nv)!=0 then inflow vel is in global coords with nv specifying the direction
    DO q=0,Nloc; DO p=0,Nloc
      ! Prescribe Total Temp, Total Pressure, inflow angle of attack alpha
      ! and inflow yaw angle beta
      ! WARNING: REFSTATE is different: Tt,alpha,beta,<empty>,pT (4th entry ignored!!), angles in DEG not RAD
      ! Tt is computed by 
      ! BC not from FUN3D Paper by JR Carlson (too many bugs), but from AIAA 2001 3882
      ! John W. Slater: Verification Assessment of Flow Boundary Conditions for CFD
      ! The BC State is described, not the outer state: use BC state to compute flux directly

      Tt=RefStatePrim(1,BCState)
      nv=RefStatePrim(2:4,BCState)
      pt=RefStatePrim(5,BCState)
      ! Term A from paper with normal vector defined into the domain, dependent on p,q
      A=SUM(nv(1:3)*(-1.)*NormVec(1:3,p,q))
      ! sound speed from inner state
      c=SQRT(kappa*UPrim_boundary(5,p,q)/UPrim_boundary(1,p,q))
      ! 1D Riemann invariant: Rminus = Ui-2ci /kappamM1, Rminus = Ubc-2cb /kappaM1, normal component only!
      Rminus=-UPrim_boundary(2,p,q)-2./KappaM1*c
      ! The Newton iteration for the T_b in the paper can be avoided by rewriting EQ 5 from the  paper
      ! not in T, but in sound speed -> quadratic equation, solve with PQ Formel (Mitternachtsformel is
      ! FORBIDDEN)
      tmp1=(A**2*KappaM1+2.)/(Kappa*R*A**2*KappaM1)   !a
      tmp2=2*Rminus/(Kappa*R*A**2)                    !b
      tmp3=KappaM1*Rminus*Rminus/(2.*Kappa*R*A**2)-Tt !c
      cb=(-tmp2+SQRT(tmp2**2-4*tmp1*tmp3))/(2*tmp1)   ! 
      c=(-tmp2-SQRT(tmp2**2-4*tmp1*tmp3))/(2*tmp1)    ! dummy
      cb=MAX(cb,c)                                    ! Following the FUN3D Paper, the max. of the two
      ! is the physical one...not 100% clear why
      ! compute static T  at bc from c
      Tb=cb**2/(Kappa*R)
      Ma=SQRT(2./KappaM1*(Tt/Tb-1.))       
      pb=pt*(1.+0.5*KappaM1*Ma**2)**(-kappa/kappam1) 
      U=Ma*SQRT(Kappa*R*Tb)
      UPrim_boundary(1,p,q) = pb/(R*Tb)
      UPrim_boundary(5,p,q) = pb

      ! we need the state in the global system for the diff fluxes
      UPrim_boundary(2,p,q)=SUM(U*nv(1:3)*Normvec( 1:3,p,q))
      UPrim_boundary(3,p,q)=SUM(U*nv(1:3)*Tangvec1(1:3,p,q))
      UPrim_boundary(4,p,q)=SUM(U*nv(1:3)*Tangvec2(1:3,p,q))
      UPrim_boundary(6,p,q)=UPrim_boundary(5,p,q)/(R*UPrim_boundary(1,p,q))
    END DO; END DO !p,q
  END SELECT

  ! rotate state back to physical system
  DO q=0,Nloc; DO p=0,Nloc
    UPrim_boundary(2:4,p,q) = UPrim_boundary(2,p,q)*NormVec( :,p,q) &
                             +UPrim_boundary(3,p,q)*TangVec1(:,p,q) &
                             +UPrim_boundary(4,p,q)*TangVec2(:,p,q)
  END DO; END DO

CASE(1) !Periodic already filled!
  CALL Abort(__STAMP__, &
      "GetBoundaryState called for periodic side!")
CASE DEFAULT ! unknown BCType
  CALL abort(__STAMP__,&
       'no BC defined in navierstokes/getboundaryflux.f90!')
END SELECT ! BCType

END SUBROUTINE GetBoundaryState

!==================================================================================================================================
!> Computes the boundary fluxes for a given Cartesian mesh face (defined by SideID).
!> Calls GetBoundaryState an directly uses the returned vales for all Riemann-type BCs.
!> For other types of BCs, we directly compute the flux on the interface.
!==================================================================================================================================
SUBROUTINE GetBoundaryFlux(SideID,t,Nloc,Flux,UPrim_master,                   &
#if PARABOLIC
                           gradUx_master,gradUy_master,gradUz_master,&
#endif
                           NormVec,TangVec1,TangVec2,Face_xGP)
! MODULES
USE MOD_PreProc
USE MOD_Globals      ,ONLY: Abort
USE MOD_Mesh_Vars    ,ONLY: BoundaryType,BC
USE MOD_EOS          ,ONLY: PrimToCons,ConsToPrim
USE MOD_ExactFunc    ,ONLY: ExactFunc
#if PARABOLIC
USE MOD_Flux         ,ONLY: EvalDiffFlux2D
USE MOD_Riemann      ,ONLY: ViscousFlux
#endif
USE MOD_Riemann      ,ONLY: Riemann
#ifdef EDDYVISCOSITY
USE MOD_EddyVisc_Vars,ONLY: DeltaS_master,SGS_Ind_master
#endif
USE MOD_Testcase     ,ONLY: GetBoundaryFluxTestcase
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT / OUTPUT VARIABLES
INTEGER,INTENT(IN)   :: SideID  
REAL,INTENT(IN)      :: t       !< current time (provided by time integration scheme)
INTEGER,INTENT(IN)   :: Nloc    !< polynomial degree
REAL,INTENT(IN)      :: UPrim_master( PP_nVarPrim,0:Nloc,0:Nloc) !< inner surface solution
#if PARABOLIC
                                                           !> inner surface solution gradients in x/y/z-direction
REAL,INTENT(IN)      :: gradUx_master(PP_nVarPrim,0:Nloc,0:Nloc)
REAL,INTENT(IN)      :: gradUy_master(PP_nVarPrim,0:Nloc,0:Nloc)
REAL,INTENT(IN)      :: gradUz_master(PP_nVarPrim,0:Nloc,0:Nloc)
#endif /*PARABOLIC*/
                                                           !> normal and tangential vectors on surfaces
REAL,INTENT(IN)      :: NormVec (3,0:Nloc,0:Nloc)
REAL,INTENT(IN)      :: TangVec1(3,0:Nloc,0:Nloc)
REAL,INTENT(IN)      :: TangVec2(3,0:Nloc,0:Nloc)
REAL,INTENT(IN)      :: Face_xGP(3,0:Nloc,0:Nloc) !< positions of surface flux points
REAL,INTENT(OUT)     :: Flux(PP_nVar,0:Nloc,0:Nloc)  !< resulting boundary fluxes
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                              :: p,q
INTEGER                              :: BCType,BCState
REAL                                 :: UPrim_boundary(PP_nVarPrim,0:Nloc,0:Nloc)
REAL                                 :: UCons_boundary(PP_nVar    ,0:Nloc,0:Nloc)
REAL                                 :: UCons_master  (PP_nVar    ,0:Nloc,0:Nloc)
#if PARABOLIC
INTEGER                              :: ivar
REAL                                 :: nv(3)
REAL                                 :: BCGradMat(3,3)
REAL,DIMENSION(PP_nVar    ,0:Nloc,0:Nloc):: Fd_Face_loc,    Gd_Face_loc,    Hd_Face_loc
REAL,DIMENSION(PP_nVarPrim,0:Nloc,0:Nloc):: gradUx_Face_loc,gradUy_Face_loc,gradUz_Face_loc
#endif /*PARABOLIC*/
!==================================================================================================================================
BCType  = Boundarytype(BC(SideID),BC_TYPE)
BCState = Boundarytype(BC(SideID),BC_STATE)

IF (BCType.LT.0) THEN ! testcase boundary condition
  CALL GetBoundaryFluxTestcase(SideID,t,Nloc,Flux,UPrim_master,              &
#if PARABOLIC
                               gradUx_master,gradUy_master,gradUz_master,&
#endif
                               NormVec,TangVec1,TangVec2,Face_xGP)
ELSE                       
  CALL GetBoundaryState(SideID,t,Nloc,UPrim_boundary,UPrim_master,&
      NormVec,TangVec1,TangVec2,Face_xGP)

  SELECT CASE(BCType)
  CASE(2,12,22,23,24,25,27) ! Riemann-Type BCs 
    DO q=0,PP_N; DO p=0,PP_N
      CALL PrimToCons(UPrim_master(  :,p,q),UCons_master(  :,p,q)) 
      CALL PrimToCons(UPrim_boundary(:,p,q),UCons_boundary(:,p,q)) 
    END DO; END DO ! p,q=0,PP_N
    CALL Riemann(Nloc,Flux,UCons_master,UCons_boundary,UPrim_master,UPrim_boundary, &
        NormVec,TangVec1,TangVec2,doBC=.TRUE.)
#if PARABOLIC
    CALL ViscousFlux(Nloc,Fd_Face_loc,UPrim_master,UPrim_boundary,&
         gradUx_master,gradUy_master,gradUz_master,&
         gradUx_master,gradUy_master,gradUz_master,&
         NormVec&
#ifdef EDDYVISCOSITY
        ,DeltaS_master(SideID),DeltaS_master(SideID),SGS_Ind_master(1,:,:,SideID),SGS_Ind_master(1,:,:,SideID),Face_xGP&
#endif
    )
    Flux = Flux + Fd_Face_loc
#endif /*PARABOLIC*/

  CASE(3,4,9) ! Walls
    DO q=0,Nloc; DO p=0,Nloc
      ! Now we compute the 1D Euler flux, but use the info that the normal component u=0
      ! we directly tranform the flux back into the Cartesian coords: F=(0,n1*p,n2*p,n3*p,0)^T
      Flux(1  ,p,q) = 0.
      Flux(2:4,p,q) = UPrim_boundary(5,p,q)*NormVec(:,p,q)
      Flux(5  ,p,q) = 0.
    END DO; END DO !p,q
    ! Diffusion
#if PARABOLIC
    SELECT CASE(BCType)
    CASE(3,4)
      ! Evaluate 3D Diffusion Flux with interior state and symmetry gradients
      CALL EvalDiffFlux2D(Nloc,Fd_Face_loc,Gd_Face_loc,Hd_Face_loc,UPrim_boundary,&
          gradUx_master, gradUy_master, gradUz_master &
#ifdef EDDYVISCOSITY
          ,DeltaS_master(SideID),SGS_Ind_master(1,:,:,SideID),Face_xGP            &
#endif
      )
      IF (BCType.EQ.3) THEN
        ! Enforce energy flux is exactly zero at adiabatic wall
        Fd_Face_loc(5,:,:)=0.
        Gd_Face_loc(5,:,:)=0.
        Hd_Face_loc(5,:,:)=0.
      END IF
    CASE(9)
      ! Euler/(full-)slip wall
      ! We prepare the gradients and set the normal derivative to zero (symmetry condition!)
      ! BCGradMat = I - n * n^T = (gradient -normal component of gradient)
      DO q=0,Nloc; DO p=0,Nloc
        nv = NormVec(:,p,q)
        BCGradMat(1,1) = 1. - nv(1)*nv(1)
        BCGradMat(2,2) = 1. - nv(2)*nv(2)
        BCGradMat(3,3) = 1. - nv(3)*nv(3)
        BCGradMat(1,2) = -nv(1)*nv(2)
        BCGradMat(1,3) = -nv(1)*nv(3)
        BCGradMat(3,2) = -nv(3)*nv(2)
        BCGradMat(2,1) = BCGradMat(1,2)
        BCGradMat(3,1) = BCGradMat(1,3)
        BCGradMat(2,3) = BCGradMat(3,2)
        gradUx_Face_loc(:,p,q) = BCGradMat(1,1) * gradUx_master(:,p,q) &
                               + BCGradMat(1,2) * gradUy_master(:,p,q) &
                               + BCGradMat(1,3) * gradUz_master(:,p,q)
        gradUy_Face_loc(:,p,q) = BCGradMat(2,1) * gradUx_master(:,p,q) &
                               + BCGradMat(2,2) * gradUy_master(:,p,q) &
                               + BCGradMat(2,3) * gradUz_master(:,p,q)
        gradUz_Face_loc(:,p,q) = BCGradMat(3,1) * gradUx_master(:,p,q) &
                               + BCGradMat(3,2) * gradUy_master(:,p,q) &
                               + BCGradMat(3,3) * gradUz_master(:,p,q)
      END DO; END DO !p,q

      ! Evaluate 3D Diffusion Flux with interior state (with normalvel=0) and symmetry gradients
      ! Only velocities will be used from state (=inner velocities, except normal vel=0)
      CALL EvalDiffFlux2D(Nloc,Fd_Face_loc,Gd_Face_loc,Hd_Face_loc,UPrim_boundary,&
          gradUx_Face_loc,gradUy_Face_loc,gradUz_Face_loc                         &
#ifdef EDDYVISCOSITY
          ,DeltaS_master(SideID),SGS_Ind_master(1,:,:,SideID),Face_xGP&
#endif
      )
    END SELECT

    ! Sum up Euler and Diffusion Flux
    DO iVar=2,PP_nVar
      Flux(iVar,:,:) = Flux(iVar,:,:)        + &
        NormVec(1,:,:)*Fd_Face_loc(iVar,:,:) + &
        NormVec(2,:,:)*Gd_Face_loc(iVar,:,:) + &
        NormVec(3,:,:)*Hd_Face_loc(iVar,:,:)
    END DO ! ivar
#endif /*PARABOLIC*/

  CASE(1) !Periodic already filled!
  CASE DEFAULT ! unknown BCType
    CALL abort(__STAMP__,&
        'no BC defined in navierstokes/getboundaryflux.f90!')
  END SELECT
END IF ! BCType < 0
END SUBROUTINE GetBoundaryFlux

#if FV_ENABLED
#if FV_RECONSTRUCT
!==================================================================================================================================
!> Computes the gradient at a boundary for FV subcells.
!==================================================================================================================================
SUBROUTINE GetBoundaryFVgradient(SideID,t,gradU,UPrim_master,NormVec,TangVec1,TangVec2,Face_xGP,sdx_Face)
! MODULES
USE MOD_PreProc
USE MOD_Globals       ,ONLY: Abort
USE MOD_Mesh_Vars     ,ONLY: BoundaryType,BC
USE MOD_Testcase      ,ONLY: GetBoundaryFVgradientTestcase
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT / OUTPUT VARIABLES
INTEGER,INTENT(IN):: SideID  
REAL,INTENT(IN)   :: t
REAL,INTENT(IN)   :: UPrim_master(PP_nVarPrim,0:PP_N,0:PP_N)
REAL,INTENT(OUT)  :: gradU       (PP_nVarPrim,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: NormVec (              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: TangVec1(              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: TangVec2(              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: Face_xGP(              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: sdx_Face(                0:PP_N,0:PP_N,3)
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL              :: UPrim_boundary(1:PP_nVarPrim,0:PP_N,0:PP_N)
INTEGER           :: p,q
INTEGER           :: BCType,BCState
!==================================================================================================================================
BCType  = Boundarytype(BC(SideID),BC_TYPE)
BCState = Boundarytype(BC(SideID),BC_STATE)

IF (BCType.LT.0) THEN ! testcase boundary condition
  CALL GetBoundaryFVgradientTestcase(SideID,t,gradU,UPrim_master)
ELSE 
  CALL GetBoundaryState(SideID,t,PP_N,UPrim_boundary,UPrim_master,&
      NormVec,TangVec1,TangVec2,Face_xGP)
  SELECT CASE(BCType)
  CASE(2,3,4,9,12,22,23,24,25,27)
    DO q=0,PP_N; DO p=0,PP_N
      gradU(:,p,q) = (UPrim_master(:,p,q) - UPrim_boundary(:,p,q)) * sdx_Face(p,q,3)
    END DO; END DO ! p,q=0,PP_N
  CASE(1) !Periodic already filled!
  CASE DEFAULT ! unknown BCType
    CALL abort(__STAMP__,&
         'no BC defined in navierstokes/getboundaryflux.f90!')
  END SELECT
END IF ! BCType < 0

END SUBROUTINE GetBoundaryFVgradient
#endif
#endif

#if PARABOLIC
!==================================================================================================================================
!> Computes the boundary fluxes for the lifting procedure for a given Cartesian mesh face (defined by SideID).
!==================================================================================================================================
SUBROUTINE Lifting_GetBoundaryFlux(SideID,t,UPrim_master,Flux,NormVec,TangVec1,TangVec2,Face_xGP,SurfElem)
! MODULES
USE MOD_PreProc
USE MOD_Globals      ,ONLY: Abort
USE MOD_Mesh_Vars    ,ONLY: BoundaryType,BC
USE MOD_Lifting_Vars ,ONLY: doWeakLifting
USE MOD_Testcase     ,ONLY: Lifting_GetBoundaryFluxTestcase
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT / OUTPUT VARIABLES
INTEGER,INTENT(IN):: SideID  
REAL,INTENT(IN)   :: t                                       !< current time (provided by time integration scheme)
REAL,INTENT(IN)   :: UPrim_master(PP_nVarPrim,0:PP_N,0:PP_N) !< primitive solution from the inside
REAL,INTENT(OUT)  :: Flux(        PP_nVarPrim,0:PP_N,0:PP_N) !< lifting boundary flux
REAL,INTENT(IN)   :: NormVec (              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: TangVec1(              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: TangVec2(              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: Face_xGP(              3,0:PP_N,0:PP_N)
REAL,INTENT(IN)   :: SurfElem(                0:PP_N,0:PP_N)
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER           :: p,q
INTEGER           :: BCType,BCState
REAL              :: UPrim_boundary(PP_nVarPrim,0:PP_N,0:PP_N)
!==================================================================================================================================
BCType  = Boundarytype(BC(SideID),BC_TYPE)
BCState = Boundarytype(BC(SideID),BC_STATE)

IF (BCType.LT.0) THEN ! testcase boundary conditions
  CALL Lifting_GetBoundaryFluxTestcase(SideID,t,UPrim_master,Flux)
ELSE
  CALL GetBoundaryState(SideID,t,PP_N,UPrim_boundary,UPrim_master,&
                        NormVec,TangVec1,TangVec2,Face_xGP)
  SELECT CASE(BCType)
  CASE(2,12,22,23,24,25,27) ! Riemann solver based BCs
      Flux=0.5*(UPrim_master+UPrim_boundary)
  CASE(3,4) ! No-slip wall BCs
    DO q=0,PP_N; DO p=0,PP_N
      Flux(1  ,p,q) = UPrim_Boundary(1,p,q) 
      Flux(2:4,p,q) = 0.
      Flux(5  ,p,q) = UPrim_Boundary(5,p,q)
      Flux(6  ,p,q) = UPrim_Boundary(6,p,q)
    END DO; END DO !p,q
  CASE(9)
    ! Euler/(full-)slip wall
    ! symmetry BC, v=0 strategy a la HALO (is very perfect)
    ! U_boundary is already in normal system
    DO q=0,PP_N; DO p=0,PP_N
      ! Compute Flux
      Flux(1            ,p,q) = UPrim_boundary(1,p,q)
      Flux(2:PP_nVarPrim,p,q) = 0.5*(UPrim_boundary(2:PP_nVarPrim,p,q)+UPrim_master(2:PP_nVarPrim,p,q))
    END DO; END DO !p,q
  CASE(1) !Periodic already filled!
  CASE DEFAULT ! unknown BCType
    CALL abort(__STAMP__,&
         'no BC defined in navierstokes/getboundaryflux.f90!')
  END SELECT

  !in case lifting is done in strong form
  IF(.NOT.doWeakLifting) Flux=Flux-UPrim_master

  DO q=0,PP_N; DO p=0,PP_N
    Flux(:,p,q)=Flux(:,p,q)*SurfElem(p,q)
  END DO; END DO
END IF

END SUBROUTINE Lifting_GetBoundaryFlux
#endif /*PARABOLIC*/



!==================================================================================================================================
!> Read in a HDF5 file containing the state for a boundary. Used in BC Type 12.
!==================================================================================================================================
SUBROUTINE ReadBCFlow(FileName)
! MODULES
USE MOD_PreProc
USE MOD_Globals
USE MOD_Equation_Vars     ,ONLY:BCData,BCDataPrim
USE MOD_Mesh_Vars         ,ONLY:offsetElem,nElems,nBCSides,S2V2,SideToElem
USE MOD_HDF5_Input        ,ONLY:OpenDataFile,GetDataProps,CloseDataFile,ReadAttribute,ReadArray
USE MOD_Interpolation     ,ONLY:GetVandermonde
USE MOD_ProlongToFace     ,ONLY:EvalElemFace
USE MOD_Interpolation_Vars,ONLY:NodeType
#if (PP_NodeType==1)
USE MOD_Interpolation_Vars,ONLY:L_minus,L_plus
#endif
USE MOD_ChangeBasis       ,ONLY:ChangeBasis3D
USE MOD_EOS               ,ONLY:ConsToPrim
 IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT / OUTPUT VARIABLES
CHARACTER(LEN=255),INTENT(IN) :: FileName       !< name of file BC data is read from
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL,POINTER                  :: U_N(:,:,:,:,:)=>NULL()
REAL,ALLOCATABLE,TARGET       :: U_local(:,:,:,:,:)
REAL,ALLOCATABLE              :: Vdm_NHDF5_N(:,:)
REAL                          :: Uface(PP_nVar,0:PP_N,0:PP_N)
INTEGER                       :: nVar_HDF5,N_HDF5,nElems_HDF5
INTEGER                       :: p,q,SideID,ElemID,locSide
CHARACTER(LEN=255)            :: NodeType_HDF5
LOGICAL                       :: InterpolateSolution
!==================================================================================================================================
SWRITE(UNIT_StdOut,'(A,A)')'  Read BC state from file "',FileName
CALL OpenDataFile(FileName,create=.FALSE.,single=.FALSE.,readOnly=.TRUE.)
CALL GetDataProps(nVar_HDF5,N_HDF5,nELems_HDF5,NodeType_HDF5)

ALLOCATE(U_local(PP_nVar,0:N_HDF5,0:N_HDF5,0:N_HDF5,nElems))
CALL ReadArray('DG_Solution',5,(/PP_nVar,N_HDF5+1,N_HDF5+1,N_HDF5+1,nElems/),OffsetElem,5,RealArray=U_local)
CALL CloseDataFile()

! Read in state
InterpolateSolution=((N_HDF5.NE.PP_N) .OR. (TRIM(NodeType_HDF5).NE.TRIM(NodeType)))
IF(.NOT. InterpolateSolution)THEN
  ! No interpolation needed, read solution directly from file
  U_N=>U_local
ELSE
  ! We need to interpolate the solution to the new computational grid
  ALLOCATE(U_N(PP_nVar,0:PP_N,0:PP_N,0:PP_N,nElems))
  ALLOCATE(Vdm_NHDF5_N(0:PP_N,0:N_HDF5))
  CALL GetVandermonde(N_HDF5,NodeType_HDF5,PP_N,NodeType,Vdm_NHDF5_N,modal=.TRUE.)

  SWRITE(UNIT_stdOut,*)'Interpolate base flow from restart grid with N=',N_HDF5,' to computational grid with N=',PP_N
  CALL ChangeBasis3D(PP_nVar,nElems,N_HDF5,PP_N,Vdm_NHDF5_N,U_local,U_N,.FALSE.)
  DEALLOCATE(Vdm_NHDF5_N)
END IF

! Prolong boundary state
DO SideID=1,nBCSides
  ElemID  = SideToElem(S2E_ELEM_ID    ,SideID)
  locSide = SideToElem(S2E_LOC_SIDE_ID,SideID)

#if (PP_NodeType==1)
  CALL EvalElemFace(PP_nVar,PP_N,U_N(:,:,:,:,ElemID),Uface,L_Minus,L_Plus,locSide)
#else
  CALL EvalElemFace(PP_nVar,PP_N,U_N(:,:,:,:,ElemID),Uface,locSide)
#endif
  DO q=0,PP_N; DO p=0,PP_N
    BCData(:,p,q,SideID)=Uface(:,S2V2(1,p,q,0,locSide),S2V2(2,p,q,0,locSide))
    CALL ConsToPrim(BCDataPrim(:,p,q,SideID),BCData(:,p,q,SideID))
  END DO; END DO
END DO

IF(InterpolateSolution) DEALLOCATE(U_N)
DEALLOCATE(U_local)

SWRITE(UNIT_stdOut,'(A)')'  done initializing BC state!'
END SUBROUTINE ReadBCFlow



!==================================================================================================================================
!> Finalize arrays used for boundary conditions.
!==================================================================================================================================
SUBROUTINE FinalizeBC()
! MODULES
USE MOD_Equation_Vars,ONLY: BCData,BCDataPrim,nBCByType,BCSideID
IMPLICIT NONE
!----------------------------------------------------------------------------------------------------------------------------------
! INPUT / OUTPUT VARIABLES
!----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
!==================================================================================================================================
SDEALLOCATE(BCData)
SDEALLOCATE(BCDataPrim)
SDEALLOCATE(nBCByType)
SDEALLOCATE(BCSideID)
END SUBROUTINE FinalizeBC

END MODULE MOD_GetBoundaryFlux
