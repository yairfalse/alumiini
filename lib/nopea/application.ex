defmodule Nopea.Application do
  @moduledoc """
  NOPEA OTP Application.

  Supervision tree:
  - Nopea.Cache (ETS storage)
  - Nopea.Registry (process name registry)
  - Nopea.Git (Rust Port GenServer)
  - Nopea.Supervisor (DynamicSupervisor for Workers)
  - Nopea.Controller (CRD watcher, optional)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # ETS cache for commits, resources, sync state
        Nopea.Cache,
        # Registry for worker name lookup
        {Registry, keys: :unique, name: Nopea.Registry}
      ] ++
        if Application.get_env(:nopea, :enable_git, true) do
          [Nopea.Git]
        else
          []
        end ++
        [
          # DynamicSupervisor for Worker processes
          Nopea.Supervisor
        ]

    # Add Controller if enabled (watches GitRepository CRDs)
    children =
      if Application.get_env(:nopea, :enable_controller, true) do
        namespace = Application.get_env(:nopea, :watch_namespace, "default")
        children ++ [{Nopea.Controller, namespace: namespace}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Nopea.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
