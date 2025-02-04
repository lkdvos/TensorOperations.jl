module TensorOperationscuTENSORExt

if !isdefined(Base, :get_extension)
    using ..TensorOperations
    using ..cuTENSOR: cuTENSOR
    # import ..cuTENSOR.CUDA as CUDA
else
    using TensorOperations
    using cuTENSOR: cuTENSOR
    # import cuTENSOR.CUDA as CUDA
end

using TensorOperations
using TupleTools
using cuTENSOR: CUDA, handle, CuTensorDescriptor, cudaDataType_t,
                cutensorContractionDescriptor_t,
                cutensorContractionFind_t, cutensorContractionPlan_t,
                CUTENSOR_OP_IDENTITY,
                CUTENSOR_OP_CONJ, CUTENSOR_OP_ADD, CUTENSOR_ALGO_DEFAULT,
                CUTENSOR_WORKSPACE_RECOMMENDED, cutensorPermutation,
                cutensorElementwiseBinary, cutensorReduction,
                cutensorReductionGetWorkspace,
                cutensorComputeType, cutensorGetAlignmentRequirement,
                cutensorInitContractionDescriptor, cutensorInitContractionFind,
                cutensorContractionGetWorkspace, cutensorInitContractionPlan,
                cutensorContraction
using cuTENSOR.CUDA: CUDA, CuArray
using cuTENSOR.CUDA.CUBLAS: CublasFloat, CublasReal
using cuTENSOR.CUDA: with_workspace, default_stream

# this might be dependency-piracy, but removes a dependency from the main package
using cuTENSOR.CUDA.Adapt: adapt

const TO = TensorOperations
function TO.tensorscalar(C::CuArray)
    return ndims(C) == 0 ? tensorscalar(collect(C)) : throw(DimensionMismatch())
end

@inline function tensorop(T::Type{<:Number}, op::Symbol)
    return (T <: Real || op == :N) ? CUTENSOR_OP_IDENTITY : CUTENSOR_OP_CONJ
end

function tensordescriptor(T::Type{<:Number}, A::CuArray, pA::Index2Tuple, conjA::Symbol)
    return CuTensorDescriptor(A;
                              op=tensorop(T, conjA),
                              size=TupleTools.getindices(size(A), linearize(pA)),
                              strides=TupleTools.getindices(strides(A), linearize(pA)))
end

#-------------------------------------------------------------------------------------------
# Operations
#-------------------------------------------------------------------------------------------

function TO.tensoradd!(C::CuArray, pC::Index2Tuple, A::CuArray, conjA::Symbol,
                       α::Number, β::Number)
    TO.argcheck_tensoradd(C, pC, A)

    T = eltype(C)
    conjA == :N || conjA == :C ||
        throw(ArgumentError("Value of conjA should be :N or :C instead of $conjA"))
    opA = (T <: Real || conjA == :N) ? CUTENSOR_OP_IDENTITY : CUTENSOR_OP_CONJ
    opAC = CUTENSOR_OP_ADD

    descA = CuTensorDescriptor(A; op=opA)
    descC = CuTensorDescriptor(C; op=CUTENSOR_OP_IDENTITY)

    typeCompute = convert(cudaDataType_t, T)
    modeA = collect(Cint, 1:ndims(A))
    modeC = collect(Cint, linearize(pC))
    stream = default_stream()
    if β == zero(β)
        cutensorPermutation(handle(), T[α], A, descA, modeA, C, descC, modeC,
                            typeCompute, stream)
    else
        cutensorElementwiseBinary(handle(), T[α], A, descA, modeA, T[β], C, descC,
                                  modeC, C, descC, modeC, opAC, typeCompute, stream)
    end

    return C
end

