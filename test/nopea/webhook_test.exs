defmodule Nopea.WebhookTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Nopea.Webhook
  alias Nopea.Webhook.Router

  describe "GitHub push events" do
    test "parses push event and extracts commit" do
      payload = github_push_payload("abc123def456")

      assert {:ok, parsed} = Webhook.parse_payload(payload, :github)
      assert parsed.commit == "abc123def456"
      assert parsed.ref == "refs/heads/main"
      assert parsed.repository == "octocat/Hello-World"
    end

    test "returns error for non-push events" do
      payload = %{"action" => "opened", "pull_request" => %{}}

      assert {:error, :unsupported_event} = Webhook.parse_payload(payload, :github)
    end
  end

  describe "GitLab push events" do
    test "parses push event and extracts commit" do
      payload = gitlab_push_payload("def456abc123")

      assert {:ok, parsed} = Webhook.parse_payload(payload, :gitlab)
      assert parsed.commit == "def456abc123"
      assert parsed.ref == "refs/heads/main"
      assert parsed.repository == "group/project"
    end

    test "returns error for non-push events" do
      payload = %{"object_kind" => "merge_request"}

      assert {:error, :unsupported_event} = Webhook.parse_payload(payload, :gitlab)
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
    test "returns 200 for valid GitHub push webhook" do
      payload = Jason.encode!(github_push_payload("abc123"))
      signature = compute_github_signature(payload, "test-secret")

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", signature)

      # Set secret in config for test
      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "received"
    end

    test "returns 401 for invalid signature" do
      payload = Jason.encode!(github_push_payload("abc123"))

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")

      Application.put_env(:nopea, :webhook_secret, "test-secret")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 401
    end

    test "returns 400 for unknown provider" do
      payload = Jason.encode!(%{"data" => "test"})

      conn =
        conn(:post, "/webhook/test-repo", payload)
        |> put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
    end

    test "returns 200 for valid GitLab push webhook" do
      payload = Jason.encode!(gitlab_push_payload("def456"))
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

    test "health check returns 200" do
      conn = conn(:get, "/health")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "ok"
    end
  end
end
