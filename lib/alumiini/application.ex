defmodule Alumiini.Application do
  @moduledoc """
  ALUMIINI OTP Application.

  Supervision tree:
  - Alumiini.Cache (ETS storage)
  - Alumiini.Registry (process name registry)
  - Alumiini.Git (Rust Port GenServer)
  - Alumiini.Supervisor (DynamicSupervisor for Workers)
  - Alumiini.Controller (CRD watcher, optional)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ETS cache for commits, resources, sync state
      Alumiini.Cache,
      # Registry for worker name lookup
      {Registry, keys: :unique, name: Alumiini.Registry},
      # Git Port GenServer (communicates with Rust binary)
      Alumiini.Git,
      # DynamicSupervisor for Worker processes
      Alumiini.Supervisor
    ]

    # Add Controller if enabled (watches GitRepository CRDs)
    children =
      if Application.get_env(:alumiini, :enable_controller, true) do
        namespace = Application.get_env(:alumiini, :watch_namespace, "default")
        children ++ [{Alumiini.Controller, namespace: namespace}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Alumiini.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
