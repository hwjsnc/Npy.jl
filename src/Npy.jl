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


"""TODO: document this

automatically unmapped when there is no more reference
to sync changes to the file, use sync!
"""
struct NpyArray{T, N} <: AbstractArray{T,N}
  endianness :: Header.Endianness
  fortran_order :: Bool
  shape :: NTuple{N, UInt64}
  data :: Array{UInt8,1} # Mmapped file
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
  filesize = prod(BigInt.(size(arr))) * sizeof(T) + length(header)
  truncate(f, filesize)
  seek(f, 0)
  write(f, header) == length(header) || error("Short write")
  npy_arr = NpyArray(f)
  npy_arr .= arr
end


function NpyArray(fn :: AbstractString; write = false :: Bool)
  return open(fn, read=true, write=write) do f
    NpyArray(f)
  end
end


function NpyArray(fn :: AbstractString, args...)
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
    close(arr)
  end
end


# Useful file functions
isreadable(arr :: NpyArray) = true
iswritable(arr :: NpyArray) = arr.writable
sync!(arr :: NpyArray) = Mmap.sync!(arr.data)


# AbstractArray functions
IndexStyle(arr :: NpyArray) = IndexLinear()
size(arr :: NpyArray, args...) = arr.shape

function getindex(arr :: NpyArray{T,N}, i :: Integer) :: T where {T<:SupportedTypeUnion,N}
  x = unsafe_load(getptr(arr, i))
  return if arr.endianness == LittleEndian
    x_ = ltoh(x)
  else
    x_ = ntoh(x)
  end
  return x_
end

function getindex(arr :: NpyArray{T,N}, i1 :: Integer, inds...) :: T where {T<:SupportedTypeUnion,N}
  return getindex(arr, flatten(arr, i1, inds...))
end

function setindex!(arr :: NpyArray{T,N}, x, i :: Integer) :: T where {T<:SupportedTypeUnion,N}
  iswritable(arr) || ReadOnlyMemoryError()
  x_ = convert(T, x)
  if arr.endianness == LittleEndian
    x__ = htol(x_)
  else
    x__ = hton(x_)
  end
  unsafe_store!(getptr(arr, i), x__)
  return x_
end

function setindex!(arr :: NpyArray{T,N}, x, i1 :: Integer, inds...) :: T where {T<:SupportedTypeUnion,N}
  return setindex!(arr, flatten(arr, i1, inds...))
end


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
