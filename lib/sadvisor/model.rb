require 'binding_of_caller'

module Sadvisor
  # A representation of an object in the conceptual data model
  class Entity
    attr_reader :fields, :name
    attr_accessor :count

    def initialize(name, &block)
      @name = name
      @fields = {}
      @count = 1

      # Precompute the hash
      hash

      # Apply the DSL
      EntityDSL.new(self).instance_eval(&block) if block_given?
    end

    def state
      @name
    end

    # :nocov:
    def to_color
      @name.light_blue + ' [' + fields.keys.map(&:to_color).join(', ') + ']'
    end
    # :nocov:

    # Compare by name, fields, and count
    # @return [Boolean]
    def ==(other)
      self.hash == other.hash
    end
    alias_method :eql?, :==

    # The hash is based on the name of the entity and its fields
    # @return [Fixnum]
    def hash
      @hash ||= [@name, @fields].hash
    end

    # Get the key fields for the entity
    # @return [Array<Field>]
    def id_fields
      fields.values.select { |field| field.instance_of? IDField }
    end

    # Find the foreign key to a particular entity
    # @return [Field, nil]
    def foreign_key_for(entity)
      fields.values.find do |field|
        field.kind_of?(ForeignKey) && field.entity == entity
      end
    end

    # Adds a {Field} to the entity
    def <<(field)
      @fields[field.name] = field
      field.instance_variable_set(:@parent, self)
      self
    end

    # Shortcut for {#count=}
    # @return [Entity]
    def *(other)
      if other.is_a? Integer
        @count = other
      else
        fail TypeError 'count must be an integer'
      end

      self
    end

    # Get the field on the entity with the given name
    # @return [Field]
    def [](field)
      @fields[field]
    end

    # All the keys found when traversing foreign keys
    # @return [KeyPath]
    def key_fields(path)
      KeyPath.new path, self
    end
  end

  # A helper class for DSL creation to avoid messing with {Entity}
  class EntityDSL
    def initialize(entity)
      @entity = entity
    end
  end

  # A single field on an {Entity}
  class Field
    attr_reader :name, :type, :size, :parent

    def initialize(name, type, size)
      @name = name
      @type = type
      @size = size
      @cardinality = nil
    end

    def state
      @parent.name + '.' + @name
    end

    # Compare by parent entity and name
    def ==(other)
      other.kind_of?(Field) && @type == other.type &&
        @parent == other.parent && @name == other.name
    end
    alias_method :eql?, :==

    # Hash by entity and name
    # @return [Fixnum]
    def hash
      @hash ||= [@parent.name, @name].hash
    end

    # :nocov:
    def to_color
      parent.name.light_blue + '.' + name.blue
    end
    # :nocov:

    # Set the estimated cardinality of the field
    # @return [Field]
    def *(other)
      if other.is_a? Integer
        @cardinality = other
      else
        fail TypeError 'cardinality must be an integer'
      end

      self
    end

    # Return the previously set cardinality, falling back to the number of
    # entities for the field if set, or just 1
    def cardinality
      @cardinality || @parent.count || 1
    end

    # Populate a helper DSL object with all subclasses of Field
    def self.inherited(child_class)
      # Add convenience methods for all field types for an entity DSL
      method_name = child_class.name.sub(/^Sadvisor::(.*?)(Field)?$/, '\1')
      EntityDSL.send :define_method, method_name,
                     (proc do |*args|
                       send(:instance_variable_get, :@entity).send \
                           :<<, child_class.new(*args)
                     end)
    end
    private_class_method :inherited
  end

  # Field holding an integer
  class IntegerField < Field
    def initialize(name)
      super(name, :integer, 8)
    end
  end

  # Field holding a float
  class FloatField < Field
    def initialize(name)
      super(name, :float, 8)
    end
  end

  # Field holding a string of some average length
  class StringField < Field
    def initialize(name, length = 10)
      super(name, :string, length)
    end
  end

  # Field holding a date
  class DateField < Field
    def initialize(name)
      super(name, :date, 8)
    end
  end

  # Field holding a unique identifier
  class IDField < Field
    def initialize(name)
      super(name, :key, 16)
    end
  end

  # Field holding a foreign key to another entity
  class ForeignKey < IDField
    attr_reader :entity, :relationship

    def initialize(name, entity)
      super(name)
      @relationship = :one

      # XXX: This is a hack which allows us to look up the stack to find an
      #      enclosing workload and the entity being referenced by the key
      if entity.is_a? String
        workload = binding.callers.each do |binding|
          obj = binding.eval 'self'
          break obj if obj.class == Workload
        end
        entity = workload[entity] unless workload.nil?
      end
      @entity = entity
    end

    # The number of entities associated with the foreign key,
    # or a manually set cardinality
    def cardinality
      @entity.count || super
    end
  end

  # Alias of {ForeignKey}
  ToOneKey = ForeignKey

  # Field holding a foreign key to many other entities
  class ToManyKey < ForeignKey
    def initialize(name, entity)
      super(name, entity)
      @relationship = :many
    end
  end

  # All the keys found when traversing foreign keys
  class KeyPath
    include Enumerable

    # Most of the work is delegated to the array
    extend Forwardable
    def_delegators :@key_fields, :each, :<<, :[], :==, :===, :eql?,
                   :inspect, :to_s, :to_a, :to_ary, :last

    def initialize(path, entity)
      @key_fields = fields_for_path path, entity
    end

    # Get the keys along a given path of entities
    # @return [Array<Field>]
    def fields_for_path(path, entity)
      path = path[1..-1] if path[0] == entity.name

      key_field = entity.fields[path[0]]
      if key_field.instance_of? IDField
        [key_field]
      elsif key_field.is_a? ForeignKey
        [key_field] + key_field.entity.key_fields(path[1..-1])
      else
        entity.id_fields
      end
    end

    # Get the common prefix of two paths
    # return [Array<Field>]
    def &(other)
      fail TypeError unless other.is_a? KeyPath
      each_with_index do |field, i|
        return self[0..i] if field != other[i]
      end
    end
  end
end
