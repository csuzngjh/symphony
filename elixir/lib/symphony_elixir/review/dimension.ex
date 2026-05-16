defmodule SymphonyElixir.Review.Dimension do
  @moduledoc """
  Review dimension definitions for multi-dimensional code review scoring.

  Each dimension represents a distinct review axis with its own weight,
  allowing reviewers to evaluate code changes across orthogonal concerns.
  """

  defstruct [
    :name,
    :label,
    weight: 1
  ]

  @type t :: %__MODULE__{
          name: atom(),
          label: String.t(),
          weight: integer()
        }

  @code_quality %{name: :code_quality, label: "代码质量", weight: 1}

  @security_audit %{name: :security_audit, label: "安全审计", weight: 1}

  @test_coverage %{name: :test_coverage, label: "测试覆盖", weight: 1}

  @business_compliance %{name: :business_compliance, label: "业务合规", weight: 1}

  @spec all() :: [t()]
  def all do
    [
      struct!(__MODULE__, @code_quality),
      struct!(__MODULE__, @security_audit),
      struct!(__MODULE__, @test_coverage),
      struct!(__MODULE__, @business_compliance)
    ]
  end
end
