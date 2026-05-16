defmodule SymphonyElixir.Review.DimensionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Review.Dimension

  test "all returns 4 dimensions" do
    dimensions = Dimension.all()
    assert length(dimensions) == 4
  end

  test "all dimensions have correct names" do
    names = Dimension.all() |> Enum.map(& &1.name)
    assert names == [:code_quality, :security_audit, :test_coverage, :business_compliance]
  end

  test "each dimension has required fields" do
    for dim <- Dimension.all() do
      assert is_atom(dim.name)
      assert is_binary(dim.label)
      assert is_integer(dim.weight)
      assert dim.weight > 0
    end
  end

  test "code_quality dimension" do
    dim = Dimension.all() |> Enum.find(&(&1.name == :code_quality))
    assert dim.label == "代码质量"
  end

  test "security_audit dimension" do
    dim = Dimension.all() |> Enum.find(&(&1.name == :security_audit))
    assert dim.label == "安全审计"
  end

  test "test_coverage dimension" do
    dim = Dimension.all() |> Enum.find(&(&1.name == :test_coverage))
    assert dim.label == "测试覆盖"
  end

  test "business_compliance dimension" do
    dim = Dimension.all() |> Enum.find(&(&1.name == :business_compliance))
    assert dim.label == "业务合规"
  end
end
