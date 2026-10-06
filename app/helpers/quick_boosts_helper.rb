module QuickBoostsHelper
  # The quick boost forms in messages/_actions, as the form_with loop rendered them, built without a
  # form builder per emoji: they were a quarter of rendering a message.
  QUICK_BOOSTS = EmojiHelper::REACTIONS.map do |character, title|
    character, title = ERB::Util.html_escape(character), ERB::Util.html_escape(title)
    %(\n            <input type="hidden" name="boost[content]" id="boost_content" value="#{character}" />) +
      %(\n            <button name="button" type="submit" title="#{title}" class="btn message__action-btn" data-emoji="#{character}">) +
      %(\n              <figure class="margin-none boost-character">#{character}</figure>) +
      %(\n              <span class="for-screen-reader">#{title}</span>\n</button></form>).freeze
  end.freeze

  def quick_boost_forms(message)
    form_tag = %(          <form data-turbo-frame="#{ERB::Util.html_escape(dom_id(message, :boosting))}" data-action="popup#close" action="#{ERB::Util.html_escape(message_boosts_path(message))}" accept-charset="UTF-8" method="post">)

    QUICK_BOOSTS.map do |form_body|
      form_tag + form_body
    end.join.html_safe
  end
end
