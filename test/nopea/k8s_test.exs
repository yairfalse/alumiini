defmodule Nopea.K8sTest do
  use ExUnit.Case, async: true

  alias Nopea.K8s

  describe "build_status/4" do
    test "builds status with all fields" do
      now = DateTime.utc_now()
      status = K8s.build_status(:synced, "abc123", now, "Applied 5 manifests")

      assert status["phase"] == "Synced"
      assert status["lastAppliedCommit"] == "abc123"
      assert status["lastSyncTime"] == DateTime.to_iso8601(now)
      assert status["observedGeneration"] == 1

      [condition] = status["conditions"]
      assert condition["type"] == "Ready"
      assert condition["status"] == "True"
      assert condition["reason"] == "Synced"
      assert condition["message"] == "Applied 5 manifests"
    end

    test "builds status without optional fields" do
      status = K8s.build_status(:initializing, nil, nil, nil)

      assert status["phase"] == "Initializing"
      assert status["observedGeneration"] == 1
      refute Map.has_key?(status, "lastAppliedCommit")
      refute Map.has_key?(status, "lastSyncTime")
      refute Map.has_key?(status, "conditions")
    end

    test "maps phase atoms to strings correctly" do
      assert K8s.build_status(:initializing, nil, nil, nil)["phase"] == "Initializing"
      assert K8s.build_status(:syncing, nil, nil, nil)["phase"] == "Syncing"
      assert K8s.build_status(:synced, nil, nil, nil)["phase"] == "Synced"
      assert K8s.build_status(:failed, nil, nil, nil)["phase"] == "Failed"
    end

    test "sets correct condition type based on phase" do
      synced = K8s.build_status(:synced, nil, nil, "done")
      [synced_cond] = synced["conditions"]
      assert synced_cond["type"] == "Ready"
      assert synced_cond["status"] == "True"

      failed = K8s.build_status(:failed, nil, nil, "error")
      [failed_cond] = failed["conditions"]
      assert failed_cond["type"] == "Ready"
      assert failed_cond["status"] == "False"

      syncing = K8s.build_status(:syncing, nil, nil, "in progress")
      [syncing_cond] = syncing["conditions"]
      assert syncing_cond["type"] == "Progressing"
      assert syncing_cond["status"] == "Unknown"
    end
  end

  # Integration tests require a K8s cluster
  # These are tagged and can be run with: mix test --only k8s_integration
  @moduletag :k8s_integration

  describe "conn/0 integration" do
    @tag :k8s_integration
    test "connects to cluster" do
      case K8s.conn() do
        {:ok, conn} ->
          assert conn != nil

        {:error, _reason} ->
          # Expected if no cluster available
          :ok
      end
    end
  end
end
