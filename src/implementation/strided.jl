#-------------------------------------------------------------------------------------------
# StridedView implementation
#-------------------------------------------------------------------------------------------
function tensoradd!(C::StridedView, pC::Index2Tuple,
                    A::StridedView, conjA::Symbol,
                    α, β, backend::Union{StridedNative,StridedBLAS}=StridedNative())
    argcheck_tensoradd(C, pC, A)
    dimcheck_tensoradd(C, pC, A)

    p = linearize(pC)
    if !istrivialpermutation(pC) && Base.mightalias(C, A)
        throw(ArgumentError("output tensor must not be aliased with input tensor"))
    end
    add!(C, permutedims(flag2op(conjA)(A), linearize(pC)), α, β)
    return C
end

function tensortrace!(C::StridedView, pC::Index2Tuple,
                      A::StridedView, pA::Index2Tuple, conjA::Symbol,
                      α, β, backend::Union{StridedNative,StridedBLAS}=StridedNative())
    argcheck_tensortrace(C, pC, A, pA)
    dimcheck_tensortrace(C, pC, A, pA)

    Base.mightalias(C, A) &&
        throw(ArgumentError("output tensor must not be aliased with input tensor"))

    sizeA = i -> size(A, i)
    strideA = i -> stride(A, i)
    tracesize = sizeA.(pA[1])
    newstrides = (strideA.(linearize(pC))..., (strideA.(pA[1]) .+ strideA.(pA[2]))...)
    newsize = (size(C)..., tracesize...)
    A2 = flag2op(conjA)(StridedView(A.parent, newsize, newstrides, A.offset, A.op))
    if α != 1
        if β == 0
            Strided._mapreducedim!(x -> α * x, +, zero, newsize, (C, A2))
        elseif β == 1
            Strided._mapreducedim!(x -> α * x, +, nothing, newsize, (C, A2))
        else
            Strided._mapreducedim!(x -> α * x, +, y -> β * y, newsize, (C, A2))
        end
    else
        if β == 0
            return Strided._mapreducedim!(identity, +, zero, newsize, (C, A2))
        elseif β == 1
            Strided._mapreducedim!(identity, +, nothing, newsize, (C, A2))
        else
            Strided._mapreducedim!(identity, +, y -> β * y, newsize, (C, A2))
        end
    end
    return C
end

function tensorcontract!(C::StridedView{T}, pC::Index2Tuple,
                         A::StridedView, pA::Index2Tuple, conjA::Symbol,
                         B::StridedView, pB::Index2Tuple, conjB::Symbol,
                         α, β,
                         backend::StridedBLAS=StridedBLAS()) where {T<:LinearAlgebra.BlasFloat}
    argcheck_tensorcontract(C, pC, A, pA, B, pB)
    dimcheck_tensorcontract(C, pC, A, pA, B, pB)

    (Base.mightalias(C, A) || Base.mightalias(C, B)) &&
        throw(ArgumentError("output tensor must not be aliased with input tensor"))

    rpA = reverse(pA)
    rpB = reverse(pB)
    indCinoBA = let N₁ = numout(pA), N₂ = numin(pB)
        map(n -> ifelse(n > N₁, n - N₁, n + N₂), linearize(pC))
    end
    tpC = trivialpermutation(pC)
    rpC = (TupleTools.getindices(indCinoBA, tpC[1]),
           TupleTools.getindices(indCinoBA, tpC[2]))
    if contract_memcost(C, pC, A, pA, conjA, B, pB, conjB) <=
       contract_memcost(C, rpC, B, rpB, conjB, A, rpA, conjA)
        return blas_contract!(C, pC, A, pA, conjA, B, pB, conjB, α, β)
    else
        return blas_contract!(C, rpC, B, rpB, conjB, A, rpA, conjA, α, β)
    end
end

function tensorcontract!(C::StridedView, pC::Index2Tuple,
                         A::StridedView, pA::Index2Tuple, conjA::Symbol,
                         B::StridedView, pB::Index2Tuple, conjB::Symbol,
                         α, β,
                         backend::StridedNative)
    argcheck_tensorcontract(C, pC, A, pA, B, pB)
    dimcheck_tensorcontract(C, pC, A, pA, B, pB)

    sizeA = size(A)
    sizeB = size(B)
    csizeA = TupleTools.getindices(sizeA, pA[2])
    csizeB = TupleTools.getindices(sizeB, pB[1])
    osizeA = TupleTools.getindices(sizeA, pA[1])
    osizeB = TupleTools.getindices(sizeB, pB[2])

    let opA = flag2op(conjA), opB = flag2op(conjB), α = α
        AS = sreshape(permutedims(A, linearize(pA)),
                      (osizeA..., one.(osizeB)..., csizeA...))
        BS = sreshape(permutedims(B, linearize(reverse(pB))),
                      (one.(osizeA)..., osizeB..., csizeB...))
        CS = sreshape(permutedims(C, invperm(linearize(pC))),
                      (osizeA..., osizeB..., one.(csizeA)...))
        tsize = (osizeA..., osizeB..., csizeA...)

        if α != 1
            op1 = (x, y) -> α * opA(x) * opB(y)
            if β == 0
                Strided._mapreducedim!(op1, +, zero, tsize, (CS, AS, BS))
            elseif β == 1
                Strided._mapreducedim!(op1, +, nothing, tsize, (CS, AS, BS))
            else
                Strided._mapreducedim!(op1, +, y -> β * y, tsize, (CS, AS, BS))
            end
        else
            op2 = (x, y) -> opA(x) * opB(y)
            if β == 0
                if isbitstype(eltype(C))
                    Strided._mapreducedim!(op2, +, zero, tsize, (CS, AS, BS))
                else
                    fill!(C, zero(eltype(C)))
                    Strided._mapreducedim!(op2, +, nothing, tsize, (CS, AS, BS))
                end
            elseif β == 1
                Strided._mapreducedim!(op2, +, nothing, tsize, (CS, AS, BS))
            else
                Strided._mapreducedim!(op2, +, y -> β * y, tsize, (CS, AS, BS))
            end
        end
    end

    return C
