

module OrthPolys

using SparseArrays
using LinearAlgebra: dot

import ACE

import ACE: evaluate!, evaluate_d!, evaluate_ed!, 
            evaluate, evaluate_d, evaluate_ed, evaluate_dd, 
            frule_evaluate, 
            _rrule_evaluate, _rrule_evaluate_d,
            read_dict, write_dict,
            inv_transform,
            ACEBasis, ScalarACEBasis, 
            acquire!, release!, 
            ArrayCache, 
            chain 

using ForwardDiff: derivative

import Base: ==

import ChainRules: rrule, NoTangent

export orthpolys, transformed_jacobi, discrete_jacobi


# these inner functions have been timed to run at 
#    6.7ns, 9.2ns, 11.7ns => no need to hand-optimise
_fcut_inner(pl, tl, pr, tr, t) = (t - tl)^pl * (t - tr)^pr

_fcut_d_inner(pl, tl, pr, tr, t) = 
      derivative( t -> _fcut_inner(pl, tl, pr, tr, t),  t )

_fcut_dd_inner(pl, tl, pr, tr, t) = 
      derivative( t -> _fcut_d_inner(pl, tl, pr, tr, t),  t )


function _fcut_(pl, tl, pr, tr, t)
   if (pl > 0 && t < tl) || (pr > 0 && t > tr)
      return zero(t)
   end
   return _fcut_inner(pl, tl, pr, tr, t)
end

function _fcut_d_(pl, tl, pr, tr, t)
   if (pl > 0 && t < tl) || (pr > 0 && t > tr)
      return zero(t)
   end
   return _fcut_d_inner(pl, tl, pr, tr, t)
end

function _fcut_dd_(pl, tl, pr, tr, t)
   if (pl > 0 && t < tl) || (pr > 0 && t > tr)
      return zero(t)
   end
   return _fcut_dd_inner(pl, tl, pr, tr, t)
end




@doc raw"""
`OrthPolyBasis:` defined a basis of orthonormal polynomials in terms of the
recursion coefficients. What is slightly unusual is that the polynomials have
an "envelope". This results in the recursion
```math
\begin{aligned}
   J_1(x) &= A_1 (x - x_l)^{p_l} (x - x_r)^{p_r} \\
   J_2 &= (A_2 x + B_2) J_1(x) \\
   J_{n} &= (A_n x + B_n) J_{n-1}(x) + C_n J_{n-2}(x)
\end{aligned}
```
Orthogonality is achieved with respect to a user-specified distribution, which
can be either continuous or discrete.

TODO: say more on the distribution! Maybe generalize to non-diagonal 
inner products?
"""
struct OrthPolyBasis{T} <: ScalarACEBasis
   # ----------------- the parameters for the cutoff function
   pl::Int        # cutoff power left
   tl::T          # cutoff left (transformed variable)
   pr::Int        # cutoff power right
   tr::T          # cutoff right (transformed variable)
   # ----------------- the recursion coefficients
   A::Vector{T}
   B::Vector{T}
   C::Vector{T}
   # ----------------- used only for construction ...
   #                   but useful to have since it defines the notion of orth.
   tdf::Vector{T}
   ww::Vector{T}
   # -------------
   B_pool::ArrayCache{T}
   dB_pool::ArrayCache{T}
end

OrthPolyBasis(pl, tl::T, pr, tr::T, A::Vector{T}, B::Vector{T}, C::Vector{T}, 
              tdf, ww) where {T} = 
   OrthPolyBasis(pl, tl, pr, tr, A, B, C, tdf, ww, 
                 ArrayCache{T}(), ArrayCache{T}())

Base.length(P::OrthPolyBasis) = length(P.A)

_valtype(::OrthPolyBasis{T}, t::S) where {T, S} = 
         promote_type(T, S) 

==(J1::OrthPolyBasis, J2::OrthPolyBasis) =
      all( getfield(J1, sym) == getfield(J2, sym)
           for sym in (:pr, :tr, :pl, :tl, :A, :B, :C) )

Base.show(io::IO, P::OrthPolyBasis) = 
         print(io, "OrthPolyBasis(pl = $(P.pl), tl = $(P.tl), pr = $(P.pr), tr = $(P.tr), ...)")


