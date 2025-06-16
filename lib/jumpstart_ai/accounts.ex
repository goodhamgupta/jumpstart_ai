defmodule JumpstartAi.Accounts do
  use Ash.Domain,
    otp_app: :jumpstart_ai,
    extensions: [AshAi]

  tools do
    tool :search_emails_by_from, JumpstartAi.Accounts.Email, :search_emails_by_from
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
