defmodule Marrylocal.Repo.Migrations.AddProfileColumnsToUsers do
  use Ecto.Migration

  @moduledoc """
  Completes the `users` table expected by `Marrylocal.Accounts.User`.

  The original auth migration only created the email/password shell. This
  migration is intentionally idempotent (`ADD COLUMN IF NOT EXISTS`) so it is
  safe on both fresh databases and environments that already received the
  profile columns out-of-band.
  """

  def up do
    execute """
    ALTER TABLE users
      ADD COLUMN IF NOT EXISTS first_name varchar(100),
      ADD COLUMN IF NOT EXISTS last_name varchar(100),
      ADD COLUMN IF NOT EXISTS date_of_birth date,
      ADD COLUMN IF NOT EXISTS age integer,
      ADD COLUMN IF NOT EXISTS gender varchar(32),
      ADD COLUMN IF NOT EXISTS state varchar(100),
      ADD COLUMN IF NOT EXISTS city varchar(100),
      ADD COLUMN IF NOT EXISTS language varchar(100),
      ADD COLUMN IF NOT EXISTS religion varchar(100),
      ADD COLUMN IF NOT EXISTS community varchar(100),
      ADD COLUMN IF NOT EXISTS phone_number varchar(20),
      ADD COLUMN IF NOT EXISTS latitude double precision,
      ADD COLUMN IF NOT EXISTS longitude double precision,
      ADD COLUMN IF NOT EXISTS bio varchar(500) NOT NULL DEFAULT '',
      ADD COLUMN IF NOT EXISTS facebook varchar(255),
      ADD COLUMN IF NOT EXISTS instagram varchar(255),
      ADD COLUMN IF NOT EXISTS whatsapp varchar(255),
      ADD COLUMN IF NOT EXISTS shortid varchar(16),
      ADD COLUMN IF NOT EXISTS aadhar_number varchar(16),
      ADD COLUMN IF NOT EXISTS around_user_count integer NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS verify_retry_count integer NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS password_retry_count integer NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS education_level varchar(64),
      ADD COLUMN IF NOT EXISTS economic_status varchar(64),
      ADD COLUMN IF NOT EXISTS user_state varchar(32) NOT NULL DEFAULT 'inactive',
      ADD COLUMN IF NOT EXISTS role varchar(32) NOT NULL DEFAULT 'user',
      ADD COLUMN IF NOT EXISTS job_status boolean,
      ADD COLUMN IF NOT EXISTS show_phone boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS show_facebook boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS show_instagram boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS show_community boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS show_in_other_religion_people_search boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS email_verified boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS aadhar_verified boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS passport_verified boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS license_verified boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS terms_accepted boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS onetime_fees_paid boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS onetime_fees_required boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS sample_profile boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS default_coordinates_set boolean NOT NULL DEFAULT true,
      ADD COLUMN IF NOT EXISTS user_coordinates_set boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS location_change_payment_required boolean NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS accepted_one_time_fees_amount integer NOT NULL DEFAULT 500,
      ADD COLUMN IF NOT EXISTS accepted_years_initial_term integer NOT NULL DEFAULT 1,
      ADD COLUMN IF NOT EXISTS max_search_distance integer NOT NULL DEFAULT 100,
      ADD COLUMN IF NOT EXISTS referral_code varchar(32),
      ADD COLUMN IF NOT EXISTS referrer varchar(32),
      ADD COLUMN IF NOT EXISTS shortlist text[] NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS images text[] NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS referree_emails text[] NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS addons jsonb,
      ADD COLUMN IF NOT EXISTS time_of_login timestamp(0),
      ADD COLUMN IF NOT EXISTS date_of_creation timestamp(0) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      ADD COLUMN IF NOT EXISTS date_of_activation timestamp(0),
      ADD COLUMN IF NOT EXISTS date_of_location timestamp(0),
      ADD COLUMN IF NOT EXISTS date_of_coordinates timestamp(0),
      ADD COLUMN IF NOT EXISTS last_login_at timestamp(0),
      ADD COLUMN IF NOT EXISTS last_seen_at timestamp(0),
      ADD COLUMN IF NOT EXISTS last_active_at timestamp(0),
      ADD COLUMN IF NOT EXISTS push_token varchar(255)
    """
  end

  def down do
    # Columns may predate this migration in shared environments; rolling them
    # back would destroy production profile data. Intentional no-op.
    :ok
  end
end
