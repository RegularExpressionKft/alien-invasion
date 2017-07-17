Promise = require 'bluebird'
WebSocket = require 'ws'
pathToRegexp = require 'path-to-regexp'
pu = require 'alien-utils/promise'
uuid = require 'uuid'
url = require 'url'
_ = require 'lodash'

AlienPlugin = require '../plugin'

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
    route.path = path
    route.re =  pathToRegexp path,
      route.keys = [],
      _.pick route, ['end', 'strict', 'sensitive']
    @routes.push route
    route

  checkPath: (path, info) ->
    pu.promiseFirst @routes, (r) ->
      if r.re.test path
        if _.isFunction r.check
          r.check path, info
        else
          true
      else
        null

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
    @wss.on 'connection', @onServerConnection
    @wss.on 'error', @onServerError
    null

  addRoute: (path, options) ->
    @router ?= new @Router @
    options = handler: options if _.isFunction options
    route = @router.newRoute path, options
    route.id

  # Fatarrow changes function.length as of 1.12.4
  # https://github.com/jashkenas/coffeescript/issues/2489
  # _verifyClient: (info, cb) =>
  _verifyClient: (info, cb) ->
    req = info.req
    req.alienStartDate ?= new Date()
    u = req.alienUuid = uuid.v4()
    l = req.alienLogger = @app.createLogger u
    l.info "@@@@ BEGIN #{l.id} @@@@",
      _.pick req, 'method', 'url', 'headers', 'ip'

    if @router?
      req.alienUrl =
        new url.URL req.url, "ws://#{req.headers.host ? 'localhost'}/"

      @router.checkPath req.alienUrl.pathname, info
             .then (res) ->
               if res?
                 l.debug 'checkPath',
                   res: res
                   type: typeof res
                   obj: _.isObject res
                   bool: !!res
                 if _.isObject res
                   unless res.accept
                     l.info "@@@@ END #{res.code} #{res.string} @@@@"
                   cb res.accept, res.code, res.string
                 else
                   l.info '@@@@ END denied @@@@' unless res
                   cb res
               else
                 l.info '@@@@ END no handler @@@@'
                 cb false, 404, 'Not Found'
             .catch (error) ->
               l.error 'checkPath', error
               l.info '@@@@ END exception @@@@'
               cb false, 500, 'Internal Server Error'
    else
      l.info '@@@@ END no router @@@@'
      cb false, 404, 'Not Found'

  onServerConnection: (ws) =>
    req = ws.upgradeReq
    logger = req.alienLogger
    logger.debug 'Upgraded.'

    ws.on 'close', (code, msg) ->
      logger.info "@@@@ CLOSE @@@@",
        code: code
        msg: msg
      null

    if @router?
      @router.dispatch req.alienUrl.pathname, ws, @onRouterDefault
    else
      @onRouterDefault req.alienUrl.pathname, ws

  onServerError: (e) =>
    @warn e
    null

  onRouterDefault: (path, ws) =>
    ws.upgradeReq.alienLogger.error "Router defaulted on #{path}"
    ws.close()
    null

module.exports = AlienWsServer
