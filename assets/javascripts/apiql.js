const APIQL = {
  on_error: null,
  endpoint: '',
  CSRFToken: '',
  http: null,

  hash: function(s) {
    var hash = 0, i, chr
    if(s.length === 0) return hash
    for(i = 0; i < s.length; i++) {
      chr   = s.charCodeAt(i)
      hash  = ((hash << 5) - hash) + chr
      hash |= 0
    }
    return hash
  },

  post: function(endpoint, data) {
    return new Promise(function(resolve, reject) {
      var http = new XMLHttpRequest()
      http.open("POST", endpoint, true)
      if(APIQL.CSRFToken.length > 0) {
        http.setRequestHeader("X-CSRF-Token", APIQL.CSRFToken)
      }
      http.setRequestHeader("Content-Type", "application/json;charset=UTF-8")
      http.onload = function() {
        APIQL.http = http

        if(http.status >= 200 && http.status < 300) {
          resolve({
            status: http.status,
            body: JSON.parse(http.responseText),
            http: http
          })
        } else {
          reject({
            status: http.status,
            body: JSON.parse(http.responseText),
            http: http
          })
        }
      }
      http.send(JSON.stringify(data))
    })
  },

  call: function(schema, params, form) {
    if(!params) params = {}
    if(!form) form = null

    return new Promise(function(resolve, reject) {
      if(params instanceof FormData) {
        form = params
        params = {}
      }

      if(form) {
        Object.keys(params).forEach(function(key) {
          form.append(key, params[key])
        })
      }

      if(form) {
        form.append('apiql', APIQL.hash(schema))
      } else {
        params.apiql = APIQL.hash(schema)
      }

      APIQL.post(APIQL.endpoint, form || params)
      .then(function(response) {
        resolve(response.body)
      }, function(response) {
        if(response.status == 401 && APIQL.on_error) {
          APIQL.on_error(response)
          return
        }

        if(response.status < 400) return

        if(form) {
          form.append('apiql_request', schema)
        } else {
          params.apiql_request = schema
        }

        APIQL.post(APIQL.endpoint, form || params)
        .then(function(response) {
          resolve(response.body)
        }, function(ressponse) {
          if(APIQL.on_error) {
            APIQL.on_error(response)
          } else {
            alert(response.body)
          }
        })
      })
    })
  }
}

function apiql(schema, params, form) {
  if(!params) params = {}
  if(!form) form = null
  return APIQL.call(schema, params, form)
}
