defmodule JumpstartAi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JumpstartAiWeb.Telemetry,
      JumpstartAi.Repo,
      {DNSCluster, query: Application.get_env(:jumpstart_ai, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:jumpstart_ai, :ash_domains),
         Application.fetch_env!(:jumpstart_ai, Oban)
       )},
      # Start the Finch HTTP client for sending emails
      # Start a worker by calling: JumpstartAi.Worker.start_link(arg)
      # {JumpstartAi.Worker, arg},
      # Start to serve requests, typically the last entry
      {Phoenix.PubSub, name: JumpstartAi.PubSub},
      {Finch, name: JumpstartAi.Finch},
      JumpstartAiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: JumpstartAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JumpstartAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