write_dict(J::OrthPolyBasis{T}) where {T} = Dict(
      "__id__" => "ACE_OrthPolyBasis",
      "T" => write_dict(T),
      "pr" => J.pr,
      "tr" => J.tr,
      "pl" => J.pl,
      "tl" => J.tl,
      "A" => J.A,
      "B" => J.B,
      "C" => J.C, 
      "tdf" => J.tdf, 
      "ww" => J.ww
   )

OrthPolyBasis(D::Dict, T=read_dict(D["T"])) =
   OrthPolyBasis(
      D["pl"], D["tl"], D["pr"], D["tr"],
      Vector{T}(D["A"]), Vector{T}(D["B"]), Vector{T}(D["C"]),
      T.(D["tdf"]), T.(D["ww"])
   )

read_dict(::Val{:ACE_OrthPolyBasis}, D::Dict) = OrthPolyBasis(D)

# rand applied to a J will return a random transformed distance drawn from
# the measure w.r.t. which the polynomials were constructed.
# TODO: allow non-constant weights!
function ACE.rand_radial(J::OrthPolyBasis)
   @assert maximum(abs, diff(J.ww)) == 0
   return rand(J.tdf)
end

OrthPolyBasis(N::Integer, J::OrthPolyBasis) = 
      OrthPolyBasis(N, J.pcut, J.tcut, J.pin, J.tin, J.tdf, J.ww)

function OrthPolyBasis(N::Integer,
                       pcut::Integer,
                       tcut::T,
                       pin::Integer,
                       tin::T,
                       tdf::AbstractVector{T},
                       ww::AbstractVector{T} = ones(T, length(tdf))
                       ) where {T <: AbstractFloat}
   @assert pcut >= 0  && pin >= 0
   @assert N > 0

   if tcut < tin
      tl, tr = tcut, tin
      pl, pr = pcut, pin
   else
      tl, tr = tin, tcut
      pl, pr = pin, pcut
   end

   if minimum(tdf) < tl || maximum(tdf) > tr
      @warn("OrthPolyBasis: t range outside [tl, tr]")
   end

   A = zeros(T, N)
   B = zeros(T, N)
   C = zeros(T, N)

   # normalise the weights s.t. <1, 1> = 1
   ww = ww ./ sum(ww)
   # define inner products
   dotw = (f1, f2) -> dot(f1, ww .* f2)

   # start the iteration
   _J1 = _fcut_.(pl, tl, pr, tr, tdf)
   a = sqrt( dotw(_J1, _J1) )
   A[1] = 1/a
   J1 = A[1] * _J1

   if N > 1
      # a J2 = (t - b) J1
      b = dotw(tdf .* J1, J1)
      _J2 = (tdf .- b) .* J1
      a = sqrt( dotw(_J2, _J2) )
      A[2] = 1/a
      B[2] = -b / a
      J2 = (A[2] * tdf .+ B[2]) .* J1

      # keep the last two for the 3-term recursion
      Jprev = J2
      Jpprev = J1
   end 

   for n = 3:N
      # a Jn = (t - b) J_{n-1} - c J_{n-2}
      b = dotw(tdf .* Jprev, Jprev)
      c = dotw(tdf .* Jprev, Jpprev)
      _J = (tdf .- b) .* Jprev -c * Jpprev
      a = sqrt( dotw(_J, _J) )
      A[n] = 1/a
      B[n] = - b / a
      C[n] = - c / a
      Jprev, Jpprev = _J / a, Jprev
   end

   return OrthPolyBasis(pl, tl, pr, tr, A, B, C, collect(tdf), collect(ww))
end


function evaluate(J::OrthPolyBasis, t) 
   cA = acquire!(J.B_pool, length(J), _valtype(J, t))
   evaluate!(parent(cA), J, t)
   return cA 
end

function evaluate_d(J::OrthPolyBasis, t) 
   cA = acquire!(J.B_pool, length(J), _valtype(J, t))
   evaluate_d!(parent(cA), J, t)
   return cA 
end

