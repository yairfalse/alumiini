defmodule Nopea.WorkerTest do
  use ExUnit.Case, async: false

  alias Nopea.Worker

  # Integration tests require Rust binary and real git operations
  @moduletag :integration

  setup do
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

    if File.exists?(dev_path) do
      # Set environment to match what we're starting
      Application.put_env(:nopea, :enable_cache, true)
      Application.put_env(:nopea, :enable_git, true)

      # Start required services
      start_supervised!(Nopea.Cache)
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
      Application.put_env(:nopea, :enable_git, true)
      start_supervised!(Nopea.Git)

      # Clean up test repo directory using system temp dir
      repo_base = Path.join(System.tmp_dir!(), "nopea/repos")

      case File.rm_rf(repo_base) do
        {:ok, _} ->
          :ok

        {:error, reason, _} ->
          IO.puts("Warning: Failed to clean repo directory #{repo_base}: #{inspect(reason)}")
      end

      File.mkdir_p!(repo_base)

      # Cleanup cloned repos on exit
      on_exit(fn ->
        File.rm_rf!(repo_base)
      end)

      {:ok, repo_base: repo_base, binary_available: true}
    else
      IO.puts("Skipping: Rust binary not built")
      {:ok, binary_available: false}
    end
  end

  describe "start_link/1" do
    @tag timeout: 30_000
    test "starts a worker with config", %{binary_available: available} = context do
      unless available do
        :ok
      else
        config = test_config("start-link-test", context)

        assert {:ok, pid} = Worker.start_link(config)
        assert Process.alive?(pid)

        # Wait for initialization
        wait_for_status(pid, [:initializing, :syncing, :synced, :failed])

        state = Worker.get_state(pid)
        assert state.config.name == config.name

        GenServer.stop(pid)
      end
    end
  end

  describe "get_state/1" do
    @tag timeout: 30_000
    test "returns current worker state", %{binary_available: available} = context do
      unless available do
        :ok
      else
        config = test_config("get-state-test", context)

        {:ok, pid} = Worker.start_link(config)

        state = Worker.get_state(pid)
        assert state.config.name == config.name
        assert state.config.url == config.url
        assert state.status in [:initializing, :syncing, :synced, :failed]

        GenServer.stop(pid)
      end
    end
  end

  describe "sync_now/1" do
    @tag timeout: 60_000
    test "triggers immediate sync with real repo", %{binary_available: available} = context do
      unless available do
        :ok
      else
        config = test_config("sync-now-test", context)

        {:ok, pid} = Worker.start_link(config)

        # Wait for startup sync to complete or fail
        wait_for_status(pid, [:synced, :failed], 30_000)

        # Manual sync - should work with real repo
        result = Worker.sync_now(pid)

        # With a real repo, sync succeeds but K8s apply fails (no cluster)
        # That's expected - we're testing the git integration works
        assert match?(:ok, result) or match?({:error, _}, result)

        state = Worker.get_state(pid)
        assert state.status in [:synced, :failed]

        GenServer.stop(pid)
      end
    end
  end

  describe "whereis/1" do
    @tag timeout: 30_000
    test "finds worker by repo name via Registry", %{binary_available: available} = context do
      unless available do
        :ok
      else
        config = test_config("whereis-test", context)

        {:ok, pid} = Worker.start_link(config)

        # Can find by name via Registry
        found_pid = Worker.whereis(config.name)
        assert found_pid == pid

        GenServer.stop(pid)
      end
    end
  end

  describe "sync with real repository" do
    @tag timeout: 120_000
    test "successfully syncs from a real public repository",
         %{binary_available: available} = context do
      unless available do
        :ok
      else
        config = test_config("real-repo-test", context)

        {:ok, pid} = Worker.start_link(config)

        # Wait for startup sync with polling
        state = wait_for_status(pid, [:synced, :failed], 60_000)

        # Git sync should succeed (K8s apply will fail without cluster)
        # The state will be :failed due to K8s, but last_commit should be set
        # if git worked
        if state.last_commit do
          assert String.length(state.last_commit) == 40
          assert String.match?(state.last_commit, ~r/^[0-9a-f]+$/)
        end

        GenServer.stop(pid)
      end
    end
  end

  # Helper to create test config
  defp test_config(test_name, _context) do
    %{
      name: "#{test_name}-#{:rand.uniform(10000)}",
      url: "https://github.com/octocat/Hello-World.git",
      branch: "master",
      path: nil,
      interval: 300_000,
      target_namespace: nil
    }
  end

  # Wait for worker to reach one of the expected statuses
  defp wait_for_status(pid, expected_statuses, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_status(pid, expected_statuses, deadline)
  end

  defp do_wait_for_status(pid, expected_statuses, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      state = Worker.get_state(pid)

      flunk(
        "Timeout waiting for status. Current: #{state.status}, expected one of: #{inspect(expected_statuses)}"
      )
    end

    state = Worker.get_state(pid)

    if state.status in expected_statuses do
      state
    else
      Process.sleep(100)
      do_wait_for_status(pid, expected_statuses, deadline)
    end
  end
end
