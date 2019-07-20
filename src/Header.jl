#=
This file is part of the Npy.jl package.

Copyright © 2019  Lukas Himbert

Npy.jl is free software:
you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3 of the License.

Npy.jl is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with Npy.jl.
If not, see https://www.gnu.org/licenses/.
=#


"""
Parse or write an .npy header

Note:
 - The parser assumes ASCII encoding and does not handle escape sequences (which is ok for .npy)
 - Performance is not necessary for this function, since .npy header dictionaries are very small.
"""
module Header

export ParseError, parseheader, writeheader


struct ParseError <: Exception
  msg :: String
end


@enum Endianness BigEndian LittleEndian NoEndian


function String(e :: Endianness)
  if e == BigEndian
    return ">"
  elseif e == LittleEndian
    return "<"
  elseif e == NoEndian
    return "|"
  end
  @assert false
end


function endianness(s :: AbstractString)
  if s == ">"
    return BigEndian
  elseif s == "<"
    return LittleEndian
  elseif s == "|"
    return NoEndian
  elseif s == "="
    return throw(ParseError("Host endianness is intentionally unsupported."))
  end
  return throw(ParseError("Unknown endianness '$s'."))
end


dtypes_s = [
  "b1",
  "i1",
  "i2",
  "i4",
  "i8",
  "u1",
  "u2",
  "u4",
  "u8",
  "f4",
  "f8",
  "c8",
  "c16",
]

