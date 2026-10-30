#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: {{CURRENT_YEAR}} {{AUTHOR}} ({{OWNER}}) <{{AUTHOR_EMAIL}}>
#
# julia-quality.jl — the `fmt`, `fmt-check` and `lint` verbs for a Julia package.
#
# ── Why this file exists ────────────────────────────────────────────────────
#
# `just quality` is fmt-check + lint + test. For a Julia package the engine had
# no command for fmt-check or lint, so both reported N/A, exited 0, and
# `just quality` printed a pass having run only `Pkg.test()`. A gate that cannot
# fail is not a gate.
#
# ── Why the tools live in their own environment ─────────────────────────────
#
# JuliaFormatter and Aqua are DEVELOPMENT tools. Putting them in the package's
# [deps] would ship them to every user of the library — and Aqua's own
# deps_compat/stale-deps checks fail a package that does that. `[extras]` is not
# enough either: extras resolve only inside `Pkg.test`'s temporary environment,
# so `julia --project=. -e 'using JuliaFormatter'` cannot see them.
#
# So they get a private environment (default ~/.cache/rsr/julia-quality,
# override with RSR_JULIA_QUALITY_ENV), the package is `develop`ed into it for
# lint, and the package's own Project.toml stays honest. The first run resolves
# the tools from the registry; the depot caches them afterwards.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   julia --project=. scripts/julia-quality.jl fmt          # rewrite
#   julia --project=. scripts/julia-quality.jl fmt-check    # fail if it would
#   julia --project=. scripts/julia-quality.jl lint         # Aqua shape gate
#
# Exit: 0 pass, 1 finding, 2 usage, 3 the tool environment could not be built.

using Pkg

const ROOT = normpath(joinpath(@__DIR__, ".."))
const TOOLS = get(ENV, "RSR_JULIA_QUALITY_ENV",
                  joinpath(homedir(), ".cache", "rsr", "julia-quality"))
const CMD = isempty(ARGS) ? "" : ARGS[1]

if !(CMD in ("fmt", "fmt-check", "lint"))
    println(stderr, "usage: julia --project=. scripts/julia-quality.jl fmt|fmt-check|lint")
    exit(2)
end

mkpath(TOOLS)
Pkg.activate(TOOLS; io = devnull)

"""Install `pkg` into the tools environment unless it is already loadable."""
function ensure(pkg::AbstractString)
    Base.find_package(pkg) === nothing || return
    try
        Pkg.add(pkg; io = devnull)
    catch err
        println(stderr, "FAIL: could not install ", pkg, " into ", TOOLS, ": ", err)
        println(stderr, "      a quality gate that cannot run its tool is not a pass.")
        exit(3)
    end
    if Base.find_package(pkg) === nothing
        println(stderr, "FAIL: ", pkg, " is still not loadable after Pkg.add")
        exit(3)
    end
    return
end

if CMD == "fmt" || CMD == "fmt-check"
    ensure("JuliaFormatter")
    @eval using JuliaFormatter
    # overwrite=false both PREDICTS and reports: it returns true when the file
    # would be (or was) rewritten.
    changed = format(ROOT; overwrite = (CMD == "fmt"), verbose = false)
    if CMD == "fmt-check" && changed
        println(stderr, "FAIL: JuliaFormatter would rewrite files — run: just fmt")
        exit(1)
    end
    CMD == "fmt-check" && println("PASS: Julia formatting is clean")
else
    ensure("Aqua")
    # Aqua checks a LOADED package: develop this one into the tools environment
    # so its own dependencies resolve, then bring it into scope by the name its
    # Project.toml declares (a package's module name is not its directory name).
    try
        Pkg.develop(Pkg.PackageSpec(path = ROOT); io = devnull)
    catch err
        println(stderr, "FAIL: could not develop ", ROOT, " into the tools environment: ", err)
        exit(3)
    end
    @eval using Aqua

    text = read(joinpath(ROOT, "Project.toml"), String)
    m = match(r"(?m)^name\s*=\s*\"([^\"]+)\"", text)
    if m === nothing
        println(stderr, "FAIL: no name = \"…\" line in Project.toml")
        exit(1)
    end
    modname = Symbol(m.captures[1])
    try
        Base.eval(Main, Expr(:using, Expr(:(:), modname)))
    catch err
        println(stderr, "FAIL: the package does not load: ", err)
        exit(1)
    end
    Aqua.test_all(getfield(Main, modname))
    println("PASS: Aqua package-shape checks are clean")
end
