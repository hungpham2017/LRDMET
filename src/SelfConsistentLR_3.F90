module SelfConsistentLR3
    use const
    use timing
    use errors
    use LinearResponse
    use globals
    use utils, only: get_free_unit,append_ext_real,append_ext
    use lattices, only: zero_localpot_comp
    use SC_Data                  
    use SelfConsistentUtils
    use matrixops, only: mat_inv
    use writedata
    implicit none

    contains

    subroutine SC_Spectrum_Static()
        implicit none
        real(dp) :: GFChemPot,NI_ChemPot
        integer :: i,j,nFreq,iter
        complex(dp), allocatable :: h_lat_fit(:,:)
        complex(dp), allocatable :: LatVecs(:,:),Lat_CorrFn(:,:,:),CorrFn_HL(:,:,:)
        complex(dp), allocatable :: Prev_CorrFn_HL(:,:,:),Prev_Lat_CorrFn(:,:,:)
        complex(dp), allocatable :: SE_Update(:,:,:),UpdatePotential(:,:),TotalPotential(:,:)
        complex(dp), allocatable :: CorrFn_HL_Inv(:,:,:),ctemp(:,:)
        complex(dp) :: Ei_ij_val,Ei_ji_val,Ej_ij_val,Ej_ji_val,ZDOTC,MeanImpDiag
        real(dp) :: MaxOffLocalEl
        real(dp), allocatable :: AllDiffs(:,:),LatVals(:) 
        integer, allocatable :: LatFreqs(:)
        logical, parameter :: tRetarded = .true. 
        logical, parameter :: tIncFullSigmaGF0 = .false.
        logical, parameter :: tBandStructureConv = .true.
        logical, parameter :: tUncontract_DynBath = .true.
        character(len=*), parameter :: t_r='SC_Spectrum_Static'

        call set_timer(SelfCon_LR)

        write(6,"(A)") "Entering quasiparticle self-consistent DMET..."

        !TODO:  
        !       o Only ever store 1-electron hamiltonians over k-blocks
        !       o DIIS for extrapolating potential
        !       o Uncontracted bath space
        !       o Ground state energy from Migdal
        !       o Optimize chemical potential
        !       o Constraints on potential (real diags, ph sym?)
        !       o Choice of potential in bath and bath/imp coupling?
        !           - Frequency dependent hermitian in bath?
        !           - Non-hermitian, frequency-dependent in bath
        !           - U in coupling terms?
        !           - Non-hermitian in contracted system?

        !Speculative:
        !       o How to include non-hermitian parts of self-energy?
        !       o Non-hermitian and/or frequency dependent potential in dynamic
        !               bath space
        !       o Contracted GS space: Thermal. Take GS density for bath from
        !           *correlated* wavefunction? Also solves Van Voohis problem.

        tFitPoints_Legendre = .false.
        tFitRealFreq = .true.
        tFitMatAxis = .false.
        tLR_ReoptGS = .true.
        tRemakeStaticBath = .true.
        tFullReoptGS = .false.
        tCompressedMats = .false.
        tMinRes_NonDir = .false.
        tPrecond_MinRes = .false.
        tReuse_LS = .false.

        !Let h be complex to allow for easier integration with previous code
        allocate(h_lat_fit(nSites,nSites))
        allocate(TotalPotential(nSites,nSites))
        call InitLatticePotential(h_lat_fit,TotalPotential,GFChemPot)

        !NI_ChemPot is fixed for the calculation as a shift for the grid
        NI_ChemPot = GFChemPot

        allocate(LatVals(nSites))
        allocate(LatVecs(nSites,nSites))
        LatVecs(:,:) = h_lat_fit(:,:)
        LatVals(:) = zero
        call DiagOneEOp(LatVecs,LatVals,nImp,nSites,tDiag_kspace,.false.)
        !Note that the chemical potential is *not* included in the definition of h 

        !call writevector(LatVals,'LatVals')

        !LatFreqs tells you which frequency point corresponds to which
        !eigenvalue of the lattice
        allocate(LatFreqs(nSites))
        !nFreq should not change in this version of SetReFreqPoints
        call SetReFreqPoints(LatVals,NI_ChemPot,nFreq,LatFreqs)

        allocate(Lat_CorrFn(nImp,nImp,nFreq))
        allocate(CorrFn_HL(nImp,nImp,nFreq))
        allocate(CorrFn_HL_Inv(nImp,nImp,nFreq))

        allocate(Prev_CorrFn_HL(nImp,nImp,nFreq))
        allocate(Prev_Lat_CorrFn(nImp,nImp,nFreq))

        allocate(SE_Update(nImp,nImp,nFreq))
        Lat_CorrFn(:,:,:) = zzero ; CorrFn_HL(:,:,:) = zzero
        Prev_CorrFn_HL(:,:,:) = zzero ; Prev_Lat_CorrFn(:,:,:) = zzero
        SE_Update(:,:,:) = zzero

        allocate(UpdatePotential(nSites,nSites))

        !1: Change in correlation potential
        !2: Change in impurity greens function
        !3: Change in lattice greens function
        !4: Largest off-local part of correlation potential
        !5: Mean diagonal of local part of correlation potential
        allocate(AllDiffs(5,0:iMaxIter_MacroFit+1))
        AllDiffs(:,:) = zero
           
        iter = 0
        do while(.not.tSkip_Lattice_Fit)
            iter = iter + 1

            if(iter.ne.1) call SetReFreqPoints(LatVals,NI_ChemPot,nFreq,LatFreqs)
            !call writevector(LatFreqs,'LatFreqs')
        
            if(.not.tIncFullSigmaGF0.or.(iter.eq.1)) then
                call CalcLatticeSpectrum(1,nFreq,Lat_CorrFn,GFChemPot,tMatbrAxis=.false.,    &
                    Freqpoints=FreqPoints,ham=h_lat_fit,tRetarded=tRetarded)
            endif
            
            call writedynamicfunction(nFreq,Lat_CorrFn,'G_Lat',tag=iter,tCheckCausal=.false.,   &
                tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)

            if(tUncontract_DynBath) then
                call ImpGF_OneEDynamicBath(CorrFn_HL,GFChemPot,nFreq,tFitMatAxis,h_lat_fit,FreqPoints,tRetarded=tRetarded)
            else
                call SchmidtGF_FromLat(CorrFn_HL,GFChemPot,nFreq,tFitMatAxis,h_lat_fit,FreqPoints,tRetarded=tRetarded)
            endif

            call writedynamicfunction(nFreq,CorrFn_HL,'G_Imp',tag=iter,tCheckCausal=.false.,  &
                tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)
            
            !Now use Dysons equation: Sigma = G_lat^-1 - G_HL^-1
            SE_Update(:,:,:) = Lat_CorrFn(:,:,:)
            call InvertLocalNonHermFunc(nFreq,SE_Update)
            CorrFn_HL_Inv(:,:,:) = CorrFn_HL(:,:,:)
            call InvertLocalNonHermFunc(nFreq,CorrFn_HL_Inv)
            SE_Update(:,:,:) = SE_Update(:,:,:) - CorrFn_HL_Inv(:,:,:)

            if(.false.) then
                !Test - write out the lattice greens function with the self energy
                call writedynamicfunction(nFreq,SE_Update,'SE_Imp',tag=iter,tCheckCausal=.false., &
                    tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)

                call CalcLatticeSpectrum(1,nFreq,CorrFn_HL_Inv,GFChemPot,tMatbrAxis=.false., &
                    FreqPoints=FreqPoints,ham=h_lat_fit,SE=SE_Update,tRetarded=tRetarded)

                call writedynamicfunction(nFreq,CorrFn_HL_Inv,'G_Lat_wSE',tag=iter,tCheckCausal=.false., &
                    tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)
            endif

            if(tBandStructureConv) then
                !Calculate the bandstructure by including the
                !local self-energy, along with the lattice
                !bandstructure
                call CalcBandstructure(nFreq,GFChemPot,'Bands',tag=iter,h_lat=h_lat_fit, &
                    SelfEnergy=SE_Update,FreqPoints=FreqPoints)
            endif

            !Find hermitian potential which best approximates the real part of
            !the self-energy
            SE_Update(:,:,:) = SE_Update(:,:,:) * Damping_SE    !Damp the self-energy update
            call QPSC_UpdatePotential(nFreq,LatFreqs,GFChemPot,h_lat_fit,LatVals,LatVecs,SE_Update,UpdatePotential)

            if(tIncFullSigmaGF0) then
                !Before updating h_lat_fit, find the lattice greens function with
                !the full self-energy - i.e. what we would want if we could fully
                !update h
                call CalcLatticeSpectrum(1,nFreq,Lat_CorrFn,GFChemPot,tMatbrAxis=.false., &
                    FreqPoints=FreqPoints,ham=h_lat_fit,SE=SE_Update,tRetarded=tRetarded)
            endif

            !Add new potential to lattice hamiltonian
            h_lat_fit(:,:) = h_lat_fit(:,:) + UpdatePotential(:,:)
            TotalPotential(:,:) = TotalPotential(:,:) + UpdatePotential(:,:)
            
            !Is Update potential local?!
            allocate(ctemp(nSites,nSites))
            ctemp(:,:) = TotalPotential(:,:)
            call zero_localpot_comp(ctemp)
            MaxOffLocalEl = zero
            do i = 1,nSites
                do j = 1,nSites
                    if(abs(ctemp(j,i)).gt.MaxOffLocalEl) MaxOffLocalEl = abs(ctemp(j,i))
                enddo
            enddo
            AllDiffs(4,iter) = MaxOffLocalEl 
            MeanImpDiag = TotalPotential(1,1)
            do i = 2,nImp
                MeanImpDiag = MeanImpDiag + TotalPotential(i,i)
            enddo
            AllDiffs(5,iter) = abs(MeanImpDiag / nImp )
            !write(6,*) "Largest off-local part of the correlation potential: ",MaxOffLocalEl
            deallocate(ctemp)

            !Rediagonalize
            LatVecs(:,:) = h_lat_fit(:,:)
            LatVals(:) = zero
            call DiagOneEOp(LatVecs,LatVals,nImp,nSites,tDiag_kspace,.false.)

            !What is change in update potential and G (Use SE_Update to store
            !differences)
            AllDiffs(1,iter) = sum(real(UpdatePotential(:,:)*dconjg(UpdatePotential(:,:)))) 
            AllDiffs(1,iter) = AllDiffs(1,iter) / PotentialUpdateDamping
            SE_Update(:,:,:) = Prev_CorrFn_HL(:,:,:) - CorrFn_HL(:,:,:)
            SE_Update(:,:,:) = SE_Update(:,:,:) * dconjg(SE_Update(:,:,:))
            AllDiffs(2,iter) = sum(real(SE_Update(:,:,:),dp))
            SE_Update(:,:,:) = Prev_Lat_CorrFn(:,:,:) - Lat_CorrFn(:,:,:)
            SE_Update(:,:,:) = SE_Update(:,:,:) * dconjg(SE_Update(:,:,:))
            AllDiffs(3,iter) = sum(real(SE_Update(:,:,:),dp))

            !Update previous correlation functions
            Prev_CorrFn_HL(:,:,:) = CorrFn_HL(:,:,:)
            Prev_Lat_CorrFn(:,:,:) = Lat_CorrFn(:,:,:)

            write(6,"(A)") ""
            write(6,"(A,I7,A)") "***   COMPLETED MACROITERATION ",iter," ***"
            write(6,"(A)") "     Iter.  PotentialChange   Delta_GF_Imp(iw)    Delta_GF_Lat(iw)   MaxOff-local_v     MeanDiag_v"
            do i = 0,iter
                write(6,"(I7,5G20.13)") i,AllDiffs(1,i),AllDiffs(2,i),AllDiffs(3,i),AllDiffs(4,i),AllDiffs(5,i)
            enddo
            write(6,"(A)") ""
            call flush(6)

            if(iter.ge.iMaxIter_MacroFit) then
                write(6,"(A,I9)") "Exiting. Max iters hit of: ",iMaxIter_MacroFit
                exit
            endif

            if(AllDiffs(1,iter).lt.dSelfConsConv) then
                write(6,"(A)") "Success! Static potential converged"
                write(6,"(A,G20.13)") "Correlation potential changing by less than: ",dSelfConsConv
                exit
            endif
            !call WriteLatHamil(h_lat_fit,GFChemPot,'LatticeHamiltonian',tag=iter)

        enddo

        call writedynamicfunction(nFreq,CorrFn_HL,'G_Imp_Final',tCheckCausal=.false., &
            tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)
        
        call writedynamicfunction(nFreq,Lat_CorrFn,'G_Lat_Final',tCheckCausal=.false., &
            tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)
            
        !Calculate the bandstructure by including the imaginary only
        !part of the local self-energy, along with the lattice
        !bandstructure

        !Get Final Self-energy
        !Now use Dysons equation: Sigma = G_lat^-1 - G_HL^-1
        SE_Update(:,:,:) = Lat_CorrFn(:,:,:)
        call InvertLocalNonHermFunc(nFreq,SE_Update)
        CorrFn_HL_Inv(:,:,:) = CorrFn_HL(:,:,:)
        call InvertLocalNonHermFunc(nFreq,CorrFn_HL_Inv)
        SE_Update(:,:,:) = (SE_Update(:,:,:) - CorrFn_HL_Inv(:,:,:))
        !First, remove the real part of the self-energy, which is already
        !(approximatly) in the lattice
        do i = 1,nFreq
            SE_Update(:,:,i) = cmplx(zero,aimag(SE_Update(:,:,i)),dp)
        enddo
        call CalcBandstructure(nFreq,GFChemPot,'Bands_Final',h_lat=h_lat_fit, &
            SelfEnergy=SE_Update,FreqPoints=FreqPoints)
            
        if(nSites.lt.15) then
            call writematrix(TotalPotential,'Final potential in the AO basis',.true.)
        endif

        !Calculate final self-energy

        !Calculate HL with self-energy as environment potential?

        !Write out G + self-energy for final bit (to match greens functions?)

        !Calculate the bandstructure

        call WriteImpLatCouplings(TotalPotential)
        
        if(.not.tRetarded) then
            !Calculate the retarded greens function for the spectrum
            call CalcLatticeSpectrum(1,nFreq,Lat_CorrFn,GFChemPot,tMatbrAxis=.false.,    &
                Freqpoints=FreqPoints,ham=h_lat_fit,tRetarded=.true.)
            call writedynamicfunction(nFreq,Lat_CorrFn,'G_Lat_Ret_Final',tCheckCausal=.true.,   &
                tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)
            call SchmidtGF_FromLat(CorrFn_HL,GFChemPot,nFreq,tFitMatAxis,h_lat_fit,FreqPoints,tRetarded=.true.)
            call writedynamicfunction(nFreq,CorrFn_HL,'G_Imp_Ret_Final',tCheckCausal=.true.,  &
                tCheckOffDiagHerm=.false.,tWarn=.true.,tMatbrAxis=.false.,FreqPoints=FreqPoints)
        endif

        call WriteLatHamil(h_lat_fit,GFChemPot,'LatticeHamiltonian_Final')

        call writevector(LatVals,'Final lattice eigenvalues')

        deallocate(h_lat_fit,LatVals,LatVecs,Lat_CorrFn,CorrFn_HL,Prev_CorrFn_HL,Prev_Lat_CorrFn)
        deallocate(UpdatePotential,TotalPotential,AllDiffs,SE_Update,LatFreqs,CorrFn_HL_Inv)

        call halt_timer(SelfCon_LR)

    end subroutine SC_Spectrum_Static

    subroutine WriteImpLatCouplings(h)
        implicit none
        complex(dp), intent(in) :: h(nSites,nSites)
        integer :: iunit,step,ind,i

        !TODO: Test for translational invariance
        write(6,"(A)") "Writing impurity lattice couplings..."
        iunit = get_free_unit()
        open(unit=iunit,file='ImpLatCouplings',status='unknown')

        do step = 0,nSites-1
            write(iunit,"(I8)",advance='no') step
            do i = 1,nImp-1
                ind = mod(i+step,nSites)
                if(ind.eq.0) ind = nSites
                write(iunit,"(2G30.13)",advance='no') h(i,ind)
            enddo
            ind = mod(nImp+step,nSites)
            if(ind.eq.0) ind = nSites
            write(iunit,"(2G30.13)") h(nImp,ind)
        enddo

        close(iunit)

    end subroutine WriteImpLatCouplings

    subroutine InitLatticePotential(h_lat,TotalPotential,GFChemPot)
        implicit none
        complex(dp), intent(out) :: h_lat(nSites,nSites),TotalPotential(nSites,nSites)
        real(dp), intent(out) :: GFChemPot
        !
        integer :: i,j
        real(dp) :: mu
        logical :: exists
    
        h_lat(:,:) = zzero
        TotalPotential(:,:) = zzero

        if(tReadCouplings) then

            !Read in change from h0
            write(6,"(A)") "Reading lattice correlation potential from file..."
            call ReadLatHam(h_lat,mu)
            do i = 1,nSites
                if(tHalfFill) then
                    !Do proper fock potenital
                    h_lat(i,i) = U/2.0_dp
                endif
                do j = 1,nSites
                    TotalPotential(j,i) = h_lat(j,i) - h0(j,i)
                enddo
            enddo
        else

            if(tSC_StartwGSCorrPot) then
                write(6,"(A)") "Starting from correlation potential from ground-state calculation..."
            else
                write(6,"(A)") "Starting from bare lattice hamiltonian, with Fock potential..."
                if(tStretchNILatticeHam) then
                    write(6,"(A,F10.4)") "Introducing lattice hamiltonian with stretch coefficient: ",dStretchNILatticeHam
                endif
            endif

            !Do we want to start from a prior GS DMET calculation, or 
            do i = 1,nSites
                do j = 1,nSites
                    if(tSC_StartwGSCorrPot) then
                        h_lat(j,i) = cmplx(h0v(j,i),zero,dp)
                        TotalPotential(j,i) = cmplx(h0v(j,i)-h0(j,i),zero,dp)
                    else
                        h_lat(j,i) = cmplx(h0(j,i),zero,dp)
                        if(i.eq.j.and.tHalfFill) then 
                            !TODO: Do proper fock potential
                            h_lat(i,i) = U/2.0_dp
                        else
                            if(tStretchNILatticeHam) h_lat(j,i) = h_lat(j,i)*dStretchNILatticeHam
                        endif
                    endif 
                enddo
            enddo
    
        endif
            
        if(tReadChempot.and.tReadCouplings) then
            write(6,"(A)") "Taking initial chemical potential for system from file..."
            GFChemPot = mu
        else
            call SetChemPot(GFChemPot)
        endif

        write(6,"(A,G20.15)") "Chemical potential set to: ",GFChemPot

    end subroutine InitLatticePotential

    subroutine WriteLatHamil(h_lat,mu,FileRoot,tag)
        implicit none
        complex(dp), intent(in) :: h_lat(nSites,nSites)
        real(dp), intent(in) :: mu
        character(len=*), intent(in), optional :: FileRoot
        integer, intent(in), optional :: tag
        !
        integer :: i,j,iunit
        character(64) :: FileRoot_
        character(64) :: filename
        character(len=*), parameter :: t_r='WriteLatHamil'

        write(6,"(A)") "Writing lattice hamiltonian..."
        iunit = get_free_unit()

        if(present(FileRoot)) then
            FileRoot_ = FileRoot
        else
            FileRoot_ = 'LatticeHamiltonian'
        endif

        if(present(tag)) then
            call append_ext(FileRoot_,tag,filename)
        else
            filename = FileRoot_ 
        endif
        open(unit=iunit,file=filename,status='unknown')

        write(iunit,"(3I8)") nSites,nImp,LatticeDim
        write(iunit,"(F25.10)") mu
        do i = 1,nSites
            do j = 1,i
                write(iunit,*) h_lat(j,i)
            enddo
        enddo
        close(iunit)

    end subroutine WriteLatHamil

    subroutine ReadLatHam(LatHam,mu)
        implicit none
        complex(dp), intent(out) :: LatHam(nSites,nSites)
        real(dp), intent(out) :: mu
        !
        logical :: lexists
        integer :: iunit,nImp_,nSites_,LatticeDim_,i,j
        character(len=*), parameter :: t_r='ReadLatHam'

        LatHam(:,:) = zzero
        write(6,"(A)") "Reading lattice hamiltonian from file..."
        iunit=get_free_unit()
        inquire(file='LatticeHamiltonian',exist=lexists)
        if(.not.lexists) then
            call stop_all(t_r,'LatticeHamiltonian file does not exist to read in...')
        endif
        open(unit=iunit,file='LatticeHamiltonian',status='old')
        read(iunit,*) nSites_,nImp_,LatticeDim_
        if(nSites_.ne.nSites) then
            call stop_all(t_r,'Number of sites not consistent')
        endif
        if(nImp_.ne.nImp) then
            call stop_all(t_r,'Number of impurities not consistent')
        endif
        if(LatticeDim_.ne.LatticeDim) then
            call stop_all(t_r,'Dimension of lattice not consistent')
        endif
        read(iunit,*) mu
        do i = 1,nSites
            do j = 1,i
                read(iunit,*) LatHam(j,i)
                LatHam(i,j) = conjg(LatHam(j,i))
            enddo
        enddo
        close(iunit)

    end subroutine ReadLatHam
            
    subroutine QPSC_UpdatePotential(nFreq,LatFreqs,GFChemPot,ham,LatVals,LatVecs,SE_Update,UpdatePotential)
        implicit none
        complex(dp), intent(out) :: UpdatePotential(nSites,nSites)
        integer, intent(in) :: LatFreqs(nSites),nFreq
        real(dp), intent(in) :: GFChemPot,LatVals(nSites)
        complex(dp), intent(in) :: LatVecs(nSites,nSites),SE_Update(nImp,nImp,nFreq)
        complex(dp), intent(in) :: ham(nSites,nSites)
        !local
        real(dp), allocatable :: EVals(:)
        complex(dp), allocatable :: EVecs(:,:,:),SE_K(:,:),SE_K_k(:,:),Pot_k(:,:,:)
        complex(dp), allocatable :: KBlocks(:,:,:),ctemp_vec(:)
        complex(dp), allocatable :: ctemp(:,:),HalfContract_i(:)
        complex(dp), allocatable :: HalfContract_j(:),LatSelfEnergy_i(:,:)
        complex(dp), allocatable :: LatSelfEnergy_j(:,:),ctemp2(:,:)
        complex(dp) :: Ei_ij_val,Ei_ji_val,zdotc
        integer :: i,j,k,l,m,ind_1,ind_2,nval,nval_k,pos,pos_k
        character(len=*), parameter :: t_r='QPSC_UpdatePotential'
    
        UpdatePotential(:,:) = zzero

        if(.false.) then
            allocate(LatSelfEnergy_j(nSites,nSites))
            allocate(HalfContract_i(nSites))
            allocate(HalfContract_j(nSites))
            allocate(LatSelfEnergy_i(nSites,nSites))
            allocate(ctemp(nSites,nSites))
            !Use Quasi-particle self-consistency to find best static, hermitian
            !potential approximation to the value: IS THIS LOCAL?
            do i = 1,nSites
                
