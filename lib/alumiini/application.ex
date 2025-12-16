defmodule Alumiini.Application do
  @moduledoc """
  ALUMIINI OTP Application.

  Supervision tree:
  - Alumiini.Cache (ETS storage)
  - Alumiini.Registry (process name registry)
  - Alumiini.Supervisor (DynamicSupervisor for Workers)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ETS cache for commits, resources, sync state
      Alumiini.Cache,
      # Registry for worker name lookup
      {Registry, keys: :unique, name: Alumiini.Registry},
      # DynamicSupervisor for Worker processes
      Alumiini.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Alumiini.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
