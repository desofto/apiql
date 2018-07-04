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
variables `session`, `current_user` and `params` will be stored into context you can use in presenters and handlers

Define presenters for your models:

```ruby
class User < ApplicationRecord
  class Entity < ::APIQL::Entity
    attributes :full_name, :email, :token, :role, :roles

    def token
      object.token if object == current_user
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
authenticate(email, password) {
  let api = new APIQL("user")
  api.call(`
    logout()
    authenticate(email,password) {
      token
    }
    me {
      email full_name role token
   }
  `, {
    email: email,
    password: password
  })
  .then(response => {
    let user = response.me
  })
}

logout() {
  let api = new APIQL("user")
  api.call(`
    logout
  `)
  .then(response => {
  })
}

```

You can use initializer like this for authorization using cancancan gem:

config/initializers/apiql.rb:

```ruby
class APIQL
  delegate :authorize!, to: :@context

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
