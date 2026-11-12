defmodule Marrylocal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MarrylocalWeb.Telemetry,
      Marrylocal.Repo,
      {DNSCluster, query: Application.get_env(:marrylocal, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Marrylocal.PubSub},
      MarrylocalWeb.Presence,
      {Marrylocal.RateLimit, [clean_period: :timer.minutes(1)]},
      # Finch pool used by Swoosh's Resend API adapter.
      {Finch, name: Swoosh.Finch},
      # Start a worker by calling: Marrylocal.Worker.start_link(arg)
      # {Marrylocal.Worker, arg},
      # Start to serve requests, typically the last entry
      MarrylocalWeb.Endpoint,
      # Oban starts after the endpoint so notification workers can broadcast
      # immediately when their first job is claimed.
      {Oban, Application.fetch_env!(:marrylocal, Oban)}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Marrylocal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MarrylocalWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
