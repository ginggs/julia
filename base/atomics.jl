# This file is a part of Julia. License is MIT: http://julialang.org/license

using Core.Intrinsics: llvmcall

import Base: setindex!, getindex, unsafe_convert

export
    Atomic,
    atomic_cas!,
    atomic_xchg!,
    atomic_add!, atomic_sub!,
    atomic_and!, atomic_nand!, atomic_or!, atomic_xor!,
    atomic_max!, atomic_min!,
    atomic_fence

# Disable 128-bit types on 32-bit Intel sytems due to LLVM problems;
# see <https://github.com/JuliaLang/julia/issues/14818>
if Base.ARCH === :i686
    const inttypes = (Int8, Int16, Int32, Int64,
                      UInt8, UInt16, UInt32, UInt64)
else
    const inttypes = (Int8, Int16, Int32, Int64, Int128,
                      UInt8, UInt16, UInt32, UInt64, UInt128)
end
const floattypes = (Float16, Float32, Float64)
# TODO: Support Bool, Ptr
const atomictypes = (inttypes..., floattypes...)
typealias IntTypes Union{inttypes...}
typealias FloatTypes Union{floattypes...}
typealias AtomicTypes Union{atomictypes...}

type Atomic{T<:AtomicTypes}
    value::T
    Atomic() = new(zero(T))
    Atomic(value) = new(value)
end

Atomic() = Atomic{Int}()

unsafe_convert{T}(::Type{Ptr{T}}, x::Atomic{T}) = convert(Ptr{T}, pointer_from_objref(x))
setindex!{T}(x::Atomic{T}, v) = setindex!(x, convert(T, v))

const llvmtypes = Dict{Type, ASCIIString}(
    Bool => "i1",
    Int8 => "i8", UInt8 => "i8",
    Int16 => "i16", UInt16 => "i16",
    Int32 => "i32", UInt32 => "i32",
    Int64 => "i64", UInt64 => "i64",
    Int128 => "i128", UInt128 => "i128",
    Float16 => "i16", # half
    Float32 => "float",
    Float64 => "double")
inttype{T<:Integer}(::Type{T}) = T
inttype(::Type{Float16}) = Int16
inttype(::Type{Float32}) = Int32
inttype(::Type{Float64}) = Int64

