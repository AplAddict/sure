class UserMessage < Message
  validates :ai_model, presence: true

  after_create_commit :request_response_later

  def role
    "user"
  end

  # What the model sees: the typed text plus any attached documents, each wrapped as
  # untrusted data. The stored/displayed content stays exactly what the user typed.
  def llm_content
    blocks = chat_documents.order(:created_at).map(&:prompt_block)
    return content if blocks.empty?

    [ content, *blocks ].join("\n\n")
  end

  def request_response_later
    chat.ask_assistant_later(self)
  end

  def request_response(assistant_message: nil)
    chat.ask_assistant(self, assistant_message: assistant_message)
  end
end
