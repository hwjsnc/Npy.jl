"""
Parse an .npy header

Note:
 - The parser assumes ASCII encoding and does not handle escape sequences (which is ok for .npy)
 - Performance is not necessary for this function, since .npy header dictionaries are very small.
 - All functions return either a tuple (remaining input, result) on success, or a tuple (original input, err-struct) on failure, unless noted otherwise.
"""
module ParseHeader

export Error, parseheader


struct Error
  offset :: UInt64
  msg :: String
end


@enum Endianness BigEndian LittleEndian NoEndian


struct Header
  data_offset :: Int64
  shape :: Array{Int64,1}
  size :: Int64
  datatype :: DataType
  endianness :: Endianness # TODO: replace?
  fortran_order :: Bool
end


"""`parseheader(s)`

Parses the .npy header.
Returns a tuple (data_offset, header_dict :: Header) on success, (error_offset, error :: Error) on failure.
Entries of the header
"""
function parseheader(s)
  length(s) >= 16 || return Error(0, "File too short to contain a header")
  s[1:6] == b"\x93NUMPY" || return Error(0, "Magic header not present")
  version = (s[7], s[8])
  version[1] in [1, 2] || return Error(7, "Unknown major version $version")
  version[2] == 0 || return Error(8, "Unknown minor version $version")
  if version[0] == 1
    headersize = Int16(s[9]) + Int16(s[10] << 8)
    offset = 11
  elseif version[0] == 2
    headersize = Int32(s[9]) + Int32(s[10] << 8) + Int32(s[11] << 16) + Int32(s[12] << 24)
    offset = 13
  end
  if (offset + headersize) % 16 != 0
    return (0, Error(0, "Header size is not a multiple of 16 bytes"))
  end
  (off, dict) = parsedict(view(s, offset, headersize), 1)
  typeof(dict) != Error || return (off, dict)
  for i in off:offset+headersize # We don't care about a trailing '\n'.
    if !isspace(Char(s[i]))
      return Error(i, "Junk character '$(Char(s[i]))' after dtype")
    end
  end
  # TODO: check dict!
  #return (offset + headersize + 1, Header(...))
end


function parsedict(s, offset)
  (off, _) = parsewhitespace(s, offset)
  (off, x) = expect(s, off, '{')
  typeof(x) != Error || return (offset, x)
  (off, _) = parsewhitespace(s, off)
  dict = Dict()
  # TODO: parse entries, add to dict
  while off <= length(s) && Char(s[off]) != '}'
    off_ = off
    (off, p) = parsepair(s, off)
    typeof(p) != Error || return (offset, p)
    if haskey(dict, p[1])
      return Error(off_, "Duplicate key \"$(String(p[1]))\"")
    end
    push!(dict, p) # XXX: We might check if the key exists already
    (off, _) = parsewhitespace(s, off)
    if off < length(s) && Char(s[off]) == ','
      (off, _) = parsewhitespace(s, off+1)
    else
      break
    end
  end
  (off, x) = expect(s, off, '}')
  typeof(x) != Error || return (offset, x);
  return (off, dict)
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
  if !(key in [b"dtype", b"fortran_order", b"shape"])
    return (offset, Error(offset, "Invalid key \"$(String(key))\"")) # Should be offset, not off.
  end
  (off, _) = parsewhitespace(s, off)
  (off, c) = expect(s, off, ':')
  typeof(c) != Error || return (offset, c)
  (off, _) = parsewhitespace(s, off)
  if key == b"dtype"
    off_ = off
    (off, val) = parsestring(s, off)
    typeof(val) != Error || return (offset, val)
    val = parsedtype(val, off_)
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


"""`parsedtype(s, off)`

Parse a dtype string.
Returns a tuple (e :: Endianness, type :: DataType) on success, or an Error on failure.
off should be the offset of the dtype string (for debugging purposes).
"""
function parsedtype(s, off)
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
    b"U3" => Error(off, "UTF-8 dtype is unsupported"),
    b"S3" => Error(off, "String dtype is unsupported"),
    b"O" => Error(off, "Object dtype is unsupported"),
  )
  length(s) >= 2 || return Error(off, "Invalid dtype '$s' (too short)")
  datatype = get(datatypes, s[2:end], Error(off, "Unknown or invalid dtype '$(String(s[2:end]))'"))
  typeof(datatype) != Error || return datatype
  endianness = get(endiannesses, Char(s[1]), Error(off, "npy.jl BUG: unknown endianness '$(Char(s[1]))'"))
  typeof(endianness) != Error || return endianness
  return (endianness, datatype)
end


end
