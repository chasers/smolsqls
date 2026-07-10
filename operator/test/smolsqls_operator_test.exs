defmodule SmolsqlsOperatorTest do
  use ExUnit.Case

  test "crds/0 defines the SqliteNode CRD" do
    assert [crd] = SmolsqlsOperator.Operator.crds()
    assert crd.group == "smolsqls.supabase.com"
    assert crd.names.kind == "SqliteNode"

    manifest = Bonny.API.CRD.to_manifest(crd)
    assert manifest.metadata.name == "sqlitenodes.smolsqls.supabase.com"

    [version] = manifest.spec.versions
    columns = Enum.map(version.additionalPrinterColumns, & &1.name)
    assert "Region" in columns

    assert %{type: :string} =
             version.schema.openAPIV3Schema.properties.status.properties.region
  end

  test "controllers/2 watches SqliteNode resources" do
    assert [%{controller: SmolsqlsOperator.Controller.SqliteNodeController}] =
             SmolsqlsOperator.Operator.controllers("smolsqls", [])
  end
end
