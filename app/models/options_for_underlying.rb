# Narrows an approved OptionsDesk result to one underlying (and, on a holding drawer, one account) for display.
# Filtering only: every figure, total and exclusion is the read model's own and nothing is recalculated here.
class OptionsForUnderlying
  attr_reader :desk, :ticker, :now

  def initialize(desk:, ticker:, now:, account_id: nil)
    @desk = desk
    @ticker = ticker.to_s.strip.upcase
    @account_id = account_id
    @now = now
  end

  def invalid_scope?
    desk.invalid_account_scope
  end

  def source_state
    desk.source_state
  end

  def rows
    @rows ||= desk.rows.select { |row| row.underlying == ticker && in_scope?(row) }
  end

  def rows?
    rows.any?
  end

  def group
    desk.groups[ticker] if rows?
  end

  # What stands in for the ledger when this underlying has no rows. An unreadable or stale source must never read as
  # "no open contracts"; only a source that is readable and current may say that.
  def placeholder
    return :invalid_scope if invalid_scope?
    return nil if rows?

    %i[available empty].include?(source_state) ? :empty : source_state
  end

  def covered_call_ideas
    scoped(desk.ideas.covered_calls.ideas)
  end

  def covered_call_exclusions
    scoped(desk.ideas.covered_calls.exclusions)
  end

  def put_exclusions
    scoped(desk.ideas.puts.exclusions)
  end

  def ideas?
    !invalid_scope? && (covered_call_ideas.any? || covered_call_exclusions.any? || put_exclusions.any?)
  end

  def joint_exposure_note
    desk.ideas.covered_calls.joint_exposure_note
  end

  # The ticker page stays quiet for symbols the user neither holds nor has option rows for.
  def visible?(held:)
    rows? || held
  end

  private
    def in_scope?(entry)
      @account_id.blank? || entry.account_id.to_s == @account_id.to_s
    end

    def scoped(entries)
      return [] if invalid_scope?

      entries.select { |entry| entry.underlying == ticker && in_scope?(entry) }
    end
end