!                write(6,"(A,I7)") "Site: ",i
!                call flush(6)
                !Find the energy according to this orbital
                !This is the frequency of the FreqPoints(LatFreqs(i))
                if(abs(FreqPoints(LatFreqs(i))-(LatVals(i)-GFChemPot)).gt.1.0e-7_dp) then
                    write(6,*) i,LatFreqs(i),FreqPoints(LatFreqs(i)),LatVals(i)
                    call stop_all(t_r,'Error in assigning frequencies')
                endif

                !Stripe the self energy from the LatFreqs(i) local self energy
                !across the lattice
                LatSelfEnergy_i(:,:) = zzero
                call add_localpot_comp_inplace(LatSelfEnergy_i,SE_Update(:,:,LatFreqs(i)),.true.)

                !Rotate the ij and ji elements of LatSelfEnergy to the MO basis
!                call ZGEMV('C',nSites,nSites,zone,LatSelfEnergy_i,nSites,LatVecs(:,i),1,zzero,HalfContract_i,1)
                call ZGEMM('C','N',nSites,nSites,nSites,zone,LatVecs,nSites,LatSelfEnergy_i,nSites,zzero,ctemp,nSites)
                call ZGEMM('N','N',nSites,nSites,nSites,zone,ctemp,nSites,LatVecs,nSites,zzero,LatSelfEnergy_i,nSites)

                do j = 1,nSites
                    !Find the energy according to this orbital
                    !This is the frequency of the FreqPoints(LatFreqs(i))
                    if(abs(FreqPoints(LatFreqs(j))-(LatVals(j)-GFChemPot)).gt.1.0e-7_dp) then
                        call stop_all(t_r,'Error in assigning frequencies')
                    endif
                
                    !call ZGEMV('C',nSites,nSites,zone,LatSelfEnergy_i,nSites,LatVecs(:,j),1,zzero,HalfContract_j,1)
                    !Ei_ij_val = zdotc(nSites,HalfContract_i,1,LatVecs(:,j),1)
                    !Ei_ji_val = zdotc(nSites,HalfContract_j,1,LatVecs(:,i),1)

                    !Stripe the self energy from the LatFreqs(i) local self energy
                    !across the lattice
                    LatSelfEnergy_j(:,:) = zzero
                    call add_localpot_comp_inplace(LatSelfEnergy_j,SE_Update(:,:,LatFreqs(j)),.true.)

                    !Rotate LatSelfEnergy to the MO basis
                    call ZGEMM('C','N',nSites,nSites,nSites,zone,LatVecs,nSites,LatSelfEnergy_j,nSites,zzero,ctemp,nSites)
                    call ZGEMM('N','N',nSites,nSites,nSites,zone,ctemp,nSites,LatVecs,nSites,zzero,LatSelfEnergy_j,nSites)
