defmodule JumpstartAi.Accounts do
  use Ash.Domain,
    otp_app: :jumpstart_ai

  resources do
    resource JumpstartAi.Accounts.Token
    resource JumpstartAi.Accounts.User
    resource JumpstartAi.Accounts.Email
    resource JumpstartAi.Accounts.Contact
    resource JumpstartAi.Accounts.ContactNote
  end
end