end

#-------------------------------------------------------------------------------------------
# StridedViewBLAS contraction implementation
#-------------------------------------------------------------------------------------------
function blas_contract!(C, pC, A, pA, conjA, B, pB, conjB, α, β)
    TC = eltype(C)

    A_, pA, conjA, flagA = makeblascontractable(A, pA, conjA, TC)
    B_, pB, conjB, flagB = makeblascontractable(B, pB, conjB, TC)

    ipC = oindABinC(pC, pA, pB)
    flagC = isblascontractable(C, ipC, :D)
    if flagC
        C_ = C
        _unsafe_blas_contract!(C_, ipC, A_, pA, conjA, B_, pB, conjB, α, β)
    else
        C_ = StridedView(TensorOperations.tensoralloc_add(TC, ipC, C, :N))
        ipC = trivialpermutation(ipC)
        _unsafe_blas_contract!(C_, ipC, A_, pA, conjA, B_, pB, conjB, one(TC), zero(TC))
        tensoradd!(C, pC, C_, :N, α, β)
        tensorfree!(C_.parent)
    end
    flagA || tensorfree!(A_.parent)
    flagB || tensorfree!(B_.parent)
    return C
end

function _unsafe_blas_contract!(C::StridedView{T}, ipC,
                                A::StridedView{T}, pA, conjA,
                                B::StridedView{T}, pB, conjB, α, β) where {T<:BlasFloat}
    sizeA = size(A)
    sizeB = size(B)
    csizeA = TupleTools.getindices(sizeA, pA[2])
    csizeB = TupleTools.getindices(sizeB, pB[1])
    osizeA = TupleTools.getindices(sizeA, pA[1])
    osizeB = TupleTools.getindices(sizeB, pB[2])

    opA = flag2op(conjA)
    opB = flag2op(conjB)

    mul!(sreshape(permutedims(C, linearize(ipC)), (prod(osizeA), prod(osizeB))),
         opA(sreshape(permutedims(A, linearize(pA)), (prod(osizeA), prod(csizeA)))),
         opB(sreshape(permutedims(B, linearize(pB)), (prod(csizeB), prod(osizeB)))),
         α, β)

    return C
end

function makeblascontractable(A, pA, conjA, TC)
    flagA = isblascontractable(A, pA, conjA) && eltype(A) == TC
    if !flagA
        A_ = StridedView(TensorOperations.tensoralloc_add(TC, pA, A, conjA, true))
        A = tensoradd!(A_, pA, A, conjA, one(TC), zero(TC))
        conjA = :N
        pA = trivialpermutation(pA)
    end
    return A, pA, conjA, flagA
end

function isblascontractable(A::StridedView, p::Index2Tuple, C::Symbol)
    eltype(A) <: LinearAlgebra.BlasFloat || return false
    sizeA = size(A)
    stridesA = strides(A)
    sizeA1 = TupleTools.getindices(sizeA, p[1])
    sizeA2 = TupleTools.getindices(sizeA, p[2])
    stridesA1 = TupleTools.getindices(stridesA, p[1])
    stridesA2 = TupleTools.getindices(stridesA, p[2])

    canfuse1, d1, s1 = _canfuse(sizeA1, stridesA1)
    canfuse2, d2, s2 = _canfuse(sizeA2, stridesA2)

    if C == :D # destination
        return A.op == identity && canfuse1 && canfuse2 && s1 == 1
    elseif (C == :C && A.op == identity) || (C == :N && A.op == conj) # conjugated
        return canfuse1 && canfuse2 && s2 == 1
    else
        return canfuse1 && canfuse2 && (s1 == 1 || s2 == 1)
    end
end

_canfuse(::Dims{0}, ::Dims{0}) = true, 1, 1
_canfuse(dims::Dims{1}, strides::Dims{1}) = true, dims[1], strides[1]
function _canfuse(dims::Dims{N}, strides::Dims{N}) where {N}
    if dims[1] == 0
        return true, 0, 1
    elseif dims[1] == 1
        return _canfuse(Base.tail(dims), Base.tail(strides))
    else
        b, d, s = _canfuse(Base.tail(dims), Base.tail(strides))
        if b && (s == dims[1] * strides[1] || d == 1)
            dnew = dims[1] * d
            return true, dnew, (dnew == 0 || dnew == 1) ? 1 : strides[1]
        else
            return false, dims[1] * d, strides[1]
        end
    end
end

function oindABinC(pC, pA, pB)
    ipC = invperm(linearize(pC))
    oindAinC = TupleTools.getindices(ipC, trivialpermutation(pA[1]))
    oindBinC = TupleTools.getindices(ipC, numout(pA) .+ trivialpermutation(pB[2]))
    return (oindAinC, oindBinC)
end

function contract_memcost(C, pC, A, pA, conjA, B, pB, conjB)
    ipC = oindABinC(pC, pA, pB)
    return length(A) *
           (!isblascontractable(A, pA, conjA) || eltype(A) !== eltype(C)) +
           length(B) *
           (!isblascontractable(B, pB, conjB) || eltype(B) !== eltype(C)) +
           length(C) * !isblascontractable(C, ipC, :D)
end
