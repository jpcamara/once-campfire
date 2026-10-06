module FormsHelper
  def auto_submit_form_with(**attributes, &)
    data = attributes.delete(:data) || {}
    data[:controller] = "auto-submit #{data[:controller]}".strip

    form_with **attributes, data: data, &
  end

  # Forgery protection checks Sec-Fetch-Site (SameOriginForgeryProtection), so forms carry no
  # authenticity token. This is the helper form_with and button_to add it with.
  def token_tag(token = nil, form_options: {})
    ""
  end
end
