"""TODO: document this
"""
module Npy

import Base.isreadable
import Base.iswritable
import Base.size
import Base.IndexStyle
import Base.getindex
import Base.setindex!

import LinearAlgebra # Transpose
import Mmap
import Mmap.sync!

include("Header.jl")

using .Header: Endianness, LittleEndian, BigEndian, NoEndian


export NpyArray, sync!


SupportedTypeUnion = let
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
  eval(Expr(:curly, Union, (t for t in supportedTypes)...))
end


"""TODO: document this

automatically unmapped when there is no more reference
to sync changes to the file, use sync!
"""
struct NpyArray{T, N, ARR <: AbstractArray} <: AbstractArray{T,N}
  endianness :: Header.Endianness
  data :: Array{UInt8,1} # Mmapped file
  arr :: ARR # Note: This array is a view of data (or a transposed view, in the case of C-ordering), excluding the header; it should _not_ be used directly by users of the library, as no endianness conversion is performed!
  writable :: Bool

  function NpyArray(f :: IOStream)
    data = Mmap.mmap(f, Array{UInt8,1}, fsize(f), 0; grow=false, shared=true)
    header = Header.parseheader(data)
    typeof(header) != Header.Error || error("Error at offset $(header.offset) while parsing file header: $(header.msg).")
    length(data) == BigInt(header.data_offset) - 1 + prod(header.shape) * sizeof(header.datatype) || error("File size does not match header size + data size.")
    arr_ = reinterpret(header.datatype, view(data, header.data_offset:length(data)))
    shape = Array{Int,1}(header.shape)
    if header.fortran_order
      arr = reshape(arr_, shape...)
    else
      arr = LinearAlgebra.transpose(reshape(arr_, reverse(shape)...))
    end
    return new{header.datatype, length(shape), typeof(arr)}(header.endianness, data, arr, iswritable(f))
  end
end


function NpyArray(f :: IOStream, type :: T, shape :: Tuple) where {T <: SupportedTypeUnion}
  # TODO: write array; data filled with zeros (unless file exists)
end


function NpyArray(f :: IOStream, arr :: Array{T,N}) where {T <: SupportedTypeUnion, N}
  # TODO: write array; data filled with zeros (unless file exists)
end


function NpyArray(fn :: AbstractString; write = false :: Bool)
  return open(fn, read=true, write=write) do f
    NpyArray(f)
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
IndexStyle(arr :: NpyArray) = IndexCartesian
size(arr :: NpyArray, args...) = Base.size(arr.arr)

function getindex(arr :: NpyArray{T,N,ARR}, inds...) :: T where {T<:SupportedTypeUnion,N,ARR}
  return if arr.endianness == LittleEndian
    ltoh(getindex(arr.arr, inds...))
  else
    ntoh(getindex(arr.arr, inds...))
  end
end

function setindex!(arr :: NpyArray{T,N,ARR}, x, inds...) :: T where {T<:SupportedTypeUnion,N,ARR}
  if arr.endianness == LittleEndian
    setindex!(arr.arr, htol(convert(eltype(arr), x)), inds...)
  else
    setindex!(arr.arr, hton(convert(eltype(arr), x)), inds...)
  end
  return x
end


function fsize(f :: IOStream)
  pos = position(f)
  seekend(f)
  ret = position(f)
  seek(f, pos)
  return ret
end


end
