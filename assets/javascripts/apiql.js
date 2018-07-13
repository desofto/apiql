const APIQL = {
  on_error: null,
  endpoint: '',

  hash(s) {
    let hash = 0, i, chr
    if(s.length === 0) return hash
    for(i = 0; i < s.length; i++) {
      chr   = s.charCodeAt(i)
      hash  = ((hash << 5) - hash) + chr
      hash |= 0
    }
    return hash
  },

  call(endpoint, schema, params = {}, form = null) {
    return new Promise((resolve, reject) => {
      if(params instanceof FormData) {
        form = params
        params = {}
      }

      if(form) {
        Object.keys(params).forEach(key => {
          form.append(key, params[key])
        })
      }

      if(form) {
        form.append('apiql', this.hash(schema))
      } else {
        params.apiql = this.hash(schema)
      }

      Vue.http.post(`${APIQL.endpoint}${endpoint}`, params)
      .then(response => {
        resolve(response.body)
      })
      .catch(response => {
        if(response.status == 401 && APIQL.on_error) {
          APIQL.on_error(response)
          return
        }

        if(form) {
          form.append('apiql_request', schema)
        } else {
          params.apiql_request = schema
        }

        Vue.http.post(`${APIQL.endpoint}${endpoint}`, form || params)
        .then(response => {
          resolve(response.body)
        })
        .catch(response => {
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

function apiql(endpoint, schema, params = {}, form = null) {
  return APIQL.call(endpoint, schema, params, form)
}