# All atomic operations have acquire and/or release semantics, depending on
# whether the load or store values. Most of the time, this is what one wants
# anyway, and it's only moderately expensive on most hardware.
for typ in atomictypes
    lt = llvmtypes[typ]
    ilt = llvmtypes[inttype(typ)]
    rt = VersionNumber(Base.libllvm_version) >= v"3.6" ? "$lt, $lt*" : "$lt*"
    irt = VersionNumber(Base.libllvm_version) >= v"3.6" ? "$ilt, $ilt*" : "$ilt*"
    if VersionNumber(Base.libllvm_version) >= v"3.8"
        @eval getindex(x::Atomic{$typ}) =
            llvmcall($"""
                     %rv = load atomic $rt %0 acquire, align $(WORD_SIZE ÷ 8)
                     ret $lt %rv
                     """, $typ, Tuple{Ptr{$typ}}, unsafe_convert(Ptr{$typ}, x))
        @eval setindex!(x::Atomic{$typ}, v::$typ) =
            llvmcall($"""
                     store atomic $lt %1, $lt* %0 release, align $(WORD_SIZE ÷ 8)
                     ret void
                     """, Void, Tuple{Ptr{$typ},$typ}, unsafe_convert(Ptr{$typ}, x), v)
    else
        if typ <: Integer
            @eval getindex(x::Atomic{$typ}) =
                llvmcall($"""
                         %rv = load atomic $rt %0 acquire, align $(WORD_SIZE ÷ 8)
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ}}, unsafe_convert(Ptr{$typ}, x))
            @eval setindex!(x::Atomic{$typ}, v::$typ) =
                llvmcall($"""
                         store atomic $lt %1, $lt* %0 release, align $(WORD_SIZE ÷ 8)
                         ret void
                         """, Void, Tuple{Ptr{$typ},$typ}, unsafe_convert(Ptr{$typ}, x), v)
        else
            @eval getindex(x::Atomic{$typ}) =
                llvmcall($"""
                         %iptr = bitcast $lt* %0 to $ilt*
                         %irv = load atomic $irt %iptr acquire, align $(WORD_SIZE ÷ 8)
                         %rv = bitcast $ilt %irv to $lt
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ}}, unsafe_convert(Ptr{$typ}, x))
            @eval setindex!(x::Atomic{$typ}, v::$typ) =
                llvmcall($"""
                         %iptr = bitcast $lt* %0 to $ilt*
                         %ival = bitcast $lt %1 to $ilt
                         store atomic $ilt %ival, $ilt* %iptr release, align $(WORD_SIZE ÷ 8)
                         ret void
                         """, Void, Tuple{Ptr{$typ},$typ}, unsafe_convert(Ptr{$typ}, x), v)
        end
    end
    # Note: atomic_cas! succeeded (i.e. it stored "new") if and only if the result is "cmp"
    if VersionNumber(Base.libllvm_version) >= v"3.5"
        if typ <: Integer
            @eval atomic_cas!(x::Atomic{$typ}, cmp::$typ, new::$typ) =
                llvmcall($"""
                         %rs = cmpxchg $lt* %0, $lt %1, $lt %2 acq_rel acquire
                         %rv = extractvalue { $lt, i1 } %rs, 0
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ},$typ,$typ},
                         unsafe_convert(Ptr{$typ}, x), cmp, new)
        else
            @eval atomic_cas!(x::Atomic{$typ}, cmp::$typ, new::$typ) =
                llvmcall($"""
                         %iptr = bitcast $lt* %0 to $ilt*
                         %icmp = bitcast $lt %1 to $ilt
                         %inew = bitcast $lt %2 to $ilt
                         %irs = cmpxchg $ilt* %iptr, $ilt %icmp, $ilt %inew acq_rel acquire
                         %irv = extractvalue { $ilt, i1 } %irs, 0
                         %rv = bitcast $ilt %irv to $lt
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ},$typ,$typ},
                         unsafe_convert(Ptr{$typ}, x), cmp, new)
        end
    else
        if typ <: Integer
            @eval atomic_cas!(x::Atomic{$typ}, cmp::$typ, new::$typ) =
                llvmcall($"""
                         %rv = cmpxchg $lt* %0, $lt %1, $lt %2 acq_rel
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ},$typ,$typ},
                         unsafe_convert(Ptr{$typ}, x), cmp, new)
        else
            @eval atomic_cas!(x::Atomic{$typ}, cmp::$typ, new::$typ) =
                llvmcall($"""
                         %iptr = bitcast $lt* %0 to $ilt*
                         %icmp = bitcast $lt %1 to $ilt
                         %inew = bitcast $lt %2 to $ilt
                         %irv = cmpxchg $ilt* %iptr, $ilt %icmp, $ilt %inew acq_rel
                         %rv = bitcast $ilt %irv to $lt
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ},$typ,$typ},
                         unsafe_convert(Ptr{$typ}, x), cmp, new)
        end
    end
    for rmwop in [:xchg, :add, :sub, :and, :nand, :or, :xor, :max, :min]
        rmw = string(rmwop)
        fn = symbol("atomic_", rmw, "!")
        if (rmw == "max" || rmw == "min") && typ <: Unsigned
            # LLVM distinguishes signedness in the operation, not the integer type.
            rmw = "u" * rmw
        end
        if typ <: Integer
            @eval $fn(x::Atomic{$typ}, v::$typ) =
                llvmcall($"""
                         %rv = atomicrmw $rmw $lt* %0, $lt %1 acq_rel
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ}, $typ}, unsafe_convert(Ptr{$typ}, x), v)
        else
            rmwop == :xchg || continue
            @eval $fn(x::Atomic{$typ}, v::$typ) =
                llvmcall($"""
                         %iptr = bitcast $lt* %0 to $ilt*
                         %ival = bitcast $lt %1 to $ilt
                         %irv = atomicrmw $rmw $ilt* %iptr, $ilt %ival acq_rel
                         %rv = bitcast $ilt %irv to $lt
                         ret $lt %rv
                         """, $typ, Tuple{Ptr{$typ}, $typ}, unsafe_convert(Ptr{$typ}, x), v)
        end
    end
end

# Provide atomic floating-point operations via atomic_cas!
const opnames = Dict{Symbol, Symbol}(:+ => :add, :- => :sub)
for op in [:+, :-, :max, :min]
    opname = get(opnames, op, op)
    @eval function $(symbol("atomic_", opname, "!")){T<:FloatTypes}(var::Atomic{T}, val::T)
        IT = inttype(T)
        old = var[]
        while true
            new = $op(old, val)
            cmp = old
            old = atomic_cas!(var, cmp, new)
            reinterpret(IT, old) == reinterpret(IT, cmp) && return new
        end
    end
end

# Use sequential consistency for a memory fence. There are algorithms where this
# is needed (where an acquire/release ordering is insufficient). This is likely
# a very expensive operation. Given that all other atomic operations have
# already acquire/release semantics, explicit fences should not be necessary in
# most cases.
atomic_fence() = llvmcall("""
                          fence seq_cst
                          ret void
                          """, Void, Tuple{})
