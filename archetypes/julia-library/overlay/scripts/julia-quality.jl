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

    # Judge by content, not by JuliaFormatter's return value. Its `format`
    # documents the return as "was the tree already formatted" in some releases
    # and "did it write" in others, so `changed` inverted this check on at least
    # one: a clean scaffold failed and an unformatted one passed. Formatting a
    # COPY and diffing the bytes cannot be ambiguous.
    jl_files(root) = [joinpath(d, f) for (d, _, fs) in walkdir(root)
                      for f in fs if endswith(f, ".jl")]

    if CMD == "fmt"
        n = length(jl_files(ROOT))
        format(ROOT; overwrite = true, verbose = false)
        println("PASS: formatted ", n, " Julia file(s) in place")
    else
        tmp = mktempdir()
        copy_root = joinpath(tmp, "tree")
        cp(ROOT, copy_root; force = true)
        before = Dict(f => read(f) for f in jl_files(copy_root))
        format(copy_root; overwrite = true, verbose = false)
        dirty = sort!([relpath(f, copy_root) for (f, bytes) in before if read(f) != bytes])
        rm(tmp; recursive = true, force = true)
        if !isempty(dirty)
            println(stderr, "FAIL: JuliaFormatter would rewrite ", length(dirty),
                    " file(s) — run: just fmt")
            foreach(f -> println(stderr, "  ", f), dirty)
            exit(1)
        end
        println("PASS: Julia formatting is clean")
    end
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
        # `using Pkg` parses to Expr(:using, Expr(:., :Pkg)); a colon node is the
        # `using A: b` form. Building the colon expression loads nothing, so the
        # check failed for every package it was meant to validate.
        Base.eval(Main, Meta.parse("using " * String(modname)))
    catch err
        println(stderr, "FAIL: the package does not load: ", err)
        exit(1)
    end
    Aqua.test_all(getfield(Main, modname))
    println("PASS: Aqua package-shape checks are clean")
end
