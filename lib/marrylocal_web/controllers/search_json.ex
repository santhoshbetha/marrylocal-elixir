# lib/marrylocal_web/controllers/search_json.ex
defmodule MarrylocalWeb.SearchJSON do
  def index(%{users: users}) do
    %{data: Enum.map(users, &data/1)}
  end

  # New function to handle paginated responses
  def index_paginated(%{page: page}) do
    %{
      data: Enum.map(page.entries, &data/1),
      pagination: %{
        current_page: page.page_number,
        total_pages: page.total_pages,
        total_entries: page.total_entries,
        page_size: page.page_size,
        has_next: page.page_number < page.total_pages,
        has_prev: page.page_number > 1
      }
    }
  end

  def data(user) do
    %{
      id: user.id,
      shortid: user.shortid,
      first_name: user.first_name,
      age: user.age,
      # Green dot indicator from the live Phoenix Presence registry.
      is_online: MarrylocalWeb.Presence.online?(user.id),
      religion: user.religion,
      community: user.community,
      economic_status: user.economic_status,
      job_status: user.job_status,
      city: user.city,
      images: user.images,
      # Support virtual field
      is_mutual: Map.get(user, :is_mutual, false),
      # Persisted authentication metrics
      last_login_at: user.last_login_at || user.time_of_login,
      last_seen_at: user.last_seen_at,
      # You could also add distance if you select it in the query
      is_active: user.user_state == :active
    }
  end
end

# Pro-Tip: If you find that updating the database on every single API request is too slow, you can use Redis to track "Online" status and only sync
# it to PostgreSQL every few minutes.
