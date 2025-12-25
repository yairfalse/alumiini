defmodule Nopea.Drift do
  @moduledoc """
  Three-way drift detection for GitOps reconciliation.

  Compares three states to detect drift:
  - **Last Applied**: What we last applied to the cluster
  - **Desired**: What's currently in git (desired state)
  - **Live**: What's actually in the K8s cluster

  This enables detecting both:
  - Git changes (desired ≠ last_applied)
  - Manual drift (live ≠ last_applied)

  ## Example

      case Drift.three_way_diff(last_applied, desired, live) do
        :no_drift -> :ok
        {:git_change, diff} -> apply_and_update_cache(desired)
        {:manual_drift, diff} -> heal_drift(desired)
        {:conflict, diff} -> resolve_conflict(desired, live)
      end
  """

  require Logger

  @type diff_result ::
          :no_drift
          | {:git_change, map()}
          | {:manual_drift, map()}
          | {:conflict, map()}

  # Fields that K8s adds automatically and should be ignored in comparisons
  @k8s_managed_metadata_fields [
    "resourceVersion",
    "uid",
    "creationTimestamp",
    "generation",
    "managedFields",
    "selfLink"
  ]

  # Annotations that should be stripped
  @k8s_managed_annotations [
    "kubectl.kubernetes.io/last-applied-configuration"
  ]

  @doc """
  Normalizes a manifest by removing K8s-managed fields.

  Strips:
  - `metadata.resourceVersion`, `uid`, `creationTimestamp`, `generation`, `managedFields`
  - `status` section entirely
  - `kubectl.kubernetes.io/last-applied-configuration` annotation

  This allows comparing manifests from different sources (git vs cluster)
  without false positives from K8s-added fields.
  """
  @spec normalize(map()) :: map()
  def normalize(manifest) when is_map(manifest) do
    manifest
    |> strip_status()
    |> strip_managed_metadata()
    |> strip_managed_annotations()
  end

  @doc """
  Performs three-way diff to detect drift type.

  ## Parameters

  - `last_applied` - The manifest we last applied to the cluster
  - `desired` - The current desired state from git
  - `live` - The current state in the K8s cluster

  ## Returns

  - `:no_drift` - All three states match (normalized)
  - `{:git_change, diff}` - Git has changed, cluster matches last applied
  - `{:manual_drift, diff}` - Cluster changed manually, git matches last applied
  - `{:conflict, diff}` - Both git and cluster have diverged from last applied
  """
  @spec three_way_diff(map(), map(), map()) :: diff_result()
  def three_way_diff(last_applied, desired, live) do
    # Normalize all three for comparison
    norm_last = normalize(last_applied)
    norm_desired = normalize(desired)
    norm_live = normalize(live)

    # Compute hashes for comparison
    last_hash = do_hash(norm_last)
    desired_hash = do_hash(norm_desired)
    live_hash = do_hash(norm_live)

    git_changed = desired_hash != last_hash
    manual_drift = live_hash != last_hash

    cond do
      not git_changed and not manual_drift ->
        :no_drift

      git_changed and not manual_drift ->
        {:git_change, %{from: last_hash, to: desired_hash}}

      not git_changed and manual_drift ->
        {:manual_drift, %{expected: last_hash, actual: live_hash}}

      git_changed and manual_drift ->
        {:conflict, %{last: last_hash, desired: desired_hash, live: live_hash}}
    end
  end

  @doc """
  Checks if the desired state (from git) differs from the last-applied state.

  This is a simplified two-way comparison for detecting git changes when
  cluster state is not available. For full three-way drift detection
  (including manual drift), use `three_way_diff/3`.

  ## Returns

  - `false` - No changes (git matches last-applied)
  - `{:changed, diff}` - Git has changed since last apply
  """
  @spec git_changed?(map(), map()) :: false | {:changed, map()}
  def git_changed?(last_applied, desired) do
    norm_last = normalize(last_applied)
    norm_desired = normalize(desired)

    last_hash = do_hash(norm_last)
    desired_hash = do_hash(norm_desired)

    if last_hash == desired_hash do
      false
    else
      {:changed, %{from: last_hash, to: desired_hash}}
    end
  end

  @doc """
  Performs three-way drift detection with cluster state.

  This is the main entry point for full drift detection that compares:
  - `last_applied` - What we last applied to the cluster (from cache)
  - `desired` - What's currently in git (desired state)
  - `live` - What's actually in the K8s cluster (from K8s GET)

  All manifests are normalized before comparison to ignore K8s-managed fields.

  ## Returns

  - `:no_drift` - All states match (no action needed)
  - `{:git_change, diff}` - Git changed, cluster matches last applied
  - `{:manual_drift, diff}` - Cluster was manually changed
  - `{:conflict, diff}` - Both git and cluster have diverged
  """
  @spec detect_drift_with_cluster(map(), map(), map()) :: diff_result()
  def detect_drift_with_cluster(last_applied, desired, live) do
    three_way_diff(last_applied, desired, live)
  end

  @doc """
  Checks a manifest for drift by fetching live state from K8s.

  This function:
  1. Extracts resource key from the manifest
  2. Looks up last_applied from Cache
  3. Fetches live state from K8s cluster
  4. Performs three-way drift detection

  ## Options

  - `:k8s_module` - K8s module to use (default: `Nopea.K8s`)
  - `:cache_module` - Cache module to use (default: `Nopea.Cache`)

  ## Returns

  - `:no_drift` - All states match
  - `{:git_change, diff}` - Git has changed
  - `{:manual_drift, diff}` - Cluster was manually modified
  - `{:conflict, diff}` - Both changed
  - `:new_resource` - Resource doesn't exist in cluster or cache
  - `:needs_apply` - Resource exists in cluster but not in cache (needs baseline)
  """
  @spec check_manifest_drift(String.t(), map(), keyword()) ::
          diff_result() | :new_resource | :needs_apply
  def check_manifest_drift(repo_name, manifest, opts \\ []) do
    k8s_module = Keyword.get(opts, :k8s_module, Nopea.K8s)
    cache_module = Keyword.get(opts, :cache_module, Nopea.Cache)

    resource_key = Nopea.Applier.resource_key(manifest)
    api_version = Map.fetch!(manifest, "apiVersion")
    kind = Map.fetch!(manifest, "kind")
    name = get_in(manifest, ["metadata", "name"])
    namespace = get_in(manifest, ["metadata", "namespace"]) || "default"

    # Get last_applied from cache
    last_applied_result = cache_module.get_last_applied(repo_name, resource_key)

    # Get live state from cluster
    live_result = k8s_module.get_resource(api_version, kind, name, namespace)

    case {last_applied_result, live_result} do
      # No cache, no cluster -> new resource
      {{:error, :not_found}, {:error, _}} ->
        :new_resource

      # No cache, but exists in cluster -> needs apply to establish baseline
      {{:error, :not_found}, {:ok, _live}} ->
        :needs_apply

      # Has cache, no cluster -> resource was deleted, treat as new
      {{:ok, _last}, {:error, _}} ->
        :new_resource

      # Both exist -> do three-way diff
      {{:ok, last_applied}, {:ok, live}} ->
        detect_drift_with_cluster(last_applied, manifest, live)
    end
  end

  @doc """
  Checks a manifest for drift and returns the live resource.

  Same as `check_manifest_drift/3` but returns a tuple `{result, live}` where
  `live` is the actual resource from the K8s cluster (or nil if not found).

  This is useful when you need to inspect the live resource for additional
  filtering (e.g., checking break-glass annotations).

  ## Returns

  - `{:no_drift, live}` - All states match
  - `{{:git_change, diff}, live}` - Git has changed
  - `{{:manual_drift, diff}, live}` - Cluster was manually modified
  - `{{:conflict, diff}, live}` - Both changed
  - `{:new_resource, nil}` - Resource doesn't exist in cluster
  - `{:needs_apply, live}` - Resource exists but not in cache
  """
  @spec check_manifest_drift_with_live(String.t(), map(), keyword()) ::
          {diff_result() | :new_resource | :needs_apply, map() | nil}
  def check_manifest_drift_with_live(repo_name, manifest, opts \\ []) do
    k8s_module = Keyword.get(opts, :k8s_module, Nopea.K8s)
    cache_module = Keyword.get(opts, :cache_module, Nopea.Cache)

    resource_key = Nopea.Applier.resource_key(manifest)
    api_version = Map.fetch!(manifest, "apiVersion")
    kind = Map.fetch!(manifest, "kind")
    name = get_in(manifest, ["metadata", "name"])
    namespace = get_in(manifest, ["metadata", "namespace"]) || "default"

    # Get last_applied from cache
    last_applied_result = cache_module.get_last_applied(repo_name, resource_key)

    # Get live state from cluster
    live_result = k8s_module.get_resource(api_version, kind, name, namespace)

    case {last_applied_result, live_result} do
      # No cache, no cluster -> new resource
      {{:error, :not_found}, {:error, _}} ->
        {:new_resource, nil}

      # No cache, but exists in cluster -> needs apply to establish baseline
      {{:error, :not_found}, {:ok, live}} ->
        {:needs_apply, live}

      # Has cache, no cluster -> resource was deleted, treat as new
      {{:ok, _last}, {:error, _}} ->
        {:new_resource, nil}

      # Both exist -> do three-way diff
      {{:ok, last_applied}, {:ok, live}} ->
        drift_result = detect_drift_with_cluster(last_applied, manifest, live)
        {drift_result, live}
    end
  end

  @doc """
  Computes a normalized hash of a manifest for drift detection.

  The manifest is normalized before hashing, so K8s-added fields
  don't affect the hash.
  """
  @spec compute_hash(map()) :: {:ok, String.t()} | {:error, term()}
  def compute_hash(manifest) do
    normalized = normalize(manifest)
    {:ok, "sha256:#{do_hash(normalized)}"}
  end

  @suspend_heal_annotation "nopea.io/suspend-heal"
  @truthy_values ["true", "1", "yes"]

  @doc """
  Checks if a resource has the break-glass annotation that suspends healing.

  Returns `true` if the resource has the `nopea.io/suspend-heal` annotation
  set to a truthy value ("true", "1", or "yes"), indicating that NOPEA
  should NOT heal drift on this resource.

  This is the "break-glass" escape hatch for emergencies - ops can add this
  annotation with their kubectl hotfix to prevent NOPEA from reverting it.

  ## Examples

      # Emergency hotfix - protect from NOPEA
      kubectl annotate deploy/api nopea.io/suspend-heal=true
      kubectl set image deploy/api image=hotfix-v1

      # Later, remove annotation to resume GitOps
      kubectl annotate deploy/api nopea.io/suspend-heal-

  """
  @spec healing_suspended?(map() | nil) :: boolean()
  def healing_suspended?(nil), do: false

  def healing_suspended?(resource) when is_map(resource) do
    resource
    |> get_in(["metadata", "annotations", @suspend_heal_annotation])
    |> truthy?()
  end

  defp truthy?(value) when value in @truthy_values, do: true
  defp truthy?(_), do: false

  # Private functions

  defp strip_status(manifest) do
    Map.delete(manifest, "status")
  end

  defp strip_managed_metadata(manifest) do
    case Map.get(manifest, "metadata") do
      nil ->
        manifest

      metadata ->
        cleaned_metadata = Map.drop(metadata, @k8s_managed_metadata_fields)
        Map.put(manifest, "metadata", cleaned_metadata)
    end
  end

  defp strip_managed_annotations(manifest) do
    case get_in(manifest, ["metadata", "annotations"]) do
      nil ->
        manifest

      annotations ->
        cleaned_annotations = Map.drop(annotations, @k8s_managed_annotations)

        # Remove annotations key entirely if empty
        if map_size(cleaned_annotations) == 0 do
          update_in(manifest, ["metadata"], &Map.delete(&1, "annotations"))
        else
          put_in(manifest, ["metadata", "annotations"], cleaned_annotations)
        end
    end
  end

  # Core hashing implementation - encodes to JSON and hashes with SHA256
  defp do_hash(normalized_manifest) do
    # JSON encoding should always succeed for valid K8s manifests
    # If it fails, we fall back to inspect() for safety
    json =
      case Jason.encode(normalized_manifest, pretty: false) do
        {:ok, encoded} -> encoded
        {:error, _} -> inspect(normalized_manifest)
      end

    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end
end
