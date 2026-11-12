defmodule Marrylocal.Accounts.UserToken do
  @moduledoc """
  Database-backed bearer and email tokens.

  Session tokens are opaque URL-safe random strings. Only a SHA-256 hash of the
  raw token is persisted, so a read-only database leak does not expose usable
  credentials. Verification is a shared database lookup, which keeps the API
  stateless across nodes and lets a single logout revoke one session.
  """

  use Ecto.Schema
  import Ecto.Query

  alias Marrylocal.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  @magic_link_validity_in_minutes 15
  @reset_password_validity_in_hours 1
  @confirm_validity_in_days 7
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :string
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime

    belongs_to :user, Marrylocal.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a session token and its hashed counterpart.

  The raw token is URL-safe Base64 and is the only value the client sees. Only
  `encode_hash/1` of the raw bytes is persisted.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: encode_hash(token),
       context: "session",
       user_id: user.id,
       authenticated_at: dt
     }}
  end

  @doc """
  Verifies a client bearer token and returns the lookup query for its user.
  """
  def verify_session_token_query(token) do
    with {:ok, hashed_token} <- hash_session_token(token) do
      query =
        from token in by_token_and_context_query(hashed_token, "session"),
          join: user in assoc(token, :user),
          where: token.inserted_at > ago(@session_validity_in_days, "day"),
          select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

      {:ok, query}
    end
  end

  @doc "Builds a token and its hash for delivery by email."
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: encode_hash(token),
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Verifies a confirmation or password-reset token and returns its user query.

  Password-reset tokens are accepted for exactly one hour. Confirmation and
  email-change tokens keep their previous multi-day windows.
  """
  def verify_email_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        encoded_hashed_token = encode_hash(decoded_token)
        {:ok, email_token_query(encoded_hashed_token, context)}

      :error ->
        :error
    end
  end

  defp email_token_query(encoded_hashed_token, "reset_password") do
    from token in by_token_and_context_query(encoded_hashed_token, "reset_password"),
      join: user in assoc(token, :user),
      where:
        token.inserted_at > ago(^@reset_password_validity_in_hours, "hour") and
          token.sent_to == user.email,
      select: user
  end

  defp email_token_query(encoded_hashed_token, context) do
    days = days_for_context(context)

    from token in by_token_and_context_query(encoded_hashed_token, context),
      join: user in assoc(token, :user),
      where: token.inserted_at > ago(^days, "day") and token.sent_to == user.email,
      select: user
  end

  defp days_for_context("confirm"), do: @confirm_validity_in_days
  defp days_for_context(_context), do: @change_email_validity_in_days

  @doc """
  Verifies a magic-link login token. Returns `{user, token}` for the caller.
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        encoded_hashed_token = encode_hash(decoded_token)

        query =
          from token in by_token_and_context_query(encoded_hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc "Verifies an email-change token whose context starts with `change:`."
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        encoded_hashed_token = encode_hash(decoded_token)

        query =
          from token in by_token_and_context_query(encoded_hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc "Returns a query for all tokens owned by the user, optionally by context."
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end

  @doc "Backwards-compatible alias used by the password reset flow."
  def user_and_contexts_query(user, contexts), do: by_user_and_contexts_query(user, contexts)

  @doc """
  Hashes a raw client token into the value persisted in the database.

  Returns `:error` when the token is not valid URL-safe Base64.
  """
  def hash_session_token(token) when is_binary(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false) do
      {:ok, encode_hash(decoded_token)}
    end
  end

  def hash_session_token(_token), do: :error

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  defp encode_hash(token) do
    Base.encode64(:crypto.hash(@hash_algorithm, token), padding: false)
  end
end
