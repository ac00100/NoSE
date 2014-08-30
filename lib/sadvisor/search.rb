require 'gurobi'
require 'ostruct'
require 'tempfile'

module Sadvisor
  # Searches for the optimal indices for a given workload
  class Search
    def initialize(workload)
      @workload = workload
    end

    # Search for optimal indices using an ILP which searches for
    # non-overlapping indices
    # @return [Array<Index>]
    def search_overlap(max_space = Float::INFINITY)
      # Construct the simple indices for all entities and
      # remove this from the total size
      simple_indexes = @workload.entities.values.map(&:simple_index)
      simple_size = simple_indexes.map(&:size).inject(0, &:+)
      max_space -= simple_size
      return [] if max_space <= 0

      # Generate all possible combinations of indices
      indexes = IndexEnumerator.new(@workload).indexes_for_workload.to_a
      index_sizes = indexes.map(&:size)
      return [] if indexes.empty?

      # Get the cost of all queries with the simple indices
      simple_planner = Planner.new @workload, simple_indexes
      simple_costs = {}
      @workload.queries.each do |query|
        simple_costs[query] = simple_planner.min_plan(query).cost
      end

      benefits = benefits indexes.map { |index| simple_indexes + [index] },
                          simple_costs

      query_overlap = overlap indexes, benefits

      # Solve the LP using Gurobi
      solve_gurobi indexes,
                   max_space: max_space,
                   index_sizes: index_sizes,
                   query_overlap: query_overlap,
                   benefits: benefits
    end

    private

    # Add all necessary constraints to the Gurobi model
    def gurobi_add_constraints(model, index_vars, query_vars, indexes, data)
      # Add constraint for indices being present
      (0...indexes.length).each do |i|
        (0...@workload.queries.length).each do |q|
          model.addConstr(query_vars[i][q] + index_vars[i] * -1 <= 0)
        end
      end

      # Add space constraint if needed
      if data[:max_space].finite?
        space = indexes.each_with_index.map do |index, i|
          index_vars[i] * (index.size * 1.0)
        end.reduce(&:+)
        model.addConstr(space <= data[:max_space] * 1.0)
      end

      # Add overlapping index constraints
      data[:query_overlap].each do |q, overlaps|
        overlaps.each do |i, overlap|
          overlap.each do |j|
            model.addConstr(query_vars[i][q] + query_vars[j][q] <= 1)
          end
        end
      end
    end

    # Set the objective function on the Gurobi model
    def gurobi_set_objective(model, query_vars, data)
      max_benefit = (0...query_vars.length).to_a \
        .product((0...@workload.queries.length).to_a).map do |i, q|
        next if data[:benefits][q][i] == 0
        query_vars[i][q] * (data[:benefits][q][i] * 1.0)
      end.compact.reduce(&:+)

      model.setObjective(max_benefit, Gurobi::MAXIMIZE)
    end

    # Solve the index selection problem using Gurobi
    def solve_gurobi(indexes, data)
      model = Gurobi::Model.new(Gurobi::Env.new)
      model.getEnv.set_int(Gurobi::IntParam::OUTPUT_FLAG, 0)

      # Initialize query and index variables
      index_vars = []
      query_vars = []
      (0...indexes.length).each do |i|
        index_vars[i] = model.addVar(0, 1, 0, Gurobi::BINARY, "i#{i}")
        query_vars[i] = []
        (0...@workload.queries.length).each do |q|
          query_vars[i][q] = model.addVar(0, 1, 0, Gurobi::BINARY, "q#{q}i#{i}")

        end
      end

      # Add all constraints to the model
      model.update
      gurobi_add_constraints model, index_vars, query_vars, indexes, data

      # Set the objective function
      gurobi_set_objective model, query_vars, data

      # Run the optimizer
      model.update
      model.optimize

      # Return the selected indices
      indexes.select.with_index do |_, i|
        index_vars[i].get_double(Gurobi::DoubleAttr::X) == 1.0
      end
    end

    # Determine which indices overlap each other for queries in the workload
    def overlap(indexes, benefits)
      query_overlap = {}

      Parallel.each_with_index(@workload.queries) do |query, i|
        entities = query.longest_entity_path
        query_indices = benefits[i].each_with_index.map do |benefit, j|
          if benefit > 0
            [j, indexes[j].entity_range(entities)]
          end
        end.compact

        query_indices.each_with_index do |(overlap1, range1), j|
          query_indices[j + 1..-1].each do |(overlap2, range2)|
            unless (range1.to_a & range2.to_a).empty?
              query_overlap[i] = {} unless query_overlap.key?(i)
              if query_overlap[i].key? overlap1
                query_overlap[i][overlap1] << overlap2
              else
                query_overlap[i][overlap1] = [overlap2]
              end
            end
          end
        end
      end

      query_overlap
    end

    # Get the reduction in cost from using each configuration of indices
    def benefits(combos, simple_costs)
      @workload.queries.map do |query|
        entities = query.longest_entity_path

        Parallel.map(combos) do |combo|
          # Skip indices which don't cross the query path
          range = combo.last.entity_range entities
          next 0 if range == (nil..nil)

          combo_planner = Planner.new @workload, combo
          begin
            [0, simple_costs[query] - combo_planner.min_plan(query).cost].max
          rescue NoPlanException
            0
          end
        end
      end
    end
  end
end
