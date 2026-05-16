defmodule SymphonyElixir.Review.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Review.PromptBuilder

  describe "build/1" do
    test "builds code_quality prompt with required sections" do
      prompt = PromptBuilder.build(:code_quality)
      assert prompt =~ "代码质量"
      assert prompt =~ "评审范围"
      assert prompt =~ "非评审范围"
      assert prompt =~ "输出格式"
      assert prompt =~ "score"
      assert prompt =~ "summary"
      assert prompt =~ "details"
      assert prompt =~ "business_summary"
    end

    test "builds security_audit prompt with required sections" do
      prompt = PromptBuilder.build(:security_audit)
      assert prompt =~ "安全"
      assert prompt =~ "评审范围"
      assert prompt =~ "非评审范围"
      assert prompt =~ "输出格式"
      assert prompt =~ "score"
    end

    test "builds test_coverage prompt with required sections" do
      prompt = PromptBuilder.build(:test_coverage)
      assert prompt =~ "测试"
      assert prompt =~ "评审范围"
      assert prompt =~ "非评审范围"
      assert prompt =~ "输出格式"
      assert prompt =~ "score"
    end

    test "builds business_compliance prompt with required sections" do
      prompt = PromptBuilder.build(:business_compliance)
      assert prompt =~ "业务"
      assert prompt =~ "评审范围"
      assert prompt =~ "非评审范围"
      assert prompt =~ "输出格式"
      assert prompt =~ "score"
    end

    test "code_quality prompt excludes security audit" do
      prompt = PromptBuilder.build(:code_quality)
      assert prompt =~ "安全" && prompt =~ "非评审范围"
    end

    test "prompts are dimension-specific" do
      cq = PromptBuilder.build(:code_quality)
      sa = PromptBuilder.build(:security_audit)
      assert cq != sa
    end

    test "unknown dimension raises" do
      assert_raise ArgumentError, fn ->
        PromptBuilder.build(:unknown)
      end
    end
  end

  describe "parse_response/1" do
    test "parses valid JSON" do
      json = ~s({"score":85,"summary":"Good","details":"Details here","business_summary":"Looks good"})
      assert {:ok, result} = PromptBuilder.parse_response(json)
      assert result.score == 85
      assert result.summary == "Good"
      assert result.details == "Details here"
      assert result.business_summary == "Looks good"
    end

    test "parses JSON from markdown code fence" do
      md = """
      Here is the review:

      ```json
      {"score":70,"summary":"OK","details":"Some details","business_summary":"OK overall"}
      ```

      End of review.
      """

      assert {:ok, result} = PromptBuilder.parse_response(md)
      assert result.score == 70
      assert result.summary == "OK"
    end

    test "parses JSON from code fence without json tag" do
      md = """
      ```
      {"score":90,"summary":"Great","details":"Nice work","business_summary":"Excellent"}
      ```
      """

      assert {:ok, result} = PromptBuilder.parse_response(md)
      assert result.score == 90
    end

    test "returns error for unparseable input" do
      assert {:error, "unparseable response"} = PromptBuilder.parse_response("not json at all")
    end

    test "truncates float score to integer" do
      json = ~s({"score":85.7,"summary":"S","details":"D","business_summary":"B"})
      assert {:ok, result} = PromptBuilder.parse_response(json)
      assert result.score == 85
    end

    test "returns defaults for missing fields" do
      json = ~s({"other":"data"})
      assert {:ok, result} = PromptBuilder.parse_response(json)
      assert result.score == 0
      assert result.summary == ""
    end
  end
end
