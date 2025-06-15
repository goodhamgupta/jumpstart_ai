defmodule JumpstartAiWeb.AuthController do
  use JumpstartAiWeb, :controller
  use AshAuthentication.Phoenix.Controller
  require Logger

  def success(conn, activity, user, _token) do
    # Log successful OAuth callback
    Logger.info("AuthController.success - Activity: #{inspect(activity)}")
    Logger.info("AuthController.success - User ID: #{user.id}")
    Logger.info("AuthController.success - User Email: #{user.email}")
    Logger.info("AuthController.success - Request Path: #{conn.request_path}")

    Logger.info(
      "AuthController.success - HubSpot Connected: #{not is_nil(user.hubspot_access_token)}"
    )

    return_to = get_session(conn, :return_to) || ~p"/"

    message =
      case activity do
        {:confirm_new_user, :confirm} -> "Your email address has now been confirmed"
        {:password, :reset} -> "Your password has successfully been reset"
        _ -> "You are now signed in"
      end

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, activity, reason) do
    # Log authentication failure
    Logger.error("AuthController.failure - Activity: #{inspect(activity)}")
    Logger.error("AuthController.failure - Reason: #{inspect(reason)}")
    Logger.error("AuthController.failure - Request Path: #{conn.request_path}")
    Logger.error("AuthController.failure - Query Params: #{inspect(conn.query_params)}")

    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        _ ->
          "Incorrect email or password"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session()
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
