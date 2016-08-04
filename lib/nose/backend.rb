module NoSE
  # Communication with backends for index creation and statement execution
  module Backend
    # Superclass of all database backends
    class BackendBase
      def initialize(model, indexes, plans, update_plans, _config)
        @model = model
        @indexes = indexes
        @plans = plans
        @update_plans = update_plans
      end

      # @abstract Subclasses implement to check if an index is empty
      # @return [Boolean]
      def index_empty?(_index)
        true
      end

      # @abstract Subclasses implement to check if an index already exists
      # @return [Boolean]
      def index_exists?(_index)
        false
      end

      # @abstract Subclasses implement to remove existing indexes
      # @return [void]
      def drop_index
      end

      # @abstract Subclasses implement to allow inserting
      #           data into the backend database
      # :nocov:
      # @return [void]
      def index_insert_chunk(_index, _chunk)
        fail NotImplementedError
      end
      # :nocov:

      # @abstract Subclasses implement to generate a new random ID
      # :nocov:
      # @return [Object]
      def generate_id
        fail NotImplementedError
      end
      # :nocov:

      # @abstract Subclasses should create indexes
      # :nocov:
      # @return [Enumerable]
      def indexes_ddl(_execute = false, _skip_existing = false,
                      _drop_existing = false)
        fail NotImplementedError
      end
      # :nocov:

      # @abstract Subclasses should return sample values from the index
      # :nocov:
      # @return [Array<Hash>]
      def indexes_sample(_index, _count)
        fail NotImplementedError
      end
      # :nocov:

      # Prepare a query to be executed with the given plans
      # @return [PreparedQuery]
      def prepare_query(query, fields, conditions, plans = [])
        plan = plans.empty? ? find_query_plans(query) : plans.first

        state = Plans::QueryState.new(query, @model) unless query.nil?
        first_step = Plans::RootPlanStep.new state
        steps = [first_step] + plan.to_a + [nil]
        PreparedQuery.new query, prepare_query_steps(steps, fields, conditions)
      end

      # Prepare a statement to be executed with the given plans
      def prepare(statement, plans = [])
        if statement.is_a? Query
          prepare_query statement, statement.all_fields,
                        statement.conditions, plans
        elsif statement.is_a? Delete
          prepare_update statement, [], plans
        else
          prepare_update statement, statement.settings, plans
        end
      end

      # Execute a query with the stored plans
      # @return [Array<Hash>]
      def query(query, plans = [])
        prepared = prepare query, plans
        prepared.execute query.conditions
      end

      # Prepare an update for execution
      # @return [PreparedUpdate]
      def prepare_update(update, update_settings, plans)
        # Search for plans if they were not given
        plans = find_update_plans(update) if plans.empty?
        fail PlanNotFound if plans.empty?

        # Prepare each plan
        plans.map do |plan|
          delete = false
          insert = false
          plan.update_steps.each do |step|
            delete = true if step.is_a?(Plans::DeletePlanStep)
            insert = true if step.is_a?(Plans::InsertPlanStep)
          end

          steps = []
          add_delete_step(plan, steps) if delete
          add_insert_step(plan, steps, update_settings) if insert

          PreparedUpdate.new update, prepare_support_plans(plan), steps
        end
      end

      # Execute an update with the stored plans
      # @return [void]
      def update(update, plans = [])
        prepared = prepare_update update, update.settings, plans
        prepared.each { |p| p.execute update.settings, update.conditions }
      end

      # Superclass for all statement execution steps
      class StatementStep
        include Supertype
        attr_reader :index
      end

      # Look up data on an index in the backend
      class IndexLookupStatementStep < StatementStep
        def initialize(client, _select, _conditions,
                       step, next_step, prev_step)
          @client = client
          @step = step
          @index = step.index
          @prev_step = prev_step
          @next_step = next_step

          @eq_fields = step.eq_filter
          @range_field = step.range_filter
        end

        protected

        # Get lookup values from the query for the first step
        def initial_results(conditions)
          [Hash[conditions.map do |field_id, condition|
            fail if condition.value.nil?
            [field_id, condition.value]
          end]]
        end

        # Construct a list of conditions from the results
        def result_conditions(conditions, results)
          results.map do |result|
            result_condition = @eq_fields.map do |field|
              Condition.new field, :'=', result[field.id]
            end

            unless @range_field.nil?
              operator = conditions.values.find(&:range?).operator
              result_condition << Condition.new(@range_field, operator,
                                                result[@range_field.id])
            end

            result_condition
          end
        end

        # Decide which fields should be selected
        def expand_selected_fields(select)
          # We just pick whatever is contained in the index that is either
          # mentioned in the query or required for the next lookup
          # TODO: Potentially try query.all_fields for those not required
          #       It should be sufficient to check what is needed for future
          #       filtering and sorting and use only those + query.select
          select += @next_step.index.hash_fields \
            unless @next_step.nil? ||
              !@next_step.is_a?(Plans::IndexLookupPlanStep)
          select &= @step.index.all_fields

          select
        end
      end

      # Insert data into an index on the backend
      class InsertStatementStep < StatementStep
        def initialize(client, index, fields)
          @client = client
          @index = index
        end
      end

      # Delete data from an index on the backend
      class DeleteStatementStep < StatementStep
        def initialize(client, index)
          @client = client
          @index = index
        end
      end

      # Perform filtering external to the backend
      class FilterStatementStep < StatementStep
        def initialize(_client, _fields, _conditions,
                       step, _next_step, _prev_step)
          @step = step
        end

        # Filter results by a list of fields given in the step
        # @return [Array<Hash>]
        def process(conditions, results)
          # Extract the equality conditions
          eq_conditions = conditions.values.select do |condition|
            !condition.range? && @step.eq.include?(condition.field)
          end

          # XXX: This assumes that the range filter step is the same as
          #      the one in the query, which is always true for now
          range = @step.range && conditions.values.find(&:range?)

          results.select! { |row| include_row?(row, eq_conditions, range) }

          results
        end

        private

        # Check if the row should be included in the result
        # @return [Boolean]
        def include_row?(row, eq_conditions, range)
          select = eq_conditions.all? do |condition|
            row[condition.field.id] == condition.value
          end

          if range
            range_check = row[range.field.id].method(range.operator)
            select &&= range_check.call range.value
          end

          select
        end
      end

      # Perform sorting external to the backend
      class SortStatementStep < StatementStep
        def initialize(_client, _fields, _conditions,
                       step, _next_step, _prev_step)
          @step = step
        end

        # Sort results by a list of fields given in the step
        # @return [Array<Hash>]
        def process(_conditions, results)
          results.sort_by! do |row|
            @step.sort_fields.map do |field|
              row[field.id]
            end
          end
        end
      end

      # Perform a client-side limit of the result set size
      class LimitStatementStep < StatementStep
        def initialize(_client, _fields, _conditions,
                       step, _next_step, _prev_step)
          @limit = step.limit
        end

        # Remove results past the limit
        # @return [Array<Hash>]
        def process(_conditions, results)
          results[0..@limit - 1]
        end
      end

      private

      # Find plans for a given query
      # @return [Array<Plans::QueryPlan>]
      def find_query_plans(query)
        plan = @plans.find do |possible_plan|
          possible_plan.query == query
        end unless query.nil?
        fail PlanNotFound if plan.nil?
      end

      # Prepare all the steps for executing a given query
      # @return [Array<StatementStep>]
      def prepare_query_steps(steps, fields, conditions)
        steps.each_cons(3).map do |prev_step, step, next_step|
          step_class = StatementStep.subtype_class step.subtype_name

          # Check if the subclass has overridden this step
          subclass_step_name = step_class.name.sub \
            'NoSE::Backend::BackendBase', self.class.name
          step_class = Object.const_get subclass_step_name
          step_class.new client, fields, conditions,
                         step, next_step, prev_step
        end
      end

      # Find plans for a given update
      # @return [Array<Plans::UpdatePlan>]
      def find_update_plans(update)
        @update_plans.select do |possible_plan|
          possible_plan.statement == update
        end
      end

      # Add a delete step to a prepared update plan
      # @return [void]
      def add_delete_step(plan, steps)
        step_class = DeleteStatementStep
        subclass_step_name = step_class.name.sub \
          'NoSE::Backend::BackendBase', self.class.name
        step_class = Object.const_get subclass_step_name
        steps << step_class.new(client, plan.index)
      end

      # Add an insert step to a prepared update plan
      # @return [void]
      def add_insert_step(plan, steps, update_settings)
        step_class = InsertStatementStep
        subclass_step_name = step_class.name.sub \
          'NoSE::Backend::BackendBase', self.class.name
        step_class = Object.const_get subclass_step_name
        steps << step_class.new(client, plan.index,
                                update_settings.map(&:field))
      end

      # Prepare plans for each support query
      # @return [Array<PreparedQuery>]
      def prepare_support_plans(plan)
        plan.query_plans.map do |query_plan|
          query = query_plan.instance_variable_get(:@query)
          prepare_query query, query_plan.select_fields, query_plan.params,
                        [query_plan.steps]
        end
      end
    end

    # A prepared query which can be executed against the backend
    class PreparedQuery
      attr_reader :query, :steps

      def initialize(query, steps)
        @query = query
        @steps = steps
      end

      # Execute the query for the given set of conditions
      # @return [Array<Hash>]
      def execute(conditions)
        results = nil

        @steps.each do |step|
          if step.is_a?(BackendBase::IndexLookupStatementStep)
            field_ids = step.index.all_fields.map(&:id)
            conditions = conditions.select { |key| field_ids.include? key }
          end
          results = step.process conditions, results

          # The query can't return any results at this point, so we're done
          break if results.empty?
        end

        # Only return fields selected by the query
        select_ids = @query.select.map(&:id).to_set
        results.map { |row| row.select! { |k, _| select_ids.include? k } }

        results
      end
    end

    # An update prepared with a backend which is ready to execute
    class PreparedUpdate
      attr_reader :statement, :steps

      def initialize(statement, support_plans, steps)
        @statement = statement
        @support_plans = support_plans
        @delete_step = steps.find do |step|
          step.is_a? BackendBase::DeleteStatementStep
        end
        @insert_step = steps.find do |step|
          step.is_a? BackendBase::InsertStatementStep
        end
      end

      # Execute the statement for the given set of conditions
      # @return [void]
      def execute(update_settings, update_conditions)
        # Execute all the support queries
        settings = initial_update_settings update_settings, update_conditions

        # Execute the support queries for this update
        support = support_results update_conditions

        # Perform the deletion
        @delete_step.process support unless support.empty? || @delete_step.nil?
        return if @insert_step.nil?

        if support.empty?
          support = [settings]
        else
          support.each do |row|
            row.merge!(settings) { |_, value, _| value }
          end
        end

        # Stop if we have nothing to insert, otherwise insert
        return if support.empty?
        @insert_step.process support
      end

      private

      # Get the initial values which will be used in the first plan step
      # @return [Hash]
      def initial_update_settings(update_settings, update_conditions)
        if !@insert_step.nil? && @delete_step.nil?
          # Populate the data to insert for Insert statements
          settings = Hash[update_settings.map do |setting|
            [setting.field.id, setting.value]
          end]
        else
          # Get values for updates and deletes
          settings = Hash[update_conditions.map do |field_id, condition|
            [field_id, condition.value]
          end]
        end

        settings
      end

      # Execute all the support queries
      # @return [Array<Hash>]
      def support_results(settings)
        # Get a hash of values used in settings
        setting_values = Hash[settings.map { |k, v| [k, v.value] }]

        if @support_plans.empty?
          support = @support_plans.map do |plan|
            plan.execute settings
          end

          # Combine the results from multiple support queries
          unless support.empty?
            support = support.first.product(*support[1..-1])
            support.map! do |results|
              results.reduce(&:merge!).merge!(setting_values)
            end
          end
        else
          # Execute the first support query to get a list of IDs
          first_query = @support_plans.first.query
          id = first_query.entity.id_field
          select_key = first_query.select.include? id
          ids = @support_plans.first.execute settings
          conditions = ids.map do |row|
            { id.id => Condition.new(id, :'=', row[id.id]) }
          end

          # Execute the support queries for each ID
          support = conditions.map do |condition|
            results = @support_plans[(select_key ? 1 : 0)..-1].map do |plan|
              plan.execute condition
            end

            # Combine the results of the different support queries
            results[0].product(*results[1..-1]).map do |result|
              row = result.reduce(&:merge!)
              row[id.id] = condition.values.first.value
              row.merge!(setting_values)

              row
            end
          end
        end

        support
      end
    end

    # Raised when a statement is executed that we have no plan for
    class PlanNotFound < StandardError
    end

    # Raised when a backend attempts to create an index that already exists
    class IndexAlreadyExists < StandardError
    end
  end
end
