defmodule Marrylocal.Accounts.SignupGuard do
  @moduledoc """
  Zero-cost launch guards for account registration and manual identity review.

  Phone numbers are stored as canonical 10-digit Indian mobile numbers.
  Disposable email domains are rejected before persistence. Identity hashes are
  one-way and salted so raw document numbers are never stored in plain text.
  """

  @disposable_domains ~w(
    mailinator.com
    yopmail.com
    tempmail.com
    10minutemail.com
    guerrillamail.com
    sharklasers.com
    dispostable.com
    trashmail.com
    getnada.com
    temp-mail.org
    fakeinbox.com
    maildrop.cc
  )

  @doc "Normalizes Indian phone input to the canonical 10-digit form."
  def normalize_phone(value) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")

    cond do
      String.length(digits) == 10 -> digits
      String.length(digits) > 10 -> String.slice(digits, -10, 10)
      true -> digits
    end
  end

  def normalize_phone(value), do: value

  @doc "True when the email belongs to a known disposable-email provider."
  def disposable_email?(email) when is_binary(email) do
    domain =
      email
      |> String.trim()
      |> String.downcase()
      |> String.split("@")
      |> List.last()

    domain in @disposable_domains
  end

  def disposable_email?(_email), do: false

  @doc "Normalizes a passport/license number for hashing and comparison."
  def normalize_document_number(value) when is_binary(value) do
    value
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
  end

  def normalize_document_number(value), do: value |> to_string() |> normalize_document_number()

  @doc "One-way salted identity hash used to block duplicate document claims."
  def identity_hash(document_type, document_number) do
    salt = System.get_env("KYC_IDENTITY_SALT", "marrylocal-manual-kyc-v1")
    type = document_type |> to_string() |> String.downcase()
    number = normalize_document_number(document_number)

    :crypto.hash(:sha256, "#{type}:#{number}:#{salt}")
    |> Base.encode16(case: :lower)
  end
end
