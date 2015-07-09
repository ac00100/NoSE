module NoSE
  module Plans
    # Superclass for steps using indices
    class IndexLookupPlanStep < PlanStep
      attr_reader :index, :limit, :order_by

      def initialize(index, state = nil, parent = nil)
        super()
        @index = index

        if state && state.query
          all_fields = state.query.all_fields
          @fields = (@index.hash_fields + @index.order_fields).to_set + \
            (@index.extra.to_set & all_fields)
        else
          @fields = @index.all_fields
        end

        return if state.nil?
        @state = state.dup
        update_state parent
        @state.freeze
      end

      # :nocov:
      def to_color
        if @state.nil?
          "#{super} #{@index.to_color}"
        else
          "#{super} #{@index.to_color} * #{@state.cardinality} "
        end
      end
      # :nocov:

      # Two index steps are equal if they use the same index
      def ==(other)
        other.instance_of?(self.class) && @index == other.index
      end
      alias_method :eql?, :==

      def hash
        index.hash
      end

      # Check if this step can be applied for the given index,
      # returning a possible application of the step
      def self.apply(parent, index, state)
        # Check that this index is a valid jump in the path
        return nil unless state.path[0..index.path.length - 1] == index.path

        # We must move forward on paths at each lookup
        # XXX This disallows plans which look up additional attributes
        #     for entities other than the final one in the query path
        return nil if index.path.length == 1 && state.path.length > 1 &&
                      !parent.is_a?(RootPlanStep)
        return nil if index.identity? && state.path.length > 1

        parent_index = parent.parent_index
        unless parent_index.nil?
          # If the last step gave an ID, we must use it
          # XXX This doesn't cover all cases
          parent_ids = parent_index.path.entities.last.id_fields.to_set
          has_ids = parent_ids.all?(&parent_index.extra.method(:include?))
          return nil if has_ids && index.hash_fields.to_set != parent_ids

          # If we're looking up from a previous step, only allow lookup by ID
          return nil unless (index.path.length == 1 &&
                             parent_index.path != index.path) ||
                            index.hash_fields == parent_ids
        end

        # We need all hash fields to perform the lookup
        return nil unless index.hash_fields.all? do |field|
          (parent.fields + state.given_fields).include? field
        end

        # Get fields in the query relevant to this index
        path_fields = state.fields_for_entities(index.path.entities).to_set
        path_fields -= parent.fields  # exclude fields already fetched
        return nil unless path_fields.all?(&index.all_fields.method(:include?))
        return nil if !path_fields.empty? &&
                      path_fields.all?(&parent.fields.method(:include?))

        # Get the possible fields we need to select
        # This always includes the ID of the last and next entities
        # as well as the selected fields if we're at the end of the path
        last_choices = [index.path.entities.last.id_fields]
        next_key = state.path[index.path.length]
        last_choices << next_key.parent.id_fields unless next_key.nil?
        last_choices << state.fields if state.path == index.path

        has_last_fields = last_choices.any? do |fields|
          fields.all?(&index.all_fields.method(:include?))
        end

        return IndexLookupPlanStep.new(index, state, parent) if has_last_fields

        nil
      end

      private

      # Modify the state to reflect the fields looked up by the index
      def update_state(parent)
        # Get the set of fields which can be filtered by the ordered keys
        order_prefix = (@state.eq - @index.hash_fields) & @index.order_fields
        order_prefix << @state.range unless @state.range.nil?
        order_prefix = order_prefix.zip(@index.order_fields)
        order_prefix = order_prefix.take_while { |x, y| x == y }.map(&:first)

        # Find fields which are filtered by the index
        eq_filter = @state.eq & (@index.hash_fields + order_prefix).to_set
        if order_prefix.include?(@state.range)
          range_filter = @state.range
          @state.range = nil
        else
          range_filter = nil
        end

        # Remove fields resolved by this index
        @state.fields -= @index.all_fields
        @state.eq -= eq_filter

        # We can't resolve ordering if we're doing an ID lookup
        # since only one record exists per row (if it's the same entity)
        # We also need to have the fields used in order
        indexed_by_id = @index.hash_fields.include? @index.path.first
        order_prefix = @state.order_by.longest_common_prefix \
          @index.order_fields
        unless indexed_by_id && order_prefix.map(&:parent).to_set ==
                                Set.new([index.path.entities.first])
          @state.order_by -= order_prefix
        else
          order_prefix = []
        end
        @order_by = order_prefix

        # Strip the path for this index, but if we haven't fetched all
        # fields, leave the last one so we can perform a separate ID lookup
        if @state.fields_for_entities(@index.path.entities,
                                      select: true).empty? &&
           @state.path == index.path
          @state.path = @state.path[index.path.length..-1]
        else
          @state.path = @state.path[index.path.length - 1..-1]
        end

        # Check if we can apply the limit from the query
        if @state.answered?(check_limit: false) && !@state.query.limit.nil?
          @limit = @state.cardinality = @state.hash_cardinality = \
            @state.query.limit
        else
          @state.cardinality = @state.query.longest_entity_path.last.count \
            if parent.is_a? RootPlanStep
          @state.cardinality = Cardinality.new_cardinality @state.cardinality,
                                                           eq_filter,
                                                           range_filter,
                                                           @index.path.entities

          # Track the cardinality of hash fields by updating
          # using only the hash fields of the index
          @state.hash_cardinality = Cardinality.new_cardinality \
            @state.hash_cardinality, @state.eq & @index.hash_fields, nil,
            @index.path.entities
        end
      end
    end
  end
end
