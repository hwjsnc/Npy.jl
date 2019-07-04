"""TODO: document this
"""
module Npy

import LinearAlgebra # Transpose

include("Header.jl")

using .Header: Endianness, LittleEndian, BigEndian, NoEndian

export NpyArray


SupportedTypesType = let
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
  eval(Expr(:curly, Union, (Expr(:curly, Type, t) for t in supportedTypes)...))
end


"""TODO: document this
"""
struct NpyArray{T, DIM} <: AbstractArray{T,DIM}
  endianness :: Header.Endianness
  data :: Array{UInt8,1} # Mmapped file
  arr :: Union{Array{T,DIM},LinearAlgebra.Transpose{T,Array{T,DIM}}} # Note: This array is a view of data (or a transposed view, in the case of C-ordering), excluding the header; it should _not_ be used directly by users of the library, as no endianness conversion is performed!
  readable :: Bool
end


function NpyArray(f :: IOStream, writable = false :: Bool)
  # TODO
# TODO: error message: "Error while parsing file header: $err.val at offset $err.offset"
end


function NpyArray(f :: IOStream, type :: SupportedTypesType, shape :: Tuple; fortran_order = false :: Bool, endianness = BigEndian :: Endianness) # TODO: maybe don't allow changing fortran_order and endianness?
  # TODO
end


function NpyArray(f :: IOStream, arr :: Array{T,DIM}) where {T <: SupportedTypesType, DIM}
  # TODO
end


# convenient context manager wrapper (for do-notation)
function NpyArray(f :: Function, args...)
  arr = NpyArray(args...)
  try
    f(arr)
  finally
    close(arr)
  end
end


function close(arr :: NpyArray{T,DIM}) where {T,DIM}
  if isreadable(arr)
    sync!(arr)
  end
  # TODO: munmap()!
end


# Useful file functions
isreadable(arr :: NpyArray) = true
iswritable(arr :: NpyArray) = false


# Delegating array functions
axes(arr :: NpyArray) = axes(arr.arr)
getindex(arr :: NpyArray, inds...) = if arr.endianness == Header.BigEndian; ntoh.(getindex(arr.arr, inds)); else ltoh.(getindex(arr.arr, inds)); end
setindex!(arr :: NpyArray, x, inds...) = setindex!(arr, if arr.endianness == Header.BigEndian; hton.(x); else ntoh.(x); end, inds...);


end
