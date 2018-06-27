class APIQL {
  constructor(endpoint) {
    this.endpoint = endpoint
  }

  hash(s) {
    let hash = 0, i, chr
    if(s.length === 0) return hash
    for(i = 0; i < s.length; i++) {
      chr   = s.charCodeAt(i)
      hash  = ((hash << 5) - hash) + chr
      hash |= 0
    }
    return hash
  }

  call(schema, params = {}, form = null) {
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

      Vue.http.post(`${APIQL.endpoint}${this.endpoint}`, params)
      .then(response => {
        resolve(response.body)
      })
      .catch(response => {
        if(response.status == 401 && APIQL.unauthenticated) {
          APIQL.unauthenticated()
        }

        if(form) {
          form.append('apiql_request', schema)
        } else {
          params.apiql_request = schema
        }

        Vue.http.post(`${APIQL.endpoint}${this.endpoint}`, form || params)
        .then(response => {
          resolve(response.body)
        })
        .catch(response => {
          alert(response.body.errors)
        })
      })
    })
  }
}

APIQL.unauthenticated = null
APIQL.endpoint = ''