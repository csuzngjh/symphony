defmodule SymphonyElixir.Review.Result do
  @moduledoc """
  Structured review result returned by review dimensions.
  """

  defstruct [
    :dimension,
    :score,
    :summary,
    :details,
    :business_summary,
    :status
  ]

  @type status :: :success | :failure | :timeout

  @type t :: %__MODULE__{
          dimension: atom() | nil,
          score: integer() | nil,
          summary: String.t() | nil,
          details: String.t() | nil,
          business_summary: String.t() | nil,
          status: status() | nil
        }

  @spec success(atom(), integer(), String.t(), String.t(), String.t()) :: t()
  def success(dimension, score, summary, details, business_summary) do
    %__MODULE__{
      dimension: dimension,
      score: score,
      summary: summary,
      details: details,
      business_summary: business_summary,
      status: :success
    }
  end

  @spec failure(atom(), String.t()) :: t()
  def failure(dimension, error_message) do
    %__MODULE__{
      dimension: dimension,
      summary: error_message,
      status: :failure
    }
  end

  @spec timeout(atom()) :: t()
  def timeout(dimension) do
    %__MODULE__{
      dimension: dimension,
      status: :timeout
    }
  end
end
