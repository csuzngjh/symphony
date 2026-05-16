defmodule SymphonyElixir.Review.PromptBuilder do
  @moduledoc """
  Builds dimension-specific review prompts for the multi-dimensional code review system.

  Each review dimension (`:code_quality`, `:security_audit`, `:test_coverage`,
  `:business_compliance`) has a tailored prompt with role, scope, non-goals, and
  a strict JSON output contract.  `parse_response/1` extracts structured results
  from raw executor output.
  """

  @spec build(atom()) :: String.t()
  def build(dimension) do
    case dimension do
      :code_quality -> code_quality_prompt()
      :security_audit -> security_audit_prompt()
      :test_coverage -> test_coverage_prompt()
      :business_compliance -> business_compliance_prompt()
      _ -> raise ArgumentError, "unknown review dimension: #{inspect(dimension)}"
    end
  end

  @spec parse_response(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_response(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} ->
        {:ok, normalize_result(parsed)}

      {:error, _} ->
        case extract_json_from_markdown(raw) do
          {:ok, json_str} ->
            case Jason.decode(json_str) do
              {:ok, parsed} -> {:ok, normalize_result(parsed)}
              {:error, _} -> {:error, "unparseable response"}
            end

          {:error, _} ->
            {:error, "unparseable response"}
        end
    end
  end

  defp normalize_result(%{"score" => score, "summary" => summary, "details" => details, "business_summary" => business_summary})
       when is_number(score) and is_binary(summary) and is_binary(details) and is_binary(business_summary) do
    %{
      score: trunc(score),
      summary: summary,
      details: details,
      business_summary: business_summary
    }
  end

  defp normalize_result(_), do: %{score: 0, summary: "", details: "", business_summary: ""}

  defp extract_json_from_markdown(raw) do
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)```/s, raw, capture: :all_but_first) do
      [json_str] ->
        {:ok, String.trim(json_str)}

      _ ->
        {:error, :no_json_block}
    end
  end

  defp code_quality_prompt do
    """
    你是一位资深软件工程师，负责对代码变更进行代码质量评审。

    ## 评审范围
    - 代码规范与编码风格是否符合项目约定
    - 潜在 Bug 与逻辑错误
    - 性能问题（N+1 查询、不必要的内存分配等）
    - 可维护性与可读性
    - 错误处理是否健全
    - 是否有重复代码或可抽象的模式

    ## 非评审范围
    - 安全漏洞（由安全审计维度覆盖）
    - 业务逻辑正确性（由业务合规维度覆盖）
    - 测试覆盖率是否充分（由测试覆盖维度覆盖）

    ## 输出格式
    请严格输出以下 JSON 结构，不要包含任何其他文字：

    ```json
    {
      "score": <0-100 的整数>,
      "summary": "<技术评审摘要，中文>",
      "details": "<详细技术发现，中文>",
      "business_summary": "<面向非技术人员的通俗摘要，中文>"
    }
    ```
    """
  end

  defp security_audit_prompt do
    """
    你是一位安全工程师，负责对代码变更进行安全审计。

    ## 评审范围
    - SQL / 命令注入风险
    - 认证与授权问题
    - 敏感数据泄露（密钥、Token、用户隐私）
    - 依赖项安全（已知漏洞、过期版本）
    - 输入验证与输出编码
    - 会话管理与 CSRF 风险

    ## 非评审范围
    - 代码风格与规范（由代码质量维度覆盖）
    - 性能问题（由代码质量维度覆盖）
    - 业务逻辑正确性（由业务合规维度覆盖）
    - 测试覆盖率（由测试覆盖维度覆盖）

    ## 输出格式
    请严格输出以下 JSON 结构，不要包含任何其他文字：

    ```json
    {
      "score": <0-100 的整数>,
      "summary": "<安全评审摘要，中文>",
      "details": "<详细安全发现，中文>",
      "business_summary": "<面向非技术人员的通俗摘要，中文>"
    }
    ```
    """
  end

  defp test_coverage_prompt do
    """
    你是一位 QA 工程师，负责对代码变更进行测试覆盖评审。

    ## 评审范围
    - 测试用例是否覆盖核心逻辑路径
    - 边界条件与异常路径是否被测试
    - Mock 策略是否合理（是否过度 Mock 导致测试失真）
    - 测试可维护性与可读性
    - 是否有遗漏的测试场景

    ## 非评审范围
    - 代码风格与规范（由代码质量维度覆盖）
    - 安全漏洞（由安全审计维度覆盖）
    - 业务逻辑正确性（由业务合规维度覆盖）
    - 性能问题（由代码质量维度覆盖）

    ## 输出格式
    请严格输出以下 JSON 结构，不要包含任何其他文字：

    ```json
    {
      "score": <0-100 的整数>,
      "summary": "<测试评审摘要，中文>",
      "details": "<详细测试发现，中文>",
      "business_summary": "<面向非技术人员的通俗摘要，中文>"
    }
    ```
    """
  end

  defp business_compliance_prompt do
    """
    你是一位产品经理，负责对代码变更进行业务合规评审。

    ## 评审范围
    - 功能实现是否符合需求文档 / Ticket 描述
    - 用户体验是否合理
    - 业务逻辑是否正确
    - 边界业务场景是否处理得当
    - 是否引入与现有功能的冲突

    ## 非评审范围
    - 代码实现细节（由代码质量维度覆盖）
    - 性能问题（由代码质量维度覆盖）
    - 安全漏洞（由安全审计维度覆盖）
    - 测试覆盖率（由测试覆盖维度覆盖）

    ## 输出格式
    请严格输出以下 JSON 结构，不要包含任何其他文字：

    ```json
    {
      "score": <0-100 的整数>,
      "summary": "<技术评审摘要，中文>",
      "details": "<详细技术发现，中文>",
      "business_summary": "<面向非技术人员的通俗摘要，中文>"
    }
    ```
    """
  end
end
