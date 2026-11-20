require_relative "units"

module Pitstop
  # What changed between two versions of one Ruby file, unit by unit:
  #
  #   :changed   a unit's tokens differ           → tests that ran its old lines
  #   :removed   a unit is gone                   → tests that ran its old lines
  #   :added     a new unit (may override one)    → every test that ran the file
  #   :skeleton  code outside the units changed   → every test that ran the file
  #   :unparsable  the new file doesn't parse     → every test that ran the file
  #
  # Old line numbers are what matter: the map was recorded against the old version.
  class UnitDiff
    Change = Struct.new(:kind, :key, :old_lines, :single_line, keyword_init: true)

    def self.compare(old_source, new_source) = new(old_source, new_source).changes

    def initialize(old_source, new_source)
      @old = Units.parse(old_source)
      @new = Units.parse(new_source)
    end

    def changes
      return [Change.new(kind: :unparsable, key: @new.error)] if @new.error
      return [Change.new(kind: :unparsable, key: @old.error)] if @old.error

      changes = []
      @old.units.each do |unit|
        now = @new[unit.key]
        next if now && now.tokens == unit.tokens

        changes << Change.new(kind: now ? :changed : :removed, key: unit.key, old_lines: unit.lines,
                              single_line: unit.single_line?)
      end
      (@new.keys - @old.keys).each { changes << Change.new(kind: :added, key: _1) }
      changes << Change.new(kind: :skeleton) if skeleton_changed?
      changes
    end

    private

    # Placeholders for units that were added or removed don't count as a skeleton change by
    # themselves; those show up as :added/:removed.
    def skeleton_changed?
      shared = @old.keys & @new.keys
      mark = Units::PLACEHOLDER
      strip = ->(tokens) { tokens.reject { |t| t.start_with?(mark) && !shared.include?(t.delete_prefix(mark)) } }
      strip.(@old.skeleton) != strip.(@new.skeleton)
    end
  end
end
