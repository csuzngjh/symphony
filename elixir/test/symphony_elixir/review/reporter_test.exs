defmodule SymphonyElixir.Review.ReporterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Review.{Reporter, Result}

  describe "build_report/1" do
    test "all success results show 4/4 passed" do
      results = [
        Result.success(:code_quality, 90, "Good code", "Details", "Code is clean"),
        Result.success(:security_audit, 85, "Secure", "No issues", "Security looks good"),
        Result.success(:test_coverage, 80, "Adequate", "Some gaps", "Tests are fine"),
        Result.success(:business_compliance, 95, "Matches spec", "All good", "Meets requirements")
      ]

      report = Reporter.build_report(results)
      assert report =~ "综合评分：4/4 通过"
    end

    test "mixed results show correct pass count" do
      results = [
        Result.success(:code_quality, 90, "Good", "D1", "B1"),
        Result.failure(:security_audit, "Connection error"),
        Result.success(:test_coverage, 80, "OK", "D2", "B2"),
        Result.timeout(:business_compliance)
      ]

      report = Reporter.build_report(results)
      assert report =~ "综合评分：2/4 通过"
    end

    test "all failure results show 0/4 passed" do
      results = [
        Result.failure(:code_quality, "Error 1"),
        Result.failure(:security_audit, "Error 2"),
        Result.timeout(:test_coverage),
        Result.timeout(:business_compliance)
      ]

      report = Reporter.build_report(results)
      assert report =~ "综合评分：0/4 通过"
    end

    test "report includes business summary section" do
      results = [
        Result.success(:code_quality, 90, "Good", "D", "Business friendly"),
        Result.success(:security_audit, 85, "OK", "D", "Secure enough"),
        Result.success(:test_coverage, 80, "OK", "D", "Tests pass"),
        Result.success(:business_compliance, 95, "OK", "D", "Meets spec")
      ]

      report = Reporter.build_report(results)
      assert report =~ "业务人员摘要"
      assert report =~ "Business friendly"
      assert report =~ "Secure enough"
    end

    test "report includes technical details section" do
      results = [
        Result.success(:code_quality, 90, "Summary text", "Detail text", "Biz"),
        Result.success(:security_audit, 85, "Secure", "No vulns", "Safe"),
        Result.success(:test_coverage, 80, "OK", "Some gaps", "Fine"),
        Result.success(:business_compliance, 95, "Good", "Matches", "OK")
      ]

      report = Reporter.build_report(results)
      assert report =~ "技术详情"
      assert report =~ "Summary text"
      assert report =~ "Detail text"
      assert report =~ "No vulns"
    end

    test "failure result shows appropriate status in table" do
      results = [Result.failure(:code_quality, "Boom")]
      report = Reporter.build_report(results)
      assert report =~ "❌ 失败"
      assert report =~ "N/A"
    end

    test "timeout result shows appropriate status in table" do
      results = [Result.timeout(:code_quality)]
      report = Reporter.build_report(results)
      assert report =~ "⏱️ 超时"
      assert report =~ "N/A"
    end

    test "success result shows score and pass status" do
      results = [Result.success(:code_quality, 85, "S", "D", "B")]
      report = Reporter.build_report(results)
      assert report =~ "85"
      assert report =~ "✅ 通过"
    end

    test "failure business summary shows failure text" do
      results = [Result.failure(:code_quality, "Error")]
      report = Reporter.build_report(results)
      assert report =~ "评审未能完成"
    end

    test "timeout business summary shows timeout text" do
      results = [Result.timeout(:code_quality)]
      report = Reporter.build_report(results)
      assert report =~ "评审超时"
    end

    test "report contains expected headers" do
      results = [Result.success(:code_quality, 80, "S", "D", "B")]
      report = Reporter.build_report(results)
      assert report =~ "## 自动评审报告"
      assert report =~ "### 综合评分"
      assert report =~ "### 👤 业务人员摘要"
      assert report =~ "### 🔧 技术详情"
    end
  end
end
