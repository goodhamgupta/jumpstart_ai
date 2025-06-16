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
    tool :semantic_search_contact_notes, JumpstartAi.Accounts.ContactNote, :semantic_search_contact_notes do
      description "Semantic search for contact notes using AI-powered vector similarity matching"
    end
    tool :semantic_search_calendar_events, JumpstartAi.Accounts.CalendarEvent, :semantic_search_calendar_events do
      description "Semantic search for calendar events using AI-powered vector similarity matching"
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
