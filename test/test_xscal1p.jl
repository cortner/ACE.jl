

##

using ACE
using Printf, Test, LinearAlgebra, StaticArrays
using ACE: evaluate, evaluate_d, Rn1pBasis, Ylm1pBasis,
      PositionState, Product1pBasis, State, ACEConfig, 
      SymmetricBasis
using Random: shuffle
using ACEbase.Testing: dirfdtest, fdtest, print_tf, test_fio, println_slim
using ACE.OrthPolys: transformed_jacobi

##

@info("======= Testing XScal1pBasis ======= ")

maxdeg = 5
trans = ACE.Transforms.IdTransform()
P = transformed_jacobi(2*maxdeg, trans, 1.0, 0.0; pin = 0, pcut = 0) 

Bsel = ACE.SimpleSparseBasis(3, maxdeg)

##

B1p = ACE.xscal1pbasis(:u, (k = 0:maxdeg, m = 0:maxdeg), P)
ACE.init1pspec!(B1p, Bsel)
ACE.fill_rand_coeffs!(B1p, randn)

##

@info("check symbols")
println_slim(@test sort(ACE.symbols(B1p)) == sort([:k, :m]) )

@info("check `get_index`")
for ntest = 1:30 
   local idx, b 
   idx = rand(1:length(B1p))
   b = B1p.spec[idx] 
   print_tf(@test ACE.get_index(B1p, b) == idx)
end
println() 

@info("check fio")
println_slim(@test all( test_fio(B1p; warntype=false) ))


##

@info("evaluation test ")
X = State(u = rand())
B = evaluate(B1p, X)
dB = evaluate_d(B1p, X)
println_slim(@test ACE.evaluate_ed(B1p, X) == (B, dB) )

##

@info("Finite-difference tests at a few random points")
for ntest = 1:10 
   local c, F, dF 
   c = rand(length(B1p))
   F = u -> ACE.contract(c, evaluate(B1p, State(u = u)))
   dF = u -> ACE.contract(c, getproperty.(evaluate_d(B1p, State(u = u)), :u))
   print_tf(@test all( fdtest(F, dF, rand() - 0.5; verbose=false) ))
end
println() 



##
