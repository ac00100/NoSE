require_relative './model'
require_relative './parser'

module Sadvisor
  # A representation of a query workload over a given set of entities
  class Workload
    attr_reader :queries, :entities

    def initialize
      @queries = []
      @entities = {}
    end

    def <<(other)
      if other.is_a? Entity
        add_entity other
      elsif other.is_a? CQL::Statement
        add_query other
      else
        fail TypeError, 'can only add queries and entities to a workload'
      end
    end

    # Retrieve an entity by name
    def [](name)
      @entities[name]
    end

    def add_query(query)
      query = Parser.parse query if query.is_a? String

      @queries << query
    end

    # Add an {Entity} to the workload
    def add_entity(entity)
      @entities[entity.name] = entity
    end

    # Find a field given an +Enumerable+ of identifiers
    def find_field(field)
      if field.count > 2
        # Do a foreign key lookup
        field = field.dup
        key_field = @entities[field[0]].fields[field[1]]
        field[0..1] = key_field ? key_field.entity.name : field[1]
        find_field field
      else
        @entities[field[0]].fields[field[1]]
      end
    end

    def find_field_keys_each(field, keys = [])
      if field.count >= 2
        field = field.dup
        key_field = @entities[field[0]].fields[field[1]]
        keys << (key_field ? [key_field] : @entities[field[0]].id_fields)
        field[0..1] = key_field ? key_field.entity.name : field[1]
        keys += find_field_keys_each(field)
        keys
      else
        [@entities[field[0]].id_fields]
      end
    end

    # Find the keys traversed looking up a given field
    def find_field_keys(field)
      find_field_keys_each field[0..-2].reverse
    end

    # Check if all the fields used by queries in the workload exist
    def fields_exist?
      @queries.each do |query|
        entity = @entities[query.from.value]

        # Projected fields and fields in the where clause exist
        fields = query.where.map { |condition| condition.field } + query.fields
        fields.each do |field|
          parts = field.value
          return false unless @entities.key?(parts.first)
          return false if parts.length == 2 && \
            !entity.fields.key?(parts.last)
        end
      end
    end

    # Check if the queries are valid for the loaded entities
    def valid?
      @queries.each do |query|
        # Entity must exist
        return false unless @entities.key?(query.from.value)

        # No more than one range query
        return false if query.range_field

      end

      fields_exist?
    end
  end
end
