defmodule MarrylocalWeb.UserJSON do
  def data(user) do

    ref_count = Enum.count(user.referee_emails || [])
    # Logic: 500 base - (50 * count), capped at 8 referrals
    discount = min(ref_count, 8) * 50
    current_fee = 500 - discount

    %{
      id: user.id, # Internal DB ID
      shortid: user.shortid,
      first_name: user.first_name,
      age: user.age,
      images: user.images,
      is_mutual: user.is_mutual, # Boolean for React UI
      last_login_at: user.time_of_login,
      onetime_fees_required: !user.onetime_fees_paid,
      base_fee: 500,
      current_discount: discount,
      payable_amount: current_fee,
      referral_count: ref_count,
      # ... other public fields ...
      phone: if(user.show_phone, do: user.phone_number, else: nil)
    }
end

end
