# APIQL

Implementation of the API language similar to GraphQL for Ruby on Rails.

It compiles requests into Hashes for faster rendering.

It automatically detects nested entities and eager-loads them for faster DB access!

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
In controller or Grape API endpoint, handler of POST /apiql method (or any other, see below APIQL.endpoint):

```ruby
def apiql
  schema = APIQL.cache(params)
  UserAPIQL.new(self, :session, :current_user, :params).render(schema)
end

```
variables `session`, `current_user` and `params` (you can list any you need in your presenters/responders) will be stored into context you can use in presenters and handlers

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
APIQL.endpoint = "/apiql"
```

```javascript
// function apiql(schema, params = {}, form = null) -- schema is cached, so entire request is passed only for first time, later - short hashes only

authenticate(email, password) {
  apiql(`
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
    email: email, // these vars will be passed into methods on the server side
    password: password
  })
  .then(response => { // response contains results of called methods
    let user = response.me
  })
}

logout() {
  apiql(`
    logout
  `)
  .then(response => {
  })
}

```

you can call methods on entities:

```javascript
  apiql(`
    authenticate(email, password) {
      token
    }

    user: me.reload {
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

you can add CRUD methods for your models:

```ruby
class UserAPIQL < ::APIQL
  model ::User
  model ::Role
end
```

or mount methods from external modules:

```ruby
class UserAPIQL < ::APIQL
  mount ::Services::User # all methouds could be called with "user" prefix like "user.logout()"
  mount ::Services::Common, as: '' # all methods could be called without prefixes
  mount ::Services::Employer, as: 'dashboard" # all methods could be called with specified prefix
end
```
