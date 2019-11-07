class APIQL
  module Rails
    class Engine < ::Rails::Engine
      initializer 'apiql.assets' do |app|
        app.config.assets.paths << root.join('assets', 'javascripts').to_s
      end
    end
  end

  class ::Hash
    def deep_merge(second)
      merger = proc { |key, v1, v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : Array === v1 && Array === v2 ? v1 | v2 : [:undefined, nil, :nil].include?(v2) ? v1 : v2 }
      self.merge(second.to_h, &merger)
    end
  end

  module CRUD
    def model(klass)
      define_method "#{klass.name.pluralize.underscore}" do |page = nil, page_size = 10|
        authorize! :read, klass

        if page.present?
          {
            total: klass.count,
            items: klass.eager_load(eager_load).offset(page * page_size).limit(page_size)
          }
        else
          klass.eager_load(eager_load).all
        end
      end

      define_method "#{klass.name.underscore}" do |id|
        item = klass.eager_load(eager_load).find(id)

        authorize! :read, item

        item
      end

      define_method "#{klass.name.underscore}.create" do |params|
        authorize! :create, klass

        klass_entity = "#{klass.name}::Entity".constantize

        if klass_entity.respond_to?(:create_params, params)
          params = klass_entity.send(:create_params, params)
        elsif klass_entity.respond_to?(:params, params)
          params = klass_entity.send(:params, params)
        end

        klass.create!(params)
      end

      define_method "#{klass.name.underscore}.update" do |id, params|
        item = klass.find(id)

        authorize! :update, item

        klass_entity = "#{klass.name}::Entity".constantize

        if klass_entity.respond_to?(:update_params, params)
          params = klass_entity.send(:update_params, params)
        elsif klass_entity.respond_to?(:params, params)
          params = klass_entity.send(:params, params)
        end

        item.update!(params)
      end

      define_method "#{klass.name.underscore}.destroy" do |id|
        item = klass.find(id)

        authorize! :destroy, item

        item.destroy!
      end
    end
  end

  class Error < StandardError; end
  class CacheMissed < StandardError; end

  attr_reader :context
  delegate :authorize!, to: :@context

  class << self
    include ::APIQL::CRUD

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
        redis&.set("api-ql-cache-#{request_id}", request.to_json)
        @@cache[request_id] = request
        @@cache = {} if(@@cache.count > 1000)
      else
        request = @@cache[request_id]
        request ||= JSON.parse(redis.get("api-ql-cache-#{request_id}")) rescue nil
        raise CacheMissed unless request.present? && request.is_a?(::Array)
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

    def redis
      @redis ||=
        begin
          ::Redis.new(host: 'localhost')
        rescue
          nil
        end
    end

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
          if reg = schema.match(/\A\s*((?<alias>[\w\.]+):\s*)?(?<name>[\w\.]+)(\((?<params>.*?)\))?(?<rest>.*)\z/m)
            schema = reg[:rest]

            key = reg[:alias].present? ? "#{reg[:alias]}: #{reg[:name]}" : reg[:name]
            key += "(#{reg[:params]})" unless reg[:params].nil?

            push_key.call(key)

            last_key = key
          else
            raise Error, schema
          end
        elsif reg = schema.match(/\A\s*((?<alias>[\w\.]+):\s*)?(?<name>[\w\.]+)(\((?<params>((\w+)(\s*\,\s*\w+)*))?\))?\s*\{(?<rest>.*)\z/m)
          schema = reg[:rest]

          key = "#{reg[:alias] || reg[:name]}: #{reg[:name]}(#{reg[:params]})"

          pool.push(ptr)

          ptr = push_key.call(key, true)
        elsif reg = schema.match(/\A\s*((?<alias>[\w\.]+):\s*)?(?<name>[\w\.]+)(\((?<params>((\w+)(\s*\,\s*\w+)*))?\))?\s*\n?(?<rest>.*)\z/m)
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
          reg = function.match(/\A((?<alias>[\w\.\!]+):\s*)?(?<name>[\w\.\!]+)(\((?<params>.*?)\))?\z/)
          raise Error, function unless reg.present?

          name = reg[:alias] || reg[:name]
          function = reg[:name]
          params = @context.parse_params(reg[:params].presence)

          @eager_load = APIQL::eager_loads(sub_schema)
          data = public_send(function, *params)
          if @eager_load.present? && !data.is_a?(::Hash) && !data.is_a?(::Array)
            if data.respond_to?(:eager_load)
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
        reg = call.match(/\A((?<alias>[\w\.\!]+):\s*)?(?<name>[\w\.\!]+)(\((?<params>.*?)\))?\z/)
        raise Error, call unless reg.present?

        name = reg[:alias] || reg[:name]
        function = reg[:name]
        params = @context.parse_params(reg[:params].presence)

        @eager_load = []
        data = public_send(function, *params)
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

  class Entity
    delegate :authorize!, to: :@context

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
      authorize! :read, object
      @context.inject_delegators(self)
    end

    def render(schema = nil)
      return unless @object.present?

      respond = {}

      schema.each do |field|
        if field.is_a? Hash
          field.each do |field, sub_schema|
            reg = field.match(/\A((?<alias>[\w\.\!]+):\s*)?(?<name>[\w\.\!]+)(\((?<params>.*?)\))?\z/)
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
          reg = field.match(/\A((?<alias>[\w\.\!]+):\s*)?(?<name>[\w\.\!]+)(\((?<params>.*?)\))?\z/)
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
        names.each do |field|
          if o.nil?
            return unless field.to_sym.in? self.class.apiql_attributes

            if respond_to? field
              o = public_send(field, *params)
            else
              o = object.public_send(field, *params)
            end

            break if o.nil?
          else
            if o.respond_to? field
              o = o.public_send(field, *params)
            else
              o = nil
              break
            end
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
          o = object[name.to_sym]
          break if o.nil?
        else
          if o.respond_to? name
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
          if ::Rails.env.development?
            raise
          else
            nil
          end
        end
      end
    end
  end
end
