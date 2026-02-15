defmodule MarrylocalWeb.Router do
  use MarrylocalWeb, :router

  import MarrylocalWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {MarrylocalWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MarrylocalWeb do
    pipe_through :api
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug MarrylocalWeb.ApiAuth, :fetch_api_user
  end

  pipeline :admin_required do
    plug MarrylocalWeb.ApiAuth, :fetch_api_user             # 1. Check if logged in
    plug MarrylocalWeb.Plugs.RequireAdmin # 2. Check if role is :admin
  end

  scope "/api/admin", MarrylocalWeb do
    pipe_through [:api, :admin_required]

    get "/stats", AdminController, :dashboard_stats
    get "/archive", AdminController, :archived_users

    post "/ban/:id", AdminController, :ban
  end

  scope "/api", MarrylocalWeb do
    pipe_through :api_auth

    # Protected MarryLocal routes
    get "/matches", MatchController, :index
    post "/matches", MatchController, :create
  end

  scope "/api", MarrylocalWeb do
    pipe_through :api

    post "/users/reset_password", UserResetPasswordController, :create
    put "/users/reset_password/:token", UserResetPasswordController, :update

    # This must be the LAST route in the scope
    match :*, "/*path", ErrorController, :not_found

    #DELETE /api/me
    delete "/me", UserController, :delete_self
    post "/me/deactivate", UserController, :deactivate
  end

  # lib/marrylocal_web/router.ex
  pipeline :api_authenticated do
    plug MarrylocalWeb.ApiAuth, :fetch_api_user
    plug MarrylocalWeb.Plugs.TrackUserActivity # New tracking plug
  end

  #GET /api/search/users?religion=Hindu&community=Brahmin&lat=12.97&lng=77.59&dist=50
  #GET /api/search/users?age_from=22&age_to=28&online_only=true
  scope "/api", MarrylocalWeb do
    pipe_through [:api, :api_authenticated]
    get "/search/users", UserSearchController, :index
    # All routes here now update 'time_of_login' automatically

    get "/users/find", UserController, :find_by_contact

    get "/users/city-stats", UserController, :city_count

    get "/users/stats/today", UserController, :today_count
    get "/users/stats/date/:date", UserController, :stats_by_date

    post "/users/referral/track", UserController, :add_referee
  end


  scope "/api", MarrylocalWeb do
    pipe_through [:api, :api_authenticated]

    # POST because we are modifying data
    post "/users/shortlist/:shortid", UserController, :add_to_shortlist

    # DELETE is the semantic choice for removing an item
    delete "/users/shortlist/:shortid", UserController, :delete_shortlist

    get "/users/shortlist", UserController, :index_shortlist
  end

  ## Authentication routes

  scope "/", MarrylocalWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", MarrylocalWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", MarrylocalWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
