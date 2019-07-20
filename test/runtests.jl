#!/usr/bin/env julia

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


using Npy
using Test
import PyCall
using PyCall: @py_str
numpy = PyCall.pyimport("numpy")
using Random: AbstractRNG, randexp
using RandomizedPropertyTest

@testset "Test header parser" begin
  using Npy.Header: ParseError

  @testset "Empty dictionary" begin
    @test_throws ParseError Npy.Header.parsedict("{}")
    @test Npy.Header.parsedict("{}\n") == Dict()
    @test Npy.Header.parsedict("{ \t \n } \n   \n") == Dict()
    @test_throws ParseError Npy.Header.parsedict("{\n")
    @test_throws ParseError Npy.Header.parsedict("\n")
  end

  @testset "fortran_order dictionary" begin
    @test Npy.Header.parsedict("{'fortran_order': True}\n") == Dict("fortran_order" => true)
    @test Npy.Header.parsedict("""{"fortran_order": False}\n""") == Dict("fortran_order" => false)
    @test_throws ParseError Npy.Header.parsedict("{'fortran_order': 17}\n")
    @test_throws ParseError Npy.Header.parsedict("{'fortran_order': \"seventeen\"}\n")
  end

  @testset "descr dictionary" begin
    @test_throws ParseError Npy.Header.parsedict("{'descr': |U3}\n")
    @test_throws ParseError Npy.Header.parsedict("{'descr': |S3}\n")
    @test_throws ParseError Npy.Header.parsedict("{'descr': |O}\n")
    @test_throws ParseError Npy.Header.parsedict("{'descr': =f8}\n")
    @test_throws ParseError Npy.Header.parsedict("{'descr': >f3}\n")
    @test_throws ParseError Npy.Header.parsedict("{'descr': (2, 5)}\n")
    @test_throws ParseError Npy.Header.parsedict("{'descr': True}\n")
    @test Npy.Header.parsedict("""{'descr': ">f8"}\n""") == Dict("descr" => (Npy.Header.BigEndian, Float64))
    @test Npy.Header.parsedict("""{"descr": '<i4'}\n""") == Dict("descr" => (Npy.Header.LittleEndian, Int32))
    @test Npy.Header.parsedict("{'descr': '|i1'}\n") == Dict("descr" => (Npy.Header.NoEndian, Int8))
    @test Npy.Header.parsedict("{'descr': '|b1'}\n") == Dict("descr" => (Npy.Header.NoEndian, Bool))
  end

  @testset "shape dictionary" begin
    @test Npy.Header.parsedict("{'shape': ()}\n") == Dict("shape" => [])
    @test Npy.Header.parsedict("{'shape': (+25)}\n") == Dict("shape" => [25])
    @test Npy.Header.parsedict("{'shape': (25,)}\n") == Dict("shape" => [25])
    @test Npy.Header.parsedict("{'shape': (25, 18)}\n") == Dict("shape" => [25, 18])
    @test Npy.Header.parsedict("{'shape': (25, 18,)}\n") == Dict("shape" => [25, 18])
    @test_throws ParseError Npy.Header.parsedict("{'shape': (25, true,)}\n")
    @test Npy.Header.parsedict("{'shape': (1, 2)}\n") == Dict("shape" => [1, 2])
    @test Npy.Header.parsedict("{'shape': (1, 2,)}\n") == Dict("shape" => [1, 2])
    @test Npy.Header.parsedict("{'shape': (1, 3 , 5, 7, 11, 2134098712768342839871623947863782986328761,)}\n") == Dict("shape" => BigInt[1, 3, 5, 7, 11, 2134098712768342839871623947863782986328761])
    @test_throws ParseError Npy.Header.parsedict("{'shape': (,)}\n")
    @test_throws ParseError Npy.Header.parsedict("{'shape': (1, 2, 'xyz', 4)}\n")
    @test_broken #= @test_throws ParseError =# ( try Npy.Header.parsedict("{'shape': (1 2 3)}\n"); false; catch e; true; end)
  end

  @testset "Complete dictionary" begin
    @test Npy.Header.parsedict("{'descr': '>f8', 'fortran_order': False, \n 'shape': (1,2,6,24,120,720,5040)}  \n") == Dict("descr" => (Npy.Header.BigEndian, Float64), "fortran_order" => false, "shape" => collect(factorial(i) for i in 1:7))
    @test Npy.Header.parsedict("{ 'shape': (2,3,),    'descr':'|b1', \t'fortran_order': \nTrue,}\t\n\n") == Dict("descr" => (Npy.Header.NoEndian, Bool), "fortran_order" => true, "shape" => BigInt[2, 3])
    @test Npy.Header.parsedict("""{'shape': (3, 2, 6, 1092, 183,), 'fortran_order': False, "descr": '<c8'}\n\t\n""") == Dict("shape" => [3, 2, 6, 1092, 183], "fortran_order" => false, "descr" => (Npy.Header.LittleEndian, ComplexF32))

    @test_broken #= @test_throws ParseError =# ( try Npy.Header.parsedict("""{'shape': (1 9 42) "fortran_order": True "descr": '>u2'}\n"""); false; catch e; true; end )
  end
