Promise = require 'bluebird'
WebSocket = require 'ws'
EventEmitter = require 'events'
pathToRegexp = require 'path-to-regexp'
pu = require 'alien-utils/promise'
uuid = require 'uuid'
url = require 'url'
_ = require 'lodash'

AlienPlugin = require '../plugin'

class AlienWsConnection extends EventEmitter
  constructor: (properties) -> return _.defaults @, properties

class AlienWsRouter
  constructor: ->
    @routeSeq = 0
    @routes = []

  newRoute: (path, options) ->
    route = _.extend
        sensitive: true
        strict: true
        end: true
        hits: 0
      , options
    route.id = ++@routeSeq
    if path?
      route.path = path
      route.re =  pathToRegexp path,
        route.keys = [],
        _.pick route, ['end', 'strict', 'sensitive']
    @routes.push route
    route

  findRoute: (connection) ->
    route = null
    path = connection.url.pathname
    pu.promiseFirst @routes, (r) ->
        route = r
        if !r.re? or r.re.test path
          if _.isFunction r.check
            r.check path, connection
          else
            true
        else
          null
      .then (res) ->
        if res?
          if _.isObject res
            _.defaults route: route, res
          else
            accept: res
            route: route
        else
          null

  # TODO Route parameters are only partially implemented:
  #      Missing: repeat, optional, unnamed (more?)
  dispatch: (connection) ->
    path = connection.url.pathname
    route = connection.route

    unless connection.params?
      params = connection.params = {}
      if route.re? and path? and (match = path.match route.re)?
        params[k.name] = match[i + 1] for k, i in route.keys
    connection.debug \
      "Matching route [#{route.id}]: #{route.path ? '<generic>'}",
      connection.params

    route.handler connection

# TODO cookieparser
# TODO merge connection id / logging with Express
class AlienWsServer extends AlienPlugin
  defaultConfig:
    expressModule: 'express'

  Router: AlienWsRouter

  _init: ->
    @wss = new WebSocket.Server
      noServer: true
    @wss.on 'connection', @onServerConnection
    @wss.on 'error', @onServerError

    express_module = @app.module @config 'expressModule'
    express_module.server.on 'upgrade', @onUpgrade

    null

  _sendHttpResponse: (connection, response) ->
    reason = response.reason ?
      if response.code?
        if response.status?
          "#{response.code} #{response.status}"
        else
          response.code
      else if response.status?
        "<default> #{res.status}"
      else
        'denied'
    connection.info "@@@@ END #{reason} @@@@"

    headers = if response.headers? then _.clone response.headers else {}
    headers['Connection'] ?= 'close'

    content =
      if response.text?
        headers['Content-Type'] ?= 'text/html; charset=utf-8'
        "#{response.text}"
      else if response.json?
        headers['Content-Type'] ?= 'application/json'
        JSON.stringify response.json
      else
        ''

    headers['Content-Length'] ?= content.length if headers['Content-Type']?

    crlf = "\r\n"
    msg =
      "HTTP/1.1 #{response.code ? 400} #{response.status ? 'Bad request'}" + crlf +
      _.map(headers, (v, k) -> "#{k}: #{v}#{crlf}").join('') +
      crlf +
      content

    connection.socket.write msg
    connection.socket.destroy()

    null

  _route: Promise.method (connection) ->
    if @router?
      @router.findRoute connection
      .then (response) ->
        if response?
          if response.accept
            connection.route = response.route if response.route?
            null
          else
            response
        else
          code: 404
          status: 'Not Found'
          reason: 'no handler'
      .catch (error) ->
        connection.error 'findRoute', error

        code: 500
        status: 'Internal Server Error'
        reason: 'findRoute exception'
    else
      code: 404
      status: 'Not Found'
      reason: 'no router'

  onUpgrade: (req, socket, head) =>
    try
      connection = new AlienWsConnection
        connect_date: req.alienStartDate ?= new Date()
        uuid: req.alienUuid ?= uuid.v4()

        upgrade_request: req
        socket: socket
        head: head

        url: req.alienUrl ?=
          new url.URL req.url, "ws://#{req.headers.host ? 'localhost'}/"

      req.alienLogger ?= @app.createLogger connection.uuid
      req.alienLogger.decorate connection

      connection.info "@@@@ BEGIN #{connection.logger.id} @@@@",
        _.pick req, 'method', 'url', 'headers', 'ip'

      @_route connection
      .then (response) =>
        if response?
          @_sendHttpResponse connection, response
        else
          @wss.handleUpgrade req, socket, head, (ws) =>
            @onUpgraded connection, ws
        null
      .catch (error) =>
        connection.error "_route: #{error}", error
        @_sendHttpResponse connection,
          code: 500
          status: 'Internal Server Error'
          reason: '_route exception'
    catch error
      @error "onUpgrade: #{error}", error

    null

  onUpgraded: (connection, ws) ->
    ws.alienConnection = connection
    connection.ws = ws
    connection.debug 'Upgraded.'
    @wss.emit 'connection', ws
    null

  onServerConnection: (ws) =>
    connection = ws.alienConnection

    ws.on 'close', (code, msg) ->
      connection.info "@@@@ CLOSE @@@@",
        code: code
        msg: msg
      null

    if @router? and connection.route?
      @router.dispatch connection
    else
      @onRouterDefault connection

  onServerError: (e) =>
    @warn e
    null

  onRouterDefault: (connection) =>
    connection.error "Router defaulted on #{connection.url.pathname}"
    connection.ws.close()
    null

  addRoute: (path, options) ->
    @router ?= new @Router @
    options = handler: options if _.isFunction options
    route = @router.newRoute path, options
    route.id

module.exports = AlienWsServer
