class MessagesController < ApplicationController
  guard_feature unless: -> { Current.user.ai_enabled? }

  before_action :set_chat

  def create
    files = params.dig(:message, :documents) || params[:documents]
    typed = message_params[:content].presence
    typed ||= t("messages.chat_form.default_document_prompt") if Array(files).reject(&:blank?).any?

    @message = UserMessage.new(
      chat: @chat,
      content: typed,
      ai_model: message_params[:ai_model].presence || Chat.default_model
    )

    if save_with_documents(@message)
      redirect_to chat_path(@chat, thinking: true)
    else
      redirect_to chat_path(@chat), alert: @message.errors.full_messages.to_sentence
    end
  rescue ActiveRecord::InvalidForeignKey
    redirect_to chats_path, alert: t(".chat_not_found")
  end

  # Called by the chat watchdog when an assistant "Thinking…" bubble has waited
  # too long for a response that never arrived. Idempotent and scoped to the
  # current user's chat.
  def report_timeout
    message = @chat.messages.find(params[:id])

    if @chat.handle_undelivered_response!(message)
      head :ok
    else
      # Declined — the message has not waited past the server's own floor yet,
      # which usually means the client's clock runs ahead of ours and it reported
      # early. This must not be a 2xx: the watchdog only stops retrying a URL once
      # it sees one, so answering OK here would strand the bubble spinning forever.
      head :conflict
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    # The message and its documents are one unit: validate the files first, then commit
    # both together, so the assistant job never runs against a half-attached message.
    def save_with_documents(message)
      files = params.dig(:message, :documents) || params[:documents]
      saved = false

      Message.transaction do
        saved = message.save
        raise ActiveRecord::Rollback unless saved

        ChatDocument.attach_all!(chat: @chat, message: message, files: files)
      end
      saved
    rescue ChatDocument::InvalidUpload => e
      message.errors.add(:base, t("messages.chat_form.upload_errors.#{e.code}", default: t("messages.chat_form.upload_errors.generic")))
      false
    end

    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    end

    def message_params
      params.require(:message).permit(:content, :ai_model)
    end
end
