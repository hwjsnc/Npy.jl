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


descr_regex = r"""
  ('|")descr\1
  \s* : \s*
  ('|")
    (?<endianness>[><|=])
    (?<dtype>[[:alnum:]]+)
  \2
"""x :: Regex
fortran_order_regex = r"""
  ('|")fortran_order\1
  \s* : \s*
  (?<val>True|False)
"""x :: Regex
shape_regex = r"""
  ('|")shape\1
  \s* : \s*
  (?<shape>
    \(
      \s*
      (\+?\d+)?
      \s*
      (, \s* \+?\d+ \s* )
      *\s*
      (,\s*)?
    \)
  )
"""x :: Regex

function parsedict(s)
  m = match(r"\s*{\s*", s)
  m != nothing && m.offset == 1 || return Error(1, "Expected '{' at beginning of header dictionary.")
  off = length(m.match) + 1
  dict = Dict()
  while off <= length(s) && s[off] != '}'
    off_ = off
    if (m = match(descr_regex, s, off)) != nothing && m.offset == off
      endiannesses = Dict(
        ">" => BigEndian,
        "<" => LittleEndian,
        "|" => NoEndian,
        # Host endianness is a terrible choice for long-term storage of data.
        "=" => Error(off, "\"Host\" endianness is intentionally unsupported")
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
        "U3" => Error(off, "UTF-8 descr is unsupported"),
        "S3" => Error(off, "String descr is unsupported"),
        "O" => Error(off, "Object descr is unsupported"),
      )
      datatype = get(datatypes, m[:dtype], Error(off, "Unknown or invalid dtype '$(m[:dtype])'"))
      typeof(datatype) != Error || return datatype
      endianness = get(endiannesses, m[:endianness], Error(off, "npy.jl BUG: unknown endianness '$(m[:endianness])'"))
      typeof(endianness) != Error || return endianness
      endianness != NoEndian || sizeof(datatype) == 1 || return Error(off, "dtype is $(String(m[:dtype])), but no endianness is given")
      key = "descr"
      val = (endianness, datatype)
      off += length(m.match)
    elseif (m = match(fortran_order_regex, s, off)) != nothing && m.offset == off
      key = "fortran_order"
      val = (m[:val] == "True")
      off += length(m.match)
    elseif (m = match(shape_regex, s, off)) != nothing && m.offset == off
      number_regex = r"\+?\d+"
      key = "shape"
      val = collect(parse(BigInt, m2.match) for m2 in eachmatch(number_regex, m[:shape]))
      off += length(m.match)
    else
      return Error(off, "Invalid key-value pair")
    end
    #!haskey(dict, key) || return Error(off_, "Duplicate key \"$key\"") # XXX
    push!(dict, key => val)
    m = match(r"\s*(,\s*)?", s, off)
    @assert m != nothing && m.offset == off
    off += length(m.match)
    if isempty(m.captures) # no ","
      break
    end
  end
  m = match(r"\s*}\s*\n"s, s, off)
  m != nothing && m.offset == off || return Error(off, "Header dictionary not closed correctly")
  off += length(m.match)
  off == length(s)+1 || return Error(1, "Junk character '$(s[off])' after end of header dictionary")
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
