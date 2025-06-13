defmodule JumpstartAi.Accounts do
  use Ash.Domain,
    otp_app: :jumpstart_ai

  resources do
    resource JumpstartAi.Accounts.Token
    resource JumpstartAi.Accounts.User
  end
end
