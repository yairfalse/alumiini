defmodule Nopea.WebhookTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Nopea.Webhook
  alias Nopea.Webhook.Router

  # Suppress warning logs in tests
  @moduletag capture_log: true

  # Valid 40-character SHA-1 hashes for testing
  @valid_sha_1 "abc123def456789012345678901234567890abcd"
  @valid_sha_2 "def456abc123789012345678901234567890efab"

  describe "GitHub push events" do
    test "parses push event and extracts commit and branch" do
      payload = github_push_payload(@valid_sha_1)

      assert {:ok, parsed} = Webhook.parse_payload(payload, :github)
      assert parsed.commit == @valid_sha_1
      assert parsed.branch == "main"
      assert parsed.ref == "refs/heads/main"
      assert parsed.repository == "octocat/Hello-World"
    end

    test "returns error for non-push events" do
      payload = %{"action" => "opened", "pull_request" => %{}}

      assert {:error, :unsupported_event} = Webhook.parse_payload(payload, :github)
    end

    test "returns error for invalid commit SHA" do
      payload = github_push_payload("not-a-valid-sha")

      assert {:error, :invalid_commit_sha} = Webhook.parse_payload(payload, :github)
    end
  end

  describe "GitLab push events" do
    test "parses push event and extracts commit and branch" do
      payload = gitlab_push_payload(@valid_sha_2)

      assert {:ok, parsed} = Webhook.parse_payload(payload, :gitlab)
      assert parsed.commit == @valid_sha_2
      assert parsed.branch == "main"
      assert parsed.ref == "refs/heads/main"
      assert parsed.repository == "group/project"
    end

    test "returns error for non-push events" do
      payload = %{"object_kind" => "merge_request"}

      assert {:error, :unsupported_event} = Webhook.parse_payload(payload, :gitlab)
    end

    test "returns error for invalid commit SHA" do
      payload = gitlab_push_payload("short")

      assert {:error, :invalid_commit_sha} = Webhook.parse_payload(payload, :gitlab)
    end
  end

  describe "valid_commit_sha?/1" do
    test "accepts valid 40-character SHA-1 hash" do
      assert Webhook.valid_commit_sha?("abc123def456789012345678901234567890abcd")
    end

    test "accepts valid 64-character SHA-256 hash" do
      sha256 = String.duplicate("a", 64)
      assert Webhook.valid_commit_sha?(sha256)
    end

    test "rejects short strings" do
      refute Webhook.valid_commit_sha?("abc123")
    end

    test "rejects strings with invalid characters" do
      refute Webhook.valid_commit_sha?("ghijklmnopqrstuvwxyz12345678901234567890")
    end

    test "rejects non-strings" do
      refute Webhook.valid_commit_sha?(nil)
      refute Webhook.valid_commit_sha?(123)
    end
  end

  describe "signature verification" do
    test "verifies valid GitHub HMAC signature" do
      secret = "webhook-secret-123"
      payload = ~s({"ref":"refs/heads/main"})
      signature = compute_github_signature(payload, secret)

      assert :ok = Webhook.verify_signature(payload, signature, secret, :github)
    end

    test "rejects invalid GitHub signature" do
      secret = "webhook-secret-123"
      payload = ~s({"ref":"refs/heads/main"})
      bad_signature = "sha256=invalid"

      assert {:error, :invalid_signature} =
               Webhook.verify_signature(payload, bad_signature, secret, :github)
    end

    test "verifies valid GitLab token" do
      token = "gitlab-token-456"

      assert :ok = Webhook.verify_signature("", token, token, :gitlab)
    end

    test "rejects invalid GitLab token" do
      assert {:error, :invalid_signature} =
               Webhook.verify_signature("", "wrong-token", "correct-token", :gitlab)
    end
  end

  describe "detect_provider/1" do
    test "detects GitHub from headers" do
      headers = [{"x-github-event", "push"}, {"x-hub-signature-256", "sha256=abc"}]
      assert :github = Webhook.detect_provider(headers)
    end

    test "detects GitLab from headers" do
      headers = [{"x-gitlab-event", "Push Hook"}, {"x-gitlab-token", "secret"}]
      assert :gitlab = Webhook.detect_provider(headers)
    end

    test "returns unknown for unrecognized headers" do
      headers = [{"content-type", "application/json"}]
      assert :unknown = Webhook.detect_provider(headers)
    end
  end

  # Helper functions

  defp github_push_payload(commit_sha) do
    %{
      "ref" => "refs/heads/main",
      "after" => commit_sha,
      "repository" => %{
        "full_name" => "octocat/Hello-World"
      },
      "pusher" => %{
        "name" => "octocat"
      }
    }
  end

  defp gitlab_push_payload(commit_sha) do
    %{
      "object_kind" => "push",
      "ref" => "refs/heads/main",
      "after" => commit_sha,
      "project" => %{
        "path_with_namespace" => "group/project"
      }
    }
  end

  defp compute_github_signature(payload, secret) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    "sha256=#{signature}"
  end

  describe "Router endpoint" do
    setup do
      # Store original config value
      original_secret = Application.get_env(:nopea, :webhook_secret)

      on_exit(fn ->
        # Restore original config
        if original_secret do
          Application.put_env(:nopea, :webhook_secret, original_secret)
        else
          Application.delete_env(:nopea, :webhook_secret)
        end
      end)

      :ok
    end

    test "returns 200 for valid GitHub push webhook" do
      payload = Jason.encode!(github_push_payload(@valid_sha_1))
      signature = compute_github_signature(payload, "test-secret")

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", signature)

      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "received"
    end

    test "returns 401 for invalid signature" do
      payload = Jason.encode!(github_push_payload(@valid_sha_1))

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")

      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 401
      assert conn.resp_body =~ "invalid_signature"
    end

    test "returns 401 for missing GitHub signature header" do
      payload = Jason.encode!(github_push_payload(@valid_sha_1))

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")

      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 401
      assert conn.resp_body =~ "missing_signature"
    end

    test "returns 401 for missing GitLab token header" do
      payload = Jason.encode!(gitlab_push_payload(@valid_sha_2))

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitlab-event", "Push Hook")

      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 401
      assert conn.resp_body =~ "missing_signature"
    end

    test "returns 500 when webhook secret not configured" do
      payload = Jason.encode!(github_push_payload(@valid_sha_1))
      signature = compute_github_signature(payload, "any-secret")

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", signature)

      # Ensure no secret is configured
      Application.delete_env(:nopea, :webhook_secret)

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 500
      assert conn.resp_body =~ "webhook_not_configured"
    end

    test "returns 400 for unknown provider" do
      payload = Jason.encode!(%{"data" => "test"})

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      assert conn.resp_body =~ "unknown_provider"
    end

    test "returns 400 for invalid repo name" do
      payload = Jason.encode!(github_push_payload(@valid_sha_1))

      conn =
        conn(:post, "/webhook/repo<script>", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_repo_name"
    end

    test "returns 200 for valid GitLab push webhook" do
      payload = Jason.encode!(gitlab_push_payload(@valid_sha_2))
      token = "gitlab-secret"

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitlab-event", "Push Hook")
        |> put_req_header("x-gitlab-token", token)

      Application.put_env(:nopea, :webhook_secret, token)

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
    end

    test "returns 404 for unknown routes" do
      conn = conn(:get, "/unknown")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 404
    end

    test "health check returns status" do
      conn = conn(:get, "/health")

      conn = Router.call(conn, Router.init([]))

      # Returns JSON with status field (may be healthy or unhealthy depending on process state)
      body = Jason.decode!(conn.resp_body)
      assert body["status"] in ["healthy", "unhealthy"]
      assert is_map(body["checks"])
    end

    test "notifies Worker when webhook is received" do
      # Start Registry for worker lookup
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})

      # Start a mock worker registered under the repo name
      repo_name = "webhook-worker-test"

      {:ok, worker_pid} =
        Agent.start_link(fn -> [] end, name: {:via, Registry, {Nopea.Registry, repo_name}})

      # Intercept messages sent to the worker using erlang tracing
      :erlang.trace(worker_pid, true, [:receive])

      payload = Jason.encode!(github_push_payload(@valid_sha_1))
      signature = compute_github_signature(payload, "test-secret")

      conn =
        conn(:post, "/webhook/#{repo_name}", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", signature)

      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200

      # Verify the worker received the webhook message
      assert_receive {:trace, ^worker_pid, :receive, {:webhook, @valid_sha_1}}, 1000

      Agent.stop(worker_pid)
    end
  end

  describe "health and readiness probes" do
    test "GET /health returns process health status" do
      # Ensure processes are running
      ensure_process_running(Nopea.Cache, {Nopea.Cache, []})
      ensure_process_running(Nopea.ULID, {Nopea.ULID, []})

      conn = conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["status"] == "healthy"
      assert body["checks"]["cache"] == "up"
      assert body["checks"]["ulid"] == "up"
    end

    test "GET /health returns 503 when critical process is down" do
      # Ensure ULID is running but Cache is NOT
      ensure_process_running(Nopea.ULID, {Nopea.ULID, []})
      ensure_process_stopped(Nopea.Cache)

      conn = conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)

      assert body["status"] == "unhealthy"
      assert body["checks"]["cache"] == "down"
      assert body["checks"]["ulid"] == "up"
    end

    test "GET /ready returns 200 when controller is watching" do
      # Use a mock GenServer that responds to :get_state
      {:ok, pid} = MockController.start_link(%{watch_ref: make_ref(), repos: %{}})

      conn = conn(:get, "/ready")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["ready"] == true
      assert body["watching"] == true

      GenServer.stop(pid)
    end

    test "GET /ready returns 503 when controller not watching" do
      # Mock controller state without watch_ref
      {:ok, pid} = MockController.start_link(%{watch_ref: nil, repos: %{}})

      conn = conn(:get, "/ready")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)

      assert body["ready"] == false
      assert body["watching"] == false

      GenServer.stop(pid)
    end

    test "GET /ready returns 503 when controller is not running" do
      # Make sure no controller is running
      if pid = Process.whereis(Nopea.Controller), do: GenServer.stop(pid)

      conn = conn(:get, "/ready")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)

      assert body["ready"] == false
    end
  end

  # Helper to ensure a process is running
  defp ensure_process_running(name, child_spec) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      pid when is_pid(pid) -> pid
    end
  end

  # Helper to ensure a process is stopped
  defp ensure_process_stopped(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal, 100)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          200 -> :ok
        end
    end
  end
end

# Mock GenServer that responds to :get_state
defmodule MockController do
  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: Nopea.Controller)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}
end
