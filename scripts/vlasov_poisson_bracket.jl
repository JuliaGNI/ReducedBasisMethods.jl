
using OffsetArrays
using ReducedBasisMethods
using Test


struct PoissonTensor{DT,FT}
    nx::Int
    nv::Int
    f::FT

    function PoissonTensor(DT, nx, nv, f)
        new{DT, typeof(f)}(nx, nv, f)
    end
end

Base.size(pt::PoissonTensor) = tuple(pt.nx * pt.nv * ones(Int,3)...)
Base.size(pt::PoissonTensor, i) = i ≥ 1 && i ≤ 3 ? pt.nx * pt.nv : 1

function Base.getindex(pt::PoissonTensor, I::CartesianIndex, J::CartesianIndex, K::CartesianIndex)
    @assert isvalid(I, pt.nx, pt.nv)
    @assert isvalid(J, pt.nx, pt.nv)
    @assert isvalid(K, pt.nx, pt.nv)

    pt.f(I, J, K)
end

function Base.getindex(pt::PoissonTensor, i::Int, j::Int, k::Int)
    I = multiindex(i, pt.nx, pt.nv)
    J = multiindex(j, pt.nx, pt.nv)
    K = multiindex(k, pt.nx, pt.nv)

    pt[I,J,K]
end

function Base.materialize(rt::PoissonTensor)
    [ rt[i,j,k] for i in 1:size(rt,1), j in 1:size(rt,2), k in 1:size(rt,3) ]
end



struct ReducedTensor{DT, PT <: PoissonTensor{DT}, PM1, PM2} <: AbstractArray{DT,3}
    tensor::PT
    projection_i::PM1
    projection_j::PM2

    function ReducedTensor(tensor::PoissonTensor{DT}, Pi::PM1, Pj::PM2) where {DT, PM1, PM2}
        @assert size(PM1, 2) == size(tensor, 1)
        @assert size(PM2, 1) == size(tensor, 2)
        new{DT, typeof(tensor), PM1, PM2}(tensor, Pi, Pj)
    end
end

Base.size(rt::ReducedTensor) = (size(rt.projection_i, 1), size(rt.projection_j, 2), size(rt.tensor, 3))
Base.size(rt::ReducedTensor, i) = size(rt)[i]
Base.axes(rt::ReducedTensor, i) = OneTo(size(rt, i))

function Base.getindex(rt::ReducedTensor{DT}, i::Int, j::Int, k::Int) where {DT}
    @assert i ≥ 1 && i ≤ size(rt, 1)
    @assert j ≥ 1 && j ≤ size(rt, 2)
    @assert k ≥ 1 && k ≤ size(rt, 3)

    local x = zero(DT)

    # TODO: Account for stencil size and loop only over nonzero entries
    @inbounds for m in axes(rt.projection_i, 2)
        for n in axes(rt.projection_j, 1)
            x += rt.projection_i[i,m] * rt.tensor[m,n,k] * rt.projection_j[n,j]
        end
    end

    return x
end

function Base.materialize(rt::ReducedTensor)
    [ rt[i,j,k] for i in axes(rt,1), j in axes(rt,2), k in axes(rt,3) ]
end




struct PoissonOperator{DT, PT, HT} <: AbstractMatrix{DT}
    tensor::PT
    hamiltonian::HT

    function PoissonOperator(tensor::Union{PoissonTensor{DT},ReducedTensor{DT}}, h::HT) where {DT, HT}
        new{DT, typeof(tensor), HT}(tensor, h)
    end
end

Base.size(po::PoissonOperator) = (size(po.tensor, 1), size(po.tensor, 2))
Base.size(po::PoissonOperator, i) = size(po)[i]

function Base.getindex(po::PoissonOperator{DT}, i::Int, j::Int) where {DT}
    @assert i ≥ 1 && i ≤ size(po, 1)
    @assert j ≥ 1 && j ≤ size(po, 2)

    local x = zero(DT)

    @inbounds for k in eachindex(po.hamiltonian)
        x += po.tensor[i,j,k] * po.hamiltonian[k]
    end

    return x
end

function Base.materialize(rt::PoissonOperator)
    [ rt[i,j] for i in 1:size(rt,1), j in 1:size(rt,2) ]
end




### Arakawa ###

