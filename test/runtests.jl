#!/usr/bin/env julia

import Npy

using Test

@testset "Test-Testset" begin
  @test 1 + 1 == 2
  @test 2 + 2 == 5
  @test 3 + 3 == 6
end

@testset "Header parsing tests" begin
  # TODO
end
