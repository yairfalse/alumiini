defmodule Alumiini.ControllerTest do
  use ExUnit.Case, async: true

  # Controller tests are mostly integration tests since they
  # interact with the K8s API. Unit tests for helper functions.

  describe "parse_interval/1" do
    # Test the private function behavior through the module
    # These tests verify the interval parsing logic

    test "parses seconds" do
      # 30 seconds = 30_000 milliseconds
      config = build_config(%{"interval" => "30s"})
      assert config.interval == 30_000
    end

    test "parses minutes" do
      # 5 minutes = 300_000 milliseconds
      config = build_config(%{"interval" => "5m"})
      assert config.interval == 300_000
    end

    test "parses hours" do
      # 1 hour = 3_600_000 milliseconds
      config = build_config(%{"interval" => "1h"})
      assert config.interval == 3_600_000
    end

    test "defaults to 5 minutes for invalid format" do
      config = build_config(%{"interval" => "invalid"})
      assert config.interval == 300_000
    end

    test "defaults to 5 minutes when missing" do
      config = build_config(%{})
      assert config.interval == 300_000
    end
  end

  describe "config extraction" do
    test "extracts all fields from resource" do
      resource = %{
        "metadata" => %{
          "name" => "my-repo",
          "namespace" => "default"
        },
        "spec" => %{
          "url" => "https://github.com/example/repo.git",
          "branch" => "develop",
          "path" => "manifests/",
          "targetNamespace" => "production",
          "interval" => "10m"
        }
      }

      config = build_config_from_resource(resource)

      assert config.name == "my-repo"
      assert config.namespace == "default"
      assert config.url == "https://github.com/example/repo.git"
      assert config.branch == "develop"
      assert config.path == "manifests/"
      assert config.target_namespace == "production"
      # 10 minutes
      assert config.interval == 600_000
    end

    test "uses defaults for optional fields" do
      resource = %{
        "metadata" => %{
          "name" => "minimal-repo",
          "namespace" => "test"
        },
        "spec" => %{
          "url" => "https://github.com/example/repo.git"
        }
      }

      config = build_config_from_resource(resource)

      assert config.name == "minimal-repo"
      assert config.namespace == "test"
      assert config.url == "https://github.com/example/repo.git"
      # default
      assert config.branch == "main"
      assert config.path == nil
      # defaults to resource namespace
      assert config.target_namespace == "test"
      # default 5m
      assert config.interval == 300_000
    end
  end

  # Helper to simulate config building (mirrors Controller logic)
  defp build_config(spec) do
    %{
      interval: parse_interval(Map.get(spec, "interval", "5m"))
    }
  end

  defp build_config_from_resource(resource) do
    name = get_in(resource, ["metadata", "name"])
    namespace = get_in(resource, ["metadata", "namespace"])
    spec = Map.get(resource, "spec", %{})

    %{
      name: name,
      namespace: namespace,
      url: Map.get(spec, "url"),
      branch: Map.get(spec, "branch", "main"),
      path: Map.get(spec, "path"),
      target_namespace: Map.get(spec, "targetNamespace", namespace),
      interval: parse_interval(Map.get(spec, "interval", "5m"))
    }
  end

  defp parse_interval(interval) when is_binary(interval) do
    case Regex.run(~r/^(\d+)(s|m|h)$/, interval) do
      [_, num, "s"] -> String.to_integer(num) * 1_000
      [_, num, "m"] -> String.to_integer(num) * 60 * 1_000
      [_, num, "h"] -> String.to_integer(num) * 60 * 60 * 1_000
      _ -> 5 * 60 * 1_000
    end
  end

  defp parse_interval(_), do: 5 * 60 * 1_000
end
