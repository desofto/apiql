# APIQL

Implementation of the API language similar to GraphQL for Ruby on Rails.

It compiles requests into Hashes for faster rendering.

It automatically detects nested entities and eager-loads them for faster DB access!

In controller or Grape API endpoint, handler of POST /apiql method (or any other, see below APIQL.endpoint):

```ruby
def apiql
  schema = APIQL.cache(params)
  APIQL.new(self, :session, :current_user, :params).render(schema)
end

```
variables `session`, `current_user` and `params` (you can list any you need in your presenters/responders) will be stored into context you can use in presenters and handlers

Define presenters for your models:

```ruby
class User < ApplicationRecord
  after_commit { APIQL.drop_cache(self) }

  class Entity < ::APIQL::Entity
    attributes :full_name, :email, :token, :role, :roles # any attributes, methods or associations

    def token # if defined, method will be called instead of attribute
      object.token if object == current_user # directly access to current_user from context
    end

    def roles
      APIQL.cacheable([object, roles], :roles, expires_in: 3600) do
        roles.pluck(:name).join(', ')
      end
    end

    class << self
      def me
        authorize! :show, ::User

        current_user
      end

      def authenticate(email, password)
        user = ::User.find_by(email)
        user.authenticate(password)

        user
      end

      def logout
        current_user&.logout

        :ok
      end
    end
  end

  has_many :roles

  ...
end

class Role < ApplicationRecord
  after_commit { APIQL.drop_cache(self) }

  class Entity < ::APIQL::Entity
    attributes :id, :name
  end
end

```
# JS:

assets/javascripts/application.js:

```javascript
//= require apiql
APIQL.endpoint = "/apiql"
```

```javascript
// function apiql(schema, params = {}, form = null) -- schema is cached, so entire request is passed only for first time, later - short hashes only

authenticate(email, password) {
  apiql(`
    User.logout()

    User.authenticate(email, password) {
      token
    }

    User.me {
      email full_name role token

      roles {
        id title
      }
   }
  `, {
    email: email, // these vars will be passed into methods on the server side
    password: password
  })
  .then(response => { // response contains results of called methods
    let user = response.me
  })
}

logout() {
  apiql(`
    User.logout
  `)
  .then(response => {
  })
}

```

you can call methods on entities:

```javascript
  apiql(`
    User.authenticate(email, password) {
      token
    }

    user: User.me.reload {
      email full_name role token

      roles(filter) {
        id title
      }

      contacts.primary {
        full_name
        email
      }
   }
  `, {
    email: email,
    filter: 'all',
    password: password
  })
  .then(response => {
    let user = response.user
  })
}
```

You can use initializer like this for authorization using cancancan gem:

config/initializers/apiql.rb:

```ruby
class APIQL
  class Context
    def authorize!(*args)
      ability.authorize!(*args)
    end

    private

    def ability
      @ability ||= ::Ability::Factory.build_ability_for(current_user)
    end
  end
end
```

CRUD methods available for all models:

```js
  apiql(`
    User.create(user)
  `, {
    user: {
      email: this.email,
      full_name: this.full_name
    }
  })
  .then(response => {
    ...
  })

  apiql(`
    User.find(id) {
      id email full_name
    }
  `, {
    id: this.id
  })
  .then(response => {
    ...
  })

  apiql(`
    User.all {
      id email full_name
    }
  `)
  .then(response => {
    ...
  })

  apiql(`
    User.update(id, user)
  `, {
    id: this.id,
    user: {
      email: this.email,
      full_name: this.full_name
    }
  })
  .then(response => {
    ...
  })

  apiql(`
    User.destroy(id)
  `, {
    id: this.id
  })
  .then(response => {
    ...
  })
```

or mount methods from external modules:

```ruby
class APIQL < ::APIQL
  mount ::Services::User # all methouds could be called with "user" prefix like "user.logout()"
  mount ::Services::Common, as: '' # all methods could be called without prefixes
  mount ::Services::Employer, as: 'dashboard" # all methods could be called with specified prefix
end
```
