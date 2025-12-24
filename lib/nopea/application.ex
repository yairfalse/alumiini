defmodule Nopea.Application do
  @moduledoc """
  NOPEA OTP Application.

  Supervision tree:
  - Nopea.ULID (monotonic ID generator)
  - Nopea.Events.Emitter (CDEvents HTTP emitter, optional)
  - Nopea.Cache (ETS storage)
  - Nopea.Registry (process name registry)
  - Nopea.Git (Rust Port GenServer)
  - Nopea.Supervisor (DynamicSupervisor for Workers)
  - Nopea.Controller (CRD watcher, optional)

  ## Configuration

  Services can be disabled via application config:

  - `enable_cache` - Enables Cache GenServer (default: true)
  - `enable_git` - Enables Git GenServer (default: true)
  - `enable_supervisor` - Enables Supervisor and Registry (default: true)
  - `enable_controller` - Enables Controller (default: true)
  - `cdevents_endpoint` - CDEvents HTTP endpoint URL (nil to disable)

  ## Service Dependencies

  The following dependencies exist between services:

  - `Nopea.Supervisor` requires `Nopea.Registry` (automatically started together)
  - `Nopea.Worker` requires `Nopea.Git` to perform sync operations
  - `Nopea.Worker` optionally uses `Nopea.Cache` for sync state storage

  Note: In tests, `enable_*` flags are set to false and services are started
  manually via `start_supervised!/1` for isolation. When doing this, ensure
  `Application.put_env/3` is called to keep config in sync with running services.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # ULID generator (monotonic, needed for events)
    children = [Nopea.ULID]

    # CDEvents emitter (optional, enabled when endpoint is configured)
    children =
      case Application.get_env(:nopea, :cdevents_endpoint) do
        nil ->
          children

        endpoint ->
          children ++ [{Nopea.Events.Emitter, endpoint: endpoint}]
      end

    # ETS cache for commits, resources, sync state
    children =
      if Application.get_env(:nopea, :enable_cache, true) do
        children ++ [Nopea.Cache]
      else
        children
      end

    # Registry for worker name lookup (always needed if supervisor is enabled)
    children =
      if Application.get_env(:nopea, :enable_supervisor, true) do
        children ++ [{Registry, keys: :unique, name: Nopea.Registry}]
      else
        children
      end

    # Git GenServer (Rust Port)
    children =
      if Application.get_env(:nopea, :enable_git, true) do
        children ++ [Nopea.Git]
      else
        children
      end

    # DynamicSupervisor for Worker processes
    children =
      if Application.get_env(:nopea, :enable_supervisor, true) do
        children ++ [Nopea.Supervisor]
      else
        children
      end

    # Controller (watches GitRepository CRDs)
    children =
      if Application.get_env(:nopea, :enable_controller, true) do
        namespace = Application.get_env(:nopea, :watch_namespace, "default")
        children ++ [{Nopea.Controller, namespace: namespace}]
      else
        children
      end

    # Webhook HTTP server (always enabled for health/readiness probes)
    children = children ++ [Nopea.Webhook.Router]

    opts = [strategy: :one_for_one, name: Nopea.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
