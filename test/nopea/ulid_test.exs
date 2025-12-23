defmodule Nopea.ULIDTest do
  use ExUnit.Case, async: true

  alias Nopea.ULID

  @moduletag :ulid

  describe "generate/0" do
    test "generates a 26-character ULID" do
      ulid = ULID.generate()
      assert is_binary(ulid)
      assert String.length(ulid) == 26
    end

    test "generates unique IDs" do
      ulids = for _ <- 1..100, do: ULID.generate()
      assert length(Enum.uniq(ulids)) == 100
    end

    test "generates monotonically increasing IDs" do
      ulids = for _ <- 1..100, do: ULID.generate()

      # ULIDs should be lexicographically sorted
      sorted = Enum.sort(ulids)
      assert ulids == sorted
    end
  end

  describe "generate_random/0" do
    test "generates a 26-character ULID without Agent" do
      ulid = ULID.generate_random()
      assert is_binary(ulid)
      assert String.length(ulid) == 26
    end

    test "generates valid ULIDs that can be parsed" do
      ulid = ULID.generate_random()
      assert {:ok, {timestamp, _random}} = ULID.parse(ulid)
      assert is_integer(timestamp)
      assert timestamp > 0
    end
  end

  describe "parse/1" do
    test "parses a valid ULID" do
      ulid = ULID.generate()
      assert {:ok, {timestamp, random}} = ULID.parse(ulid)
      assert is_integer(timestamp)
      assert is_integer(random)
    end

    test "returns error for invalid length" do
      assert {:error, :invalid_length} = ULID.parse("too_short")
      assert {:error, :invalid_length} = ULID.parse("")
      assert {:error, :invalid_length} = ULID.parse(nil)
    end

    test "returns error for invalid characters" do
      # I, L, O, U are not valid in Crockford Base32
      assert {:error, :invalid_character} = ULID.parse("01HQGXVP00ABCDEFGHIJKLMNOP")
    end
  end

  describe "timestamp/1" do
    test "extracts timestamp as DateTime" do
      ulid = ULID.generate()
      assert {:ok, %DateTime{} = dt} = ULID.timestamp(ulid)

      # Should be within the last minute
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)
      assert diff >= 0 and diff < 60
    end

    test "returns error for invalid ULID" do
      assert {:error, :invalid_ulid} = ULID.timestamp("invalid")
    end
  end

  describe "valid?/1" do
    test "returns true for valid ULIDs" do
      ulid = ULID.generate()
      assert ULID.valid?(ulid)
    end

    test "returns false for invalid ULIDs" do
      refute ULID.valid?("too_short")
      refute ULID.valid?("")
      refute ULID.valid?(nil)
      refute ULID.valid?(123)
    end
  end

  describe "generate_with_timestamp/1" do
    test "generates ULID with specific timestamp" do
      timestamp = DateTime.utc_now()
      ulid = ULID.generate_with_timestamp(timestamp)

      assert {:ok, extracted} = ULID.timestamp(ulid)
      # Should be within 1 second (millisecond precision)
      assert DateTime.diff(extracted, timestamp, :millisecond) |> abs() < 1000
    end

    test "accepts integer milliseconds" do
      ms = System.system_time(:millisecond)
      ulid = ULID.generate_with_timestamp(ms)

      assert {:ok, {extracted_ms, _}} = ULID.parse(ulid)
      assert extracted_ms == ms
    end
  end

  describe "encoding roundtrip" do
    test "parse extracts correct values from generated ULID" do
      now_ms = System.system_time(:millisecond)
      ulid = ULID.generate()

      {:ok, {timestamp, _random}} = ULID.parse(ulid)

      # Timestamp should be close to now
      assert abs(timestamp - now_ms) < 1000
    end
  end
end
