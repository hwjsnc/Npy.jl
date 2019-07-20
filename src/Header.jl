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
 - All functions return either a tuple (remaining input, result) on success, or a tuple (original input, err-struct) on failure, unless noted otherwise.
"""
module Header

export Error, parseheader, writeheader


struct Error
  offset :: UInt64
  msg :: String
end


@enum Endianness BigEndian LittleEndian NoEndian


struct NpyHeader
  data_offset :: BigInt
  shape :: Array{BigInt,1}
  datatype :: DataType
  endianness :: Endianness
  fortran_order :: Bool
end


"""`parseheader(s)`

Parses the .npy header.
Returns a tuple (data_offset, header_dict :: NpyHeader) on success, (error_offset, error :: Error) on failure.
Entries of the header
"""
function parseheader(s)
  length(s) >= 16 || return Error(0, "File too short to contain a header")
  s[1:6] == b"\x93NUMPY" || return Error(0, "Magic header not present")
  version = (s[7], s[8])
  version[1] in [1, 2] || return Error(7, "Unknown major version $version")
  version[2] == 0 || return Error(8, "Unknown minor version $version")
  if version[1] == 1
    headersize = Int16(s[9]) + Int16(s[10]) << 8
    offset = 11
  elseif version[1] == 2
    headersize = Int32(s[9]) + Int32(s[10] << 8) + Int32(s[11] << 16) + Int32(s[12] << 24)
    offset = 13
  end
  (offset - 1 + headersize) % 16 == 0 || return (0, Error(0, "Header size is not a multiple of 16 bytes"))
  dict = parsedict(String(view(s, offset:offset-1+headersize)))
  typeof(dict) != Error || return dict
  for k in ["descr", "fortran_order", "shape"]
    haskey(dict, k) || return Error(offset, "Header dict is missing key $k.")
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
  m != nothing && m.offset == 1 || return Error(1, "Invalid header dictionary.")

  dict = Dict()
  if m[:endianness] != nothing
    @assert m[:dtype] != nothing
    endiannesses = Dict(
      ">" => BigEndian,
      "<" => LittleEndian,
      "|" => NoEndian,
      # Host endianness is a terrible choice for long-term storage of data.
      "=" => Error(1, "\"Host\" endianness is intentionally unsupported")
    )
    datatypes = Dict(
      "b1" => Bool,
      "i1" => Int8,
      "i2" => Int16,
      "i4" => Int32,
      "i8" => Int64,
      "u1" => UInt8,
      "u2" => UInt16,
      "u4" => UInt32,
      "u8" => UInt64,
      "f4" => Float32,
      "f8" => Float64,
      "c8" => Complex{Float32},
      "c16" => Complex{Float64},
      # These four cannot be read without parsing (and thus reading) the whole file (as far as the author knows).
      "U3" => Error(1, "UTF-8 descr is unsupported"),
      "S3" => Error(1, "String descr is unsupported"),
      "O" => Error(1, "Object descr is unsupported"),
    )
    datatype = get(datatypes, m[:dtype], Error(1, "Unknown or invalid dtype '$(m[:dtype])'"))
    typeof(datatype) != Error || return datatype
    endianness = get(endiannesses, m[:endianness], Error(1, "npy.jl BUG: unknown endianness '$(m[:endianness])'"))
    typeof(endianness) != Error || return endianness
    endianness != NoEndian || sizeof(datatype) == 1 || return Error(1, "dtype is $(String(m[:dtype])), but no endianness is given")
    push!(dict, "descr" => (endianness, datatype))
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


function writeheader(endianness :: Endianness, datatype :: DataType, shape, fortran_order :: Bool)
  endiannesses = Dict(
    BigEndian => '>',
    LittleEndian => '<',
    NoEndian => '|',
  )
  datatypes = Dict(
    Bool => "b1",
    Int8 => "i1",
    Int16 => "i2",
    Int32 => "i4",
    Int64 => "i8",
    UInt8 => "u1",
    UInt16 => "u2",
    UInt32 => "u4",
    UInt64 => "u8",
    Float32 => "f4",
    Float64 => "f8",
    Complex{Float32} => "c8",
    Complex{Float64} => "c16",
  )
  tuplestring = if length(shape) == 1; "($(shape[1]),)"; else string("(", join(shape, ", ", ","), ")"); end
  fortran_order_string = if fortran_order; "True"; else "False"; end
  if sizeof(datatype) == 1
    endianness = NoEndian
  end
  dictstring = Array{UInt8,1}("{'descr': '$(endiannesses[endianness])$(datatypes[datatype])', 'fortran_order': $(fortran_order_string), 'shape': $(tuplestring)}")
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