function ACE.evaluate_ed(J::OrthPolyBasis, t) 
   cA = acquire!(J.B_pool, length(J), _valtype(J, t))
   cdA = acquire!(J.B_pool, length(J), _valtype(J, t))
   evaluate_ed!(parent(cA), parent(cdA), J, t)
   return cA, cdA 
end



function frule_evaluate(J::OrthPolyBasis, t, dt)
   A, dA = evaluate_ed(J, t)   
   dA_dt = parent(dA) .* Ref(dt)
   release!(dA)
   return A, dA_dt 
end


evaluate_P1(J::OrthPolyBasis, t) =
   J.A[1] * _fcut_(J.pl, J.tl, J.pr, J.tr, t)

function evaluate!(P, J::OrthPolyBasis, t; maxn=length(J))
   @assert length(P) >= maxn
   P[1] = evaluate_P1(J, t)
   if maxn == 1; return P; end
   P[2] = (J.A[2] * t + J.B[2]) * P[1]
   if maxn == 2; return P; end
   @inbounds for n = 3:maxn
      P[n] = (J.A[n] * t + J.B[n]) * P[n-1] + J.C[n] * P[n-2]
   end
   return P
end


function evaluate_d!(dP, J::OrthPolyBasis, t; maxn=length(J))
   @assert maxn <= length(dP)

   P1 = evaluate_P1(J, t)
   dP[1] = J.A[1] * _fcut_d_(J.pl, J.tl, J.pr, J.tr, t)
   if maxn == 1; return dP; end

   α = J.A[2] * t + J.B[2]
   P2 = α * P1
   dP[2] = α * dP[1] + J.A[2] * P1
   if maxn == 2; return dP; end

   @inbounds for n = 3:maxn
      α = J.A[n] * t + J.B[n]
      P3 = α * P2 + J.C[n] * P1
      P2, P1 = P3, P2
      dP[n] = α * dP[n-1] + J.C[n] * dP[n-2] + J.A[n] * P1
   end
   return dP
end

function evaluate_ed!(P, dP, J::OrthPolyBasis, t; maxn=length(J))
   @assert maxn <= length(P)
   @assert maxn <= length(dP)

   P[1] = evaluate_P1(J, t)
   dP[1] = J.A[1] * _fcut_d_(J.pl, J.tl, J.pr, J.tr, t)
   if maxn == 1; return P, dP; end

   α = J.A[2] * t + J.B[2]
   P[2] = α * P[1]
   dP[2] = α * dP[1] + J.A[2] * P[1]
   if maxn == 2; return P, dP; end

   @inbounds for n = 3:maxn
      α = J.A[n] * t + J.B[n]
      P[n] = α * P[n-1] + J.C[n] * P[n-2]
      dP[n] = α * dP[n-1] + J.C[n] * dP[n-2] + J.A[n] * P[n-1]
   end
   return dP
end


# INCORRECT???
# function evaluate_dd!(ddP, J::OrthPolyBasis, t; maxn=length(J))
#    @assert maxn <= length(dP)

#    P1 = J.A[1] * _fcut_(J.pl, J.tl, J.pr, J.tr, t)
#    dP1 = J.A[1] * _fcut_d_(J.pl, J.tl, J.pr, J.tr, t)
#    ddP[1] = J.A[1] * _fcut_d_(J.pl, J.tl, J.pr, J.tr, t)
#    if maxn == 1; return dP; end

#    α = J.A[2] * t + J.B[2]
#    P2 = α * P1
#    dP[2] = α * dP[1] + J.A[2] * P1
#    if maxn == 2; return dP; end

#    @inbounds for n = 3:maxn
#       α = J.A[n] * t + J.B[n]
#       P3 = α * P2 + J.C[n] * P1
#       P2, P1 = P3, P2
#       dP[n] = α * dP[n-1] + J.C[n] * dP[n-2] + J.A[n] * P1
#    end
#    return dP
# end


using Base: @invokelatest

"""
`discrete_jacobi(N; pcut=0, tcut=1.0, pin=0, tin=-1.0, Nquad = 1000)`

A utility function to generate a jacobi-type basis
"""
function discrete_jacobi(N; pcut=0, xcut=1.0, pin=0, xin=-1.0, Nquad = 3 * N, 
                            trans = identity)
   tcut = @invokelatest trans(xcut)
   tin = @invokelatest trans(xin)
   tl, tr = minmax(tin, tcut)
   dt = (tr - tl) / Nquad
   tdf = range(tl + dt/2, tr - dt/2, length=Nquad)
   return OrthPolyBasis(N, pcut, tcut, pin, tin, tdf)
