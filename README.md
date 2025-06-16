# JumpstartAi

An AI agent application for Financial Advisors built with Elixir Phoenix and the Ash Framework. It integrates with Gmail, Google Calendar, and HubSpot to provide a ChatGPT-like interface for managing client relationships and automating tasks.

## 🏗️ Architecture

### Framework Stack
- **Phoenix Framework**: Web framework with LiveView for real-time UI
- **Ash Framework**: Resource-based framework for building APIs and business logic
- **AshAuthentication**: Handles user authentication with Google OAuth and password strategies
- **Oban**: Background job processing with AshOban integration
- **PostgreSQL**: Database with pgvector extension for vector search (RAG)

### Key Features
- **ChatGPT-like Interface**: Real-time LiveView chat with streaming responses
- **RAG System**: Semantic search across emails, contacts, and calendar events
- **OAuth Integration**: Google (Gmail/Calendar) and HubSpot authentication
- **Tool Calling**: Comprehensive email, contact, and calendar management
- **Background Sync**: Automatic data synchronization from all connected services
- **Vector Search**: OpenAI embeddings with pgvector for semantic search

## 🚀 Setup

### Prerequisites
- Elixir 1.18.4+ with OTP 26+
- PostgreSQL 16+ with pgvector extension
- Docker and Docker Compose (for containerized setup)

### Local Development Setup

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd jumpstart_ai
   ```

2. **Install dependencies**
   ```bash
   mix setup
   ```

3. **Configure environment variables**
   ```bash
   cp .env.example .env
   # Edit .env with your actual values
   ```

4. **Setup database**
   ```bash
   mix ash.setup
   ```

5. **Start the server**
   ```bash
   source .env && mix phx.server
   ```

   Or with IEx:
   ```bash
   source .env && iex -S mix phx.server
   ```

6. **Visit the application**
   Open [http://localhost:4000](http://localhost:4000) in your browser.

### Docker Setup

1. **Configure environment for Docker**
   ```bash
   cp .env.example .env
   # Edit .env with your actual values (Docker will use these automatically)
   ```

2. **Start with Docker Compose**
   ```bash
   docker-compose up
   ```

   This will:
   - Start PostgreSQL with pgvector extension
   - Install dependencies and setup the database
   - Start the Phoenix server on port 4000

3. **Visit the application**
   Open [http://localhost:4000](http://localhost:4000) in your browser.

### Environment Variables

The application uses environment variables for configuration. Copy `.env.example` to `.env` and configure:

```bash
# Phoenix server configuration
PHX_HOST=127.0.0.1        # Use 0.0.0.0 for Docker
PHX_PORT=4000

# Database configuration  
DB_HOSTNAME=localhost      # Use 'db' for Docker
DATABASE_URL=ecto://postgres:postgres@localhost/jumpstart_ai_dev

# Google OAuth (get from Google Cloud Console)
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret
GOOGLE_REDIRECT_URI=http://localhost:4000/auth/user/google/callback

# HubSpot OAuth (get from HubSpot Developer Portal)
HUBSPOT_APP_ID=your_hubspot_app_id
HUBSPOT_CLIENT_ID=your_hubspot_client_id
HUBSPOT_CLIENT_SECRET=your_hubspot_client_secret
HUBSPOT_REDIRECT_URI=http://localhost:4000/auth/user/hubspot/callback

# OpenAI (for AI responses and embeddings)
OPENAI_API_KEY=your_openai_api_key

# Authentication
TOKEN_SIGNING_SECRET=your_token_signing_secret
```

## 🧪 Testing

Run the test suite:

```bash
mix test
```

The application includes comprehensive test coverage with 40+ test files covering:
- Email tool functionality
- User authentication flows
- Background workers
- API integrations

## 📦 Asset Management

### Development Assets
```bash
mix assets.setup    # Install Tailwind and esbuild
mix assets.build    # Build assets for development
```

### Production Assets
```bash
mix assets.deploy   # Build and minify assets for production
```

## 🗄️ Database Management

### Preferred (Ash Framework)
```bash
mix ash.setup       # Setup Ash resources and run migrations
```

### Alternative (Ecto)
```bash
mix ecto.setup      # Create database, run migrations, and seed data
mix ecto.reset      # Drop and recreate database with fresh data
```

## 📧 Gmail Integration & Email Sync

This application includes a complete Gmail integration system that automatically syncs user emails using OAuth tokens.

### Overview

The email sync system:
1. **User signs in with Google OAuth** → `email_sync_status` set to "pending"
2. **Oban scheduler runs every 6 hours** → Finds users with Google tokens and pending status
3. **Background job fetches 10 emails** → Uses stored OAuth tokens via Gmail API
4. **Emails stored in database** → Deduplication handled automatically
5. **Status updated** → "completed" or "failed" based on result

### Features

- **OAuth Token Management**: Automatic token refresh when expired
- **Background Processing**: Uses AshOban for reliable background job processing
- **Error Handling**: Comprehensive error handling with retry logic (max 3 attempts)
- **Deduplication**: Prevents duplicate emails with unique constraints
- **Queue Management**: Uses dedicated queues for different sync operations
- **Email Parsing**: Extracts subject, from/to addresses, body content, and labels
- **Security**: All OAuth tokens are stored securely and marked as sensitive

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

## 🤖 AI Tools & Capabilities

The application includes comprehensive tool calling capabilities:

### Email Tools
- `search_emails_by_from` - Find emails from specific senders
- `semantic_search_emails` - Semantic search across email content
- `draft_email` - Create email drafts
- `list_drafts` - List existing drafts
- `send_email_with_draft` - Send emails using drafts
- `list_emails` - List user emails

### Contact Tools
- `semantic_search_contacts` - Find contacts using semantic search
- `list_contacts` - List HubSpot contacts

### Calendar Tools
- `create_calendar_event` - Create Google Calendar events
- `semantic_search_calendar_events` - Semantic search across calendar events
- `list_calendar_events` - List calendar events

### Note Tools
- `semantic_search_contact_notes` - Search contact notes
- `list_contact_notes` - List HubSpot contact notes

## 🔧 Background Workers

The application uses Oban for background job processing:

- **EmailSync**: Syncs Gmail emails
- **ContactSync**: Syncs HubSpot contacts
- **CalendarSync**: Syncs Google Calendar events
- **HubSpotSync**: General HubSpot synchronization
- **PeriodicSyncScheduler**: Runs every 5 minutes to trigger syncs

## 🚀 Deployment

### Fly.io Deployment

The application is configured for deployment on Fly.io:

```bash
fly deploy
```

Configuration is available in `fly.toml` with:
- App name: `jumpstart-ai`
- Automatic database migrations
- Environment variable management

### Production Checklist

- [ ] Configure all environment variables in production
- [ ] Set up PostgreSQL with pgvector extension
- [ ] Configure OAuth apps for production URLs
- [ ] Set up monitoring and logging
- [ ] Configure backup strategies

## 📊 Implementation Status

**Overall Progress**: ~80% complete

**Completed Features**:
- ✅ OAuth integrations (Google + HubSpot)  
- ✅ ChatGPT-like interface
- ✅ RAG with vector search
- ✅ Tool calling system
- ✅ Data synchronization
- ✅ Database design
- ✅ Testing framework
- ✅ Deployment configuration

**Missing Features**:
- ❌ Ongoing instructions system
- ❌ Proactive agent behavior  
- ❌ Task memory/continuation

## 📚 Learn More

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Ash Framework](https://ash-hq.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
- [Oban](https://hexdocs.pm/oban/Oban.html)
- [Deployment Guide](https://hexdocs.pm/phoenix/deployment.html)