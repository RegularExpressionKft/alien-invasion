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
  # type: redirect | stream | json | text | html
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

  dump: ->
    switch @type
      when 'redirect'
        result: @result
        status: 'redirect',
        location: @location
      when 'stream'
        _.pick @, [ 'result', 'type', 'status', 'headers' ]
      when 'json'
        _.pick @, [ 'result', 'status', 'headers', 'body' ]
      else
        _.pick @, [ 'result', 'type', 'status', 'headers', 'body' ]

class Mci
  @Response: MciResponse
  @response: (options) -> @Response.create options

  @redirect: (location) ->
    @response
      type: 'redirect'
      location: location

  @stream: (stream, content_type, size) ->
    response =
      status: 200
      type: 'stream'
      headers:
        'content-type':
          content_type ? 'application/octet-stream; charset=binary'
      body: stream
    response.headers['content-length'] = size if size?
    @response response

  @json: (json) ->
    @response
      status: 200
      type: 'json'
      body: json

  @text: (text) ->
    @response
      status: 200
      type: 'text'
      body: text

  @html: (html) ->
    @response
      status: 200
      type: 'html'
      body: html

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
