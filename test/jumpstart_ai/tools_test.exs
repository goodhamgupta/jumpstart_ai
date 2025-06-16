defmodule JumpstartAi.ToolsTest do
  use JumpstartAi.DataCase, async: true

  alias JumpstartAi.Accounts.{User, Email}
  alias JumpstartAi.Tools

  describe "search_emails_by_from action" do
    setup do
      # Create a test user using Google OAuth action
      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{
            user_info: %{
              "email" => "test@example.com",
              "name" => "Test User",
              "given_name" => "Test",
              "family_name" => "User"
            },
            oauth_tokens: %{
              "access_token" => "test_access_token",
              "refresh_token" => "test_refresh_token",
              "expires_in" => 3600
            }
          },
          authorize?: false
        )
        |> Ash.create()

      # Create test emails
      email_data = [
        %{
          gmail_id: "email1",
          subject: "Test Email 1",
          from_email: "sender1@example.com",
          from_name: "Test Sender 1",
          to_email: user.email,
          date: DateTime.utc_now(),
          snippet: "This is a test email",
          body_text: "Full body of test email 1",
          user_id: user.id
        },
        %{
          gmail_id: "email2",
          subject: "Test Email 2",
          from_email: "sender2@example.com",
          from_name: "Test Sender 2",
          to_email: user.email,
          date: DateTime.utc_now(),
          snippet: "Another test email",
          body_text: "Full body of test email 2",
          user_id: user.id
        },
        %{
          gmail_id: "email3",
          subject: "Test Email 3",
          from_email: "sender1@example.com",
          from_name: "Test Sender 1",
          to_email: user.email,
          date: DateTime.utc_now(),
          snippet: "Third test email",
          body_text: "Full body of test email 3",
          user_id: user.id
        }
      ]

      %{records: emails} =
        Ash.bulk_create(
          email_data,
          Email,
          :create_from_gmail,
          upsert?: true,
          upsert_identity: :unique_gmail_id_per_user,
          upsert_fields: [
            :subject,
            :from_email,
            :from_name,
            :to_email,
            :date,
            :snippet,
            :body_text,
            :body_html,
            :label_ids,
            :attachments,
            :mime_type
          ],
          actor: user,
          authorize?: false,
          return_records?: true
        )

      %{user: user, emails: emails}
    end

    test "searches emails by exact from_email match", %{user: user} do
      # Test searching for sender1@example.com
      {:ok, result} =
        Tools
        |> Ash.ActionInput.for_action(:search_emails_by_from, %{from_email: "sender1@example.com"})
        |> Ash.run_action(actor: user)

      assert length(result) == 2

      # Check that all results are from sender1@example.com
      Enum.each(result, fn email ->
        assert email["from_email"] == "sender1@example.com"
        assert email["from_name"] == "Test Sender 1"
        assert is_binary(email["subject"])
        assert is_binary(email["snippet"])
      end)
    end

    test "searches emails by partial from_email match", %{user: user} do
      # Test searching for partial match
      {:ok, result} =
        Tools
        |> Ash.ActionInput.for_action(:search_emails_by_from, %{from_email: "sender2"})
        |> Ash.run_action(actor: user)

      assert length(result) == 1
      assert hd(result)["from_email"] == "sender2@example.com"
    end

    test "returns empty list when no emails match", %{user: user} do
      {:ok, result} =
        Tools
        |> Ash.ActionInput.for_action(:search_emails_by_from, %{
          from_email: "nonexistent@example.com"
        })
        |> Ash.run_action(actor: user)

      assert result == []
    end

    test "only returns emails for the authenticated user", %{emails: _emails} do
      # Create another user
      {:ok, other_user} =
        User
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{
            user_info: %{
              "email" => "other@example.com",
              "name" => "Other User",
              "given_name" => "Other",
              "family_name" => "User"
            },
            oauth_tokens: %{
              "access_token" => "other_access_token",
              "refresh_token" => "other_refresh_token",
              "expires_in" => 3600
            }
          },
          authorize?: false
        )
        |> Ash.create()

      # Search as the other user should return no results
      {:ok, result} =
        Tools
        |> Ash.ActionInput.for_action(:search_emails_by_from, %{from_email: "sender1@example.com"})
        |> Ash.run_action(actor: other_user)

      assert result == []
    end

    test "formats email data correctly", %{user: user} do
      {:ok, result} =
        Tools
        |> Ash.ActionInput.for_action(:search_emails_by_from, %{from_email: "sender1@example.com"})
        |> Ash.run_action(actor: user)

      email = hd(result)

      # Check required fields are present
      assert Map.has_key?(email, "subject")
      assert Map.has_key?(email, "from_email")
      assert Map.has_key?(email, "from_name")
      assert Map.has_key?(email, "date")
      assert Map.has_key?(email, "snippet")
      assert Map.has_key?(email, "body_preview")

      # Check date is formatted as ISO8601
      assert is_binary(email["date"])
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(email["date"])
    end

    test "limits body preview to 200 characters", %{user: user} do
      # Create an email with long body text
      long_text = String.duplicate("A", 300)

      Email
      |> Ash.Changeset.for_create(:create_from_gmail, %{
        gmail_id: "long_email",
        subject: "Long Email",
        from_email: "long@example.com",
        body_text: long_text,
        user_id: user.id
      })
      |> Ash.create!(actor: user, authorize?: false)

      {:ok, result} =
        Tools
        |> Ash.ActionInput.for_action(:search_emails_by_from, %{from_email: "long@example.com"})
        |> Ash.run_action(actor: user)

      email = hd(result)
      # 200 + "..."
      assert String.length(email["body_preview"]) <= 203
      assert String.ends_with?(email["body_preview"], "...")
    end
  end
end
