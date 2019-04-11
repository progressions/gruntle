defmodule GruntleTest do
  use ExUnit.Case
  doctest Gruntle

  test "greets the world" do
    assert Gruntle.hello() == :world
  end
end
