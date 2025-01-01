defmodule ElixirRaft.Core.TermTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Core.Term

  describe "new/0" do
    test "creates term starting at 0" do
      assert Term.new() == 0
    end
  end

  describe "increment/1" do
    test "increments term by 1" do
      assert Term.increment(0) == 1
      assert Term.increment(1) == 2
      assert Term.increment(999) == 1000
    end
  end

  describe "validate/1" do
    test "accepts valid terms" do
      assert {:ok, 0} = Term.validate(0)
      assert {:ok, 1} = Term.validate(1)
      assert {:ok, 1000} = Term.validate(1000)
    end

    test "rejects negative numbers" do
      assert {:error, "Term cannot be negative"} = Term.validate(-1)
      assert {:error, "Term cannot be negative"} = Term.validate(-1000)
    end

    test "rejects non-integers" do
      assert {:error, "Term must be a non-negative integer"} = Term.validate(1.5)
      assert {:error, "Term must be a non-negative integer"} = Term.validate("1")
      assert {:error, "Term must be a non-negative integer"} = Term.validate(nil)
    end
  end

  describe "validate!/1" do
    test "returns valid terms unchanged" do
      assert Term.validate!(0) == 0
      assert Term.validate!(1) == 1
      assert Term.validate!(1000) == 1000
    end

    test "raises for invalid terms" do
      assert_raise ArgumentError, "Term cannot be negative", fn ->
        Term.validate!(-1)
      end

      assert_raise ArgumentError, "Term must be a non-negative integer", fn ->
        Term.validate!(1.5)
      end
    end
  end

  describe "compare/2" do
    test "correctly compares terms" do
      assert :eq = Term.compare(1, 1)
      assert :lt = Term.compare(1, 2)
      assert :gt = Term.compare(2, 1)
    end
  end

  describe "greater_than?/2" do
    test "correctly checks if first term is greater" do
      assert Term.greater_than?(2, 1)
      refute Term.greater_than?(1, 2)
      refute Term.greater_than?(1, 1)
    end
  end

  describe "max/2" do
    test "returns the maximum of two terms" do
      assert Term.max(1, 2) == 2
      assert Term.max(2, 1) == 2
      assert Term.max(1, 1) == 1
    end
  end

  describe "is_current?/2" do
    test "checks if term is current compared to another term" do
      assert Term.is_current?(2, 1)
      assert Term.is_current?(1, 1)
      refute Term.is_current?(1, 2)
    end
  end
end