!                    call ZGEMV('C',nSites,nSites,zone,LatSelfEnergy_j,nSites,LatVecs(:,i),1,zzero,HalfContract_i,1)
!                    call ZGEMV('C',nSites,nSites,zone,LatSelfEnergy_j,nSites,LatVecs(:,j),1,zzero,HalfContract_j,1)
!                    Ej_ij_val = zdotc(nSites,HalfContract_i,1,LatVecs(:,j),1)
!                    Ej_ji_val = zdotc(nSites,HalfContract_j,1,LatVecs(:,i),1)
                    
                    !Add to the update potential
                    UpdatePotential(i,j) = 0.25_dp * (LatSelfEnergy_i(i,j) + conjg(LatSelfEnergy_i(j,i))    &
                        + LatSelfEnergy_j(i,j) + conjg(LatSelfEnergy_j(j,i)) )
!                    UpdatePotential(i,j) = 0.25_dp * (Ei_ij_val + conjg(Ei_ji_val)    &
!                        + Ej_ij_val + conjg(Ej_ji_val) )
                enddo
            enddo

            !Rotate the new static potential (Update Potential) to the AO basis
            call ZGEMM('N','N',nSites,nSites,nSites,zone,LatVecs,nSites,UpdatePotential,nSites,zzero,ctemp,nSites)
            call ZGEMM('N','C',nSites,nSites,nSites,zone,ctemp,nSites,LatVecs,nSites,zzero,UpdatePotential,nSites)
            deallocate(LatSelfEnergy_j)

            do i = 1,nSites
                do j = 1,nSites
                    if(abs(UpdatePotential(j,i)-conjg(UpdatePotential(i,j))).gt.1.0e-8_dp) then
                        call stop_all(t_r,'Update potential not hermitian')
                    endif
                enddo
            enddo
            deallocate(ctemp,LatSelfEnergy_i)
            deallocate(HalfContract_i,HalfContract_j)

        else
            !Do it cheaper!
            !if(.true.) then
            if(.not.tDiag_kspace) then
                allocate(HalfContract_i(nSites))
                allocate(HalfContract_j(nSites))
                allocate(LatSelfEnergy_i(nSites,nSites))
                allocate(ctemp(nSites,nSites))

                do i = 1,nSites

                    if(abs(FreqPoints(LatFreqs(i))-(LatVals(i)-GFChemPot)).gt.1.0e-7_dp) then
                        write(6,*) i,LatFreqs(i),FreqPoints(LatFreqs(i)),LatVals(i)
                        call stop_all(t_r,'Error in assigning frequencies')
                    endif

                    !Stripe the self energy from the LatFreqs(i) local self energy
                    !across the lattice
                    LatSelfEnergy_i(:,:) = zzero
                    call add_localpot_comp_inplace(LatSelfEnergy_i,SE_Update(:,:,LatFreqs(i)),.true.)

                    !TODO: Do this in k-space
                    call ZGEMV('C',nSites,nSites,zone,LatSelfEnergy_i,nSites,LatVecs(:,i),1,zzero,HalfContract_i,1)
                    call ZGEMV('N',nSites,nSites,zone,LatSelfEnergy_i,nSites,LatVecs(:,i),1,zzero,HalfContract_j,1)

                    do j = 1,nSites
                        !TODO: skip if not in same kpoint 

                        Ei_ji_val = zzero
                        Ei_ij_val = zzero
                        do k = 1,nSites
                            Ei_ji_val = Ei_ji_val + conjg(LatVecs(k,j))*HalfContract_j(k)
                            Ei_ij_val = Ei_ij_val + conjg(HalfContract_i(k))*LatVecs(k,j)
                        enddo
                        !Ei_ji_val = zdotc(nSites,LatVecs(:,j),1,HalfContract_j,1)
                        !Ei_ij_val = zdotc(nSites,HalfContract_i,1,LatVecs(:,j),1)

                        UpdatePotential(i,j) = UpdatePotential(i,j) + 0.25_dp*(Ei_ij_val+conjg(Ei_ji_val))
                        UpdatePotential(j,i) = UpdatePotential(j,i) + 0.25_dp*(conjg(Ei_ij_val)+Ei_ji_val)
                    enddo
                enddo
                
                !Rotate the new static potential (Update Potential) to the AO basis
                !TODO: Do this in k-space
                call ZGEMM('N','N',nSites,nSites,nSites,zone,LatVecs,nSites,UpdatePotential,nSites,zzero,ctemp,nSites)
                call ZGEMM('N','C',nSites,nSites,nSites,zone,ctemp,nSites,LatVecs,nSites,zzero,UpdatePotential,nSites)

                do i = 1,nSites
                    do j = 1,nSites
                        if(abs(UpdatePotential(j,i)-conjg(UpdatePotential(i,j))).gt.1.0e-8_dp) then
                            call stop_all(t_r,'Update potential not hermitian')
                        endif
                    enddo
                enddo

                deallocate(ctemp,LatSelfEnergy_i)
                deallocate(HalfContract_i,HalfContract_j)

            else
                !Do it all in kspace 
                !TODO: Parallelize over kpoints (ensure calls are not
                !parallelized themselves...)
                !This is only really worth it if h0 and sigma are always kept in
                !kspace...
                allocate(KBlocks(nImp,nImp,nKPnts))
                allocate(EVals(nSites))
                allocate(EVecs(nImp,nImp,nKPnts))
                allocate(ctemp(nSites,nImp))
                allocate(SE_K(nImp,nImp))
                allocate(LatSelfEnergy_i(nSites,nSites))
                allocate(LatSelfEnergy_j(nSites,nSites))
                allocate(SE_K_k(nImp,nImp))
                allocate(ctemp_vec(nImp))
                allocate(ctemp2(nImp,nImp))

                allocate(Pot_k(nImp,nImp,nKPnts))
                Pot_k(:,:,:) = zzero

                call ham_to_KBlocks(ham,KBlocks)
                call KBlocks_to_diag(KBlocks,EVecs,EVals)
                deallocate(KBlocks)

                do i = 1,nKPnts
                    ind_1 = ((i-1)*nImp) + 1
                    ind_2 = nImp*i
                    do j = 1,nImp
                        nval = ((i-1)*nImp)+j

                        pos = binary_search_real(FreqPoints,EVals(nval)-GFChemPot,1.0e-8_dp)
                        if(pos.lt.1) call stop_all(t_r,'Eigenvalue not found in frequency list')
                        !write(6,*) "Frequency point: ",EVals(nval)-GFChemPot

