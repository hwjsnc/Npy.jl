"""module Npy

Read and Write .npy files, using mmap().
See `NpyArray`.
"""
module Npy

import Base.isreadable
import Base.iswritable
import Base.size
import Base.IndexStyle
import Base.getindex
import Base.setindex!

import Mmap
import Mmap.sync!

include("Header.jl")

using .Header: Endianness, LittleEndian, BigEndian, NoEndian


export NpyArray, sync!


SupportedTypeUnion, SupportedTypesTypes = let
  supportedTypes = [
    Bool,
    Int8,
    Int16,
    Int32,
    Int64,
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    Float32,
    Float64,
    Complex{Float32},
    Complex{Float64},
  ]
  (
    eval(Expr(:curly, Union, (t for t in supportedTypes)...)),
    eval(Expr(:curly, Union, (Expr(:curly, Type, t) for t in supportedTypes)...)),
  )
end


#=
  NpyArray type and constructors
=#


"""`NpyArray{T,N} <: AbstractArray{T,N}`

A .npy data file, loaded into memory with `Mmap.mmap`, allowing data files which are larger than the main memory.
The following values are allowed for `T`: `Bool`, `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Float32`, `Float64`, `Complex{Float32}`, `Complex{Float64}`.

Changes to the `NpyArray` change the underlying file correspondingly (if it was opened with write permissions).
To force writing the changes to disk at a particular time, use `sync!`.
When no reference to a particular `NpyArray` remains, the memory is unmapped and all outstanding changes are written to disk at an unspecified future time.

    NpyArray(f :: IOStream)
    NpyArray(fn :: AbstractString; write :: Bool)

Read a .npy file `f` or `fn`.
The array entries may be changed if and only if `f` is writable or `write == true` (by default, `write == false`).
To check if an existing `NpyArray` is mutable, use the function `iswritable`.

    NpyArray(f :: IOStream, datatype, shape)
    NpyArray(fn :: AbstractString, datatype, shape)

Create or overwrite an existing file `f` or `fn`.
The NpyArray will have the given `shape` and `datatype` and will be writable.
`datatype` needs to be one of the allowed values for `T` listed above.
If the file did not exist prior to creating it, the array entries are initialized to zero.
Otherwise, no guarantee is made regarding the array values.

    NpyArray(f :: IOStream, a :: AbstractArray)
    NpyArray(fn :: IOStream, a :: AbstractArray)

Create or overwrite an existing file `f` or `fn` with values from `a`.
The `NpyArray` will be writable.
Note that the `NpyArray` must have standard (1-based) axes as of version 1.0.0.

    NpyArray(f :: Function, ...)

Delegating constructor for `do` notation.
Opens or creates an `NpyArray` (depending on further arguments) and calls f with it; then `sync!`s the `NpyArray`.


Examples
--------

```jldoctest
julia> tmpdir = mktempdir(); # create a temporary directory to create files in

julia> npy_arr = NpyArray(tmpdir * "/abc.npy", Float64[23.0 π; NaN exp(-42)]) # Create a new npy file; this may take a while to compile the first time.
2×2 NpyArray{Float64,2}:
 23.0      NaN
  3.14159    5.74952e-19

julia> sync!(npy_arr) # Force the changes to disk

julia> NpyArray(tmpdir * "/abc.npy") do npy_arr2
         # Open the file for reading and print the element type
         println(eltype(npy_arr2))
       end
Float64

julia> NpyArray(tmpdir * "/def.npy", Complex{Float32}, (2, 3)) do npy_arr3
         # Create a new npy array and initialize it
         for ind in CartesianIndices(npy_arr3)
           npy_arr3[ind] = 1.0 / (ind[1] + ind[2]im)
         end
         show(stdout, MIME("text/plain"), npy_arr3)
       end
2×3 NpyArray{Complex{Float32},2}:
  0.5-0.5im   0.4-0.2im       0.2-0.4im
 0.25-0.25im  0.1-0.3im  0.153846-0.230769im

julia> rm(tmpdir; recursive=true) # clean up
```
"""
struct NpyArray{T, N} <: AbstractArray{T,N}
  endianness :: Header.Endianness
  fortran_order :: Bool
  shape :: NTuple{N, UInt64}
  data :: Array{UInt8,1}
  data_offset :: UInt64
  writable :: Bool

  function NpyArray(f :: IOStream)
    data = Mmap.mmap(f, Array{UInt8,1}, fsize(f), 0; grow=false, shared=true)
    header = Header.parseheader(data)
    typeof(header) != Header.Error || error("Error at offset $(header.offset) while parsing file header: $(header.msg).")
    length(data) == BigInt(header.data_offset) - 1 + prod(BigInt.(header.shape)) * BigInt(sizeof(header.datatype)) || error("File size does not match header size + data size.")
    length(data) == UInt64(header.data_offset) - 1 + prod(UInt64.(header.shape)) * UInt64(sizeof(header.datatype)) || throw(OverflowError("Somehow, the array size is too large for UInt64."))
    return new{header.datatype, length(header.shape)}(header.endianness, header.fortran_order, tuple(UInt64.(header.shape)...), data, header.data_offset, iswritable(f))
  end
end


function NpyArray(f :: IOStream, type :: T, shape) where {T <: SupportedTypesTypes}
  # Write array, elements initialized to zero (unless the file already contains data)
  eltype(shape) <: Integer && all(x -> x > 0, shape) || error("Invalid dimensions")
  iswritable(f) || error("File is not writable")
  header = Header.writeheader(BigEndian, type, shape, false)
  filesize = prod(BigInt.(shape)) * sizeof(type) + length(header)
  truncate(f, filesize)
  seek(f, 0)
  write(f, header) == length(header) || error("Short write")
  return NpyArray(f) # parse the header again; this is inefficient, but who cares?
