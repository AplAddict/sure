class ChatsController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :set_chat, only: [ :show, :edit, :update, :destroy ]

  def index
    @chat = nil # override application_controller default behavior of setting @chat to last viewed chat
    @chats = Current.user.chats.order(created_at: :desc)
  end

  def show
    set_last_viewed_chat(@chat)
  end

  def new
    @chat = Current.user.chats.new(
      title: t(".default_title", timestamp: Time.current.strftime("%Y-%m-%d %H:%M"))
    )
  end

  def create
    files = params.dig(:chat, :documents) || params[:documents]
    content = chat_params[:content].presence
    content ||= t("messages.chat_form.default_document_prompt") if Array(files).reject(&:blank?).any?

    # The first message and its documents commit together, so the assistant job never runs
    # against a half-attached message.
    Chat.transaction do
      @chat = Current.user.chats.start!(content.to_s, model: chat_params[:ai_model])
      ChatDocument.attach_all!(chat: @chat, message: @chat.messages.find_by!(type: "UserMessage"), files: files)
    end

    set_last_viewed_chat(@chat)
    redirect_to chat_path(@chat, thinking: true)
  rescue ChatDocument::InvalidUpload => e
    redirect_back_or_to chats_path,
      alert: t("messages.chat_form.upload_errors.#{e.code}", default: t("messages.chat_form.upload_errors.generic"))
  end

  def edit
  end

  def update
    @chat.update!(chat_params)

    respond_to do |format|
      format.html { redirect_back_or_to chat_path(@chat), notice: t(".success") }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(dom_id(@chat, :title), partial: "chats/chat_title", locals: { chat: @chat }) }
    end
  end

  def destroy
    @chat.destroy
    clear_last_viewed_chat

    redirect_to chats_path, notice: t(".notice")
  end

  def retry
    @chat.retry_last_message!
    redirect_to chat_path(@chat)
  end

  private
    def set_chat
      @chat = Current.user.chats.find(params[:id])
    end

    def set_last_viewed_chat(chat)
      Current.user.update!(last_viewed_chat: chat)
    end

    def clear_last_viewed_chat
      Current.user.update!(last_viewed_chat: nil)
    end

    def chat_params
      params.require(:chat).permit(:title, :content, :ai_model)
    end
end
