using Pkg
Pkg.activate(; temp=true)
Pkg.add(url="https://github.com/JuliaCI/BaseBenchmarks.jl")
Pkg.add("DifferentialEquations")
Pkg.add("Test")
Pkg.add("LinearAlgebra")
Pkg.add("ThreadsX")
Pkg.add("Plots")

using BaseBenchmarks, DifferentialEquations, Test, ThreadsX, LinearAlgebra, Plots

BaseBenchmarks.load!("problem")

using BaseBenchmarks.ProblemBenchmarks: MonteCarlo, Raytracer, JSONParse, PROBLEM_DATA_DIR
MonteCarlo.perf_euro_option_vec(10^4)
Raytracer.perf_raytrace(5, 256, 4)

jstr = read(joinpath(PROBLEM_DATA_DIR, "test.json"), String)
JSONParse.perf_parse_json(jstr)

# https://github.com/SciML/DifferentialEquations.jl/blob/master/test/default_ode_alg_test.jl

f_2dlinear = (du, u, p, t) -> (@. du = p * u)
f_2dlinear_analytic = (u0, p, t) -> @. u0 * exp(p * t)
prob_ode_2Dlinear = ODEProblem(ODEFunction(f_2dlinear, analytic = f_2dlinear_analytic),
    rand(4, 2), (0.0, 1.0), 1.01)

alg, kwargs = default_algorithm(prob_ode_2Dlinear; dt = 1 // 2^(4))
integ = init(prob_ode_2Dlinear; dt = 1 // 2^(4))
sol = solve(prob_ode_2Dlinear; dt = 1 // 2^(4))

sol = solve(prob_ode_2Dlinear; reltol = 1e-1)

sol = solve(prob_ode_2Dlinear; reltol = 1e-7)

sol = solve(prob_ode_2Dlinear; alg_hints = [:stiff])

const linear_bigα = parse(BigFloat, "1.01")
f = (du, u, p, t) -> begin
    for i in 1:length(u)
        du[i] = linear_bigα * u[i]
    end
end
(::typeof(f))(::Type{Val{:analytic}}, u0, p, t) = u0 * exp(linear_bigα * t)
prob_ode_bigfloat2Dlinear = ODEProblem(f, map(BigFloat, rand(4, 2)) .* ones(4, 2) / 2,
    (0.0, 1.0))

sol = solve(prob_ode_bigfloat2Dlinear; dt = 1 // 2^(4))

# From OmniPackage.jl
function expm(A::AbstractMatrix{S}) where {S}
  # omitted: matrix balancing, i.e., LAPACK.gebal!
  nA = opnorm(A, 1)
  ## For sufficiently small nA, use lower order Padé-Approximations
  if (nA <= 2.1)
    A2 = A * A
    if nA > 0.95
      U = @evalpoly(
        A2,
        S(8821612800) * I,
        S(302702400) * I,
        S(2162160) * I,
        S(3960) * I,
        S(1) * I
      )
      U = A * U
      V = @evalpoly(
        A2,
        S(17643225600) * I,
        S(2075673600) * I,
        S(30270240) * I,
        S(110880) * I,
        S(90) * I
      )
    elseif nA > 0.25
      U = @evalpoly(A2, S(8648640) * I, S(277200) * I, S(1512) * I, S(1) * I)
      U = A * U
      V =
        @evalpoly(A2, S(17297280) * I, S(1995840) * I, S(25200) * I, S(56) * I)
    elseif nA > 0.015
      U = @evalpoly(A2, S(15120) * I, S(420) * I, S(1) * I)
      U = A * U
      V = @evalpoly(A2, S(30240) * I, S(3360) * I, S(30) * I)
    else
      U = @evalpoly(A2, S(60) * I, S(1) * I)
      U = A * U
      V = @evalpoly(A2, S(120) * I, S(12) * I)
    end
    expA = (V - U) \ (V + U)
  else
    s = log2(nA / 5.4)               # power of 2 later reversed by squaring
    if s > 0
      si = ceil(Int, s)
      A = A / S(exp2(si))
    end

    A2 = A * A
    A4 = A2 * A2
    A6 = A2 * A4

    U =
      A6 * (S(1) * A6 + S(16380) * A4 + S(40840800) * A2) +
      (
        S(33522128640) * A6 + S(10559470521600) * A4 + S(1187353796428800) * A2
      ) +
      S(32382376266240000) * I
    U = A * U
    V =
      A6 * (S(182) * A6 + S(960960) * A4 + S(1323241920) * A2) +
      (
        S(670442572800) * A6 +
        S(129060195264000) * A4 +
        S(7771770303897600) * A2
      ) +
      S(64764752532480000) * I
    expA = (V - U) \ (V + U)
    if s > 0            # squaring to reverse dividing by power of 2
      for t = 1:si
        expA = expA * expA
      end
    end
  end
  expA
end

function expwork(A)
  B = expm(A)
  C = similar(B)
  for i = 0:7
    C .= A .* exp(-i)
    B .+= expm(C)
  end
  return B
end

expm_bench0(N = 2, iters = 100) =
  ThreadsX.sum(1:iters) do _
    expwork(rand(N, N))
  end

expm_bench0()

# Plots.jl Example
x = range(0, 10, length=100)
y = sin.(x)
plot(x, y)