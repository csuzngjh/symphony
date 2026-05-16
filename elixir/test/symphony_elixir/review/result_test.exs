defmodule SymphonyElixir.Review.ResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Review.Result

  test "success constructor sets all fields" do
    result = Result.success(:code_quality, 85, "Good code", "Detailed analysis", "Code looks good")
    assert result.dimension == :code_quality
    assert result.score == 85
    assert result.summary == "Good code"
    assert result.details == "Detailed analysis"
    assert result.business_summary == "Code looks good"
    assert result.status == :success
  end

  test "failure constructor sets status and summary" do
    result = Result.failure(:security_audit, "Connection timeout")
    assert result.dimension == :security_audit
    assert result.status == :failure
    assert result.summary == "Connection timeout"
    assert result.score == nil
    assert result.details == nil
    assert result.business_summary == nil
  end

  test "timeout constructor sets only dimension and status" do
    result = Result.timeout(:test_coverage)
    assert result.dimension == :test_coverage
    assert result.status == :timeout
    assert result.score == nil
    assert result.summary == nil
    assert result.details == nil
    assert result.business_summary == nil
  end

  test "different dimensions produce distinct results" do
    r1 = Result.success(:code_quality, 90, "s1", "d1", "b1")
    r2 = Result.success(:security_audit, 70, "s2", "d2", "b2")
    assert r1.dimension != r2.dimension
    assert r1.score != r2.score
  end
end