end


dtypes = [Bool, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64, ComplexF32, ComplexF64]
shapes = [(1,), (5,), (1, 1), (2, 3), (2, 3, 5), (1, 3, 5, 7), (2, 3, 5, 7), (1, 2, 3, 5, 7, 9, 11)]

function genarr(T, shape)
  if T <: Integer && prod(shape) > typemax(T)
    values = reshape((1:prod(shape)) .% (BigInt(typemax(T))+1), shape)
  else
    values = reshape(1:prod(shape), shape)
  end
  return collect(T, values)
end

@testset "Reading & writing for all data types" begin
  for T in dtypes
    for shape in shapes
      arr = genarr(T, shape)
      mktempdir() do dir
        NpyArray("$dir/test1.npy", arr) do _; end
        NpyArray("$dir/test2.npy", T, shape) do npy_arr; npy_arr .= arr; end
        @test NpyArray("$dir/test1.npy") == arr
        @test NpyArray("$dir/test2.npy") == arr
      end
    end
  end
end

@testset "Numpy compatibility" begin
  @testset "Round trip Npy.jl -> numpy -> Npy.jl" begin
    for T in dtypes
      for shape in shapes
        arr = genarr(T, shape)
        mktempdir() do dir
          fn1 = "$dir/test1.npy"
          fn2 = "$dir/test2.npy"
          NpyArray(fn1, arr) do npy_arr; end
          @test py"$numpy.all($numpy.load($fn1) == $arr)"
          numpy.save(fn2, numpy.load(fn1))
          @test NpyArray(fn2) == arr
        end
      end
    end
  end
  @testset "Round trip numpy -> Npy.jl -> numpy" begin
    for T in dtypes
      for shape in shapes
        arr = genarr(T, shape)
        mktempdir() do dir
          fn1 = "$dir/test1.npy"
          fn2 = "$dir/test2.npy"
          numpy.save(fn1, arr)
          @test NpyArray(fn1) == arr
          NpyArray(fn1) do npy_arr
            @test npy_arr == arr
            NpyArray(fn2, npy_arr)
          end
          @test py"$numpy.all($numpy.load($fn1) == $arr)"
        end
      end
    end
  end
end


@testset "Miscellaneous tests" begin
  values = [ "0.2022661927765359+0.911151576381147im", "0.20182598100469062+0.4133519175328306im", "0.9668808620741635+0.582627305520001im", "NAN+0.0im", "0.9249192458333583+0.3310075212325322im", "0.11127160010859283+0.8796717133291572im", "0.2963031104798771+0.9442733515553428im", "0.06345561719683768+0.5141957086015784im", "0.2206821895359954+0.17008537585334793im", "-0.0", "0.5691229587632597+0.21229533298877334im", "0.9368828156617994+0.3256736313689854im", "0.36185613079070866+0.915687433667723im", "0.5387458342544826+0.7608628302375843im", "0.0579734879173458+0.3911584129265795im", "0.0", "0.19166313550681457+0.05848842738185045im", "0.7128463320562705+0.8451681172973272im", "0.4482344870039454+0.056531955645364285im", "0.2587450227759823+0.3519256226804538im", "0.07262674017923643+0.8871633401903899im", "0.0030913466127576728+0.8728058725334997im", "0.26822578886638215+0.4662529371923042im", "0.5905983682737793+0.3556668740391734im", "0.18905459693786564+0.1604960256972614im", "0.4220618020571275+0.9107759975080193im", "0.19552771331435126+0.9639035549815377im", "0.05026314271925025+0.584775261507355im", "0.08082359577340215+0.867438972231096im", "0.7615199569672999+0.792564580456437im" ]

  for (T, T_s) in [(Float32, "f4"), (Float64, "f8"), (ComplexF32, "c8"), (ComplexF64, "c16")]
    if T <: AbstractFloat
      arr = real(reshape(parse.(complex(T), values), (2, 3, 5)))
    else
      arr = collect(reshape(parse.(T, values), (2, 3, 5)))
    end
    for end_s in ["be", "le"]
      for order_s in ("c", "f")
        @test isequal(NpyArray("data/$(T_s)-$(end_s)-$(order_s).npy"), arr)
      end
    end
  end
end


import RandomizedPropertyTest.specialcases, RandomizedPropertyTest.generate

struct RandArr end

function RandomizedPropertyTest.specialcases(rng :: AbstractRNG, _ :: Type{RandArr})
  return []
end

function RandomizedPropertyTest.generate(rng :: AbstractRNG, _ :: Type{RandArr})
  T = rand(rng, dtypes)
  shapelen = 1 + Int(round(randexp(rng)))
  shape = tuple((1+Int(round(randexp(rng))) for _ in 1:shapelen)...)
  return collect(reshape([RandomizedPropertyTest.generate(rng, T) for _ in 1:prod(shape)], shape))
end

@testset "Randomized r/w tests" begin
  @test @quickcheck n=10^3 (mktempdir() do dir; NpyArray("$dir/test.npy", arr) do npy_arr; npy_arr == arr end end) (arr :: RandArr)
end