dtypes_T = [
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

# These four cannot be read without parsing (and thus reading) the whole file (as far as the author knows).
# They are unsuited to being mmapped and thus are not supported.
unsupported_datatypes = Dict(
  "U3" => "UTF-8 String",
  "S3" => "String",
  "O" => "Object",
)

function T_from_dt(dtype :: AbstractString)
  for i in eachindex(dtypes_s)
    if dtypes_s[i] == dtype
      return dtypes_T[i]
    end
  end
  if dtype in keys(unsupported_datatypes)
    throw(ParseError("$(unsupported_datatypes[dtype]) data type is not supported."))
  end
  throw(ParseError("Unknown dtype '$dtype'."))
end


function dt_from_T(T :: DataType)
  for i in eachindex(dtypes_T)
    if dtypes_T[i] == T
      return dtypes_s[i]
    end
  end
  @assert false
end


struct NpyHeader
  data_offset :: BigInt
  shape :: Array{BigInt,1}
  datatype :: DataType
  endianness :: Endianness
  fortran_order :: Bool
end


"""`parseheader(s)`

Parses the .npy header.
Returns an `NpyHeader` on success, throw `ParseError` on failure.
"""
function parseheader(s)
  length(s) >= 16 || throw(ParseError("File too short to contain a header."))
  s[1:6] == b"\x93NUMPY" || throw(ParseError("Magic header not present."))
  version = (s[7], s[8])
  version[1] in [1, 2] || throw(ParseError("Unknown major version $version. Please update Npy.jl or report this error."))
  version[2] == 0 || throw(ParseError("Unknown minor version $version. Please update Npy.jl or report this error."))
  if version[1] == 1
    headersize = Int16(s[9]) + Int16(s[10]) << 8
    offset = 11
  elseif version[1] == 2
    headersize = Int32(s[9]) + Int32(s[10] << 8) + Int32(s[11] << 16) + Int32(s[12] << 24)
    offset = 13
  end
  (offset - 1 + headersize) % 16 == 0 || throw(ParseError("Header size is not a multiple of 16 bytes."))
  dict = parsedict(String(view(s, offset:offset-1+headersize)))
  for k in ["descr", "fortran_order", "shape"]
    haskey(dict, k) || throw(ParseError("Header dict is missing key $k."))
  end
  return NpyHeader(offset+headersize, dict["shape"], dict["descr"][2], dict["descr"][1], dict["fortran_order"])
end


#=
Note
----

This regex does not exactly match the required grammar.

Differences are:
- Comma delimiters are optional.
  They should be mandatory, but the trailing comma needs to be optional.
  It is impossible (?) to achieve both without repeating the key-value regexes.
  This would increase the regex by a lot and make capturing more difficult.
- Entries may be repeated; later entries override earlier ones.

Design note
-----------

Using this regex to parse the header dictionary is obviously terrible.
However, it compiles quite quickly (~1 second to parse a header for the first time).
As an alternative, parsing through recursive descent takes ~5 seconds to compile.
For an expected usage of opening only a few .npy files per script / REPL session, this can be a significant part of the run time, especially for analysis scripts.
This long compile time was deemed unacceptable for productive use.
Instead of using this regex, a parser (combinator) library might be used.
This would be much cleaner, but would also require a third-party dependency.

Rant
----

That this abomination of a regex is required (and still doesn't capture the grammar) shows how badly designed the .npy spec is.
Imnsho, it should exactly specify
- the string delimiters (single or double quote),
- that trailing commas are either mandatory or forbidden,
- the order in which the keys shall appear,
- that a plus-sign for the size is forbidden,
- that only spaces are allowed as whitespace (except for the final \n),
- where space is allowed or required (e. g. no space between keys and colons).
These would make parsing much more simple to implement without hindering reverse engineering of the format.
=#
dict_regex = r"""
  \s* { \s*
    (?:(?:
      (?# Parse 'descr', capture endianness, dtype )
      (?<descrdelim>['"])descr\g{descrdelim}
      \s* : \s*
      (?<descrvaldelim>['"])
        (?<endianness>[><|=])
        (?<dtype>[[:alnum:]]+)
      \g{descrvaldelim}

      (?# Parse shape, capture the shape-tuple.
          The entries are not parsed here because is not possible to capture a variable number of matches.
          They are matched seperately. )
    | (?<shapedelim>['"])shape\g{shapedelim}
        \s* : \s*
        (?<shape>
          \( \s*
            (\+?\d+ \s* (?:,\s*)?)*
          \)
        )

      (?# Parse fortran_order, capture the truthiness )
    | (?<fodelim>['"])fortran_order\g{fodelim}
        \s* : \s*
        (?<fortran_order>True|False)
    ) \s* (,\s*)? )*
  \s* } \s* \n
"""x :: Regex


function parsedict(s)
  m = match(dict_regex, s)
  m != nothing && m.offset == 1 || throw(ParseError("Header dictionary is not valid. If you are sure that it is, please report this error."))
  dict = Dict()
  if m[:endianness] != nothing
    @assert m[:dtype] != nothing
    T = T_from_dt(m[:dtype])
    e = endianness(m[:endianness])
    endianness != NoEndian || sizeof(T) == 1 || throw(ParseError("Data type is $T, but no endianness is given."))
    push!(dict, "descr" => (e, T))
  end
  if m[:fortran_order] != nothing
    push!(dict, "fortran_order" => m[:fortran_order] == "True")
  end
  if m[:shape] != nothing
    number_regex = r"\+?\d+"
    shape = collect(parse(BigInt, m2.match) for m2 in eachmatch(number_regex, m[:shape]))
    push!(dict, "shape" => shape)
  end
  return dict
end


function writeheader(endianness :: Endianness, T :: DataType, shape, fortran_order :: Bool)
  tuplestring = if length(shape) == 1; "($(shape[1]),)"; else string("(", join(shape, ", ", ","), ")"); end
  fortran_order_string = if fortran_order; "True"; else "False"; end
  if sizeof(T) == 1
    endianness = NoEndian
  end
  dictstring = Array{UInt8,1}("{'descr': '$(String(endianness))$(dt_from_T(T))', 'fortran_order': $(fortran_order_string), 'shape': $(tuplestring)}")
  length(dictstring) < 2^16 - 16 || error("For some unfathomable reason, the size of the header string exceeds 4 KiB.")
  if (length(dictstring) + 11) % 16 != 0 # Note: 11 = length(preheaderstring) + length(b"\n")
    padding = repeat(b" ", 16 - (length(dictstring) + 11) % 16)
  else
    padding = b""
  end
  headersize = length(dictstring) + length(padding) + 1
  preheaderstring = cat(b"\x93NUMPY\x01\x00", UInt8[headersize & 255, headersize >> 8], dims=1)
  ret = cat(preheaderstring, dictstring, padding, b"\n", dims=1)
  @assert length(ret) % 16 == 0
  @assert length(ret) < 2^16
  return ret
end


end
