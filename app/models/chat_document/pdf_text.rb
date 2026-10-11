# Text extraction for uploaded PDFs. Runs poppler's pdftotext directly (no shell), with a
# page cap, an output cap and a hard timeout; returns nil on any problem.
class ChatDocument
  class PdfText
    TIMEOUT_SECONDS = 20
    MAX_OUTPUT_BYTES = 2.megabytes
    MAX_PAGES = 60

    def self.call(content)
      Tempfile.create([ "chat-doc", ".pdf" ], binmode: true) do |file|
        file.write(content)
        file.flush
        run(file.path)
      end
    rescue StandardError
      nil
    end

    def self.run(path)
      reader, writer = IO.pipe
      pid = Process.spawn("pdftotext", "-layout", "-enc", "UTF-8", "-l", MAX_PAGES.to_s, path, "-",
                          out: writer, err: File::NULL, in: File::NULL)
      writer.close
      thread = Thread.new { reader.read(MAX_OUTPUT_BYTES + 1) }

      unless thread.join(TIMEOUT_SECONDS)
        Process.kill("KILL", pid)
        Process.wait(pid)
        thread.kill
        return nil
      end

      Process.wait(pid)
      text = thread.value.to_s.force_encoding("UTF-8").scrub("").delete("\u0000").strip
      text.presence
    ensure
      reader&.close unless reader&.closed?
    end
    private_class_method :run
  end
end
