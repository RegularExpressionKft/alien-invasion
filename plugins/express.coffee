Promise = require 'bluebird'
Http = require 'http'
express = require 'express'
cookie_parser = require 'cookie-parser'
body_parser = require 'body-parser'

uuid = require 'uuid'
_ = require 'lodash'

AlienPlugin = require '../plugin'

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

  _init: ->
    @express = express()
    @router = express.Router()
    @server = Http.Server @express

    router_prefix = @config 'routerPrefix'
    static_dirs = @config 'staticDirs'

    @express.use @_loggerMiddleware.bind @
    @express.use cookie_parser()
    @express.use body_parser.json()
    @express.use body_parser.urlencoded
      extended: true
    if router_prefix?
      @express.use router_prefix, @router
    else
      @express.use @router
    if static_dirs?
      static_dirs.forEach (dir) =>
        @express.use express.static dir

    @express.use (req, res, next) =>
      @handle404 req, res, next

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

  _loggerMiddleware: (req, res, next) ->
    req.alienStartDate ?= new Date()

    u = req.alienUuid = uuid.v4()
    l = req.alienLogger = @app.createLogger u
    l.info "#### BEGIN #{l.id} ####",
      _.pick req, 'method', 'url', 'headers', 'ip'

    log_end = (ms) =>
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
      res = s.request.express.res
      res.set k, v for k, v of response.headers
      res.status response.status if response.status?
      if !response.body? or
         (_.isString response.body) or
         (response.body instanceof Buffer)
        res.send response.body
      else
        res.json response.body
      s.request.responseSent = true
    response

module.exports = AlienExpress
