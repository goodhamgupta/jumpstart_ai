defmodule JumpstartAi.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :strategies, :google, :client_id],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:jumpstart_ai, :google_client_id)

  def secret_for(
        [:authentication, :strategies, :google, :client_secret],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:jumpstart_ai, :google_client_secret)

  def secret_for(
        [:authentication, :strategies, :google, :redirect_uri],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:jumpstart_ai, :google_redirect_uri)

  def secret_for(
        [:authentication, :strategies, :hubspot, :client_id],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:jumpstart_ai, :hubspot_client_id)

  def secret_for(
        [:authentication, :strategies, :hubspot, :client_secret],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:jumpstart_ai, :hubspot_client_secret)

  def secret_for(
        [:authentication, :strategies, :hubspot, :redirect_uri],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:jumpstart_ai, :hubspot_redirect_uri)

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        JumpstartAi.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:jumpstart_ai, :token_signing_secret)
  end
end