!                        LatSelfEnergy_i(:,:) = zzero
!                        call add_localpot_comp_inplace(LatSelfEnergy_i,SE_Update(:,:,pos),.true.)
!                        call writematrix(SE_Update(:,:,pos),'Local self energy for given frequency',.true.)
!
!                        !Rotate to kpoint i
!                        call ZGEMM('N','N',nSites,nImp,nSites,zone,LatSelfEnergy_i,nSites,RtoK_Rot(:,ind_1:ind_2),  &
!                            nSites,zzero,ctemp,nSites)
!                        call ZGEMM('C','N',nImp,nImp,nSites,zone,RtoK_Rot(:,ind_1:ind_2),nSites,ctemp,nSites,   &
!                            zzero,SE_K,nImp)
!                        call writematrix(SE_K,'SE_K',.true.)
!
!                        !Take the hermitian part of SE_K
!                        ctemp2(:,:) = zzero 
!                        do l = 1,nImp
!                            do m = 1,nImp
!                                ctemp2(l,m) = SE_K(l,m) + conjg(SE_K(m,l))
!                            enddo
!                        enddo
!                        SE_K(:,:) = ctemp2(:,:) * 0.5_dp
!                        call writematrix(SE_K,'Hermitized SE_K',.true.)

                        !Since the self energy is off-diagonal symmetric (not
                        !hermitian) it should just be real everywhere
                        do l = 1,nImp
                            do m = 1,nImp
                                if(abs(SE_Update(m,l,pos)-SE_Update(l,m,pos)).gt.1.0e-5_dp) then
                                    write(6,*) l,m,EVals(nval)-GFChemPot
                                    write(6,*) SE_Update(m,l,pos),SE_Update(l,m,pos)
                                    call warning(t_r,'Self energy not quite symmetric')
                                endif
                                SE_K(m,l) = cmplx(0.5_dp*(real(SE_Update(m,l,pos),dp)+real(SE_Update(l,m,pos),dp)),zero,dp)
                            enddo
                        enddo
                        !call writematrix(SE_Update(:,:,pos),'Local self energy',.true.)
                        !call writematrix(SE_K,'Hermitized SE_K',.true.)
                        
                        do k = 1,nImp
                            !Other functions at the same kpoint
                            nval_k = ((i-1)*nImp)+k

                            pos_k = binary_search_real(FreqPoints,EVals(nval_k)-GFChemPot,1.0e-8_dp)
                            if(pos_k.lt.1) call stop_all(t_r,'Eigenvalue k not found in frequency list')
                            !write(6,*) "Found: ",FreqPoints(pos_k),EVals(nval_k)-GFChemPot

