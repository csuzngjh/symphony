defmodule SymphonyElixir.Review.Reporter do
  @moduledoc """
  Generates Markdown review reports from a list of `SymphonyElixir.Review.Result` structs.
  """

  alias SymphonyElixir.Review.{Result, Dimension}

  @spec build_report([Result.t()]) :: String.t()
  def build_report(results) do
    labels = dimension_labels()
    total = length(Dimension.all())
    passed = Enum.count(results, &(&1.status == :success))

    [
      "## 自动评审报告",
      "",
      "### 综合评分：#{passed}/#{total} 通过",
      "",
      build_table(results, labels),
      "",
      build_business_section(results, labels),
      "",
      build_technical_section(results, labels)
    ]
    |> Enum.join("\n")
  end

  defp dimension_labels do
    Dimension.all()
    |> Map.new(&{&1.name, &1.label})
  end

  defp build_table(results, labels) do
    header = "| 评审维度 | 评分 | 状态 |\n|----------|------|------|"

    rows =
      Enum.map(results, fn r ->
        label = Map.get(labels, r.dimension, to_string(r.dimension))
        "| #{label} | #{score_display(r)} | #{status_display(r)} |"
      end)

    [header | rows] |> Enum.join("\n")
  end

  defp score_display(%{status: :success, score: score}) when is_integer(score), do: to_string(score)
  defp score_display(_), do: "N/A"

  defp status_display(%{status: :success}), do: "✅ 通过"
  defp status_display(%{status: :failure}), do: "❌ 失败"
  defp status_display(%{status: :timeout}), do: "⏱️ 超时"

  defp build_business_section(results, labels) do
    items =
      Enum.map(results, fn r ->
        label = Map.get(labels, r.dimension, to_string(r.dimension))
        "- **#{label}**：#{business_summary_text(r)}"
      end)

    ["### 👤 业务人员摘要", "" | items] |> Enum.join("\n")
  end

  defp business_summary_text(%{status: :success} = r) do
    r.business_summary || r.summary || ""
  end

  defp business_summary_text(%{status: :failure}), do: "评审未能完成"
  defp business_summary_text(%{status: :timeout}), do: "评审超时"

  defp build_technical_section(results, labels) do
    sections =
      Enum.map(results, fn r ->
        label = Map.get(labels, r.dimension, to_string(r.dimension))
        build_dimension_detail(r, label)
      end)

    ["### 🔧 技术详情", "" | sections] |> Enum.join("\n")
  end

  defp build_dimension_detail(%{status: :success} = r, label) do
    """
    #### #{label} (评分: #{r.score})
    **摘要**: #{r.summary || ""}
    **详情**: #{r.details || ""}\
    """
  end

  defp build_dimension_detail(%{status: :failure} = r, label) do
    """
    #### #{label} (失败)
    **摘要**: #{r.summary || ""}\
    """
  end

  defp build_dimension_detail(%{status: :timeout} = r, label) do
    """
    #### #{label} (超时)
    **摘要**: #{r.summary || ""}\
    """
  end
end
