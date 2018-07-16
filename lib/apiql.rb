class APIQL
  module Rails
    class Engine < ::Rails::Engine
      initializer 'apiql.assets' do |app|
        app.config.assets.paths << root.join('assets', 'javascripts').to_s
      end
    end
  end

  class Error < StandardError; end
  class CacheMissed < StandardError; end

  attr_reader :context

  class << self
    @@cache = {}

    def cache(params)
      request_id = params[:apiql]
      request = params[:apiql_request]

      if request.present?
        redis&.set("api-ql-cache-#{request_id}", request)
        @@cache[request_id] = request
      else
        request = @@cache[request_id]
        request ||= redis&.get("api-ql-cache-#{request_id}")
        raise CacheMissed unless request.present?
      end

      request
    end

    def simple_class?(value)
      value.nil? ||
        value.is_a?(TrueClass) || value.is_a?(FalseClass) ||
        value.is_a?(Symbol) || value.is_a?(String) ||
        value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal) ||
        value.is_a?(Hash)
    end

    private

    def redis
      @redis ||=
        begin
          ::Redis.new(host: 'localhost')
        rescue
          nil
        end
    end
  end

  def initialize(binder, *fields)
    @context = ::APIQL::Context.new(binder, *fields)
    @context.inject_delegators(self)
  end

  def render(schema)
    result = {}

    function = nil
    data = nil

    pool = nil
    keys = nil
    last_key = nil

    while schema.present? do
      if reg = schema.match(/\A\s*\{(?<rest>.*)\z/m) # {
        schema = reg[:rest]

        pool.push [keys, last_key]
        keys = []
      elsif reg = schema.match(/\A\s*\}(?<rest>.*)\z/m) # }
        schema = reg[:rest]

        last_keys = keys

        keys, last_key = pool.pop

        if pool.empty?
          result[function] = @context.render_value(data, last_keys)
          function = nil
        else
          keys.delete(last_key)
          keys << { last_key => last_keys }
        end
      elsif function.present? && (reg = schema.match(/\A\s*(?<name>[\w\.]+)(\((?<params>.*)\))?(?<rest>.*)\z/m))
        schema = reg[:rest]

        if reg[:params].present?
          keys << [reg[:name], reg[:params]]
        else
          keys << reg[:name]
        end

        last_key = reg[:name]
      elsif reg = schema.match(/\A\s*(?<name>[\w\.]+)(\((?<params>((\w+)(\s*\,\s*\w+)*))?\))?\s*\{(?<rest>.*)\z/m)
        schema = reg[:rest]

        function = reg[:name]
        params = @context.parse_params(reg[:params])

        data = public_send(function, *params)

        pool = []
        requested = {}

        last_key = nil

        pool.push [keys, last_key]
        keys = []
      elsif reg = schema.match(/\A\s*(?<name>[\w\.]+)(\((?<params>((\w+)(\s*\,\s*\w+)*))?\))?\s*\n?(?<rest>.*)\z/m)
        schema = reg[:rest]

        function = reg[:name]
        params = @context.parse_params(reg[:params])

        data = public_send(function, *params)
        if data.is_a? Array
          if data.any? { |item| !APIQL::simple_class?(item) }
            data = nil
          end
        elsif !APIQL::simple_class?(data)
          data = nil
        end

        result[function] = data

        function = nil
      else
        raise Error
      end
    end

    result
  end

  class Entity
    class << self
      attr_reader :apiql_attributes

      def inherited(child)
        super

        return if self.class == ::APIQL::Entity

        attributes = apiql_attributes&.try(:deep_dup) || []

        child.instance_eval do
          @apiql_attributes = attributes
        end
      end

      def attributes(*attrs)
        @apiql_attributes ||= []
        @apiql_attributes += attrs.map(&:to_sym)
      end
    end

    attr_reader :object

    def initialize(object, context)
      @object = object
      @context = context
      @context.inject_delegators(self)
    end

    def render(schema = nil)
      return unless @object.present?

      respond = {}

      schema.each do |field|
        if field.is_a? Hash
          field.each do |field, sub_schema|
            name = field.is_a?(Array) ? field.first : field
            respond[name] = render_attribute(field, sub_schema)
          end
        else
          name = field.is_a?(Array) ? field.first : field
          respond[name] = render_attribute(field)
        end
      end

      respond
    end

    private

    def get_field(field)
      if field.is_a? Array
        field, params = field
        params = @context.parse_params(params)
      end

      names = field.split('.')
      if names.count > 1
        o = nil

        names.each do |field|
          if o.present?
            if o.respond_to? field
              o = o.public_send(field, *params)
            else
              o = nil
              break
            end
          else
            return unless field.to_sym.in? self.class.apiql_attributes

            if respond_to? field
              o = public_send(field, *params)
            else
              o = object.public_send(field, *params)
            end

            break unless o.present?
          end
        end

        o
      else
        return unless field.to_sym.in? self.class.apiql_attributes

        if respond_to? field
          public_send(field, *params)
        else
          object.public_send(field, *params)
        end
      end
    end

    def render_attribute(field, schema = nil)
      data = get_field(field)

      if data.is_a?(Hash) && schema.present?
        respond = {}

        schema.each do |field|
          if field.is_a? Hash
            field.each do |field, sub_schema|
              respond[field] = render_value(data[field.to_sym], sub_schema)
            end
          else
            respond[field] = render_value(data[field.to_sym])
          end
        end

        respond
      else
        render_value(data, schema)
      end
    end

    def render_value(value, schema = nil)
      if schema.present?
        @context.render_value(value, schema)
      else
        value
      end
    end
  end

  class HashEntity < Entity
    def get_field(field)
      object[field.to_sym]
    end
  end

  class Context
    def initialize(binder, *fields)
      @fields = fields
      fields.each do |field|
        instance_variable_set("@#{field}", binder.send(field))
        class_eval do
          attr_accessor field
        end
      end
    end

    def inject_delegators(target)
      @fields.each do |field|
        target.class_eval do
          delegate field, to: :@context
        end
      end
    end

    def parse_params(list)
      list&.split(',')&.map(&:strip)&.map do |name|
        if reg = name.match(/\A[a-zA-Z_]\w*\z/)
          params[name]
        else
          begin
            Float(name)
          rescue
            name
          end
        end
      end
    end

    def render_value(value, schema)
      if value.is_a? Hash
        HashEntity.new(value, self).render(schema)
      elsif value.respond_to?(:each) && value.respond_to?(:map)
        value.map do |object|
          render_value(object, schema)
        end
      elsif APIQL::simple_class?(value)
        value
      else
        "#{value.class.name}::Entity".constantize.new(value, self).render(schema)
      end
    end
  end
end