function TO.tensorcontract!(C::CuArray, pC::Index2Tuple,
                            A::CuArray, pA::Index2Tuple, conjA::Symbol,
                            B::CuArray, pB::Index2Tuple, conjB::Symbol,
                            α, β)
    TO.argcheck_tensorcontract(C, pC, A, pA, B, pB)
    TO.dimcheck_tensorcontract(C, pC, A, pA, B, pB)

    conjA == :N || conjA == :C ||
        throw(ArgumentError("Value of conjA should be :N or :C instead of $conjA"))
    conjB == :N || conjB == :C ||
        throw(ArgumentError("Value of conjB should be :N or :C instead of $conjB"))

    T = eltype(C)

    descA = tensordescriptor(T, A, pA, conjA)
    descB = tensordescriptor(T, B, reverse(pB), conjB)
    descC = CuTensorDescriptor(C)

    typeCompute = cutensorComputeType(T)

    NoA = TO.numout(pA)
    NoB = TO.numin(pB)
    Nc = TO.numin(pA)

    modeoA = ntuple(n -> n, NoA)
    modeoB = ntuple(n -> NoA + n, NoB)
    modec = ntuple(n -> NoA + NoB + n, Nc)

    modeA = collect(Cint, (modeoA..., modec...))
    modeB = collect(Cint, (modeoB..., modec...))
    modeC = collect(Cint, linearize(pC))

    algo = CUTENSOR_ALGO_DEFAULT
    stream = default_stream()
    pref = CUTENSOR_WORKSPACE_RECOMMENDED

    alignmentRequirementA = Ref{UInt32}(C_NULL)
    cutensorGetAlignmentRequirement(handle(), A, descA, alignmentRequirementA)
    alignmentRequirementB = Ref{UInt32}(C_NULL)
    cutensorGetAlignmentRequirement(handle(), B, descB, alignmentRequirementB)
    alignmentRequirementC = Ref{UInt32}(C_NULL)
    cutensorGetAlignmentRequirement(handle(), C, descC, alignmentRequirementC)
    desc = Ref{cutensorContractionDescriptor_t}()
    cutensorInitContractionDescriptor(handle(),
                                      desc,
                                      descA, modeA, alignmentRequirementA[],
                                      descB, modeB, alignmentRequirementB[],
                                      descC, modeC, alignmentRequirementC[],
                                      descC, modeC, alignmentRequirementC[],
                                      typeCompute)

    find = Ref{cutensorContractionFind_t}()
    cutensorInitContractionFind(handle(), find, algo)

    function workspacesize()
        out = Ref{UInt64}(C_NULL)
        cutensorContractionGetWorkspace(handle(), desc, find, pref, out)
        return out[]
    end
    with_workspace(workspacesize, 1 << 27) do workspace
        plan_ref = Ref{cutensorContractionPlan_t}()
        cutensorInitContractionPlan(handle(), plan_ref, desc, find, sizeof(workspace))

        return cutensorContraction(handle(), plan_ref, T[α], A, B, T[β], C, C,
                                   workspace, sizeof(workspace), stream)
    end

    return C
end

function TO.tensortrace!(C::CuArray, pC::Index2Tuple,
                         A::CuArray, pA::Index2Tuple, conjA::Symbol, α, β)
    TO.argcheck_tensortrace(C, pC, A, pA)
    T = eltype(C)
    NA, NC = ndims(A), ndims(C)

    opA = tensorop(T, conjA)
    opReduce = CUTENSOR_OP_ADD

    sizeA = i -> size(A, i)
    strideA = i -> stride(A, i)
    tracesize = sizeA.(pA[1])
    tracesize == sizeA.(pA[2]) || throw(DimensionMismatch("non-matching trace sizes"))
    size(C) == sizeA.(linearize(pC)) || throw(DimensionMismatch("non-matching sizes"))

    newstrides = (strideA.(linearize(pC))..., (strideA.(pA[1]) .+ strideA.(pA[2]))...)
    newsize = (size(C)..., tracesize...)
    descA = CuTensorDescriptor(A; op=opA, size=newsize, strides=newstrides)
    descC = CuTensorDescriptor(C; op=CUTENSOR_OP_IDENTITY)
    # descD = descC
    typeCompute = cutensorComputeType(T)
    modeA = collect(Cint, 1:NA)
    modeC = collect(Cint, 1:NC)
    stream = default_stream()
    function workspacesize()
        out = Ref{UInt64}(C_NULL)
        cutensorReductionGetWorkspace(handle(),
                                      A, descA, modeA,
                                      C, descC, modeC,
                                      C, descC, modeC,
                                      opReduce, typeCompute,
                                      out)
        return out[]
    end
    with_workspace(workspacesize, 1 << 13) do workspace
        return cutensorReduction(handle(),
                                 T[α], A, descA, modeA,
                                 T[β], C, descC, modeC,
                                 C, descC, modeC,
                                 opReduce, typeCompute,
                                 workspace, sizeof(workspace), stream)
    end
    return C
end

