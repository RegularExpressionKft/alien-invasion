WebSocket = require 'ws'
pathToRegexp = require 'path-to-regexp'
uuid = require 'uuid'
_ = require 'lodash'

AlienPlugin = require '../plugin'

class AlienWsRouter
  constructor: ->
    @routeSeq = 0
    @routes = []

  newRoute: (path, handler, options) ->
    route = _.extend
        sensitive: true
        strict: true
        end: true
        hits: 0
      , options
    route.handler = handler if handler?
    route.id = ++@routeSeq
    route.path = path
    route.re =  pathToRegexp path,
      route.keys = [],
      _.pick route, ['end', 'strict', 'sensitive']
    @routes.push route
    route

  checkPath: (path) -> _.find @routes, (r) -> path.search(r.re) >= 0

  # TODO Route parameters are only partially implemented:
  #      Missing: repeat, optional, unnamed (more?)
  dispatch: (path, ws, unhandler) ->
    routes = @routes.slice()
    next = ->
      while routes.length > 0
        route = routes.shift()
        if (match = path.match route.re)?
          params = {}
          params[k.name] = match[i + 1] for k, i in route.keys
          ws.upgradeReq.alienLogger.debug \
            "Matching route [#{route.id}]: #{route.path}",
            params
          return route.handler ws, params, next
      unhandler path, ws
    next()

# TODO cookieparser
# TODO merge connection id / logging with Express
class AlienWsServer extends AlienPlugin
  defaultConfig:
    expressModule: 'express'

  Router: AlienWsRouter

  _init: ->
    express_module = @app.module @config 'expressModule'
    @wss = new WebSocket.Server
      server: express_module.server
      verifyClient: @_verifyClient.bind @
    @wss.on 'connection', @onServerConnection.bind @
    @wss.on 'error', @onServerError.bind @
    null

  addRoute: (path, handler, options) ->
    @router ?= new @Router @
    route = @router.newRoute path, handler, options
    route.id

  _verifyClient: (info, cb) ->
    req = info.req
    req.alienStartDate ?= new Date()
    u = req.alienUuid = uuid.v4()
    l = req.alienLogger = @app.createLogger u
    l.info "@@@@ BEGIN #{l.id} @@@@",
      _.pick req, 'method', 'url', 'headers', 'ip'

    if @router? and @router.checkPath req.url
      cb true
    else
      l.info '@@@@ END http404 @@@@'
      cb false, 404, 'Not Found'

  onServerConnection: (ws) ->
    req = ws.upgradeReq
    logger = req.alienLogger
    logger.debug 'Upgraded.'

    ws.on 'close', (code, msg) ->
      logger.info "@@@@ CLOSE @@@@",
        code: code
        msg: msg
      null

    path = req.url
    if @router?
      @router.dispatch path, ws, @onRouterDefault.bind @
    else
      @onRouterDefault path, ws

  onServerError: (e) ->
    @warn e
    null

  onRouterDefault: (path, ws) ->
    ws.upgradeReq.alienLogger.error "Router defaulted on #{path}"
    ws.close()
    null

module.exports = AlienWsServer
