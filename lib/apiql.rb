class APIQL
  module Rails
    class Engine < ::Rails::Engine
      initializer 'apiql.assets' do |app|
        app.config.assets.paths << root.join('assets', 'javascripts').to_s if app.config.respond_to? :assets
      end
    end
  end

  class ::Hash
    def deep_merge(second)
      merger = proc { |key, v1, v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : Array === v1 && Array === v2 ? v1 | v2 : [:undefined, nil, :nil].include?(v2) ? v1 : v2 }
      self.merge(second.to_h, &merger)
    end
  end

  class Error < StandardError; end
  class CacheMissed < StandardError; end

  attr_reader :context
  delegate :authorize!, to: :@context

  class << self
    def mount(klass, as: nil)
      as ||= klass.name.split('::').last.underscore
      as += '.' if as.present?

      klass.instance_methods(false).each do |method|
        klass.alias_method("#{as}#{method}", method)
        klass.remove_method(method) if as.present?
      end

      include klass
    end

    @@cache = {}

    def cache(params)
      request_id = params[:apiql]
      request = params[:apiql_request]

      if request.present?
        request = compile(request)
        ::Rails.cache.write("api-ql-cache-#{request_id}", JSON.generate(request), expires_in: 31*24*60*60)
        @@cache[request_id] = request
        @@cache = {} if(@@cache.count > 1000)
      else
        request = @@cache[request_id]
        request ||= JSON.parse(::Rails.cache.fetch("api-ql-cache-#{request_id}")) rescue nil
        raise CacheMissed unless request.present? && request.is_a?(::Array)
      end

      request
    end

    def cacheable(dependencies, attr, expires_in: 31*24*60*60)
      dependencies = dependencies.flatten.map { |obj| [obj.class.name, obj.id] }
      name = ['api-ql-cache', dependencies, attr].flatten.join('-')
      begin
        raise if expires_in <= 0
        JSON.parse(::Rails.cache.fetch(name))
      rescue
        (block_given? ? yield : nil).tap { |data| expires_in > 0 && ::Rails.cache.write(name, JSON.generate(data), expires_in: expires_in) }
      end
    end

    def drop_cache(obj)
      return unless ::Rails.cache.respond_to? :delete_if
      ::Rails.cache.delete_if { |k, v| k =~ /api-ql.*-#{obj.class.name}-#{obj.id}-.*/ }
    end

    def simple_class?(value)
      value.nil? ||
        value.is_a?(TrueClass) || value.is_a?(FalseClass) ||
        value.is_a?(Symbol) || value.is_a?(String) ||
        value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal) ||
        value.is_a?(Hash)
    end

    def eager_loads(schema)
      result = []

      schema&.each do |call|
        if call.is_a? Hash
          call.each do |function, sub_schema|
            next if function.include? '('
            function = function.split(':').last.strip if function.include? ':'
            function = function.split('.').first if function.include? '.'

            sub = eager_loads(sub_schema)
            if sub.present?
              result.push(function => sub)
            else
              result.push function
            end
          end
        end
      end

      result
    end

    private

    def compile(schema)
      result = []

      ptr = result
      pool = []

      push_key = lambda do |key, subtree = false|
        ptr.each_with_index do |e, index|
          if e.is_a?(::Hash)
            return e[key] if e[key]
          elsif e == key
            if subtree
              ptr[index] = { key => (p = []) }
              return p
            end
            return
          end
        end

        if subtree
          ptr.push(key => (p = []))
          return p
        else
          ptr.push(key)
        end
      end

      last_key = nil

      while schema.present? do
        if reg = schema.match(/\A\s*\{(?<rest>.*)\z/m) # {
          schema = reg[:rest]

          pool.push(ptr)

          ptr = push_key.call(last_key, true)
        elsif reg = schema.match(/\A\s*\}(?<rest>.*)\z/m) # }
          schema = reg[:rest]

          ptr = pool.pop
        elsif pool.any?
          if reg = schema.match(/\A\s*((?<alias>[\w\.]+):\s*)?(?<name>[\w\.\:\!\?]+)(\((?<params>.*?)\))?(?<rest>.*)\z/m)
            schema = reg[:rest]

            key = reg[:alias].present? ? "#{reg[:alias]}: #{reg[:name]}" : reg[:name]
            key += "(#{reg[:params]})" unless reg[:params].nil?

            push_key.call(key)

            last_key = key
          else
            raise Error, schema
          end
        elsif reg = schema.match(/\A\s*((?<alias>[\w\.]+):\s+)?(?<name>[\w\.\:\!\?]+)(\((?<params>((\w+)(\s*\,\s*\w+)*))?\))?\s*\{(?<rest>.*)\z/m)
          schema = reg[:rest]

          key = "#{reg[:alias] || reg[:name]}: #{reg[:name]}(#{reg[:params]})"

          pool.push(ptr)

          ptr = push_key.call(key, true)
        elsif reg = schema.match(/\A\s*((?<alias>[\w\.]+):\s+)?(?<name>[\w\.\:\!\?]+)(\((?<params>((\w+)(\s*\,\s*\w+)*))?\))?\s*\n?(?<rest>.*)\z/m)
          schema = reg[:rest]

          key = "#{reg[:alias] || reg[:name]}: #{reg[:name]}(#{reg[:params]})"

          push_key.call(key)
        else
          raise Error, schema
        end
      end

      result
    end
  end

  def initialize(binder, *fields)
    @context = ::APIQL::Context.new(binder, *fields)
    @context.inject_delegators(self)
  end

  def eager_load
    result = @eager_load

    @eager_load = []

    result
  end

  def render(schema)
    result = {}

    schema.each do |call|
      if call.is_a? ::Hash
        call.each do |function, sub_schema|
          reg = function.match(/\A((?<alias>[\w\.\:\!\?]+):\s+)?(?<name>[\w\.\:\!\?]+)(\((?<params>.*?)\))?\z/)
          raise Error, function unless reg.present?

          name = reg[:alias] || reg[:name]
          function = reg[:name]
          params = @context.parse_params(reg[:params].presence)

          @eager_load = APIQL::eager_loads(sub_schema)

          data = call_function(function, *params)

          if @eager_load.present? && !data.is_a?(::Hash) && !data.is_a?(::Array)
            if data.respond_to?(:includes)
              data = data.includes(eager_load)
            elsif data.respond_to?(:id)
              data = data.class.includes(eager_load).find(data.id)
            end
          end

          if result[name].is_a? ::Hash
            result = result.deep_merge({
              name => @context.render_value(data, sub_schema)
            })
          else
            result[name] = @context.render_value(data, sub_schema)
          end
        end
      else
        reg = call.match(/\A((?<alias>[\w\.\:\!\?]+):\s+)?(?<name>[\w\.\:\!\?]+)(\((?<params>.*?)\))?\z/)
        raise Error, call unless reg.present?

        name = reg[:alias] || reg[:name]
        function = reg[:name]
        params = @context.parse_params(reg[:params].presence)

        @eager_load = []

        data = call_function(function, *params)

        if data.is_a? Array
          if data.any? { |item| !APIQL::simple_class?(item) }
            data = nil
          end
        elsif !APIQL::simple_class?(data)
          data = nil
        end

        if result[name].is_a? ::Hash
          result = result.deep_merge({
            name => data
          })
        else
          result[name] = data
        end
      end
    end

    result
  end

  private

  def call_function(name, *params)
    if respond_to?(name) && (methods - Object.methods).include?(name.to_sym)
      public_send(name, *params)
    else
      o = nil

      names = name.split('.')
      names.each_with_index do |name, index|
        if o.nil?
          o = "#{name}::Entity".constantize
          o.instance_variable_set('@context', @context)
          o.instance_variable_set('@eager_load', @eager_load)
          @context.inject_delegators(self)
        elsif o.superclass == ::APIQL::Entity || o.superclass.superclass == ::APIQL::Entity
          if o.respond_to?(name) && (o.methods - Object.methods).include?(name.to_sym)
            o =
              if index == names.count - 1
                o.public_send(name, *params)
              else
                o.public_send(name)
              end
          else
            o = nil
            break
          end
        else
          objects = o
          o = "#{o.name}::Entity".constantize
          if o.respond_to?(name) && (o.methods - Object.methods).include?(name.to_sym)
            o.instance_variable_set("@objects", objects)
            o.instance_variable_set('@context', @context)
            o.instance_variable_set('@eager_load', @eager_load)
            @context.inject_delegators(self)
            o =
              if index == names.count - 1
                o.public_send(name, *params)
              else
                o.public_send(name)
              end
          else
            o = nil
            break
          end
        end
      end

      o
    end
  end

  class Entity
    delegate :authorize!, to: :@context

    class << self
      def all
        authorize! :read, @apiql_entity_class

        @apiql_entity_class.eager_load(eager_load).all
      end

      def find(id)
        item = @apiql_entity_class.eager_load(eager_load).find(id)

        authorize! :read, item

        item
      end

      def create(params)
        authorize! :create, @apiql_entity_class

        if respond_to?(:create_params, true)
          params = create_params(params)
        elsif respond_to?(:params, true)
          params = self.params(params)
        end

        @apiql_entity_class.create!(params)
      end

      def update(id, params)
        item = @apiql_entity_class.find(id)

        authorize! :update, item

        if respond_to?(:update_params, true)
          params = update_params(params)
        elsif respond_to?(:params, true)
          params = self.params(params)
        end

        item.update!(params)
      end

      def destroy(id)
        item = @apiql_entity_class.find(id)

        authorize! :destroy, item

        item.destroy!
      end

      private

      attr_reader :apiql_attributes, :objects
      delegate :authorize!, to: :@context # , private: true

      def inherited(child)
        super

        return if self.class == ::APIQL::Entity

        attributes = apiql_attributes&.try(:deep_dup) || []

        child.instance_eval do
          @apiql_attributes = attributes

          names = child.name.split('::')
          return unless names.last == 'Entity'
          @apiql_entity_class = names[0..-2].join('::').constantize
        end
      end

      def attributes(*attrs)
        @apiql_attributes ||= []
        @apiql_attributes += attrs.map(&:to_sym)
      end

      def eager_load
        result = @eager_load

        @eager_load = []

        result
      end
    end

    attr_reader :object

    def initialize(object, context)
      @object = object
      @context = context
      authorize! :read, object
      @context.inject_delegators(self)
    end

    def render(schema = nil)
      return unless @object.present?

      respond = {}

      schema.each do |field|
        if field.is_a? Hash
          field.each do |field, sub_schema|
            reg = field.match(/\A((?<alias>[\w\.\!\?]+):\s*)?(?<name>[\w\.\!\?]+)(\((?<params>.*?)\))?\z/)
            raise Error, field unless reg.present?

            name = reg[:alias] || reg[:name]

            if respond[name].is_a? ::Hash
              respond = respond.deep_merge({
                name => render_attribute(reg[:name], reg[:params].presence, sub_schema)
              })
            else
              respond[name] = render_attribute(reg[:name], reg[:params].presence, sub_schema)
            end
          end
        else
          reg = field.match(/\A((?<alias>[\w\.\!\?]+):\s*)?(?<name>[\w\.\!\?]+)(\((?<params>.*?)\))?\z/)
          raise Error, field unless reg.present?

          name = reg[:alias] || reg[:name]

          if respond[name].is_a? ::Hash
            respond = respond.deep_merge({
              name => render_attribute(reg[:name], reg[:params].presence)
            })
          else
            respond[name] = render_attribute(reg[:name], reg[:params].presence)
          end
        end
      end

      respond
    end

    private

    def get_field(field, params = nil)
      if params.present?
        params = @context.parse_params(params)
      end

      names = field.split('.')
      if names.count > 1
        o = nil
        names.each_with_index do |field, index|
          if o.nil?
            return unless field.to_sym.in? self.class.send(:apiql_attributes)

            if respond_to?(field)
              o = public_send(field)
            else
              o = object.public_send(field)
            end

            break if o.nil?
          else
            objects = o
            o = "#{o.name}::Entity".constantize
            o.instance_variable_set("@objects", objects)
            o.instance_variable_set('@context', @context)
            o.instance_variable_set('@eager_load', @eager_load)
            @context.inject_delegators(self)

            if o.respond_to?(field) && (o.methods - Object.methods).include?(field.to_sym)
              if index == names.count - 1
                o = o.public_send(field, *params)
              else
                o = o.public_send(field)
              end
            else
              o = nil
              break
            end
          end
        end

        o
      else
        return unless field.to_sym.in? self.class.send(:apiql_attributes)

        if respond_to?(field)
          public_send(field, *params)
        else
          object.public_send(field, *params)
        end
      end
    end

    def eager_load
      result = @eager_load

      @eager_load = nil

      result
    end

    def render_attribute(field, params = nil, schema = nil)
      @eager_load = APIQL::eager_loads(schema)
      data = get_field(field, params)

      if @eager_load.present? && !data.is_a?(::Hash) && !data.is_a?(::Array)
        if data.respond_to?(:each) && data.respond_to?(:map)
          unless data.loaded?
            data = data.eager_load(eager_load)
          end
        end
      end

      if data.is_a?(Hash) && schema.present?
        HashEntity.new(data, @context).render(schema)
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
    def authorize!(*args); end

    def get_field(field, params = nil)
      o = nil

      field.split('.').each do |name|
        if o.nil?
          o = object[name.to_sym] || object[name.to_s]
          break if o.nil?
        else
          if o.respond_to?(name)
            o = o.public_send(name)
          else
            o = nil
            break
          end
        end
      end

      o
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

    def authorize!(*args); end

    def inject_delegators(target)
      @fields.each do |field|
        next if target.respond_to?(field)
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
        begin
          "#{value.class.name}::Entity".constantize.new(value, self).render(schema)
        rescue StandardError
          raise
        end
      end
    end
  end
end
