defmodule Marrylocal.Workers.BulkEmailWorkerTest do
  use ExUnit.Case, async: true

  alias Marrylocal.Workers.BulkEmailWorker

  test "delivers every recipient with the verified sender" do
    args = %{
      "emails" => ["one@example.com", "two@example.com"],
      "subject" => "Broadcast",
      "content" => "<p>Hello</p>"
    }

    assert :ok = BulkEmailWorker.perform(%Oban.Job{args: args})

    emails = collect_emails([])
    assert length(emails) == 2

    recipients =
      emails
      |> Enum.flat_map(& &1.to)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()

    assert recipients == ["one@example.com", "two@example.com"]
    assert Enum.all?(emails, &(&1.subject == "Broadcast"))
    assert Enum.all?(emails, &(&1.html_body == "<p>Hello</p>"))
    assert Enum.all?(emails, &(&1.from == {"MarryLocal", "noreply@marrylocal.in"}))
  end

  test "cancels a malformed payload instead of retrying it forever" do
    assert {:cancel, :invalid_args} =
             BulkEmailWorker.perform(%Oban.Job{args: %{"emails" => "not-a-list"}})
  end

  defp collect_emails(acc) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
