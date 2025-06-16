# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Google Calendar Integration**: Complete integration with Google Calendar API for AI agent scheduling capabilities
  - `CalendarClient` module for Google Calendar API interactions with token management and refresh logic
  - `CalendarService` module for business logic including event streaming, parsing, and free time calculation
  - `CalendarEvent` resource in Accounts domain with full CRUD operations and AI tool actions
  - `CalendarSync` background worker for automated calendar synchronization
  - Calendar-related AI agent tools: `schedule_meeting`, `find_availability`, `list_upcoming_events`
  - Calendar sync functionality integrated into User OAuth flow with automatic job scheduling
- **Calendar Database Schema**: New `calendar_events` table with proper relationships and indexes
  - Foreign key relationship to users table
  - Unique constraint on user_id + google_event_id
  - Support for event details: summary, description, location, start/end times, attendees
  - Tracking of Google-specific metadata: creator, organizer, status, html_link
- **Enhanced OAuth Scopes**: Updated Google OAuth to include `https://www.googleapis.com/auth/calendar` permission
- **Calendar Sync Status Tracking**: Added calendar sync status and timestamp fields to users table
- **Streaming Email Sync**: New streaming email processing functionality that processes emails in batches during fetching rather than loading all emails into memory at once
- `stream_user_emails/2` function in `JumpstartAi.GmailService` for paginated email processing with configurable batch sizes
- Support for Gmail API pagination using `pageToken` and `maxResults` parameters
- Progressive database writes during email sync process
- Unit tests for streaming email processing functionality

### Changed
- **AI Agent Capabilities**: Enhanced Chat domain with calendar management tools for automated scheduling workflows
  - Added calendar tools to AI agent tool registry in Chat message response handler
  - AI agent can now schedule meetings, check availability, and manage calendar events
  - Integration with existing email and contact tools for comprehensive workflow automation
- **User Resource Enhancement**: Extended User model with calendar synchronization capabilities
  - Added `sync_calendar_events` action following existing Gmail/HubSpot sync patterns
  - Automatic calendar sync scheduling in Google OAuth registration flow
  - Calendar sync status tracking alongside existing email and contact sync statuses
- **Oban Queue Configuration**: Added `calendar_sync` queue for background calendar synchronization jobs
- **Email Sync Performance**: Modified `sync_gmail_emails` action in `JumpstartAi.Accounts.User` to use streaming approach
- **Memory Usage**: Reduced memory footprint by processing emails in smaller batches (50 emails) instead of loading all 500 emails at once
- **Database Write Pattern**: Changed from bulk processing all emails at the end to incremental processing and writing in batches of 10 emails
- **Error Recovery**: Improved error handling with partial success scenarios where some emails may be saved even if the process fails later

### Technical Details
- **Calendar Integration Architecture**:
  - **CalendarClient**: Google Calendar API wrapper with OAuth token management and refresh
  - **CalendarService**: Business logic with streaming support and free time calculation
  - **Batch Processing**: Calendar events synced in batches of 50 with database writes in chunks of 10
  - **Time Range**: Syncs events from last 30 days to next 90 days (120 day window)
  - **Token Reuse**: Leverages existing Google OAuth tokens from Gmail integration
- **AI Agent Tool Integration**:
  - Tools registered in Chat domain for LangChain/AshAI framework compatibility
  - Calendar actions exposed as callable tools: schedule_meeting, find_availability, list_upcoming
  - Integration with existing email and contact tools for multi-step workflows
- **Database Design**:
  - `calendar_events` table with UUID primary keys and proper foreign key constraints
  - Unique constraint on (user_id, google_event_id) to prevent duplicates
  - JSON storage for attendee information with parsing calculations
- **Background Job Processing**:
  - CalendarSync worker follows existing EmailSync/ContactSync patterns
  - Automatic scheduling during OAuth flow with configurable delays
  - Queue: calendar_sync with limit of 10 concurrent jobs