"""

jpp = 
    + f[i-1, j  ] * h[i,   j-1]
    - f[i-1, j  ] * h[i,   j+1]
    - f[i,   j-1] * h[i-1, j  ]
    + f[i,   j-1] * h[i+1, j  ]
    + f[i,   j+1] * h[i-1, j  ]
    - f[i,   j+1] * h[i+1, j  ]
    - f[i+1, j  ] * h[i,   j-1]
    + f[i+1, j  ] * h[i,   j+1]

jpc =
    + f[i-1, j  ] * h[i-1, j-1]
    - f[i-1, j  ] * h[i-1, j+1]
    - f[i,   j-1] * h[i-1, j-1]
    + f[i,   j-1] * h[i+1, j-1]
    + f[i,   j+1] * h[i-1, j+1]
    - f[i,   j+1] * h[i+1, j+1]
    - f[i+1, j  ] * h[i+1, j-1]
    + f[i+1, j  ] * h[i+1, j+1]

jcp = 
    - f[i-1, j-1] * h[i-1, j  ]
    + f[i-1, j-1] * h[i,   j-1]
    + f[i-1, j+1] * h[i-1, j  ]
    - f[i-1, j+1] * h[i,   j+1]
    - f[i+1, j-1] * h[i,   j-1]
    + f[i+1, j-1] * h[i+1, j  ]
    + f[i+1, j+1] * h[i,   j+1]
    - f[i+1, j+1] * h[i+1, j  ]

return (jpp + jpc + jcp) * inv(hx) * inv(hv) / 12

"""
struct Arakawa{DT}
    nx::Int
    nv::Int
    hx::DT
    hv::DT
    factor::DT

    JPP::OffsetArray{Int, 4, Array{Int, 4}}
    JPC::OffsetArray{Int, 4, Array{Int, 4}}
    JCP::OffsetArray{Int, 4, Array{Int, 4}}

    function Arakawa(nx::Int, nv::Int, hx::DT, hv::DT) where {DT}
        JPP = OffsetArray(zeros(Int, 3, 3, 3, 3), -1:+1, -1:+1, -1:+1, -1:+1)
        JPC = OffsetArray(zeros(Int, 3, 3, 3, 3), -1:+1, -1:+1, -1:+1, -1:+1)
        JCP = OffsetArray(zeros(Int, 3, 3, 3, 3), -1:+1, -1:+1, -1:+1, -1:+1)
    
        JPP[-1,  0,  0, -1] = +1
        JPP[-1,  0,  0, +1] = -1
        JPP[ 0, -1, -1,  0] = -1
        JPP[ 0, -1, +1,  0] = +1
        JPP[ 0, +1, -1,  0] = +1
        JPP[ 0, +1, +1,  0] = -1
        JPP[+1,  0,  0, -1] = -1
        JPP[+1,  0,  0, +1] = +1
    
        JPC[-1,  0, -1, -1] = +1
        JPC[-1,  0, -1, +1] = -1
        JPC[ 0, -1, -1, -1] = -1
        JPC[ 0, -1, +1, -1] = +1
        JPC[ 0, +1, -1, +1] = +1
        JPC[ 0, +1, +1, +1] = -1
        JPC[+1,  0, +1, -1] = -1
        JPC[+1,  0, +1, +1] = +1
    
        JCP[-1, -1, -1,  0] = -1
        JCP[-1, -1,  0, -1] = +1
        JCP[-1, +1, -1,  0] = +1
        JCP[-1, +1,  0, +1] = -1
        JCP[+1, -1,  0, -1] = -1
        JCP[+1, -1, +1,  0] = +1
        JCP[+1, +1,  0, +1] = +1
        JCP[+1, +1, +1,  0] = -1
    
        factor = inv(hx) * inv(hv) / 12

        new{DT}(nx, nv, hx, hv, factor, JPP, JPC, JCP)
    end
end

mymod(i, n, w=1) = abs(i) ≥ n - w ? i - sign(i) * n : i


function (arakawa::Arakawa{DT})(I, J, K) where {DT}
    fi = mymod.(Tuple(J - I), (arakawa.nx, arakawa.nv))
    hi = mymod.(Tuple(K - I), (arakawa.nx, arakawa.nv))

    if any(fi .< -1) || any(fi .> +1) || any(hi .< -1) || any(hi .> +1)
        return zero(DT)
    end

    ( arakawa.JPP[fi..., hi...] +
      arakawa.JPC[fi..., hi...] +
      arakawa.JCP[fi..., hi...] ) * arakawa.factor
end



### Tests ###

const nx = 10
const nv = 24
const hx = 0.1
const hv = 0.2

for i in (5, 23, 45, 63)
    @test linearindex(multiindex(i, nx, nv), nx, nv) == i
end

@test_throws AssertionError multiindex(nx*nv+1, nx, nv)
@test_throws AssertionError linearindex(CartesianIndex(2nx, div(nv,2)), nx, nv)




arakawa = Arakawa(nx, nv, hx, hv)