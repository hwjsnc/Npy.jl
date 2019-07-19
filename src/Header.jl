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


function parsedict(s)
  (off, _) = parsewhitespace(s, 1)
  (off, x) = expect(s, off, '{')
  typeof(x) != Error || return x
  (off, _) = parsewhitespace(s, off)
  dict = Dict()
  # TODO: parse entries, add to dict
  while off <= length(s) && s[off] != '}'
    off_ = off
    (off, p) = parsepair(s, off)
    typeof(p) != Error || return p
    if haskey(dict, p[1])
      return Error(off_, "Duplicate key \"$(p[1])\"")
    end
    push!(dict, p)
    (off, _) = parsewhitespace(s, off)
    if off < length(s) && s[off] == ','
      (off, _) = parsewhitespace(s, off+1)
    else
      break
    end
  end
  (off, x) = expect(s, off, '}')
  typeof(x) != Error || return x;
  (off, _) = parsewhitespace(s, off) # We don't care about a trailing '\n'.
  off == length(s)+1 || return Error(1, "Junk character '$(s[off])' after end of header dictionary")
  return dict
end


function parsewhitespace(s, offset)
  i = offset
  while i <= length(s) && isspace(s[i])
    i += 1
  end
  return (i, nothing)
end


function expect(s, offset, c :: Char)
  offset <= length(s) || return (s, Error(offset, "Missing '$c'"))
  chr = s[offset]
  if chr != c
    return (offset, Error(offset, "Expected '$c', got '$chr'"))
  end
  return (offset+1, chr)
end


function parsestring(s, offset) # TODO: remove
  m = match(r"""('|")(?<key>[^'"]*)\1""", s, offset) # Note: We do not handle escape sequences.
  m != nothing && m.offset == offset || return (offset, Error(offset, "Expected a String"))
  return (offset + length(m.match), m[:key])
end


function parsebool(s, offset) # TODO: remove
  m = match(r"(True|False)", s, offset)
  m != nothing && m.offset == offset || return (offset, Error(offset, "Got neither True nor False while parsing a bool."))
  return (offset + length(m.match), m[1] == "True")
end


function parseuint(s, offset) # TODO: remove
  m = match(r"\+?\d+", s, offset)
  m != nothing && m.offset == offset || return (offset, Error(offset, "Expected a number"))
  return (offset+length(m.match), parse(BigInt, m.match))
end


function parseuinttuple(s, offset) # TODO: remove
  m = match(r"\(\s*(\+?\d+)?\s*(,\s*\+?\d+\s*)*\s*,?\s*\)", s, offset) # match the whole tuple
  m != nothing && m.offset == offset || return (offset, Error(offset, "Expected a tuple of ints"))
  tup = collect(parse(BigInt, m2.match) for m2 in eachmatch(r"\+?\d+", m.match)) # Match each entry, convert to BigInt
  return (offset + length(m.match), tup)
end


function parsepair(s, offset)
  descr_regex = r"""
    ('|")descr\1
    \s* : \s*
    ('|")
      (?<endianness>[><|=])
      (?<dtype>[[:alnum:]]+)
    \2
  """x
  fortran_order_regex = r"""
    ('|")fortran_order\1
    \s* : \s*
    (?<val>True|False)
  """x
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
  """x
  endiannesses = Dict(
    ">" => BigEndian,
    "<" => LittleEndian,
    "|" => NoEndian,
    # Host endianness is a terrible choice for long-term storage of data.
    "=" => Error(offset, "\"Host\" endianness is intentionally unsupported")
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
    "U3" => Error(offset, "UTF-8 descr is unsupported"),
    "S3" => Error(offset, "String descr is unsupported"),
    "O" => Error(offset, "Object descr is unsupported"),
  )
  if (m = match(descr_regex, s, offset)) != nothing && m.offset == offset
    datatype = get(datatypes, m[:dtype], Error(offset, "Unknown or invalid dtype '$(m[:dtype])'"))
    typeof(datatype) != Error || return (offset, datatype)
    endianness = get(endiannesses, m[:endianness], Error(offset, "npy.jl BUG: unknown endianness '$(m[:endianness])'"))
    typeof(endianness) != Error || return (offset, endianness)
    endianness != NoEndian || sizeof(datatype) == 1 || return Error(offset, "dtype is $(String(m[:dtype])), but no endianness is given")
    return (offset + length(m.match), "descr" => (endianness, datatype))
  elseif (m = match(fortran_order_regex, s, offset)) != nothing && m.offset == offset
    return (offset + length(m.match), "fortran_order" => (m[:val] == "True"))
  elseif (m = match(shape_regex, s, offset)) != nothing && m.offset == offset
    number_regex = r"\+?\d+"
    tup = collect(parse(BigInt, m2.match) for m2 in eachmatch(number_regex, m[:shape]))
    return (offset + length(m.match), "shape" => tup)
  end
  return (offset, Error(offset, "Invalid key-value pair"))
end


"""`parsedescr(s, off)`

Parse a descr string.
Returns a tuple (e :: Endianness, type :: DataType) on success, or an Error on failure.
off should be the offset of the descr string (for debugging purposes).
"""
function parsedescr(s, off) # TODO: remove
  endiannesses = Dict(
    '>' => BigEndian,
    '<' => LittleEndian,
    '|' => NoEndian,
    # Host endianness is a terrible choice for long-term storage of data.
    '=' => Error(off, "\"Host\" endianness is intentionally unsupported")
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
  length(s) >= 2 || return Error(off, "Invalid descr '$s' (too short)")
  datatype = get(datatypes, s[2:end], Error(off, "Unknown or invalid dtype '$(String(s[2:end]))'"))
  typeof(datatype) != Error || return datatype
  endianness = get(endiannesses, s[1], Error(off, "npy.jl BUG: unknown endianness '$(s[1])'"))
  typeof(endianness) != Error || return endianness
  endianness != NoEndian || sizeof(datatype) == 1 || return Error(off, "dtype is $(String(s[2:end])), but no endianness is given")
  return (endianness, datatype)
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
