# Model/Controller Interface

Promise = require 'bluebird'
_ = require 'lodash'

class MciResponse
  @create: (options) -> new @ options

  constructor: (options) ->
    _.extend @, options
    @cloned ?= true
    return @

  # status: HTTP response status
  # headers: HTTP response headers
  # body: HTTP response body
  # result: success | error | exception
  # type: json | ...
  # sent: response sent
  # cloned: object is safe to modify (default true)

  clone: ->
    cloned = new @constructor @
    cloned.cloned = true
    cloned
  ensureCloned: ->
    if @cloned
      @
    else
      @clone()

class Mci
  @Response: MciResponse
  @response: (options) -> @Response.create options

  @redirect: (location) ->
   new @Response
     type: 'redirect'
     location: location

  @jsonResponse = (status, body, headers) ->
    r = type: 'json'
    r.status = status if status?
    r.body = body if body?
    r.headers = headers if headers?
    @response r

  @promiseSuccess = (options) ->
    Promise.resolve @response options
  @promiseError = (options) ->
    Promise.reject @response options
  @promiseException = (e, options) ->
    error = if e instanceof Error then e else new Error e
    error.response = @response options if options?
    Promise.reject error

module.exports = Mci