- **Email Sync Batch Configuration**: 
  - Gmail API fetch: 50 emails per request
  - Database insertion: 10 emails per bulk create operation
  - Total emails: 500 (unchanged)
- **Email Sync Flow Improvement**:
  - **Before**: Fetch all 500 → Load into memory → Process in batches → Write to DB
  - **After**: Fetch 50 → Process in chunks of 10 → Write to DB → Repeat for next 50
- **Pagination**: Automatic handling of Gmail API `nextPageToken` for seamless multi-page fetching

### Performance Benefits
- **Calendar Integration Performance**:
  - **Efficient Sync**: Streaming calendar events with batched processing reduces memory usage
  - **Smart Time Range**: 120-day window (past 30 + future 90 days) balances completeness with performance  
  - **Token Optimization**: Reuses existing Google OAuth tokens, no additional authentication flows
  - **Concurrent Processing**: Calendar sync runs in parallel with email/contact sync via separate queue
- **Email Sync Performance Benefits**:
  - **Reduced Memory Usage**: ~90% reduction in peak memory usage (50 emails vs 500 emails in memory)
  - **Faster Time to First Write**: Database writes begin after first 50 emails instead of waiting for all 500
  - **Better Responsiveness**: Continuous progress instead of all-or-nothing processing
  - **Improved Scalability**: Can handle larger email volumes without memory constraints

### Files Modified
**Calendar Integration:**
- `lib/jumpstart_ai/calendar_client.ex`: **NEW** - Google Calendar API client with OAuth token management
- `lib/jumpstart_ai/calendar_service.ex`: **NEW** - Calendar business logic with streaming and free time calculation  
- `lib/jumpstart_ai/accounts/calendar_event.ex`: **NEW** - Calendar event resource with AI tool actions
- `lib/jumpstart_ai/workers/calendar_sync.ex`: **NEW** - Background worker for calendar synchronization
- `lib/jumpstart_ai/accounts.ex`: Added CalendarEvent resource to domain
- `lib/jumpstart_ai/accounts/user.ex`: Added calendar sync functionality and relationships
- `lib/jumpstart_ai/chat/message/changes/respond.ex`: Registered calendar tools for AI agent
- `config/config.exs`: Added calendar_sync queue to Oban configuration
- `priv/repo/migrations/20250616003823_add_calendar_events.exs`: **NEW** - Database migration for calendar events

**Email Sync Improvements:**
- `lib/jumpstart_ai/gmail_service.ex`: Added streaming functionality with pagination support
- `lib/jumpstart_ai/accounts/user.ex`: Updated email sync action to use streaming approach  
- `test/jumpstart_ai/accounts/user_test.exs`: Added tests for streaming functionality parameters and callback formats

### Backward Compatibility
- **Calendar Integration**: Fully additive with no breaking changes to existing functionality
  - New OAuth scope requires user re-authentication to access calendar features
  - Existing users without calendar permission continue to work normally
  - Calendar sync gracefully handles missing tokens and permissions
- **Email Sync**: All existing functionality remains unchanged
  - Original `fetch_user_emails/2` function preserved for backward compatibility
  - Existing tests continue to pass without modification
  - No breaking changes to public APIs
- **Database**: Migration is non-destructive, only adds new tables and columns
- **AI Agent**: Existing chat functionality unchanged, calendar tools are additional capabilities

### AI Agent Use Cases Enabled
- **"Schedule a meeting with John Smith next Tuesday at 2pm"** - Creates calendar event and sends invitation
- **"When am I free this week?"** - Analyzes calendar and shows available time slots
- **"What meetings do I have with ABC Corp?"** - Searches calendar events for specific attendees/companies
- **"Someone emailed asking for a meeting, find some times"** - Checks availability and suggests options
- **Multi-step workflows**: Email → Calendar check → Schedule → Email confirmation workflows