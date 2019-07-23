Npy.jl - read and write .npy files in Julia
===========================================

Npy.jl is a Julia package which implements reading and writing of a subset of the .npy file format.
Files are read and written using `mmap()`.
As a result, very large files (larger than main memory) are supported.

Files with one of the following datatypes are supported: `Bool`, `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Float32`, `Float64`, `Complex{Float32}`, `Complex{Float64}`.

Test status: [![builds.sr.ht status](https://builds.sr.ht/~quf/Npy.jl/archlinux.yml.svg)](https://builds.sr.ht/~quf/Npy.jl/archlinux.yml?)


Examples
--------

- Create (or overwrite) a .npy file with data from a regular `Array`, then force the changes to disk.

```jldoctest
julia> using Npy: NpyArray, sync!

julia> npy_arr = NpyArray("abc.npy", Float64[23.0 π; NaN exp(-42)])
2×2 NpyArray{Float64,2}:
  23.0  3.14159    
 NaN    5.74952e-19

julia> sync!(npy_arr)
```

- First create a file, fill it with ascending integers and alternating imaginary part, then close it.
  Afterwards, open it again, and compute the sum of the entries.
  Finally, open it yet again, and set every entry to zero.

```jldoctest
julia> using Npy: NpyArray

julia> NpyArray("def.npy", Complex{Float32}, (4, 5, 7)) do arr
         arr .= reshape(map(i -> ComplexF32(i)+(-im)^i, 1:length(arr)), size(arr))
       end;

julia> sum(NpyArray("def.npy")) == (4*5*7) * (4*5*7+1) / 2
true

julia> NpyArray("def.npy"; write=true) do arr
         arr .= 0
       end;
```

For more information on the `NpyArray` constructors, see its Julia docstring.


Non-Features
------------

`Npy.jl` does not and will not support the following:

- compressed archives (file ending ".npz")
- bytestrings, unicode strings, objects
- 'host endianness' ("`=`" in `descr`)


Compatibility
-------------

`Npy.jl` is written in Julia 1.0 and has no third-party dependencies (except for testing).
`Npy.jl` follows [semanting versioning v2.0.0](https://semver.org/).
The current version in 0.1.0.


Bugs and caveats
----------------

- This package does not support writing .npy version 2.0.
  This is not expected to be a problem as long as the data size does not reach approximately 10^6500 bytes (or the data files have more than approximately 2900 dimensions).
- Creating .npy files from an `AbstractArray` with non-standard axes is neither supported nor tested and may silently eat your data.
  Here be dragons.
- `Npy.jl` should work on big-endian architectures, but this has not been tested.
- Do not attempt to use linear indices with `NpyArray`s!
  Especially do not use the same linear indices of a particular `NpyArray` with any other `AbstractArray` (including other `NpyArray`s)!
  `.npy` files may be saved in either row major ("C contiguous") or column major ("Fortran contiguous", Julia convention) order.
  Using a linear index corresponding to one serialization order with an array of the other serialization order (and same shape) is incorrect, and impossible to detect.
  Using `CartesianIndices` is perfectly fine and is automatically used when broadcasting or looping over an `NpyArray`.
  If you need linear indexing, use `collect` to copy its data to a normal Julia `Array`.
- "Cold" performance is a bit slow:
  The first `NpyArray("file")` takes around one second (on a slow VPS).
  Opening another `NpyArray` afterwards takes one or two hundred microseconds.
- There are no performance benchmarks available.
  To give a rough impression:
  On the author's laptop, reading a 10 GB file (with Float64 entries and shape (50, 125, 200, 1000)) and summing its entries takes around 25 s when Julia was just started and the file is not cached; and 9.8 s when all relevant functions are precompiled and the file is cached.
  For comparison, summing an equivalent Array (completely in main memory) takes 0.7 s.


Copying
-------

Copyright © 2019  Lukas Himbert

`Npy.jl` is free software:
you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3 of the License.

`Npy.jl` is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with `Npy.jl`.
If not, see https://www.gnu.org/licenses/.


History
-------

There have been no changes since version 1.0.0.


Related work
------------

- [numpy](https://www.numpy.org/):
  Python numerical library; origin of the .npy format.
- [NPZ.jl](https://github.com/fhs/NPZ.jl):
  Another Julia library for .npy files.
  Supports the same data types as this library.
  Also supports .npz (compressed .npy files).
  It does not use mmap and is unsuitable for files larger than your main memory.
- [cnpy.h](https://git.sr.ht/~quf/cnpy/)
  The same thing as this library in form of a C library (by the author of this package).
- [npy.hpp](https://git.sr.ht/~quf/npy.hpp)
  A similar C++ library (by the author of this package).
  Uses `pread(3)` and `pwrite(3)` instead of mmap.


TODO
----

- fuzz?
- test on big endian
- re-check everything
