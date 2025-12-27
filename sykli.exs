#!/usr/bin/env elixir

# NOPEA CI Pipeline (Local-First)
#
# Run full pipeline:  sykli
# Run only changes:   sykli delta
# Visualize graph:    sykli graph
#
# Pre-commit hook uses `sykli delta` for fast incremental checks.

Mix.install([
  {:sykli_sdk, github: "yairfalse/sykli", sparse: "sdk/elixir"}
])

Code.eval_string("""
use Sykli

# Input patterns for delta detection
elixir_inputs = ["lib/**/*.ex", "test/**/*.exs", "config/**/*.exs", "mix.exs", "mix.lock"]
helm_inputs = ["charts/**/*.yaml", "charts/**/*.tpl"]

pipeline do
  # ============================================================================
  # ELIXIR BUILD & TEST
  # ============================================================================

  task "deps" do
    container "elixir:1.16-alpine"
    run "mix local.hex --force && mix local.rebar --force && mix deps.get"
    inputs ["mix.exs", "mix.lock"]
  end

  task "compile" do
    container "elixir:1.16-alpine"
    run "mix compile --warnings-as-errors"
    after_ ["deps"]
    inputs elixir_inputs
  end

  task "test" do
    container "elixir:1.16-alpine"
    run "mix test"
    after_ ["compile"]
    inputs elixir_inputs
  end

  task "format" do
    container "elixir:1.16-alpine"
    run "mix format --check-formatted"
    after_ ["deps"]
    inputs elixir_inputs
  end

  task "credo" do
    container "elixir:1.16-alpine"
    run "mix credo --strict"
    after_ ["deps"]
    inputs elixir_inputs
  end

  # ============================================================================
  # HELM VALIDATION
  # ============================================================================

  task "helm-lint" do
    container "alpine/k8s:1.30.6"
    run "helm lint charts/nopea"
    inputs helm_inputs
  end

  task "helm-template" do
    container "alpine/k8s:1.30.6"
    run "helm template nopea charts/nopea --debug > /dev/null"
    after_ ["helm-lint"]
    inputs helm_inputs
  end
end
""")
