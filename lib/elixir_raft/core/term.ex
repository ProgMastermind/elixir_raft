defmodule ElixirRaft.Core.Term do
  @moduledoc """
  Manages Raft terms, which serve as a logical clock in the Raft consensus algorithm.
  Terms are monotonically increasing numbers used to detect obsolete information.
  """

  @type t :: non_neg_integer()

  @doc """
  Creates a new term starting at 0.
  """
  @spec new() :: t()
  def new(), do: 0

  @doc """
  Increments the term by 1.
  """
  @spec increment(t()) :: t()
  def increment(term) when is_integer(term) and term >= 0 do
    term + 1
  end

  @doc """
  Validates if a given term is valid (non-negative integer).
  Returns {:ok, term} if valid, {:error, reason} if invalid.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(term) when is_integer(term) and term >= 0 do
    {:ok, term}
  end

  def validate(term) when is_integer(term) and term < 0 do
    {:error, "Term cannot be negative"}
  end

  def validate(_term) do
    {:error, "Term must be a non-negative integer"}
  end

  @doc """
  Validates a term and raises if invalid.
  """
  @spec validate!(term()) :: t() | no_return()
  def validate!(term) do
    case validate(term) do
      {:ok, valid_term} -> valid_term
      {:error, reason} -> raise ArgumentError, message: reason
    end
  end

  @doc """
  Compares two terms.
  Returns :gt if first term is greater, :lt if less, and :eq if equal.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(term1, term2) when is_integer(term1) and is_integer(term2) do
    cond do
      term1 > term2 -> :gt
      term1 < term2 -> :lt
      true -> :eq
    end
  end

  @doc """
  Checks if a term is greater than another.
  """
  @spec greater_than?(t(), t()) :: boolean()
  def greater_than?(term1, term2) when is_integer(term1) and is_integer(term2) do
    term1 > term2
  end

  @doc """
  Returns the maximum of two terms.
  """
  @spec max(t(), t()) :: t()
  def max(term1, term2) when is_integer(term1) and is_integer(term2) do
    if greater_than?(term1, term2), do: term1, else: term2
  end

  @doc """
  Checks if a term is current (not stale) compared to another term.
  A term is current if it's greater than or equal to the comparison term.
  """
  @spec is_current?(t(), t()) :: boolean()
  def is_current?(term, comparison_term)
      when is_integer(term) and is_integer(comparison_term) do
    term >= comparison_term
  end
end
