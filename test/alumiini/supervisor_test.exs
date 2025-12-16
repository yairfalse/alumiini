defmodule Alumiini.SupervisorTest do
  use ExUnit.Case, async: false

  alias Alumiini.Supervisor, as: AlumSupervisor

  # Application is started by test_helper.exs

  describe "start_worker/1" do
    test "starts a worker for a repo config" do
      config = %{
        name: "test-repo-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      assert {:ok, pid} = AlumSupervisor.start_worker(config)
      assert Process.alive?(pid)

      # Cleanup
      AlumSupervisor.stop_worker(config.name)
    end

    test "returns error for duplicate repo name" do
      config = %{
        name: "dup-repo-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, _pid} = AlumSupervisor.start_worker(config)
      assert {:error, {:already_started, _}} = AlumSupervisor.start_worker(config)

      # Cleanup
      AlumSupervisor.stop_worker(config.name)
    end
  end

  describe "stop_worker/1" do
    test "stops a running worker" do
      config = %{
        name: "stop-repo-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, pid} = AlumSupervisor.start_worker(config)
      assert Process.alive?(pid)

      :ok = AlumSupervisor.stop_worker(config.name)
      refute Process.alive?(pid)
    end

    test "returns error for unknown worker" do
      assert {:error, :not_found} = AlumSupervisor.stop_worker("unknown-repo")
    end
  end

  describe "list_workers/0" do
    test "returns list of active workers" do
      config1 = %{
        name: "list-repo-1-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo1.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      config2 = %{
        name: "list-repo-2-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo2.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, _} = AlumSupervisor.start_worker(config1)
      {:ok, _} = AlumSupervisor.start_worker(config2)

      workers = AlumSupervisor.list_workers()
      assert Enum.any?(workers, fn {name, _pid} -> name == config1.name end)
      assert Enum.any?(workers, fn {name, _pid} -> name == config2.name end)

      # Cleanup
      AlumSupervisor.stop_worker(config1.name)
      AlumSupervisor.stop_worker(config2.name)
    end
  end

  describe "get_worker/1" do
    test "returns pid for known worker" do
      config = %{
        name: "get-repo-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, pid} = AlumSupervisor.start_worker(config)
      assert {:ok, ^pid} = AlumSupervisor.get_worker(config.name)

      # Cleanup
      AlumSupervisor.stop_worker(config.name)
    end

    test "returns error for unknown worker" do
      assert {:error, :not_found} = AlumSupervisor.get_worker("unknown")
    end
  end
end
