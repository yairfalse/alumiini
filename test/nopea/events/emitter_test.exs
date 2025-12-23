defmodule Nopea.Events.EmitterTest do
  use ExUnit.Case, async: true

  alias Nopea.Events
  alias Nopea.Events.Emitter

  @moduletag :emitter

  # Test HTTP client that records requests
  defmodule TestClient do
    def post(url, body, _headers, opts) do
      test_pid = opts[:test_pid]
      response = opts[:response] || {:ok, %{status: 202}}

      if test_pid do
        send(test_pid, {:http_request, url, body})
      end

      response
    end
  end

  describe "emit/1" do
    test "queues event for delivery" do
      {:ok, pid} =
        start_emitter(
          endpoint: "http://localhost:9999/events",
          http_client: {TestClient, test_pid: self(), response: {:ok, %{status: 202}}}
        )

      event = Events.service_deployed("test-repo", %{commit: "abc123"})
      assert :ok = Emitter.emit(pid, event)

      # Wait for async processing
      assert_receive {:http_request, _url, _body}, 100
    end

    test "sends correct JSON payload" do
      {:ok, pid} =
        start_emitter(
          endpoint: "http://events.example.com/cdevents",
          http_client: {TestClient, test_pid: self(), response: {:ok, %{status: 202}}}
        )

      event =
        Events.service_deployed("my-app", %{
          commit: "abc123",
          namespace: "production"
        })

      Emitter.emit(pid, event)

      assert_receive {:http_request, url, body}, 100
      assert url == "http://events.example.com/cdevents"

      decoded = Jason.decode!(body)
      assert decoded["type"] == "dev.cdevents.service.deployed.0.3.0"
      assert decoded["source"] == "/nopea/worker/my-app"
    end
  end

  describe "retry behavior" do
    test "retries on HTTP failure" do
      # Track attempt count
      agent = start_supervised!({Agent, fn -> 0 end})

      client_opts = [
        test_pid: self(),
        response_fn: fn ->
          count = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
          if count < 3, do: {:error, :connection_refused}, else: {:ok, %{status: 202}}
        end
      ]

      {:ok, pid} =
        start_emitter(
          endpoint: "http://localhost/events",
          http_client: {Nopea.Events.EmitterTest.RetryTestClient, client_opts},
          retry_delay_ms: 10,
          max_retries: 5
        )

      event = Events.service_deployed("test-repo", %{commit: "abc123"})
      Emitter.emit(pid, event)

      # Should receive 3 attempts
      assert_receive {:http_request, _, _}, 200
      assert_receive {:http_request, _, _}, 200
      assert_receive {:http_request, _, _}, 200
    end

    test "drops event after max retries" do
      {:ok, pid} =
        start_emitter(
          endpoint: "http://localhost/events",
          http_client: {TestClient, test_pid: self(), response: {:error, :timeout}},
          retry_delay_ms: 5,
          max_retries: 2
        )

      event = Events.service_deployed("test-repo", %{commit: "abc123"})
      Emitter.emit(pid, event)

      # Wait for retries
      Process.sleep(100)

      state = Emitter.get_state(pid)
      assert state.dropped_count == 1
    end
  end

  describe "configuration" do
    test "disabled when endpoint is nil" do
      {:ok, pid} = start_emitter(endpoint: nil)

      event = Events.service_deployed("test-repo", %{commit: "abc123"})
      assert :ok = Emitter.emit(pid, event)

      state = Emitter.get_state(pid)
      assert state.enabled == false
    end
  end

  # Retry test client with dynamic responses
  defmodule RetryTestClient do
    def post(url, body, _headers, opts) do
      if opts[:test_pid], do: send(opts[:test_pid], {:http_request, url, body})
      opts[:response_fn].()
    end
  end

  defp start_emitter(opts) do
    # Use unique names for test isolation
    opts = Keyword.put_new(opts, :name, :"emitter_test_#{System.unique_integer()}")
    start_supervised({Emitter, opts})
  end
end
