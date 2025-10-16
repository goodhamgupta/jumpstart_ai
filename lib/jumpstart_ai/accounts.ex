defmodule JumpstartAi.Accounts do
  use Ash.Domain,
    otp_app: :jumpstart_ai,
    extensions: [AshAi]

  tools do
    tool :search_emails_by_from, JumpstartAi.Accounts.Email, :search_emails_by_from

    tool :semantic_search_emails, JumpstartAi.Accounts.Email, :semantic_search_emails do
      description "Semantic search for emails using AI-powered vector similarity matching"
    end

    tool :semantic_search_contacts, JumpstartAi.Accounts.Contact, :semantic_search_contacts do
      description "Semantic search for contacts using AI-powered vector similarity matching"
    end

    tool :semantic_search_contact_notes,
         JumpstartAi.Accounts.ContactNote,
         :semantic_search_contact_notes do
      description "Semantic search for contact notes using AI-powered vector similarity matching"
    end

    tool :semantic_search_calendar_events,
         JumpstartAi.Accounts.CalendarEvent,
         :semantic_search_calendar_events do
      description "Semantic search for calendar events using AI-powered vector similarity matching"
    end

    tool :draft_email, JumpstartAi.Accounts.Email, :draft_email do
      description """
      Create and save an email draft to Gmail. This is the REQUIRED first step for all email composition. 
      Never send emails directly - always draft first to allow user review and confirmation.
      Use this when the user wants to compose, write, or create any email.
      Returns a draft_id that can be used later with send_draft to actually send the email.
      """
    end

    tool :list_drafts, JumpstartAi.Accounts.Email, :list_drafts do
      description """
      List all saved email drafts from Gmail with their details including subject, recipients, and draft_id.
      Use this to show users their pending drafts so they can review and decide which ones to send.
      Essential for the draft-review-send workflow.
      """
    end

    tool :send_email_with_draft, JumpstartAi.Accounts.Email, :send_email_with_draft do
      description """
      Send an email using content from a previously created draft. This is the SAFE way to send emails.
      Requires a draft_id from an existing draft - validates draft exists and extracts content before sending.
      Always require explicit user confirmation before sending any draft.
      Ask the user to confirm: 'Should I send this draft?' before using this tool.
      Never send emails automatically - user must explicitly approve sending.
      """
    end

    tool :create_calendar_event, JumpstartAi.Accounts.CalendarEvent, :create_calendar_event do
      description """
      Creates a new calendar event in Google Calendar with the specified details.
      Supports setting title, description, location, start/end times, and attendee email addresses.
      The event will be created in the user's primary calendar and attendees will receive email notifications.
      Use this when the user wants to schedule meetings, appointments, or events.
      """
    end

    tool :list_emails, JumpstartAi.Accounts.Email, :list_emails do
      description """
      Lists the latest emails for the user. Shows the 10 most recent emails with key details like subject, from, to, date, and snippet.
      Use this to give users an overview of their recent email activity.
      """
    end

    tool :list_contacts, JumpstartAi.Accounts.Contact, :list_contacts do
      description """
      Lists the latest contacts for the user. Shows the 10 most recent contacts with details like name, email, company, phone, and lifecycle stage.
      Use this to give users an overview of their recent contacts.
      """
    end

    tool :list_contact_notes, JumpstartAi.Accounts.ContactNote, :list_contact_notes do
      description """
      Lists the latest contact notes. Shows the 10 most recent notes with details like content preview, note type, source, and creation date.
      Optionally filter notes for a specific contact by providing contact_id.
      """
    end

    tool :list_calendar_events, JumpstartAi.Accounts.CalendarEvent, :list_calendar_events do
      description """
      Lists the latest calendar events for the user. Shows the 10 most recent events with details like title, location, time, attendees, and status.
      Use this to give users an overview of their upcoming or recent calendar events.
      """
    end

    tool :search_contacts, JumpstartAi.Accounts.Contact, :search_contacts do
      description """
      Unified contact search that tries both field-based and semantic search automatically.
      First performs exact field matching on name, email, and company, then falls back to semantic search if few results found.
      Use this when you need to search for contacts and aren't sure of the exact match.
      """
    end

    tool :get_contact_by_id, JumpstartAi.Accounts.Contact, :get_contact_by_id do
      description """
      Gets a single contact by ID. Returns full contact details including notes summary if found.
      Use this when you have a specific contact_id from a mention or previous search.
      """
    end

    tool :create_hubspot_contact, JumpstartAi.Accounts.Contact, :create_hubspot_contact do
      description """
      Create a new contact in HubSpot CRM. This will create the contact both in HubSpot's API
      and in the local database for syncing and semantic search.
      Use this when you need to add a new contact to HubSpot, for example when an unknown sender emails.
      """
    end

    tool :create_contact_note, JumpstartAi.Accounts.ContactNote, :create_hubspot_note do
      description """
      Add a note to a contact (works with HubSpot contacts or local contacts).
      For HubSpot contacts, the note will be created in HubSpot and synced locally.
      For non-HubSpot contacts, the note will be stored locally only.
      Use this to record information about interactions with contacts.
      """
    end
  end

  resources do
    resource JumpstartAi.Accounts.Token
    resource JumpstartAi.Accounts.User
    resource JumpstartAi.Accounts.Email
    resource JumpstartAi.Accounts.Contact
    resource JumpstartAi.Accounts.ContactNote
    resource JumpstartAi.Accounts.CalendarEvent
  end
end
