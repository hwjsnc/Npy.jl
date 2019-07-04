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
  data_offset :: Int64
  shape :: Array{Int64,1}
  size :: Int64
  datatype :: DataType
  endianness :: Endianness # TODO: replace?
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
  dict = parsedict(view(s, offset:offset-1+headersize))
  typeof(dict) != Error || return dict
  for k in ["descr", "fortran_order", "shape"]
    haskey(dict, Array{UInt8,1}(k)) || return Error(offset, "Header dict is missing key $k.")
  end
  return NpyHeader(offset+headersize, dict[b"shape"], prod(dict[b"shape"]), dict[b"descr"][2], dict[b"descr"][1], dict[b"fortran_order"])
end


function parsedict(s)
  (off, _) = parsewhitespace(s, 1)
  (off, x) = expect(s, off, '{')
  typeof(x) != Error || return x
  (off, _) = parsewhitespace(s, off)
  dict = Dict()
  # TODO: parse entries, add to dict
  while off <= length(s) && Char(s[off]) != '}'
    off_ = off
    (off, p) = parsepair(s, off)
    typeof(p) != Error || return p
    if haskey(dict, p[1])
      return Error(off_, "Duplicate key \"$(String(p[1]))\"")
    end
    push!(dict, p)
    (off, _) = parsewhitespace(s, off)
    if off < length(s) && Char(s[off]) == ','
      (off, _) = parsewhitespace(s, off+1)
    else
      break
    end
  end
  (off, x) = expect(s, off, '}')
  typeof(x) != Error || return x;
  (off, _) = parsewhitespace(s, off) # We don't care about a trailing '\n'.
  off == length(s)+1 || return Error(1, "Junk character '$(Char(s[off]))' after end of header dictionary")
  return dict
end


function parsewhitespace(s, offset)
  i = offset
  while i <= length(s) && isspace(Char(s[i]))
    i += 1
  end
  return (i, nothing)
end


function expect(s, offset, c :: Char)
  offset <= length(s) || return (s, Error(offset, "Missing '$c'"))
  chr = Char(s[offset])
  if chr != c
    return (offset, Error(offset, "Expected '$c', got '$chr'"))
  end
  return (offset+1, chr)
end


function expect(s, offset, chars :: Array{Char,1})
  offset <= length(s) || return (offset, Error(offset, "Missing one of $chars"))
  chr = Char(s[offset])
  if !(chr in chars)
    return (offset, Error(offset, "Expected one of $chars, got '$chr'"))
  end
  return (offset+1, chr)
end


function parsestring(s, offset)
  offset <= length(s) || return (offset, Error(offset, "End of input while parsing a string"))
  off = offset
  (off, x) = expect(s, offset, ['\'', '"'])
  typeof(x) != Error || return (offset, x)
  delim = x
  for i in off:length(s)
    c = Char(s[i])
    if c == delim || !isascii(c) || !isprint(c) # Note: We do not handle escape sequences.
      (off, x) = expect(s, i, delim)
      typeof(x) != Error || return (offset, x)
      return (off, view(s, offset+1:i-1))
    end
  end
  return (offset, Error(length(s), "Unterminated string"))
end


function parsebool(s, offset)
  if s[offset:offset+3] == b"True"
    return (offset+4, true)
  elseif s[offset:offset+4] == b"False"
    return (offset+5, false)
  end
  return (offset, Error(offset, "Got neither True nor False while parsing a bool."))
end


function parseuint(s, offset)
  offset <= length(s) || return (offset, Error(offset, "End of input while parsing a number"))
  off = offset
  if Char(s[off]) == '+'
    off += 1
    off <= length(s) || return (offset, Error(off, "End of input while parsing a number"))
  end
  for i in off:length(s)
    if !isdigit(Char(s[i]))
      if i == off # no digit read!
        return (offset, Error(off, "Expected a digit, got '$(Char(s[i]))' while parsing a number"))
      else
        return (i, parse(BigInt, String(s[off:i-1])))
      end
    end
  end
  return (length(s)+1, parse(BigInt, String(s[off:length(s)])))
end


function parseuinttuple(s, offset)
  (off, x) = expect(s, offset, '(')
  typeof(x) != Error || return (offset, x)
  (off, _) = parsewhitespace(s, off)
  tup = Array{BigInt,1}()
  while true
    (off, x) = parseuint(s, off)
    if typeof(x) == Error
      break
    end
    push!(tup, x)
    (off, _) = parsewhitespace(s, off)
    if off <= length(s) && Char(s[off]) == ','
      (off, _) = parsewhitespace(s, off+1)
    else
      break
    end
  end
  (off, x) = expect(s, off, ')')
  typeof(x) != Error || return (offset, x)
  return (off, tup)
end


function parsepair(s, offset)
  (off, x) = parsestring(s, offset)
  typeof(x) != Error || return (offset, x)
  key = x
  if !(key in [b"descr", b"fortran_order", b"shape"])
    return (offset, Error(offset, "Invalid key \"$(String(key))\"")) # Should be offset, not off.
  end
  (off, _) = parsewhitespace(s, off)
  (off, c) = expect(s, off, ':')
  typeof(c) != Error || return (offset, c)
  (off, _) = parsewhitespace(s, off)
  if key == b"descr"
    off_ = off
    (off, val) = parsestring(s, off)
    typeof(val) != Error || return (offset, val)
    val = parsedescr(val, off_)
  elseif key == b"fortran_order"
    (off, val) = parsebool(s, off)
  elseif key == b"shape"
    (off, val) = parseuinttuple(s, off)
  else
    error("npy.jl BUG: invalid key")
  end
  typeof(val) != Error || return (offset, val)
  return (off, key => val)
end


"""`parsedescr(s, off)`

Parse a descr string.
Returns a tuple (e :: Endianness, type :: DataType) on success, or an Error on failure.
off should be the offset of the descr string (for debugging purposes).
"""
function parsedescr(s, off)
  endiannesses = Dict(
    '>' => BigEndian,
    '<' => LittleEndian,
    '|' => NoEndian,
    # Host endianness is a terrible choice for long-term storage of data.
    '=' => Error(off, "\"Host\" endianness is intentionally unsupported")
  )
  datatypes = Dict(
    b"b1" => Bool,
    b"i1" => Int8,
    b"i2" => Int16,
    b"i4" => Int32,
    b"i8" => Int64,
    b"u1" => UInt8,
    b"u2" => UInt16,
    b"u4" => UInt32,
    b"u8" => UInt64,
    b"f4" => Float32,
    b"f8" => Float64,
    b"c8" => Complex{Float32},
    b"c16" => Complex{Float64},
    # These four cannot be read without parsing (and thus reading) the whole file (as far as the author knows).
    b"U3" => Error(off, "UTF-8 descr is unsupported"),
    b"S3" => Error(off, "String descr is unsupported"),
    b"O" => Error(off, "Object descr is unsupported"),
  )
  length(s) >= 2 || return Error(off, "Invalid descr '$s' (too short)")
  datatype = get(datatypes, s[2:end], Error(off, "Unknown or invalid dtype '$(String(s[2:end]))'"))
  typeof(datatype) != Error || return datatype
  endianness = get(endiannesses, Char(s[1]), Error(off, "npy.jl BUG: unknown endianness '$(Char(s[1]))'"))
  typeof(endianness) != Error || return endianness
  endianness != NoEndian || datatype in [Bool, UInt8, Int8] || return Error(off, "dtype is $(String(s[2:end])), but no endianness is given")
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
  tuplestring = string("(", join(shape, ", "), ")")
  fortran_order_string = if fortran_order; "True"; else "False"; end
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
