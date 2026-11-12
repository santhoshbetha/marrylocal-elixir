defmodule MarrylocalWeb.Admin.NotificationController do
  @moduledoc """
  Queues targeted system notifications for administrative broadcasting.
  """

  use MarrylocalWeb, :controller

  require Logger

  alias Marrylocal.Workers.SystemNotificationWorker

  @target_types ~w(all location individual)
  @genders ~w(All Male Female)

  @doc """
  `POST /api/v1/admin/notifications/broadcast`

  Targets all active users, a state/city audience, or individual emails/@handles.
  """
  def broadcast(conn, params) do
    with {:ok, title} <- validate_text(params["title"], "title", 200),
         {:ok, body} <- validate_text(params["body"], "body", 5_000),
         {:ok, target_type} <- validate_target_type(params["target_type"]),
         {:ok, gender} <- validate_gender(params["gender"]),
         {:ok, identifiers} <- validate_identifiers(target_type, params["identifiers"]) do
      args = %{
        "title" => title,
        "body" => body,
        "target_type" => target_type,
        "state" => params["state"],
        "city" => params["city"],
        "gender" => gender,
        "identifiers" => identifiers
      }

      estimated_recipients = SystemNotificationWorker.count_recipients(args)

      case Oban.insert(SystemNotificationWorker.new(args)) do
        {:ok, _job} ->
          conn
          |> put_status(:accepted)
          |> json(%{status: "queued", estimated_recipients: estimated_recipients})

        {:error, reason} ->
          Logger.error("Could not enqueue system notification: #{inspect(reason)}")

          conn
          |> put_status(:internal_server_error)
          |> json(%{status: "error", error: "Could not queue the notification broadcast"})
      end
    else
      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: message})
    end
  end

  defp validate_target_type(value) when value in @target_types, do: {:ok, value}

  defp validate_target_type(_value),
    do: {:error, "target_type must be all, location, or individual"}

  defp validate_gender(nil), do: {:ok, "All"}

  defp validate_gender(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, "All"}
      trimmed in @genders -> {:ok, trimmed}
      true -> {:error, "gender must be All, Male, or Female"}
    end
  end

  defp validate_gender(_value), do: {:error, "gender must be All, Male, or Female"}

  defp validate_identifiers("individual", identifiers) do
    values =
      identifiers
      |> List.wrap()
      |> Enum.flat_map(fn value ->
        if is_binary(value), do: String.split(value, [";", ","], trim: true), else: []
      end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if values == [] do
      {:error, "identifiers must contain at least one email or @handle"}
    else
      {:ok, values}
    end
  end

  defp validate_identifiers(_target_type, _identifiers), do: {:ok, []}

  defp validate_text(value, field, max_length) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, "#{field} cannot be blank"}
      String.length(trimmed) > max_length -> {:error, "#{field} is too long"}
      true -> {:ok, trimmed}
    end
  end

  defp validate_text(_value, field, _max_length), do: {:error, "#{field} is required"}
end
