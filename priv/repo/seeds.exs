# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

import Ash.Expr

# Example: Create a test user and some contacts if they don't exist
case JumpstartAi.Accounts.User |> Ash.Query.limit(1) |> Ash.read(authorize?: false) do
  {:ok, []} ->
    # No users exist, you might want to create one here
    IO.puts("No users found. Please create a user first by signing up.")

  {:ok, [user | _]} ->
    IO.puts("Found user: #{user.email}")

    # Check if user already has contacts
    case JumpstartAi.Accounts.Contact
         |> Ash.Query.filter(expr(user_id == ^user.id))
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, []} ->
        IO.puts("Creating sample contacts for user...")

        # Create some sample contacts
        contacts = [
          %{
            firstname: "John",
            lastname: "Doe",
            email: "john.doe@example.com",
            company: "Acme Corp"
          },
          %{
            firstname: "Jane",
            lastname: "Smith",
            email: "jane.smith@example.com",
            company: "Tech Solutions"
          },
          %{
            firstname: "Bob",
            lastname: "Johnson",
            email: "bob@example.com",
            company: "StartupXYZ"
          },
          %{
            firstname: "Alice",
            lastname: "Williams",
            email: "alice.w@example.com",
            company: "Global Industries"
          },
          %{
            firstname: "Charlie",
            lastname: "Brown",
            email: "charlie@example.com",
            company: "Creative Agency"
          }
        ]

        Enum.each(contacts, fn contact_data ->
          case JumpstartAi.Accounts.Contact.create(%{
                 user_id: user.id,
                 source: "manual",
                 external_id: "seed-#{:rand.uniform(1_000_000)}",
                 firstname: contact_data.firstname,
                 lastname: contact_data.lastname,
                 email: contact_data.email,
                 company: contact_data.company,
                 lifecycle_stage: "lead"
               }) do
            {:ok, contact} ->
              IO.puts("  Created contact: #{contact.firstname} #{contact.lastname}")

            {:error, error} ->
              IO.puts("  Failed to create contact: #{inspect(error)}")
          end
        end)

      {:ok, _contacts} ->
        IO.puts("User already has contacts. Skipping seed data.")
    end

  {:error, error} ->
    IO.puts("Error reading users: #{inspect(error)}")
end
