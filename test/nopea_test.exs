defmodule NopeaTest do
  use ExUnit.Case
  doctest Nopea

  test "greets the world" do
    assert Nopea.hello() == :world
  end
end
