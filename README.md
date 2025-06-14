# JumpstartAi

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Gmail Integration & Email Sync

This application includes a complete Gmail integration system that automatically syncs user emails using OAuth tokens. Here's how to use it:

### Overview

The email sync system:
1. **User signs in with Google OAuth** → `email_sync_status` set to "pending"
2. **Oban scheduler runs every 6 hours** → Finds users with Google tokens and pending status
3. **Background job fetches 10 emails** → Uses stored OAuth tokens via Gmail API
4. **Emails stored in database** → Deduplication handled automatically
5. **Status updated** → "completed" or "failed" based on result

### Manual Email Sync

```elixir
# Manually trigger email sync for a user
user
|> Ash.Changeset.for_update(:sync_gmail_emails)
|> Ash.update()

# Check if a user needs email sync
needs_sync = not is_nil(user.google_access_token) and
  (is_nil(user.email_sync_status) or user.email_sync_status == "pending")

# Get all synced emails for a user
{:ok, user_with_emails} = user |> Ash.load(:emails)
emails = user_with_emails.emails

# Get email sync status for a user
status = %{
  status: user.email_sync_status,
  last_synced: user.emails_synced_at,
  has_google_token: not is_nil(user.google_access_token)
}
```

### Background Job Management

```elixir
# Manually run the Oban trigger to sync emails for all eligible users
AshOban.schedule(JumpstartAi.Accounts.User, :sync_emails)

# Run email sync for a specific user via Oban
AshOban.run_trigger(user, :sync_emails)
```

### Gmail API Client Usage

```elixir
# Fetch all emails (respects token expiry and auto-refreshes)
{:ok, emails} = JumpstartAi.GmailService.fetch_user_emails(user, maxResults: 10)

# Get user's Gmail labels  
{:ok, labels} = JumpstartAi.GmailService.get_user_labels(user)

# Search emails
{:ok, results} = JumpstartAi.GmailService.search_emails(user, "from:example@email.com")

# Direct API access
{:ok, response} = JumpstartAi.GmailClient.fetch_emails(user, maxResults: 10)
```

### Features

- **OAuth Token Management**: Automatic token refresh when expired
- **Background Processing**: Uses AshOban for reliable background job processing
- **Error Handling**: Comprehensive error handling with retry logic (max 3 attempts)
- **Deduplication**: Prevents duplicate emails with unique constraints
- **Queue Management**: Uses dedicated `:email_sync` queue
- **Email Parsing**: Extracts subject, from/to addresses, body content, and labels
- **Security**: All OAuth tokens are stored securely and marked as sensitive

### Configuration

The email sync runs automatically every 6 hours for users who have:
- Google OAuth access tokens
- Email sync status of `nil` or "pending"

To modify the sync schedule, update the `scheduler_cron` setting in `lib/jumpstart_ai/accounts/user.ex`:

```elixir
oban do
  triggers do
    trigger :sync_emails do
      scheduler_cron "0 */6 * * *"  # Every 6 hours
      # ... other configuration
    end
  end
end
```

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
