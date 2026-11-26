require "prism"

module Pitstop
  # Splits a Ruby file into the pieces Pitstop compares one by one:
  #
  #   class Cart
  #     MAX = 3                          ┐ the file's "skeleton": everything outside a unit
  #     scope :recent, -> { order(:id) } ── unit "Cart scope(:recent)"  (a block in a class body)
  #     def total                        ┐
  #       items.sum                      ├ unit "Cart#total"
  #     end                              ┘
  #     def self.build = new             ── unit "Cart.build"
  #   end
  #
  # Each unit and the skeleton get a fingerprint made of their tokens, without comments or
  # whitespace, so a comment-only edit changes nothing.
  class Units
    # `blind`: line coverage can't say which tests called this unit (see #blind?).
    Unit = Struct.new(:key, :first_line, :last_line, :start_offset, :end_offset, :tokens, :blind) do
      def lines = first_line..last_line
    end

    # Calls whose block is more class body, not a unit of its own.
    CONTAINERS = %i[included prepended class_methods concerning class_eval module_eval instance_eval
                    extended inherited new define].freeze
    SINGLETON_CONTAINERS = %i[class_methods].freeze
    PLACEHOLDER = "\u0000" # marks "a unit goes here" in the skeleton; no real token starts with it
    SKIP_TOKENS = %i[COMMENT EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END NEWLINE IGNORED_NEWLINE EOF __END__].freeze

    attr_reader :units, :skeleton, :error

    def self.parse(source) = new(source)

    def initialize(source)
      @source = source
      @units = []
      result = Prism.parse(source)
      if result.failure?
        @error = result.errors.first&.message || "syntax error"
        @skeleton = nil
        return
      end

      walk(result.value, [], false)
      number_duplicates
      @skeleton = build_skeleton
    end

    def [](key) = @units.find { _1.key == key }

    # No code at all (only comments or nothing): loading such a file runs no line.
    def empty? = @error.nil? && @units.empty? && @skeleton.empty?

    def keys = @units.map(&:key)

    private

    def walk(node, scope, singleton, label = nil)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        walk(node.body, scope + [node.constant_path.slice], false) if node.body
      when Prism::SingletonClassNode
        if node.expression.is_a?(Prism::SelfNode)
          walk(node.body, scope, true) if node.body
        else
          add_unit("#{name(scope)} class << #{node.expression.slice}", node)
        end
      when Prism::DefNode
        separator = node.receiver || singleton ? "." : "#"
        add_unit("#{name(scope)}#{separator}#{node.name}", node)
      when Prism::CallNode
        walk_call(node, scope, singleton)
      when Prism::BlockNode, Prism::LambdaNode
        add_unit("#{name(scope)} #{label || 'block'}", node)
      else
        node&.compact_child_nodes&.each { walk(_1, scope, singleton, label) }
      end
    end

    def walk_call(node, scope, singleton)
      label = call_label(node)
      walk(node.receiver, scope, singleton, label) if node.receiver
      node.arguments&.arguments&.each { walk(_1, scope, singleton, "#{label} ->") }
      block = node.block
      if block.is_a?(Prism::BlockNode)
        if CONTAINERS.include?(node.name)
          walk(block.body, scope, singleton || SINGLETON_CONTAINERS.include?(node.name)) if block.body
        else
          add_unit("#{name(scope)} #{label}", block)
        end
      elsif block
        walk(block, scope, singleton, label)
      end
    end

    # "scope(:recent)", "before_action", "validate(:stock_left)": the call plus its first argument.
    def call_label(node)
      first = node.arguments&.arguments&.first
      arg = first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode) ? first.slice : nil
      arg ? "#{node.name}(#{arg})" : node.name.to_s
    end

    def name(scope) = scope.empty? ? "(main)" : scope.join("::")

    def add_unit(key, node)
      stop = end_offset(node)
      @units << Unit.new(key, node.location.start_line, line_at(stop), node.location.start_offset, stop, [], blind?(node))
    end

    # A call shows up in the coverage as the unit's own lines being run. That needs the unit to
    # have code on a line after the one that opens it: the opening line also runs when the file
    # loads (`def max = 3`, `scope :recent, -> { order(:id) }`), and an empty body runs nothing
    # (`def show; end`, a Rails action that only renders). Anything that isn't a method or a
    # block (`class << obj`) is code that runs on loading, not something that gets called.
    def blind?(node)
      return true unless node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

      first = first_statement(node.body)
      first.nil? || first.location.start_line <= node.location.start_line
    end

    def first_statement(body)
      case body
      when Prism::StatementsNode then body.body.first
      when Prism::BeginNode then first_statement(body.statements)
      else body
      end
    end

    # Where a node really ends: a heredoc's text sits after the line that opens it, past the
    # node's own location.
    def end_offset(node)
      ends = [node.location.end_offset]
      stack = [node]
      while (n = stack.pop)
        ends << n.closing_loc.end_offset if n.respond_to?(:closing_loc) && n.closing_loc
        stack.concat(n.compact_child_nodes)
      end
      ends.max
    end

    def line_at(offset) = @source.byteslice(0, offset).count("\n") + 1

    def number_duplicates
      seen = Hash.new(0)
      @units.each do |unit|
        seen[unit.key] += 1
        unit.key = "#{unit.key} (#{seen[unit.key]})" if seen[unit.key] > 1
      end
    end

    # The file's tokens with each unit's tokens swapped for a placeholder naming the unit. Units are
    # never nested (the walk stops at a unit), so one pass in offset order is enough.
    def build_skeleton
      tokens = Prism.lex(@source).value.map(&:first).reject { SKIP_TOKENS.include?(_1.type) }
      units = @units.sort_by(&:start_offset)
      skeleton = []
      i = 0
      tokens.each do |token|
        offset = token.location.start_offset
        i += 1 while units[i] && offset >= units[i].end_offset
        unit = units[i]
        if unit && offset >= unit.start_offset
          skeleton << "#{PLACEHOLDER}#{unit.key}" if unit.tokens.empty?
          unit.tokens << token.value
        else
          skeleton << token.value
        end
      end
      skeleton
    end
  end
end
