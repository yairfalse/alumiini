defmodule Alumiini.K8s do
  @moduledoc """
  Kubernetes API client wrapper.

  Provides:
  - Connection management (in-cluster or kubeconfig)
  - GitRepository CRD status updates
  - Resource watching
  """

  require Logger

  @git_repository_api_version "alumiini.io/v1alpha1"
  @git_repository_kind "GitRepository"

  @doc """
  Returns a K8s connection.
  Automatically detects in-cluster vs local kubeconfig.
  """
  @spec conn() :: {:ok, K8s.Conn.t()} | {:error, term()}
  def conn do
    case Application.get_env(:alumiini, :k8s_conn) do
      nil ->
        # Try in-cluster first, fall back to kubeconfig
        case K8s.Conn.from_service_account() do
          {:ok, conn} ->
            {:ok, conn}

          {:error, _} ->
            # Fall back to kubeconfig
            K8s.Conn.from_file("~/.kube/config")
        end

      conn ->
        {:ok, conn}
    end
  end

  @doc """
  Updates the status of a GitRepository resource.
  Uses the status subresource (PATCH /status).
  """
  @spec update_status(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_status(repo_name, namespace, status) do
    with {:ok, conn} <- conn() do
      status_resource = %{
        "apiVersion" => @git_repository_api_version,
        "kind" => @git_repository_kind,
        "metadata" => %{
          "name" => repo_name,
          "namespace" => namespace
        },
        "status" => status
      }

      operation =
        K8s.Client.patch(
          @git_repository_api_version,
          @git_repository_kind,
          [namespace: namespace, name: repo_name],
          status_resource,
          subresource: "status"
        )

      case K8s.Client.run(conn, operation) do
        {:ok, _result} ->
          Logger.debug("Updated status for #{namespace}/#{repo_name}")
          :ok

        {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
          Logger.warning("GitRepository #{namespace}/#{repo_name} not found")
          {:error, :not_found}

        {:error, reason} = error ->
          Logger.error(
            "Failed to update status for #{namespace}/#{repo_name}: #{inspect(reason)}"
          )

          error
      end
    end
  end

  @doc """
  Builds a status map for a GitRepository.
  """
  @spec build_status(atom(), String.t() | nil, DateTime.t() | nil, String.t() | nil) :: map()
  def build_status(phase, commit_sha, last_sync, message \\ nil) do
    status = %{
      "phase" => to_phase_string(phase),
      "observedGeneration" => 1
    }

    status =
      if commit_sha do
        Map.put(status, "lastAppliedCommit", commit_sha)
      else
        status
      end

    status =
      if last_sync do
        Map.put(status, "lastSyncTime", DateTime.to_iso8601(last_sync))
      else
        status
      end

    status =
      if message do
        condition = %{
          "type" => condition_type(phase),
          "status" => condition_status(phase),
          "lastTransitionTime" => DateTime.to_iso8601(DateTime.utc_now()),
          "reason" => to_phase_string(phase),
          "message" => message
        }

        Map.put(status, "conditions", [condition])
      else
        status
      end

    status
  end

  defp to_phase_string(:initializing), do: "Initializing"
  defp to_phase_string(:syncing), do: "Syncing"
  defp to_phase_string(:synced), do: "Synced"
  defp to_phase_string(:failed), do: "Failed"
  defp to_phase_string(:drifted), do: "Drifted"
  defp to_phase_string(other), do: to_string(other)

  defp condition_type(:synced), do: "Ready"
  defp condition_type(:failed), do: "Ready"
  defp condition_type(_), do: "Progressing"

  defp condition_status(:synced), do: "True"
  defp condition_status(:failed), do: "False"
  defp condition_status(_), do: "Unknown"

  @doc """
  Lists all GitRepository resources in a namespace.
  """
  @spec list_git_repositories(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_git_repositories(namespace) do
    with {:ok, conn} <- conn() do
      operation =
        K8s.Client.list(@git_repository_api_version, @git_repository_kind, namespace: namespace)

      case K8s.Client.run(conn, operation) do
        {:ok, %{"items" => items}} ->
          {:ok, items}

        {:error, reason} = error ->
          Logger.error("Failed to list GitRepositories in #{namespace}: #{inspect(reason)}")
          error
      end
    end
  end

  @doc """
  Gets a single GitRepository resource.
  """
  @spec get_git_repository(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_git_repository(name, namespace) do
    with {:ok, conn} <- conn() do
      operation =
        K8s.Client.get(@git_repository_api_version, @git_repository_kind,
          namespace: namespace,
          name: name
        )

      K8s.Client.run(conn, operation)
    end
  end

  @doc """
  Watches GitRepository resources in a namespace.
  Returns a stream of watch events.
  """
  @spec watch_git_repositories(String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def watch_git_repositories(namespace) do
    with {:ok, conn} <- conn() do
      operation =
        K8s.Client.list(@git_repository_api_version, @git_repository_kind, namespace: namespace)

      K8s.Client.stream(conn, operation, stream_to: self())
    end
  end

  @doc """
  Applies a manifest to the cluster using server-side apply.
  Wraps Applier functionality with connection management.
  """
  @spec apply_manifest(map(), String.t() | nil) :: :ok | {:error, term()}
  def apply_manifest(manifest, target_namespace \\ nil) do
    with {:ok, conn} <- conn() do
      Alumiini.Applier.apply_single(manifest, conn, target_namespace)
    end
  end

  @doc """
  Applies multiple manifests to the cluster.
  """
  @spec apply_manifests([map()], String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def apply_manifests(manifests, target_namespace \\ nil) do
    with {:ok, conn} <- conn() do
      Alumiini.Applier.apply_manifests(manifests, conn, target_namespace)
    end
  end

  @doc """
  Gets a resource from the cluster.
  """
  @spec get_resource(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_resource(api_version, kind, name, namespace) do
    with {:ok, conn} <- conn() do
      operation = K8s.Client.get(api_version, kind, namespace: namespace, name: name)

      K8s.Client.run(conn, operation)
    end
  end

  @doc """
  Deletes a resource from the cluster.
  """
  @spec delete_resource(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def delete_resource(api_version, kind, name, namespace) do
    with {:ok, conn} <- conn() do
      operation = K8s.Client.delete(api_version, kind, namespace: namespace, name: name)

      case K8s.Client.run(conn, operation) do
        {:ok, _} -> :ok
        {:error, %K8s.Client.APIError{reason: "NotFound"}} -> :ok
        {:error, _} = error -> error
      end
    end
  end
end
