# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Streaming Email Sync**: New streaming email processing functionality that processes emails in batches during fetching rather than loading all emails into memory at once
- `stream_user_emails/2` function in `JumpstartAi.GmailService` for paginated email processing with configurable batch sizes
- Support for Gmail API pagination using `pageToken` and `maxResults` parameters
- Progressive database writes during email sync process
- Unit tests for streaming email processing functionality

### Changed
- **Email Sync Performance**: Modified `sync_gmail_emails` action in `JumpstartAi.Accounts.User` to use streaming approach
- **Memory Usage**: Reduced memory footprint by processing emails in smaller batches (50 emails) instead of loading all 500 emails at once
- **Database Write Pattern**: Changed from bulk processing all emails at the end to incremental processing and writing in batches of 10 emails
- **Error Recovery**: Improved error handling with partial success scenarios where some emails may be saved even if the process fails later

### Technical Details
- **Batch Configuration**: 
  - Gmail API fetch: 50 emails per request
  - Database insertion: 10 emails per bulk create operation
  - Total emails: 500 (unchanged)
- **Flow Improvement**:
  - **Before**: Fetch all 500 → Load into memory → Process in batches → Write to DB
  - **After**: Fetch 50 → Process in chunks of 10 → Write to DB → Repeat for next 50
- **Pagination**: Automatic handling of Gmail API `nextPageToken` for seamless multi-page fetching

### Performance Benefits
- **Reduced Memory Usage**: ~90% reduction in peak memory usage (50 emails vs 500 emails in memory)
- **Faster Time to First Write**: Database writes begin after first 50 emails instead of waiting for all 500
- **Better Responsiveness**: Continuous progress instead of all-or-nothing processing
- **Improved Scalability**: Can handle larger email volumes without memory constraints

### Files Modified
- `lib/jumpstart_ai/gmail_service.ex`: Added streaming functionality with pagination support
- `lib/jumpstart_ai/accounts/user.ex`: Updated email sync action to use streaming approach
- `test/jumpstart_ai/accounts/user_test.exs`: Added tests for streaming functionality parameters and callback formats

### Backward Compatibility
- All existing functionality remains unchanged
- Original `fetch_user_emails/2` function preserved for backward compatibility
- Existing tests continue to pass without modification
- No breaking changes to public APIs