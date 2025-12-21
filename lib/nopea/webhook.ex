defmodule Nopea.Webhook do
  @moduledoc """
  Webhook payload parsing and verification for GitHub and GitLab.

  Supports:
  - GitHub push events with HMAC-SHA256 signature verification
  - GitLab push events with token verification
  """

  require Logger

  @type provider :: :github | :gitlab | :unknown
  @type parsed_event :: %{
          commit: String.t(),
          ref: String.t(),
          repository: String.t()
        }

  @doc """
  Detects the webhook provider from request headers.

  Returns `:github`, `:gitlab`, or `:unknown`.
  """
  @spec detect_provider([{String.t(), String.t()}]) :: provider()
  def detect_provider(headers) do
    headers_map =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Map.new()

    cond do
      Map.has_key?(headers_map, "x-github-event") ->
        :github

      Map.has_key?(headers_map, "x-gitlab-event") ->
        :gitlab

      true ->
        :unknown
    end
  end

  @doc """
  Parses a webhook payload based on the provider.

  Returns `{:ok, parsed_event}` for push events or `{:error, reason}` otherwise.
  """
  @spec parse_payload(map(), provider()) :: {:ok, parsed_event()} | {:error, atom()}
  def parse_payload(payload, :github) do
    # GitHub push events have "ref" and "after" fields
    if Map.has_key?(payload, "ref") and Map.has_key?(payload, "after") do
      {:ok,
       %{
         commit: payload["after"],
         ref: payload["ref"],
         repository: get_in(payload, ["repository", "full_name"]) || "unknown"
       }}
    else
      {:error, :unsupported_event}
    end
  end

  def parse_payload(payload, :gitlab) do
    # GitLab push events have object_kind == "push"
    if payload["object_kind"] == "push" do
      {:ok,
       %{
         commit: payload["after"],
         ref: payload["ref"],
         repository: get_in(payload, ["project", "path_with_namespace"]) || "unknown"
       }}
    else
      {:error, :unsupported_event}
    end
  end

  def parse_payload(_payload, :unknown) do
    {:error, :unknown_provider}
  end

  @doc """
  Verifies the webhook signature/token.

  For GitHub: Verifies HMAC-SHA256 signature in `X-Hub-Signature-256` header.
  For GitLab: Compares `X-Gitlab-Token` header with configured secret.
  """
  @spec verify_signature(String.t(), String.t(), String.t(), provider()) ::
          :ok | {:error, :invalid_signature}
  def verify_signature(payload, signature, secret, :github) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    expected_signature = "sha256=#{expected}"

    if Plug.Crypto.secure_compare(expected_signature, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_signature(_payload, token, secret, :gitlab) do
    if Plug.Crypto.secure_compare(token, secret) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_signature(_payload, _signature, _secret, :unknown) do
    {:error, :invalid_signature}
  end

  @doc """
  Extracts the branch name from a ref string.

  ## Examples

      iex> Nopea.Webhook.extract_branch("refs/heads/main")
      "main"

      iex> Nopea.Webhook.extract_branch("refs/heads/feature/my-branch")
      "feature/my-branch"
  """
  @spec extract_branch(String.t()) :: String.t()
  def extract_branch("refs/heads/" <> branch), do: branch
  def extract_branch(ref), do: ref
end
