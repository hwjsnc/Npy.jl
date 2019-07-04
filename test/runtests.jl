#!/usr/bin/env julia

import Npy
import Random

using Test

@testset "Test header parser" begin
  function iserror(tup, off)
    return tup[1] == off && typeof(tup[2]) == Npy.ParseHeader.Error
  end
  @testset "Test parsestring" begin
    using Npy.ParseHeader: parsestring
    @test parsestring(b"\"hello, world!\"", 1) == (16, b"hello, world!")
    @test parsestring(b"'hello, world!'", 1) == (16, b"hello, world!")
    @test iserror(parsestring(b"'hello, world!", 1), 1)
    @test iserror(parsestring(b"\"hello, world!", 1), 1)
    @test iserror(parsestring(b"\"hello, world!'", 1), 1)
    @test iserror(parsestring(b"'hello, world!\"", 1), 1)
    @test iserror(parsestring(b"hello, world!", 1), 1)
    @test parsestring(b"lotsofjunk'abc'morejunk", 11) == (16, b"abc")
    @test iserror(parsestring(b"lotsofjunk'abc", 11), 11)
  end
  @testset "Test parsebool" begin
    using Npy.ParseHeader: parsebool
    @test parsebool(b"somejunk: True, morejunk", 11) == (15, true)
    @test parsebool(b"somejunk: False, morejunk", 11) == (16, false)
    @test iserror(parsebool(b"somejunk: true, morejunk", 11), 11)
    @test iserror(parsebool(b"somejunk: false, morejunk", 11), 11)
  end
  @testset "Test parseuint" begin
    using Npy.ParseHeader: parseuint
    for i in 0:100
      @test parseuint(Array{UInt8,1}("junk $i morejunk"), 6) == (length("$i")+6, i)
    end
    @test parseuint(b"+42", 1) == (4, 42)
    rng = Random.MersenneTwister(0)
    for _ in 1:100
      i = Random.rand(rng, UInt64)
      @test parseuint(Array{UInt8,1}("junk $i morejunk"), 6) == (length("$i")+6, i)
    end
    x = BigInt(2)^64 # > max(UInt64)
    @test parseuint(Array{UInt8,1}("$x"), 1) == (length("$x")+1, x)
    x = parse(BigInt, "129845801987043981239840219384")
    @test parseuint(Array{UInt8,1}("$x"), 1) == (length("$x")+1, x)
  end
  # TODO
  #@test Npy.ParseHeader.parsedict(b"{'dtype': '>f8', 'fortran_order': False, 'shape': (1,2,6,24,120,720,5040)}", 1) == Dict(b"dtype" => (Npy.ParseHeader.LittleEndian, Float64), b"")
  #@test Npy.ParseHeader.parsedict(b"{'dtype': '<u4', 'fortran_order': False, 'shape': (1,2,6,24,120,720,5040)}", 1) == Dict()
end
