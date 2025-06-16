defmodule JumpstartAi.Tools do
  use Ash.Resource, domain: JumpstartAi.Accounts

  actions do
    action :search_emails_by_from, {:array, :map} do
      description """
      Search for emails by from_email field. Returns a list of emails from the specified sender.
      """

      argument :from_email, :string do
        allow_nil? false
        description "The email address to search for in the from_email field"
      end

      run fn input, context ->
        user_id = context.actor.id
        from_email = input.arguments.from_email

        case JumpstartAi.Accounts.Email
             |> Ash.Query.for_read(:search_by_from_email, %{
               from_email: "%#{from_email}%",
               user_id: user_id
             })
             |> Ash.Query.select([:subject, :from_email, :from_name, :date, :snippet, :body_text])
             |> Ash.Query.sort(date: :desc)
             |> Ash.Query.limit(20)
             |> Ash.read(actor: context.actor, authorize?: false) do
          {:ok, emails} ->
            formatted_emails =
              Enum.map(emails, fn email ->
                %{
                  "subject" => email.subject || "No Subject",
                  "from_email" => email.from_email,
                  "from_name" => email.from_name,
                  "date" => email.date && DateTime.to_iso8601(email.date),
                  "snippet" => email.snippet,
                  "body_preview" =>
                    case email.body_text do
                      nil -> nil
                      text when byte_size(text) > 200 -> String.slice(text, 0, 200) <> "..."
                      text -> text
                    end
                }
              end)

            {:ok, formatted_emails}

          {:error, error} ->
            {:error, "Failed to search emails: #{inspect(error)}"}
        end
      end
    end
  end
end
