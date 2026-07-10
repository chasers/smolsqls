defmodule SmolsqlsOperator.API.V1Alpha1.SqliteNode do
  @moduledoc """
  v1alpha1 of the SqliteNode custom resource — one per data-plane node
  (never per database; per-database metadata lives in the control
  plane's Postgres). The spec is desired node state (Litestream target,
  drain); the status is the operator's report (replication-slot health,
  database count, conditions).
  """

  use Bonny.API.Version, hub: true

  @impl true
  def manifest do
    defaults()
    |> struct!(
      schema: %{
        openAPIV3Schema: %{
          type: :object,
          properties: %{
            spec: %{
              type: :object,
              required: ["ordinal"],
              properties: %{
                ordinal: %{type: :integer, description: "StatefulSet ordinal ↔ pod ↔ PVC"},
                erlangNode: %{type: :string, nullable: true},
                litestream: %{
                  type: :object,
                  nullable: true,
                  properties: %{
                    bucket: %{type: :string},
                    pathPrefix: %{type: :string}
                  }
                },
                drain: %{
                  type: :boolean,
                  default: false,
                  description: "evacuate databases before decommission"
                }
              }
            },
            status: %{
              type: :object,
              nullable: true,
              properties: %{
                databaseCount: %{type: :integer},
                region: %{
                  type: :string,
                  nullable: true,
                  description: "geographic region this node serves (from the metadb nodes table)"
                },
                replicationSlot: %{
                  type: :object,
                  nullable: true,
                  properties: %{
                    name: %{type: :string},
                    active: %{type: :boolean},
                    walStatus: %{type: :string},
                    retainedBytes: %{type: :integer, format: :int64}
                  }
                }
              },
              "x-kubernetes-preserve-unknown-fields": true
            }
          }
        }
      },
      additionalPrinterColumns: [
        %{name: "Ordinal", type: :integer, jsonPath: ".spec.ordinal"},
        %{name: "Node", type: :string, jsonPath: ".spec.erlangNode"},
        %{name: "Region", type: :string, jsonPath: ".status.region"},
        %{name: "Databases", type: :integer, jsonPath: ".status.databaseCount"},
        %{name: "SlotStatus", type: :string, jsonPath: ".status.replicationSlot.walStatus"},
        %{name: "SlotActive", type: :boolean, jsonPath: ".status.replicationSlot.active"},
        %{name: "Draining", type: :boolean, jsonPath: ".spec.drain"}
      ],
      subresources: %{status: %{}}
    )
    |> add_observed_generation_status()
    |> add_conditions()
  end
end