end



"""
`transformed_jacobi(maxdeg, trans, rcut, rin = 0.0; kwargs...)` : construct
a `TransformPolys` basis with an inner polynomial basis of `OrthPolys` type.

* `maxdeg` : maximum degree
* `trans` : distance transform; normally `PolyTransform(...)`
* `rin, rcut` : inner and outer cutoff

**Keyword arguments:**

* `pcut = 2` : cutoff parameter
* `pin = 0` : inner cutoff parameter
* `Nquad = 1000` : number of quadrature points
"""
function transformed_jacobi(maxdeg::Integer,
                            trans,
                            rcut::Real, rin::Real = 0.0;
                            kwargs...)
   J = discrete_jacobi(maxdeg; xcut = rcut,
                                xin = rin,
                                pcut = 2, trans=trans, 
                                kwargs...)
   return chain(trans, J)
end




# ------------- AD

import ACE: frule_evaluate

function ACE.frule_evaluate(J::OrthPolyBasis, t::Number, dt::Number) 
   len = length(J)
   B = acquire!(J.B_pool, len)
   dB = acquire!(J.B_pool, len)
   evaluate_ed!(B, dB, J, t)
   dB[:] .*= dt 
   return B, dB
end




function _rrule_evaluate(J::OrthPolyBasis, t::Number, 
                         w::AbstractVector{<: Number})
   maxn = length(w)
   @assert maxn <= length(J)

   P1 = J.A[1] * _fcut_(J.pl, J.tl, J.pr, J.tr, t)
   dP1 = J.A[1] * _fcut_d_(J.pl, J.tl, J.pr, J.tr, t)
   a = dP1 * w[1] 
   if maxn == 1 
      return a
   end 

   α = J.A[2] * t + J.B[2]
   P2 = α * P1
   dP2 = α * dP1 + J.A[2] * P1
   a += dP2 * w[2] 
   if maxn == 2
      return a 
   end 

   @inbounds for n = 3:maxn
      α = J.A[n] * t + J.B[n]
      P3 = α * P2 + J.C[n] * P1
      dP3 = α * dP2 + J.C[n] * dP1 + J.A[n] * P2
      a += dP3 * w[n] 
      P2, P1 = P3, P2
      dP2, dP1 = dP3, dP2
   end

   return a
end


function _rrule_evaluate_d(J::OrthPolyBasis, t::Number, 
                           w::AbstractVector{<: Number}, 
                           dt = 1.0, ddt = 0.0)
   maxn = length(w)
   @assert maxn <= length(J)

   P1 = J.A[1] * _fcut_(J.pl, J.tl, J.pr, J.tr, t)
   dP1 = J.A[1] * _fcut_d_(J.pl, J.tl, J.pr, J.tr, t)
   ddP1 = J.A[1] * _fcut_dd_(J.pl, J.tl, J.pr, J.tr, t)
   a = (ddP1 * dt^2 + dP1 * ddt) * w[1]
   if maxn == 1 
      return a
   end 

   α = J.A[2] * t + J.B[2]
   P2 = α * P1
   dP2 = α * dP1 + J.A[2] * P1
   ddP2 = α * ddP1 + 2 * J.A[2] * dP1
   a += (ddP2 * dt^2 + dP2 * ddt) * w[2] 
   if maxn == 2
      return a 
   end 

   @inbounds for n = 3:maxn
      α = J.A[n] * t + J.B[n]
      P3 = α * P2 + J.C[n] * P1
      dP3 = α * dP2 + J.C[n] * dP1 + J.A[n] * P2
      ddP3 = α * ddP2 + J.C[n] * ddP1 + 2 * J.A[n] * dP2
      a += (ddP3 * dt^2 + dP3 * ddt) * w[n] 
      P2, P1 = P3, P2
      dP2, dP1 = dP3, dP2
      ddP2, ddP1 = ddP3, ddP2
   end
   return a
end 

end
