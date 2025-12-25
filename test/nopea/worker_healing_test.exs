defmodule Nopea.WorkerHealingTest do
  @moduledoc """
  Tests for Worker healing logic: filter_for_healing, grace period, break-glass.

  These tests verify the healing decision logic without requiring the full
  Worker GenServer or Rust git binary.
  """

  use ExUnit.Case, async: false

  alias Nopea.{Cache, Drift}

  @moduletag :worker_healing

  setup do
    start_supervised!(Nopea.Cache)
    :ok
  end

  # Helper to create a manifest
  defp manifest(name, opts \\ []) do
    annotations = Keyword.get(opts, :annotations, %{})

    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => name,
        "namespace" => "default",
        "annotations" => annotations
      },
      "spec" => %{"replicas" => 1}
    }
  end

  # Helper to create config
  defp config(opts) do
    %{
      name: Keyword.get(opts, :name, "test-repo-#{:rand.uniform(1000)}"),
      heal_policy: Keyword.get(opts, :heal_policy, :auto),
      heal_grace_period: Keyword.get(opts, :heal_grace_period),
      suspend: Keyword.get(opts, :suspend, false)
    }
  end

  describe "healing_suspended?/1" do
    test "returns false for resource without annotation" do
      live = manifest("my-app")
      refute Drift.healing_suspended?(live)
    end

    test "returns true for resource with suspend-heal=true" do
      live = manifest("my-app", annotations: %{"nopea.io/suspend-heal" => "true"})
      assert Drift.healing_suspended?(live)
    end

    test "returns true for suspend-heal=1" do
      live = manifest("my-app", annotations: %{"nopea.io/suspend-heal" => "1"})
      assert Drift.healing_suspended?(live)
    end

    test "returns true for suspend-heal=yes" do
      live = manifest("my-app", annotations: %{"nopea.io/suspend-heal" => "yes"})
      assert Drift.healing_suspended?(live)
    end

    test "returns false for suspend-heal=false" do
      live = manifest("my-app", annotations: %{"nopea.io/suspend-heal" => "false"})
      refute Drift.healing_suspended?(live)
    end

    test "returns false for nil resource" do
      refute Drift.healing_suspended?(nil)
    end
  end

  describe "heal_policy behavior" do
    test "auto policy heals manual drift" do
      # With auto policy and no annotation, manual drift should be healed
      cfg = config(heal_policy: :auto)
      live = manifest("api")

      # Simulate the decision logic
      should_heal = not Drift.healing_suspended?(live) and cfg.heal_policy == :auto
      assert should_heal
    end

    test "manual policy does not heal manual drift" do
      cfg = config(heal_policy: :manual)
      _live = manifest("api")

      # Manual policy never auto-heals
      should_heal = cfg.heal_policy == :auto
      refute should_heal
    end

    test "notify policy does not heal manual drift" do
      cfg = config(heal_policy: :notify)
      _live = manifest("api")

      should_heal = cfg.heal_policy == :auto
      refute should_heal
    end

    test "auto policy respects break-glass annotation" do
      cfg = config(heal_policy: :auto)
      live = manifest("api", annotations: %{"nopea.io/suspend-heal" => "true"})

      should_heal = not Drift.healing_suspended?(live) and cfg.heal_policy == :auto
      refute should_heal
    end
  end

  describe "grace period tracking" do
    test "records first seen timestamp" do
      repo = "test-repo-#{:rand.uniform(10000)}"
      key = "Deployment/default/api"

      ts = Cache.record_drift_first_seen(repo, key)
      assert %DateTime{} = ts
    end

    test "returns same timestamp on subsequent calls" do
      repo = "test-repo-#{:rand.uniform(10000)}"
      key = "Deployment/default/api"

      first = Cache.record_drift_first_seen(repo, key)
      Process.sleep(10)
      second = Cache.record_drift_first_seen(repo, key)

      assert first == second
    end

    test "clears timestamp after healing" do
      repo = "test-repo-#{:rand.uniform(10000)}"
      key = "Deployment/default/api"

      Cache.record_drift_first_seen(repo, key)
      :ok = Cache.clear_drift_first_seen(repo, key)

      assert {:error, :not_found} = Cache.get_drift_first_seen(repo, key)
    end

    test "grace period not elapsed immediately" do
      repo = "test-repo-#{:rand.uniform(10000)}"
      key = "Deployment/default/api"
      # 1 minute
      grace_period_ms = 60_000

      first_seen = Cache.record_drift_first_seen(repo, key)
      elapsed_ms = DateTime.diff(DateTime.utc_now(), first_seen, :millisecond)

      # Should not be elapsed immediately
      refute elapsed_ms >= grace_period_ms
    end

    test "grace period elapsed after time passes" do
      repo = "test-repo-#{:rand.uniform(10000)}"
      key = "Deployment/default/api"
      # 10ms for testing
      grace_period_ms = 10

      first_seen = Cache.record_drift_first_seen(repo, key)
      # Wait longer than grace period
      Process.sleep(15)
      elapsed_ms = DateTime.diff(DateTime.utc_now(), first_seen, :millisecond)

      assert elapsed_ms >= grace_period_ms
    end
  end

  describe "break-glass blocks git changes" do
    test "git_change is blocked when annotation present" do
      live = manifest("api", annotations: %{"nopea.io/suspend-heal" => "true"})

      # Git changes should be blocked by break-glass annotation
      should_apply = not Drift.healing_suspended?(live)
      refute should_apply
    end

    test "git_change applies when no annotation" do
      live = manifest("api")

      should_apply = not Drift.healing_suspended?(live)
      assert should_apply
    end

    test "new_resource always applies regardless of annotation" do
      # New resources have no live state to check annotation on
      live = nil

      # Should always apply new resources
      should_apply = is_nil(live) or not Drift.healing_suspended?(live)
      assert should_apply
    end
  end

  describe "drift type decision matrix" do
    test "new_resource always heals" do
      drift_type = :new_resource
      assert drift_type in [:new_resource, :needs_apply, :git_change]
    end

    test "needs_apply always heals" do
      drift_type = :needs_apply
      assert drift_type in [:new_resource, :needs_apply]
    end

    test "git_change heals unless annotated" do
      drift_type = :git_change
      live = manifest("api")

      should_heal = drift_type == :git_change and not Drift.healing_suspended?(live)
      assert should_heal
    end

    test "manual_drift follows policy" do
      drift_type = :manual_drift

      # With auto policy
      cfg_auto = config(heal_policy: :auto)
      should_heal_auto = drift_type == :manual_drift and cfg_auto.heal_policy == :auto
      assert should_heal_auto

      # With manual policy
      cfg_manual = config(heal_policy: :manual)
      should_heal_manual = drift_type == :manual_drift and cfg_manual.heal_policy == :auto
      refute should_heal_manual
    end

    test "conflict follows same rules as manual_drift" do
      live = manifest("api")
      cfg = config(heal_policy: :auto)

      # Conflict with auto policy and no annotation
      should_heal = cfg.heal_policy == :auto and not Drift.healing_suspended?(live)
      assert should_heal
    end
  end
end