#-------------------------------------------------------------------------------------------
# Allocations
#-------------------------------------------------------------------------------------------

function TO.tensoradd_type(TC, pC::Index2Tuple, ::CuArray, conjA::Symbol)
    return CuArray{TC,TO.numind(pC)}
end

function TO.tensorcontract_type(TC, pC::Index2Tuple,
                                ::CuArray, pA::Index2Tuple, conjA::Symbol,
                                ::CuArray, pB::Index2Tuple, conjB::Symbol)
    return CuArray{TC,TO.numind(pC)}
end

#-------------------------------------------------------------------------------------------
# Backend
#-------------------------------------------------------------------------------------------

const cuTENSORBackend = TO.Backend{:cuTENSOR}

function TO.tensoradd!(C::AbstractArray, pC::Index2Tuple,
                       A::AbstractArray, conjA::Symbol, α::Number, β::Number,
                       backend::cuTENSORBackend)
    C_cuda = adapt(CuArray, C)
    tensoradd!(C_cuda, pC, A, conjA, α, β, backend)
    copyto!(C, collect(C_cuda))
    return C
end

function TO.tensoradd!(C::CuArray, pC::Index2Tuple,
                       A::AbstractArray, conjA::Symbol, α::Number, β::Number,
                       ::cuTENSORBackend)
    return tensoradd!(C, pC, adapt(CuArray, A), conjA, α, β)
end

function TO.tensorcontract!(C::AbstractArray, pC::Index2Tuple,
                            A::AbstractArray, pA::Index2Tuple, conjA::Symbol,
                            B::AbstractArray, pB::Index2Tuple, conjB::Symbol,
                            α, β, backend::cuTENSORBackend)
    C_cuda = adapt(CuArray, C)
    tensorcontract!(C_cuda, pC, A, pA, conjA, B, pB, conjB, α, β, backend)
    copyto!(C, collect(C_cuda))
    return C
end
function TO.tensorcontract!(C::CuArray, pC::Index2Tuple,
                            A::AbstractArray, pA::Index2Tuple, conjA::Symbol,
                            B::AbstractArray, pB::Index2Tuple, conjB::Symbol,
                            α, β, ::cuTENSORBackend)
    return tensorcontract!(C, pC, adapt(CuArray, A), pA, conjA, adapt(CuArray, B), pB,
                           conjB, α, β)
end

function TO.tensortrace!(C::AbstractArray, pC::Index2Tuple,
                         A::AbstractArray, pA::Index2Tuple, conjA::Symbol,
                         α, β, backend::cuTENSORBackend)
    C_cuda = adapt(CuArray, C)
    tensortrace!(C_cuda, pC, A, pA, conjA, α, β, backend)
    copyto!(C, collect(C_cuda))
    return C
end
function TO.tensortrace!(C::CuArray, pC::Index2Tuple,
                         A::AbstractArray, pA::Index2Tuple, conjA::Symbol,
                         α, β, ::cuTENSORBackend)
    return tensortrace!(C, pC, adapt(CuArray, A), pA, conjA, α, β)
end

function TO.tensoradd_type(TC, pC::Index2Tuple, ::AbstractArray,
                           conjA::Symbol, ::cuTENSORBackend)
    return CuArray{TC,TO.numind(pC)}
end

function TO.tensorcontract_type(TC, pC::Index2Tuple,
                                ::AbstractArray, pA::Index2Tuple, conjA::Symbol,
                                ::AbstractArray, pB::Index2Tuple, conjB::Symbol,
                                ::cuTENSORBackend)
    return CuArray{TC,TO.numind(pC)}
end

function TO.tensoralloc_add(TC, pC, A::AbstractArray, conjA, istemp,
                            ::cuTENSORBackend)
    ttype = CuArray{TC,TO.numind(pC)}
    structure = TO.tensoradd_structure(pC, A, conjA)
    return tensoralloc(ttype, structure, istemp)::ttype
end

function TO.tensoralloc_contract(TC, pC,
                                 A::AbstractArray, pA, conjA,
                                 B::AbstractArray, pB, conjB,
                                 istemp, ::cuTENSORBackend)
    ttype = CuArray{TC,TO.numind(pC)}
    structure = TO.tensorcontract_structure(pC, A, pA, conjA, B, pB, conjB)
    return tensoralloc(ttype, structure, istemp)::ttype
end

end
