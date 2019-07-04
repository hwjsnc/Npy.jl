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
  @testset "Test parseuinttuple" begin
    using Npy.ParseHeader: parseuinttuple
    @test parseuinttuple(b"()", 1) == (3, BigInt[])
    @test parseuinttuple(b"(42)", 1) == (5, BigInt[42])
    @test parseuinttuple(b"(42,)", 1) == (6, BigInt[42])
    @test parseuinttuple(b"(1, 2)", 1) == (7, BigInt[1, 2])
    @test parseuinttuple(b"(1, 2,)", 1) == (8, BigInt[1, 2])
    @test parseuinttuple(b"junk (1, 3 , 5, 7, 11, 2134098712768342839871623947863782986328761,) more junk", 6) == (69, BigInt[1, 3, 5, 7, 11, 2134098712768342839871623947863782986328761])
    @test iserror(parseuinttuple(b"(,)", 1), 1)
    @test iserror(parseuinttuple(b"(1, 2, 'xyz', 4)", 1), 1)
    @test iserror(parseuinttuple(b"(1, 2, true, 4)", 1), 1)
  end
  @testset "Test parsedescr" begin
    using Npy.ParseHeader: parsedescr, Error
    @test typeof(parsedescr("|O3", 1)) == Error
    @test typeof(parsedescr("|S3", 1)) == Error
    @test typeof(parsedescr("=f8", 1)) == Error
    @test typeof(parsedescr(">f5", 1)) == Error
    # TODO: exhaustively test dtypes
  end
  @testset "Test parsepair" begin
    using Npy.ParseHeader: parsepair, Endianness, LittleEndian, BigEndian, NoEndian
    @test parsepair(b"junk: 'fortran_order': True morejunk", 7) == (28, b"fortran_order" => true)
    @test parsepair(b"junk: \"fortran_order\": False, morejunk", 7) == (29, b"fortran_order" => false)
    @test iserror(parsepair(b"'fortran_order': 'True'", 1), 1)
    @test parsepair(b"'shape': ()", 1) == (12, b"shape" => BigInt[])
    @test parsepair(b"'shape': (1, 2, 3)", 1) == (19, b"shape" => BigInt[1, 2, 3])
    @test parsepair(b"'shape': (42)", 1) == (14, b"shape" => BigInt[42])
    @test parsepair(b"'shape': (42,)", 1) == (15, b"shape" => BigInt[42])
    @test iserror(parsepair(b"abc 'shape': 'xyz' def", 5), 5)
    @test parsepair(b"'descr': \"|b1\"", 1) == (15, b"descr" => (NoEndian, Bool))
    @test parsepair(b"'descr': \"<u2\"", 1) == (15, b"descr" => (LittleEndian, UInt16))
    @test parsepair(b"'descr': \">c8\"", 1) == (15, b"descr" => (BigEndian, Complex{Float32}))
    @test iserror(parsepair(b"abc 'descr': True,", 5), 5)
  end
  @test Npy.ParseHeader.parsedict(b"{'descr': '>f8', 'fortran_order': False, 'shape': (1,2,6,24,120,720,5040)}") == Dict(b"descr" => (Npy.ParseHeader.BigEndian, Float64), b"fortran_order" => false, b"shape" => collect(factorial(i) for i in 1:7))
  @test Npy.ParseHeader.parsedict(b"{ 'shape': (2,3,),    'descr':'|b1', \t'fortran_order': \nTrue,}") == Dict(b"descr" => (Npy.ParseHeader.NoEndian, Bool), b"fortran_order" => true, b"shape" => BigInt[2, 3])
end
