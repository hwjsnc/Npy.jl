Npy.jl - read and write .npy files in Julia
===========================================

Npy.jl is a Julia package which implements reading and writing of a subset of the .npy file format.
Files are read using mmap(), so that very large files (larger than main memory) are supported.

The following datatypes are supported: `Bool`, `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Float32`, `Float64`, `Complex{Float32}`, `Complex{Float64}`.

TODO: add sr.ht build badge.


Examples
--------

TODO


Non-Features
------------

- Will not support compressed archives (.npz).
- Will not support bytestrings, unicode strings, objects.
- Will not support 'host endianness' ("=" in descr).


Compatibility
-------------

Npy.jl is written in Julia 1.0 and has no third-party dependencies.
Npy.jl follows [semanting versioning v2.0.0](https://semver.org/).
The current version in 0.0.1.


History
-------

There have been no changes since version 1.0.0.


Bugs
----

- There are no performance tests.
- Does not support writing .npy version 2.0.
  This is not expected to be a problem as long as the data size does not reach approximately 10^6500 bytes (or the data files have more than approximately 2900 columns).


Author and Copying
------------------

GPLv3?


Similar work
------------

- [numpy](https://www.numpy.org/):
  Python numerical library; originating project for the .npy format.
- [NPZ.jl](https://github.com/fhs/NPZ.jl):
  Another Julia library for .npy files.
  Supports the same data types as this library.
  Also supports .npz (compressed .npy files).
  It does not use mmap and is unsuitable for files larger than your main memory.
- [cnpy.h](https://git.sr.ht/~quf/cnpy/)
  The same thing as a C library (by the same author as this project).
- [cnpy.hpp](https://git.sr.ht/~quf/npy.hpp)
  A similar library as a C++ library (by the same author as this project).
  Uses `pread(3)` and `pwrite(3)` instead of mmap.


TODO
----

- Add CI
- Add tests for NpyArray
- Add docs
- Add numpy compatibility tests
- fuzz?
