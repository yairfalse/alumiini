defmodule Nopea.EventsTest do
  use ExUnit.Case, async: true

  alias Nopea.Events

  @moduletag :events

  describe "service_deployed/2 builder" do
    test "creates a service.deployed event with required fields" do
      event =
        Events.service_deployed("my-app", %{
          commit: "abc123def456",
          namespace: "production",
          manifest_count: 5,
          duration_ms: 1234,
          source_url: "https://github.com/org/my-app"
        })

      assert event.type == "dev.cdevents.service.deployed.0.3.0"
      assert event.source == "/nopea/worker/my-app"
      assert event.subject.id == "my-app"
      assert event.subject.content.environment.id == "production"
      assert event.subject.content.artifactId == "pkg:git/my-app@abc123def456"
      assert event.subject.content.manifest_count == 5
      assert event.subject.content.duration_ms == 1234
    end

    test "uses default namespace when not provided" do
      event = Events.service_deployed("my-app", %{commit: "abc123"})

      assert event.subject.content.environment.id == "default"
    end
  end

  describe "service_upgraded/2 builder" do
    test "creates a service.upgraded event" do
      event =
        Events.service_upgraded("my-app", %{
          commit: "newcommit123",
          namespace: "staging",
          previous_commit: "oldcommit456"
        })

      assert event.type == "dev.cdevents.service.upgraded.0.3.0"
      assert event.subject.content.artifactId == "pkg:git/my-app@newcommit123"
      assert event.subject.content.previous_commit == "oldcommit456"
    end
  end

  describe "sync_failed/2 builder" do
    test "creates an event with error details" do
      event =
        Events.sync_failed("my-app", %{
          namespace: "production",
          error: {:git_error, "network timeout"},
          commit: nil,
          duration_ms: 500
        })

      # sync_failed uses service.removed with failure indicator
      assert event.type == "dev.cdevents.service.removed.0.3.0"
      # Error is normalized to JSON-serializable map
      assert event.subject.content.error == %{type: "git_error", message: "network timeout"}
      assert event.subject.content.outcome == "failure"
      assert event.subject.content.duration_ms == 500
    end

    test "serializes to JSON without errors" do
      event =
        Events.sync_failed("my-app", %{
          error: {:git_error, "network timeout"},
          namespace: "production"
        })

      # Should not raise - tuples are normalized to maps
      {:ok, json} = Events.to_json(event)
      decoded = Jason.decode!(json)

      assert decoded["subject"]["content"]["error"]["type"] == "git_error"
      assert decoded["subject"]["content"]["error"]["message"] == "network timeout"
    end
  end

  describe "CDEvent struct" do
    test "new/1 creates a valid event with required context fields" do
      event =
        Events.new(%{
          type: :service_deployed,
          source: "/nopea/worker/my-app",
          subject_id: "my-app-service",
          content: %{
            environment: %{id: "production", source: "/k8s/cluster"},
            artifactId: "pkg:oci/my-app@sha256:abc123"
          }
        })

      # Context fields (CDEvents spec v0.5.0)
      assert is_binary(event.id)
      # ULID format (Crockford Base32)
      assert String.length(event.id) == 26
      assert event.type == "dev.cdevents.service.deployed.0.3.0"
      assert event.source == "/nopea/worker/my-app"
      assert event.specversion == "1.0"
      assert %DateTime{} = event.timestamp

      # Subject fields
      assert event.subject.id == "my-app-service"
      assert event.subject.content.environment.id == "production"
      assert event.subject.content.artifactId == "pkg:oci/my-app@sha256:abc123"
    end

    test "new/1 generates unique IDs for each event" do
      event1 =
        Events.new(%{type: :service_deployed, source: "/test", subject_id: "svc1", content: %{}})

      event2 =
        Events.new(%{type: :service_deployed, source: "/test", subject_id: "svc1", content: %{}})

      refute event1.id == event2.id
    end

    test "new/1 supports all GitOps-relevant event types" do
      types = [
        {:service_deployed, "dev.cdevents.service.deployed.0.3.0"},
        {:service_upgraded, "dev.cdevents.service.upgraded.0.3.0"},
        {:service_removed, "dev.cdevents.service.removed.0.3.0"},
        {:environment_created, "dev.cdevents.environment.created.0.3.0"},
        {:environment_modified, "dev.cdevents.environment.modified.0.3.0"}
      ]

      for {atom_type, expected_string} <- types do
        event = Events.new(%{type: atom_type, source: "/test", subject_id: "id", content: %{}})
        assert event.type == expected_string, "Expected #{atom_type} to map to #{expected_string}"
      end
    end
  end

  describe "to_json/1" do
    test "serializes event to CloudEvents-compatible JSON" do
      event =
        Events.new(%{
          type: :service_deployed,
          source: "/nopea/worker/my-app",
          subject_id: "my-service",
          content: %{
            environment: %{id: "prod", source: "/k8s"},
            artifactId: "pkg:oci/app@sha256:def"
          }
        })

      {:ok, json} = Events.to_json(event)
      decoded = Jason.decode!(json)

      # CloudEvents envelope
      assert decoded["id"] == event.id
      assert decoded["type"] == "dev.cdevents.service.deployed.0.3.0"
      assert decoded["source"] == "/nopea/worker/my-app"
      assert decoded["specversion"] == "1.0"
      assert is_binary(decoded["timestamp"])

      # CDEvents subject
      assert decoded["subject"]["id"] == "my-service"
      assert decoded["subject"]["content"]["environment"]["id"] == "prod"
    end
  end
end
