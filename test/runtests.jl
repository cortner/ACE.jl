

using ACE, Test, Printf, LinearAlgebra, StaticArrays, BenchmarkTools

##
@testset "ACE.jl" begin
    # ------------------------------------------
    #   basic polynomial basis building blocks
    @testset "Ylm" begin include("polynomials/test_ylm.jl") end 
    include("testing/test_wigner.jl")
    include("polynomials/test_transforms.jl")
    include("polynomials/test_orthpolys.jl")

    # --------------------------------------------
    # core permutation-invariant functionality
    include("test_1pbasis.jl")
    include("test_multigrads.jl")
    @testset "PIBasis" begin include("test_pibasis.jl") end

    # ------------------------
    #   O(3) equi-variance
    @testset "Clebsch-Gordan" begin include("test_cg.jl") end
    @testset "SymmetricBasis" begin include("test_symmbasis.jl") end
    @testset "EuclideanVector" begin include("test_euclvec.jl") end

    # Model tests 
    # include("test_linearmodel.jl")

    

end


    # -----------------------------------------
    #    old tests to be re-introduced - maybe
    # include("test_real.jl")
    # include("test_orth.jl")
    # include("bonds/test_cylindrical.jl")
    # include("bonds/test_fourier.jl")
    # include("bonds/test_envpairbasis.jl")
