defmodule Marrylocal.Emails.UserEmail do
  import Swoosh.Email

  def deletion_reminder_email(user) do
    new()
    |> to({user.first_name, user.email})
    |> from({"Support", "noreply@marrylocal.in"})
    |> subject("Action Required: Your account will be deleted in 24 hours")
    |> html_body("""
      <p>Hi #{user.first_name},</p>
      <p>You haven't verified your email yet. To protect your data, unverified accounts are
      deleted after 7 days. Please verify now to keep your profile.</p>
    """)
  end

  def reset_password_instructions(user, url) do
    new()
    |> to({user.first_name, user.email})
    |> from({"Support", "noreply@marrylocal.in"})
    |> subject("Reset your password")
    |> html_body("""
      <p>Hi #{user.first_name},</p>
      <p>You can reset your password by clicking the link below:</p>
      <p><a href="#{url}">Reset Password</a></p>
      <p>If you didn't request this, please ignore this email. This link expires in 1 hour.</p>
    """)
    |> text_body("""
      Hi #{user.first_name},

      You can reset your password by visiting the URL below:

      #{url}

      If you didn't request this, please ignore this email. This link expires in 1 hour.
    """)
  end

  def inactivity_warning(user) do
    new()
    |> to({user.first_name, user.email})
    |> from({"MarryLocal", "noreply@marrylocal.in"})
    |> subject("We miss you at MarryLocal")
    |> html_body("""
      <p>Hi #{user.first_name},</p>
      <p>Your profile has been quiet for a while. New local matches are joining nearby.</p>
      <p>Sign in to refresh your discovery feed and keep your profile visible.</p>
    """)
  end

  def anniversary_reminder(user) do
    new()
    |> to({user.first_name, user.email})
    |> from({"MarryLocal", "noreply@marrylocal.in"})
    |> subject("Your Annual Membership Reset is in 7 Days")
    |> html_body("""
      <p>Hi #{user.first_name},</p>
      <p>Your one-year membership anniversary is approaching on
      <strong>#{Calendar.strftime(user.date_of_activation, "%d %b %Y")}</strong>.</p>
      <p>Per our policy, your referral list and fee status will reset.
      You currently have <strong>#{Enum.count(user.referee_emails || [])}</strong> referrals.</p>
      <p>Keep referring to maintain your discounts for the next year!</p>
    """)
  end
end