!                            if(j.eq.k) then
!                                SE_K_k(:,:) = SE_K(:,:)
!                            else
!                                LatSelfEnergy_j(:,:) = zzero
!                                call add_localpot_comp_inplace(LatSelfEnergy_j,SE_Update(:,:,pos_k),.true.)
!
!                                call ZGEMM('N','N',nSites,nImp,nSites,zone,LatSelfEnergy_j,nSites,  &
!                                    RtoK_Rot(:,ind_1:ind_2),nSites,zzero,ctemp,nSites)
!                                call ZGEMM('C','N',nImp,nImp,nSites,zone,RtoK_Rot(:,ind_1:ind_2),nSites,    &
!                                    ctemp,nSites,zzero,SE_K_k,nImp)
!
!                                !Take hermitian part
!                                ctemp2(:,:) = zzero
!                                do l = 1,nImp
!                                    do m = 1,nImp
!                                        ctemp2(l,m) = SE_K_k(l,m) + conjg(SE_K_k(m,l))
!                                    enddo
!                                enddo
!                                SE_K_k(:,:) = ctemp2(:,:) * 0.5_dp
!                            endif
                            do l = 1,nImp
                                do m = 1,nImp
                                    SE_K_k(m,l) = cmplx(0.5_dp*(real(SE_Update(m,l,pos_k),dp)+real(SE_Update(l,m,pos_k),dp)), &
                                        zero,dp)
                                enddo
                            enddo
                            !call writematrix(SE_K_k,'Hermitized SE_K_k',.true.)

                            call ZGEMV('N',nImp,nImp,cmplx(0.5_dp,zero,dp),SE_K_k,nImp,EVecs(:,k,i),1,zzero,ctemp_vec,1)
                            call ZGEMV('N',nImp,nImp,cmplx(0.5_dp,zero,dp),SE_K,nImp,EVecs(:,k,i),1,zone,ctemp_vec,1)
                            do l = 1,nImp
                                Pot_k(j,k,i) = Pot_k(j,k,i) + conjg(EVecs(l,j,i))*ctemp_vec(l)
                            enddo
                        enddo
                    enddo
                    !This is the potential in the eigenbasis of this kpoint
                    !Rotate to the original, bare k-space basis
                    call ZGEMM('N','N',nImp,nImp,nImp,zone,EVecs(:,:,i),nImp,Pot_k(:,:,i),nImp,zzero,SE_K,nImp)
                    call ZGEMM('N','C',nImp,nImp,nImp,zone,SE_K,nImp,EVecs(:,:,i),nImp,zzero,Pot_k(:,:,i),nImp)
                    !write(6,*) "For k-point: ",i
                    !call writematrix(Pot_k(:,:,i),'k-space update potential',.true.)
                enddo
                deallocate(EVals)
                deallocate(EVecs)
                deallocate(SE_K)
                deallocate(SE_K_k)
                deallocate(ctemp_vec,ctemp2)
                deallocate(LatSelfEnergy_i,LatSelfEnergy_j)

                !Now, rotate Pot_k into real space.
                do k = 1,nKPnts
                    ind_1 = ((k-1)*nImp) + 1
                    ind_2 = nImp*k
                    !call writematrix(Pot_k(:,:,k),'UpdatePotential_k',.true.)
                    call ZGEMM('N','N',nSites,nImp,nImp,zone,RtoK_Rot(:,ind_1:ind_2),nSites,Pot_k(:,:,k),nImp,zzero,    &
                        ctemp,nSites)
                    call ZGEMM('N','C',nSites,nSites,nImp,zone,ctemp,nSites,RtoK_Rot(:,ind_1:ind_2),nSites,zone,    &
                        UpdatePotential,nSites)
                enddo
                !call writematrix(UpdatePotential,'UpdatePotential_AO',.true.)
                deallocate(ctemp)
            endif
        endif

        !Just to ensure - hermitise the potential
        do i = 1,nSites
            do j = 1,nSites
                UpdatePotential(i,j) = 0.5_dp*(UpdatePotential(i,j) + conjg(UpdatePotential(j,i)))
            enddo
        enddo
        !call writematrix(UpdatePotential,'FinalUpdatePotential_AO',.true.)

        !Potentially damp the update
        UpdatePotential(:,:) = PotentialUpdateDamping*UpdatePotential(:,:)

    end subroutine QPSC_UpdatePotential
                
end module SelfConsistentLR3
