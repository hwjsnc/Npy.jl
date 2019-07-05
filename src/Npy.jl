"""TODO: document this
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
struct NpyArray{T, N, ARR <: AbstractArray} <: AbstractArray{T,N}
  endianness :: Header.Endianness
  fortran_order :: Bool
  shape
  data :: Array{UInt8,1} # Mmapped file
  arr :: ARR # Note: This array is a view of data, excluding the header; it should _not_ be used directly by users of the library, as no endianness conversion is performed!
  writable :: Bool

  function NpyArray(f :: IOStream)
    data = Mmap.mmap(f, Array{UInt8,1}, fsize(f), 0; grow=false, shared=true)
    header = Header.parseheader(data)
    typeof(header) != Header.Error || error("Error at offset $(header.offset) while parsing file header: $(header.msg).")
    length(data) == BigInt(header.data_offset) - 1 + prod(header.shape) * sizeof(header.datatype) || error("File size does not match header size + data size.")
    #arr_ = reinterpret(header.datatype, view(data, header.data_offset:length(data)))
    #shape = Array{Int,1}(header.shape)
    #if header.fortran_order
    #  arr = reshape(arr_, shape...)
    #else
    #  arr = permutedims(reshape(arr_, reverse(shape)...), length(shape):-1:1)
    #end
    arr = reinterpret(header.datatype, view(data, header.data_offset:length(data)))
    return new{header.datatype, length(header.shape), typeof(arr)}(header.endianness, header.fortran_order, tuple(Int64.(header.shape)...), data, arr, iswritable(f))
  end
end


function NpyArray(f :: IOStream, type :: T, shape) where {T <: SupportedTypesTypes}
  # Write array, elements initialized to zero (unless the file already contains data)
  @assert eltype(shape) isa Integer && all(x -> x > 0, shape)
  header = Header.writeheader(BigEndian, type, shape, false)
  filesize = prod(BigInt.(shape)) * sizeof(T) + length(header)
  truncate(f, filesize)
  seek(f, 0)
  write(f, header) == length(header) || error("Short write")
  return NpyArray(f, writable=true) # parse the header again; this is inefficient, but who cares?
end


function NpyArray(f :: IOStream, arr :: Array{T,N}) where {T <: SupportedTypeUnion, N}
  # Save arr to a newly created file f
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

function getindex(arr :: NpyArray{T,N,ARR}, i :: Integer) :: T where {T<:SupportedTypeUnion,N,ARR}
  i <= i && i <= length(arr) || throw(BoundsError(arr, i))
  return if arr.endianness == LittleEndian
    ltoh(getindex(arr.arr, i))
  else
    ntoh(getindex(arr.arr, i))
  end
end

function getindex(arr :: NpyArray{T,N,ARR}, inds...) :: T where {T<:SupportedTypeUnion,N,ARR}
  return getindex(arr, flatten(arr, inds...))
end

function setindex!(arr :: NpyArray{T,N,ARR}, x, i :: Integer) :: T where {T<:SupportedTypeUnion,N,ARR}
  i <= i && i <= length(arr) || throw(BoundsError(arr, i))
  if arr.endianness == LittleEndian
    setindex!(arr.arr, htol(convert(eltype(arr), x)), i)
  else
    setindex!(arr.arr, hton(convert(eltype(arr), x)), i)
  end
  return x
end

function setindex!(arr :: NpyArray{T,N,ARR}, x, inds...) :: T where {T<:SupportedTypeUnion,N,ARR}
  return setindex!(arr, flatten(arr, inds...))
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
  length(inds) == length(arr.shape) || throw(BoundsError(arr, inds))
  if arr.fortran_order
    ind = 0
    stride = 1
    for (i, x) in enumerate(inds)
      1 <= x && x <= size(arr)[i] || throw(BoundsError(arr, inds))
      ind += (x - 1) * stride
      stride *= arr.shape[i]
    end
  else
    ind = 0
    stride = 1
    for (i, x) in reverse(collect(enumerate(inds)))
      1 <= x && x <= size(arr)[i] || throw(BoundsError(arr, inds))
      ind += (x - 1) * stride
      stride *= arr.shape[i]
    end
  end
  return ind + 1
end


end
