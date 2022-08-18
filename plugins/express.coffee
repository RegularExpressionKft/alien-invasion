Promise = require 'bluebird'
Http = require 'http'
express = require 'express'
cookie_parser = require 'cookie-parser'
body_parser = require 'body-parser'

uuid = require 'uuid'
_ = require 'lodash'

AlienPlugin = require '../plugin'

intify = (x) -> if _.isFinite(y = parseInt x) then y else x

numCmp = (a, b) ->
  if a - b < 0
    -1
  else if a - b > 0
    1
  else
    0

strCmp = (a, b) ->
  if a < b
    -1
  else if a > b
    1
  else
    0

class AlienExpressTransaction
  transport: 'express'
  protocol: 'http'

  constructor: (req, res, next) ->
    @method = req.method
    @hostname = req.hostname
    @path = req.path
    @params =
      route: req.params
      query: req.query
      body: req.body
    @express =
      req: req
      res: res
      next: next
    @

class AlienExpress extends AlienPlugin
  defaultConfig:
    port: 6543
    size_limit: '4mb'
    timeout: null
    middleware:
      'alien-logger':
        priority: 0
        install: (plugin) ->
          plugin.express.use plugin._loggerMiddleware
      'cookie-parser':
        priority: 10
        install: (plugin) ->
          plugin.express.use cookie_parser()
      'body-parser-json':
        priority: 20
        install: (plugin) ->
          defaults = {}
          defaults.limit = t if (t = plugin.config 'size_limit')?
          options = _.defaults {}, @options, defaults
          plugin.express.use body_parser.json options
      'body-parser-urlencoded':
        priority: 21
        options:
          extended: true
        install: (plugin) ->
          # ignore global size limit
          plugin.express.use body_parser.urlencoded @options
      'body-parser-raw':
        priority: 29
        options:
          type: 'application/octet-stream'
        install: (plugin) ->
          defaults = {}
          defaults.limit = t if (t = plugin.config 'size_limit')?
          options = _.defaults {}, @options, defaults
          plugin.express.use body_parser.raw options
      router:
        priority: 100
        install: (plugin) ->
          if (router_prefix = plugin.config 'routerPrefix')?
            plugin.express.use router_prefix, plugin.router
          else
            plugin.express.use plugin.router
      static:
        priority: 200
        install: (plugin) ->
          if (static_dirs = plugin.config 'staticDirs')?
            static_dirs.forEach (dir) ->
              plugin.express.use express.static dir
          plugin.express
      error404:
        priority: 1000
        install: (plugin) ->
          plugin.express.use plugin._handle404

  _init: ->
    @express = express()
    @router = express.Router()
    @server = Http.Server @express

    @server.timeout = t if (t = @config 'timeout')?

    middlewares = @config 'middleware'
    order = _.keys(middlewares).filter (m) ->
      (mw = middlewares[m])? and
      (mw.enabled ? true) and
      _.isFinite(mw.priority) and
      _.isFunction(mw.install)
    order.sort (a, b) ->
      if (o = numCmp middlewares[a].priority, middlewares[b].priority) == 0
        strCmp a, b
      else
        o
    middlewares[m].install @ for m in order

    null

  start: ->
    if @started
      Promise.resolve @port
    else
      # TODO reentry protection
      new Promise (resolve, reject) =>
        @port = @config 'port'
        @debug "Starting on port #{@port}"
        @server.listen @port, (error) =>
          if error?
            @error error
            @port = null
            reject error
          else
            @started = true
            resolve @port
  stop: ->
    if @started
      new Promise (resolve, reject) =>
        @server.close (error) =>
          if error?
            @error error
            reject error
          else
            @started = false
            @port = null
            resolve null
    else
      Promise.resolve null

  handle404: (req, res, next) ->
    next()

  _handle404: (req, res, next) =>
    # handle404 may be overriden / replaced
    # may or may not be bound
    @handle404 req, res, next

  _loggerMiddleware: (req, res, next) =>
    req.alienStartDate ?= new Date()

    u = req.alienUuid = uuid.v4()
    l = req.alienLogger = @app.createLogger u
    l.info "#### BEGIN #{l.id} ####",
      _.pick req, 'method', 'url', 'headers', 'ip'

    log_end = (ms) =>
      req.alienLogger?.debug "Performance stats:", JSON.stringify
        route: "#{req.method} #{req.route?.path ? req.url.replace(/\?.*/, '')}"
        status: res.statusCode
        contentLength: intify res.getHeader 'content-length'
        contentType: res.getHeader 'content-type'
        toResponseMs: req.alienResponseDate - req.alienStartDate
        toFinishMs: ms
      req.alienLogger?.info "#### END #{ms}ms ####"
    req.on 'end', ->
      req.alienEndDate = new Date()
      log_end req.alienEndDate - req.alienStartDate if req.alienFinishDate?
    res.on 'finish', ->
      req.alienFinishDate = new Date()
      log_end req.alienFinishDate - req.alienStartDate if req.alienEndDate?

    next()

  makeStash: (req, res, next) ->
    stuff = request: new AlienExpressTransaction req, res, next
    stuff.request.uuid = req.alienUuid if req.alienUuid?
    stuff.logger = req.alienLogger if req.alienLogger?
    @app.makeStash stuff

  dispatch: (ctrl, action, express_args...) ->
    s = @makeStash express_args...
    p_response = if _.isFunction ctrl
        ctrl s, action
      else
        ctrl.dispatch s, action
    p_response.then (response) => @respond s, response

  makeDispatch: (ctrl, action) ->
    @dispatch.bind @, ctrl, action

  makeRoute: (method, path, ctrl, action) ->
    @router[method] path, @makeDispatch ctrl, action

  respond: (s, response) ->
    unless s.request.responseSent
      s.request.express.req.alienResponseDate = new Date()

      res = s.request.express.res
      res.set k, v for k, v of response.headers
      res.status response.status if response.status?
      switch response.type
        when 'redirect'
          res.redirect response.location
        when 'stream'
          response.body.pipe res
        else
          if !response.body? or
               (_.isString response.body) or
               (response.body instanceof Buffer)
            res.contentType 'text/plain' if response.type is 'text'
            res.send response.body
          else
            res.json response.body
      s.request.responseSent = true
    response

module.exports = AlienExpress
