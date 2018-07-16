# APIQL

Implementation of the API language similar to GraphQL for Ruby on Rails

Define your responder (requested methods):

```ruby
class UserAPIQL < ::APIQL
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

```
In controller or Grape API endpoint, handler of POST /user method:

```ruby
def user
  schema = APIQL.cache(params)
  UserAPIQL.new(self, :session, :current_user, :params).render(schema)
end

```
variables `session`, `current_user` and `params` (you can list any you need) will be stored into context you can use in presenters and handlers

Define presenters for your models:

```ruby
class User < ApplicationRecord
  class Entity < ::APIQL::Entity
    attributes :full_name, :email, :token, :role, :roles # any attributes, methods or associations

    def token # if defined, method will be called instead of attribute
      object.token if object == current_user # directly access to current_user from context
    end
  end

  has_many :roles

  ...
end

```
# JS:

assets/javascripts/application.js:

```javascript
//= require apiql
APIQL.endpoint = "/"
```

```javascript
// function apiql(endpoint, schema, params = {}, form = null) -- schema is cached, so entire request is passed only for first time, later - short hashes only

authenticate(email, password) {
  apiql("user", `
    logout()

    authenticate(email, password) {
      token
    }

    me {
      email full_name role token

      roles {
        id title
      }
   }
  `, {
    email: email, // these var will be passed into methods on the server side
    password: password
  })
  .then(response => { // response contains results of called methods
    let user = response.me
  })
}

logout() {
  apiql("user", `
    logout
  `)
  .then(response => {
  })
}

```

you can call methods on entities:

```javascript
  apiql("user", `
    authenticate(email, password) {
      token
    }

    me.reload {
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
    let user = response['me.reload'] // name in response equals to called
  })
}
```

You can use initializer like this for authorization using cancancan gem:

config/initializers/apiql.rb:

```ruby
class APIQL
  delegate :authorize!, to: :@context

  class Entity
    delegate :authorize!, to: :@context
  end

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

and even authorize access to every entity:

```ruby
class ApplicationRecord < ActiveRecord::Base
  class BaseEntity < APIQL::Entity
    def initialize(object, context)
      context.authorize! :read, object
      super(object, context)
    end
  end
end

class User < ApplicationRecord
  class Entity < BaseEntity
    ...
  end
end

```
