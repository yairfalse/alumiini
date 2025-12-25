defmodule Nopea.K8s.Behaviour do
  @moduledoc """
  Behaviour for K8s operations.

  Allows mocking K8s calls in tests for drift detection and leader election.
  """

  @doc """
  Returns a K8s connection.
  """
  @callback conn() :: {:ok, K8s.Conn.t()} | {:error, term()}

  @doc """
  Gets a resource from the cluster.
  """
  @callback get_resource(
              api_version :: String.t(),
              kind :: String.t(),
              name :: String.t(),
              namespace :: String.t()
            ) :: {:ok, map()} | {:error, term()}
end
