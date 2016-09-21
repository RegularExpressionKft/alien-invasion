Promise = require 'bluebird'
_ = require 'lodash'

Mci = require './mci'
AlienCommander = require 'alien-utils/commander'

class AlienAction
  sAdapter: (s) ->
    t_name = s.request.transport
    @adapters?[t_name] ? s.controller.adapters[t_name]
  transportAdapter: (transport, controller) ->
    t_name = transport.moduleName
    @adapters?[t_name] ? controller.adapters[t_name]

class AlienController extends AlienCommander
  name: 'anonController'

  constructor: (@app, @master, @name) ->
    @app.module @master.config 'modelModule' if @modelName?
    transports = @master.transportModules()
    for action_name, action of @actions
      for transport in transports
        if adapter = action.transportAdapter transport, @
          adapter.setup transport, @, action
    @_init()
    @

  _init: -> null

  # -- Config

  handlers: @commands
      model: 'modelHandler'
    ,
      name: (cmd, this_object, args) -> this_object.name
      what: 'handler'

  wrappers: @commands
      transaction: 'transactionWrapper'
    ,
      name: (cmd, this_object, args) -> this_object.name
      what: 'wrapper'

  # TODO @adapters should be commands?
  # TODO Adapter class?
  # TODO Move to express plugin?
  adapters:
    express:
      setup: (transport, controller, action) ->
        transport.makeRoute action.method, action.path, controller, action.name
        @
      dispatch: (s, action_name) -> s.controller.action s, action_name
      promise: (s, what, model) -> @extractors.apply what, null, arguments

      # Returns untrusted stuff
      extractors: AlienCommander.commands
        id: (s, what, model) ->
          Promise.resolve _.pick s.request.params.route, model.idFields
        filters: (s) -> Promise.resolve {}
        properties: (s) -> Promise.resolve s.request.params.body

  # -- Generic dispatch

  getAction: (s, action_name) ->
    @actions?[action_name] ?
      throw new Error "#{@name}: No action: #{action_name}"

  actionChain: (s) ->
    action = s.action
    opts = s.dispatch =
      controller: @
      wrappers: if action.wrap? then action.wrap.slice() else []
      handler: action.handler
    next = Promise.method (args...) ->
      args[0] ?= s
      o = args[0].dispatch ?= opts
      c = o.controller

      if o.wrappers? and o.wrappers.length > 0
        args[1] ?= next
        c.wrappers.fnApply o.wrappers.shift(), c, args
      else
        args[1] = null
        c.handlers.fnApply o.handler, c, args

  action: (s, action_name) ->
    try
      s.controller ?= @
      action = s.action ?= @getAction s, action_name
      next = @actionChain s

      s.debug "Controller: #{@name}, action: #{action.name}"
      @app.emit 'action', s

      (next s, next).then ((r) => @_actionResolved s, r),
                          ((e) => @_actionRejected s, e)
                    .then (r) =>
                      r.result ?= 'success'
                      s.debug 'Response:',
                        _.pick r, 'result', 'status', 'headers', 'body'
                      s.emit 'response', r
                      # r.result can be 'error'
                      s.emit r.result, r if s.listenerCount(r.result) > 0
                      r
    catch error
      s.error error
      Promise.reject error

  dispatch: (s, action_name) ->
    try
      s.controller ?= @
      action = s.action ?= @getAction s, action_name
      adapter = s.adapter ?= action.sAdapter s
      adapter.dispatch s, action_name
    catch error
      s.error error
      Promise.reject error

  # -- Response formatting

  defaultSuccessResponse: Mci.response
    status: 200
    result: 'success'
    cloned: false
  defaultErrorResponse: Mci.response
    status: 400
    result: 'error'
    cloned: false
  defaultExceptionResponse: Mci.response
    status: 500
    result: 'exception'
    cloned: false

  successResponse: (s, pr) -> pr
  errorResponse: (s, pr) -> pr
  exceptionResponse: (s, pr) -> pr

  _actionResolved: (s, r) ->
    if r instanceof Error
      @_actionException s, r
    else
      @successResponse s, @promiseResponse s, r, @defaultSuccessResponse
  _actionRejected: (s, r) ->
    if r instanceof Error
      @_actionException s, r
    else
      @errorResponse s, @promiseResponse s, r, @defaultErrorResponse
  _actionException: (s, r) ->
    s.warn r.stack
    @exceptionResponse s,
      @promiseResponse s,
        if r.response is undefined then r.toString() else r.response,
        @defaultExceptionResponse

  promiseResponse: (s, r, d) ->
    response =
      if r instanceof Mci.Response
        r.ensureCloned()
      else
        Mci.response body: r

    if d?
      for i in ['status', 'body', 'result', 'type']
        response[i] ?= d[i]
      if d.headers?
        response.headers = _.defaults {},
          response.headers,
          d.headers

    Promise.resolve response

  # -- Model interface

  model: (s) ->
    (@app.module @master.config 'modelModule').model @modelName

  # Returns trusted stuff
  promiseModelOptions: (s) -> Promise.resolve {}

  modelHandler: (s) ->
    unless adapter = s.action.sAdapter s
      throw new Error "Action #{s.action.name} doesn't support " +
                      "transport #{s.request.transport}"
    model = @model s
    op = model.ops[s.action.name] ?
      throw new Error "Model #{model.name} doesn't support " +
                      "operation #{s.action.name}"

    parameter_ps = {}
    parameter_ps[i] = adapter.promise s, i, model for i of op.needs

    (@promiseModelOptions s).then (options) ->
      model.apiUnsafe s, s.action.name, options, parameter_ps

  # -- wrappers

  transactionWrapper: (s, next) ->
    (@app.module @master.config 'modelModule').transaction s,
      (s_) -> next s_

AlienController._action = (name, opt, defaultOptions) ->
  action = new @Action
  _.extend action,
    if _.isString opt
      route: opt
    else if _.isFunction opt
      route: name
      handler: opt
    else if _.isObject opt
      opt
    else
      throw new Error "Bad action specification for #{name}"
  action.name ?= name

  # TODO move to express adapter
  if (route = action.route)?
    match = route.match /^(\w+)\s+(\S+)$/ if _.isString route
    throw new Error "Bad route specification for action #{name}" unless match?
    action.method = match[1]
    action.path = match[2]
  else if action.path?
    action.method ?= 'any'
  else
    throw new Error "No route specification for action #{name}"

  _.defaults action, defaultOptions

AlienController.Action = AlienAction
AlienController.addActions = (actions, defaultOptions) ->
  @::actions ?= {}
  for name, opt of actions
    throw new Error "Duplicate action: #{name}" if @::actions[name]?
    @::actions[name] = @_action name, opt, defaultOptions
  @

module.exports = AlienController
