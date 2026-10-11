class CreateChatDocuments < ActiveRecord::Migration[8.0]
  # Additive only: documents attached to a single user's chat message. Extracted text lives
  # here, scoped to the chat owner, and is removed with the chat.
  def change
    create_table :chat_documents, id: :uuid do |t|
      t.references :chat, null: false, foreign_key: true, type: :uuid
      t.references :message, null: false, foreign_key: true, type: :uuid, index: { unique: false }
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.string :content_sha256, null: false
      t.text :extracted_text
      t.boolean :truncated, null: false, default: false
      t.string :status, null: false, default: "extracted"
      t.string :error_code
      t.uuid :account_statement_id
      t.timestamps
    end
  end
end
