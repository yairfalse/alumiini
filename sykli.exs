#!/usr/bin/env elixir

# NOPEA CI Pipeline
# Run with: sykli
# Visualize with: sykli graph

Mix.install([
  {:sykli_sdk, github: "yairfalse/sykli", sparse: "sdk/elixir"}
])

Code.eval_string("""
use Sykli
alias Sykli.Condition

# Input patterns
elixir_inputs = ["lib/**/*.ex", "test/**/*.exs", "config/**/*.exs", "mix.exs", "mix.lock"]
helm_inputs = ["charts/**/*.yaml", "charts/**/*.tpl"]

pipeline do
  # ============================================================================
  # ELIXIR BUILD & TEST (runs directly on host - Elixir installed by setup-beam)
  # ============================================================================

  task "deps" do
    run "mix deps.get"
    inputs ["mix.exs", "mix.lock"]
  end

  task "compile" do
    run "mix compile --warnings-as-errors"
    after_ ["deps"]
    inputs elixir_inputs
  end

  task "test" do
    run "mix test"
    after_ ["compile"]
    inputs elixir_inputs
  end

  task "format" do
    run "mix format --check-formatted"
    after_ ["deps"]
    inputs elixir_inputs
  end

  task "credo" do
    run "mix credo --strict"
    after_ ["deps"]
    inputs elixir_inputs
  end

  # ============================================================================
  # HELM (using latest tag)
  # ============================================================================

  task "helm-lint" do
    container "alpine/helm:latest"
    run "helm lint charts/nopea"
    inputs helm_inputs
  end

  task "helm-template" do
    container "alpine/helm:latest"
    run "helm template nopea charts/nopea --debug > /dev/null"
    after_ ["helm-lint"]
    inputs helm_inputs
  end
end
""")
