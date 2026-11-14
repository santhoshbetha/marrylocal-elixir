defmodule MarrylocalWeb.Router do
  use MarrylocalWeb, :router

  import MarrylocalWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Public JSON endpoints (registration, login, password recovery).
  pipeline :api_public do
    plug :accepts, ["json"]
  end

  # Optional authentication. Used by endpoints that personalize a response but
  # do not require a session.
  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_current_user
  end

  # Stateless bearer authentication. The bearer token is verified against the
  # hashed `users_tokens` row on every request.
  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug :fetch_current_user
    plug :require_authenticated_api_user
    plug MarrylocalWeb.Plugs.TrackUserActivity
  end

  pipeline :rate_limit_discovery do
    plug MarrylocalWeb.Plugs.RateLimitDiscovery
  end

  pipeline :rate_limit_registration do
    plug MarrylocalWeb.Plugs.RateLimitRegistration
  end

  pipeline :rate_limit_uploads do
    plug MarrylocalWeb.Plugs.RateLimitUploads
  end

  pipeline :admin_required do
    plug :accepts, ["json"]
    plug :fetch_current_user
    plug :require_authenticated_api_user
    plug MarrylocalWeb.Plugs.RequireAdmin
  end

  pipeline :admin_sudo_required do
    plug :accepts, ["json"]
    plug :fetch_current_user
    plug :require_authenticated_api_user
    plug MarrylocalWeb.Plugs.RequireAdmin
    plug :require_api_sudo_mode
  end

  # ---------------------------------------------------------------------------
  # Admin
  # ---------------------------------------------------------------------------
  scope "/api/admin", MarrylocalWeb do
    pipe_through :admin_required

    get "/stats", AdminController, :dashboard_stats
    get "/archive", AdminController, :archived_users
    post "/ban/:id", AdminController, :ban
  end

  # ---------------------------------------------------------------------------
  # Versioned admin review endpoints
  # ---------------------------------------------------------------------------
  scope "/api/v1/admin", MarrylocalWeb do
    pipe_through :admin_sudo_required

    get "/verifications", AdminVerificationController, :index
    get "/verifications/:id", AdminVerificationController, :show
    post "/verifications/:id/approve", AdminVerificationController, :approve
    post "/verifications/:id/reject", AdminVerificationController, :reject
  end

  # ---------------------------------------------------------------------------
  # Versioned admin user management and broadcast email endpoints.
  # These require an authenticated admin but not an active sudo window.
  # ---------------------------------------------------------------------------
  scope "/api/v1/admin", MarrylocalWeb.Admin do
    pipe_through :admin_required

    get "/users", UserController, :index
    get "/users/lookup", UserController, :lookup
    get "/users/:id/verifications", UserController, :verification_history
    post "/users/grant-peer-verifier", UserController, :grant_peer_verifier
    patch "/users/:id", UserController, :update
    post "/users/bulk-update", UserController, :bulk_update
    get "/seed-verifiers", UserController, :seed_verifiers
    post "/seed-verifiers/approve", UserController, :approve_seed_verifier
    get "/settings", SettingsController, :index
    get "/settings/gating", SettingsController, :gating
    patch "/settings", SettingsController, :update
    patch "/settings/gating", SettingsController, :update
    get "/invoices", InvoiceController, :index
    get "/reports", ReportController, :index
    get "/reports/:id", ReportController, :show
    patch "/reports/:id", ReportController, :update
    post "/emails/bulk-send", EmailController, :bulk_send
    get "/emails/preview-count", EmailController, :preview_count
    post "/notifications/broadcast", NotificationController, :broadcast
  end

  # ---------------------------------------------------------------------------
  # Public authentication handshake
  # ---------------------------------------------------------------------------
  scope "/api", MarrylocalWeb do
    pipe_through [:api_public, :rate_limit_registration]

    post "/v1/auth/register", RegistrationController, :create
    post "/users/register", RegistrationController, :create
  end

  scope "/api", MarrylocalWeb do
    pipe_through :api_public

    # Versioned native API. Tokens are opaque and database-backed; no JWT
    # signature is trusted on its own.
    post "/v1/auth/admin-register", AdminRegistrationController, :create
    post "/v1/auth/login", SessionController, :create
    get "/v1/auth/check-handle", SessionController, :check_handle
    post "/v1/auth/verify-email", EmailVerificationController, :create
    post "/v1/auth/resend-confirmation", EmailVerificationController, :resend
    delete "/v1/auth/logout", SessionController, :delete

    # Verified payment-provider webhook. Requires PAYMENT_WEBHOOK_SECRET.
    post "/v1/payments/webhook", PaymentController, :webhook
    post "/v1/payments/phonepe/callback", PaymentController, :phonepe_callback

    # Legacy aliases kept for the existing mobile client during cut-over.
    post "/users/login", SessionController, :create
    delete "/users/logout", SessionController, :delete

    post "/users/reset_password", ResetPasswordController, :create
    put "/users/reset_password/:token", ResetPasswordController, :update

    # Versioned password recovery routes used by the React client.
    post "/v1/auth/forgot-password", ResetPasswordController, :create
    post "/v1/auth/reset-password", ResetPasswordController, :update
    post "/v1/auth/reset-password/:token", ResetPasswordController, :update
    put "/v1/auth/reset-password/:token", ResetPasswordController, :update

    # Public onboarding autocomplete. No user data is exposed.
    get "/v1/locations/autocomplete", LocationsController, :autocomplete
  end

  # ---------------------------------------------------------------------------
  # Public readiness probe
  # ---------------------------------------------------------------------------
  scope "/api", MarrylocalWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # ---------------------------------------------------------------------------
  # Authenticated API
  # ---------------------------------------------------------------------------
  # Multipart uploads are rate limited per user before they reach the
  # controller's hashing and R2 storage paths.
  scope "/api", MarrylocalWeb do
    pipe_through [:api_authenticated, :rate_limit_uploads]

    post "/v1/profiles/me/avatar", ProfilesController, :upload_avatar
    post "/v1/verifications/submit", VerificationController, :create
  end

  # Discovery is authenticated and rate limited independently so search abuse
  # cannot exhaust the general API budget.
  scope "/api", MarrylocalWeb do
    pipe_through [:api_authenticated, :rate_limit_discovery]

    get "/v1/profiles/discovery", ProfilesController, :discovery
  end

  scope "/api", MarrylocalWeb do
    pipe_through :api_authenticated

    # Discovery and profiles
    get "/v1/profiles", ProfilesController, :index
    get "/v1/profiles/lookup", ProfilesController, :lookup
    get "/v1/profiles/me", ProfilesController, :me
    patch "/v1/profiles/me", ProfilesController, :update
    patch "/v1/profiles/me/location", ProfilesController, :update_location
    delete "/v1/profiles/me/avatar", ProfilesController, :delete_avatar
    delete "/v1/profiles/me/photos/:slot_index", ProfilesController, :delete_photo

    # Itemized invoice history
    get "/v1/billing/invoices", BillingController, :invoices

    # Identity verification lifecycle
    get "/v1/verifications/me", VerificationController, :show
    get "/v1/verifications/history", VerificationController, :history

    # Member safety reports
    post "/v1/reports", ReportController, :create

    # Peer-to-peer vouch verification
    post "/v1/vouch/generate-token", VouchController, :request_token
    post "/v1/vouch/verify-peer", VouchController, :verify_peer
    post "/v1/vouch/seed-opt-in", VouchController, :seed_opt_in
    post "/v1/vouch/seed-opt-out", VouchController, :seed_opt_out
    get "/v1/vouch/nearest-verifiers", VouchController, :nearest_verifiers

    get "/v1/profiles/:id", ProfilesController, :show
    post "/v1/profiles/me/shortlist/:target_id", ProfilesController, :shortlist

    # Polymorphic profile-discovery relationships
    get "/v1/relationships", RelationshipsController, :index
    get "/v1/relationships/shortlisted", RelationshipsController, :shortlisted
    get "/v1/relationships/liked-me", RelationshipsController, :liked_me
    get "/v1/relationships/blocked", RelationshipsController, :blocked
    get "/v1/relationships/muted", RelationshipsController, :muted
    get "/v1/relationships/moderated", RelationshipsController, :moderated
    post "/v1/relationships", RelationshipsController, :create
    delete "/v1/relationships/:kind/:target_id", RelationshipsController, :delete

    # Server-priced addon checkout
    post "/v1/payments/initialize-addon-checkout", PaymentController, :initialize_addon_checkout
    post "/v1/payments/initialize-checkout", PaymentController, :initialize_checkout

    # Authenticated password change (requires the current password)
    put "/v1/auth/password", SessionController, :update_password

    # PhonePe annual service fee checkout and transaction history
    post "/v1/payments/phonepe/order", PaymentController, :phonepe_order
    get "/v1/payments/status/:order_id", PaymentController, :status
    get "/v1/payments/transactions", PaymentController, :transactions

    # Real-time notification inbox
    get "/v1/notifications", NotificationsController, :index
    patch "/v1/notifications/:id/read", NotificationsController, :read
    post "/v1/notifications/mark-all-read", NotificationsController, :mark_all_read

    # Referral ledger and invite dashboard
    get "/v1/referrals/summary", ReferralsController, :summary

    # Native search (PostGIS radius + lifestyle filters)
    get "/search/users", SearchController, :index

    # Legacy shortlist contract, still backed by the relationships table via
    # UserController until the React discovery screen fully replaces it.
    post "/users/shortlist/:shortid", UserController, :add_to_shortlist
    delete "/users/shortlist/:shortid", UserController, :delete_shortlist
    get "/users/shortlist", UserController, :index_shortlist

    get "/users/find", UserController, :find_by_contact
    get "/users/city-stats", UserController, :city_count
    get "/users/stats/today", UserController, :today_count
    get "/users/stats/date/:date", UserController, :stats_by_date
    post "/users/referral/track", UserController, :add_referee

    delete "/me", UserController, :delete_self
    post "/me/deactivate", UserController, :deactivate
  end

  # ---------------------------------------------------------------------------
  # Browser shell (kept for the Phoenix-rendered admin/auth utilities)
  # ---------------------------------------------------------------------------
  scope "/", MarrylocalWeb do
    pipe_through :browser

    # Legacy browser paths remain addressable for redirects and verified-route
    # helpers. The React client owns the actual account UI.
    get "/", ErrorController, :not_found
    get "/users/register", ErrorController, :not_found
    get "/users/log-in", ErrorController, :not_found
    get "/users/log-in/:token", ErrorController, :not_found
  end

  # Unknown /api routes return JSON rather than falling through to HTML.
  scope "/api", MarrylocalWeb do
    pipe_through :api_public

    match :*, "/*path", ErrorController, :not_found
  end

  if Application.compile_env(:marrylocal, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