end


function NpyArray(f :: IOStream, arr :: AbstractArray{T,N}) where {T <: SupportedTypeUnion, N}
  # Save arr to a newly created file f
  iswritable(f) || error("File is not writable")
  header = Header.writeheader(BigEndian, T, size(arr), false)
  filesize = prod(BigInt.(size(arr))) * sizeof(T) + length(header) # XXX: Here we assume standard (1-based) array axes
  truncate(f, filesize)
  seek(f, 0)
  write(f, header) == length(header) || error("Short write")
  npy_arr = NpyArray(f)
  npy_arr .= arr
end


function NpyArray(fn :: AbstractString; write = false :: Bool)
  # Open existing file by name
  return open(fn, read=true, write=write) do f
    NpyArray(f)
  end
end


function NpyArray(fn :: AbstractString, args...)
  # Create file by name
  return open(fn, read=true, write=true, create=true) do f
    NpyArray(f, args...)
  end
end


# convenient context manager wrapper (for do-notation)
function NpyArray(f :: Function, args...; kwargs...)
  arr = NpyArray(args...; kwargs...)
  return try
    f(arr)
  finally
    sync!(arr)
  end
end


#=
  Useful file functions
=#


isreadable(arr :: NpyArray) = true
iswritable(arr :: NpyArray) = arr.writable
sync!(arr :: NpyArray) = Mmap.sync!(arr.data)


#=
  AbstractArray functions
=#


# Note:
# NpyArray does allow fast linear indexing, so it is tempting to set this to IndexLinear().
# Indeed, the getindex(::NpyArray, ::Integer) and setindex!(::NpyArray, ::Any, Integer) functions perform linear indexing into the mmapped memory.
# Moreover, the variadic getindex() and setindex!() functions rely on the linear indexing as well.
# However, setting IndexLinear() here would break broadcasting for C-contiguous NpyArrays.
# An example:
# If a = NpyArray(_, [1 2 3; 4 5 6]), then a[1] == a[1,1] == 1, a[2] == a[1,2] == 2, a[3] == a[1,3] == 3, etc.
# Whereas if b =     [1 2 3; 4 5 6], then  b[1] == b[1,1] == 1, b[2] == b[2,1] == 4, b[3] == b[1,2] == 2, etc.
# Similarly, broadcasting a .= b would set a[1,1] = 1, a[1,2] = 4, etc.
IndexStyle(arr :: NpyArray) = IndexCartesian()


size(arr :: NpyArray, args...) = arr.shape


function getindex(arr :: NpyArray{T,N}, i :: Integer) :: T where {T<:SupportedTypeUnion,N}
  x = unsafe_load(getptr(arr, i))
  return if arr.endianness == LittleEndian
    x_ = ltoh(x)
  elseif arr.endianness == BigEndian
    x_ = ntoh(x)
  else
    @assert sizeof(x) == 1
    x_ = x
  end
  return x_
end


function setindex!(arr :: NpyArray{T,N}, x, i :: Integer) :: T where {T<:SupportedTypeUnion,N}
  iswritable(arr) || throw(ReadOnlyMemoryError())
  x_ = convert(T, x)
  if arr.endianness == LittleEndian
    x__ = htol(x_)
  elseif arr.endianness == BigEndian
    x__ = hton(x_)
  else
    @assert sizeof(x_) == 1
    x__ = x_
  end
  unsafe_store!(getptr(arr, i), x__)
  return x_
end


function getindex(arr :: NpyArray{T,N}, i1 :: Integer, inds...) :: T where {T<:SupportedTypeUnion,N}
  return getindex(arr, flatten(arr, i1, inds...))
end


function setindex!(arr :: NpyArray{T,N}, x, i1 :: Integer, inds...) :: T where {T<:SupportedTypeUnion,N}
  return setindex!(arr, x, flatten(arr, i1, inds...))
end


#=
   Helper functions
=#


function getptr(arr :: NpyArray{T,N}, i :: Integer) :: Ptr{T} where {T<:SupportedTypeUnion,N}
  @boundscheck 1 <= i && i <= length(arr) || throw(BoundsError(arr, i))
  @boundscheck @assert checkbounds(Bool, arr.data, arr.data_offset + (i - 1) * sizeof(T))
  @boundscheck @assert checkbounds(Bool, arr.data, arr.data_offset + i * sizeof(T) - 1)
  return convert(Ptr{T}, pointer(arr.data) + arr.data_offset - 1 + (i - 1) * sizeof(T))
end


function fsize(f :: IOStream)
  pos = position(f)
  seekend(f)
  ret = position(f)
  seek(f, pos)
  return ret
end


function flatten(arr :: NpyArray, inds :: CartesianIndex)
  return flatten(arr, Tuple(inds)...)
end


function flatten(arr :: NpyArray, inds...)
  @boundscheck length(inds) == length(arr.shape) || throw(BoundsError(arr, inds))
  if arr.fortran_order
    ind = 0
    stride = 1
    for (i, x) in enumerate(inds)
      @boundscheck 1 <= x && x <= size(arr)[i] || throw(BoundsError(arr, inds))
      ind += (x - 1) * stride
      stride *= arr.shape[i]
    end
  else
    ind = 0
    stride = 1
    for (i, x) in reverse(collect(enumerate(inds)))
      @boundscheck 1 <= x && x <= size(arr)[i] || throw(BoundsError(arr, inds))
      ind += (x - 1) * stride
      stride *= arr.shape[i]
    end
  end
  return ind + 1
end


end
