defmodule Marrylocal.Admin.AuditLog do
  @moduledoc "Structured audit record for every administrative write action."

  use Ecto.Schema
  import Ecto.Changeset

  schema "admin_audit_logs" do
    field :source, :string, default: "web_ui"
    field :action, :string
    field :target_id, :string
    field :metadata, :map, default: %{}

    belongs_to :admin, Marrylocal.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:admin_id, :source, :action, :target_id, :metadata])
    |> validate_required([:source, :action])
    |> update_change(:source, &normalize_source/1)
  end

  defp normalize_source("mcp"), do: "mcp"
  defp normalize_source(_source), do: "web_ui"
end
