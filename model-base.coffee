Promise = require 'bluebird'
assert = require 'assert'
_ = require 'lodash'

AlienCommander = require 'alien-utils/commander'
Mci = require './mci'

__op_name = (cmd, this_object, args) ->
  model_nm = this_object.name
  op_nm = args?[2]?.name ? 'unknownOp'
  "#{model_nm}.#{op_nm}"

true_object = (keys) ->
  obj = {}
  obj[k] = true for k in keys
  obj

###### AlienModelOperation ####################################################

class AlienModelOperation extends AlienCommander
  name: 'AnonOp'

  hooks: @commands null,
    name: __op_name
    what: 'hook'

  checkers: @commands null,
    name: __op_name
    what: 'checker'

  # Move to options?
  isObjectInEvent: false
  isIdInChannel: false
  responseStatus: 200
  internal: false

  constructor: (@spec) ->
    _.extend @, _.omit @spec, ['hooks', 'checkers', 'needs', 'action']
    base = Object.getPrototypeOf @

    for i in ['hooks', 'checkers']
      @[i] = if @spec[i]? then base[i].derive @spec[i] else base[i].derive()

    @needs = {}
    for what, deps of _.defaultsDeep {}, @spec.needs, base.needs
      @needs[what] = _.pickBy deps if deps

    @hooks.extend action: @spec.action if @spec.action?

    @

  @create: (spec, parent) ->
    if parent?
      @call (op = Object.create parent), spec
      op
    else
      new @ spec

  instantiate: (s, options) -> Object.create @

  init: (s, options) ->
    @options = _.defaultsDeep {}, options, @options
    @model = options.model if options.model
    @promises = if @promises? then _.clone @promises else {}
    @cache = if @cache? then _.clone @cache else {}
    @logger ?= s.logger
    @

  start: (s, options) -> (@instantiate s, options).init s, options

  getCached: (s, name) -> @cache[name]
  hasCached: (s, name) -> @cache[name]?
  addCached: (s, name, value) ->
    @cache[name] ?= value
    @
  setCached: (s, name, value) ->
    @cache[name] = value
    @

  cacheMiss: (s, name) ->
    throw new Error "#{@model}.#{name}: No cached #{name}"
  cached: (s, name) -> @cache[name] ? @cacheMiss s, name

  promiseToCache: (s, name, promise) ->
    promise.then ((v) => @cache[name] ?= v ; true),
                 ((error) -> false)

  getPromise: (s, name) -> @promises[name]
  hasPromise: (s, name) -> @promises[name]?
  setPromise: (s, name, promise) ->
    @promiseToCache s, name, (@promises[name] = promise)
    @
  addPromise: (s, name, promise) ->
    unless @promises[name]?
      @promiseToCache s, name, (@promises[name] = promise)
    @

  tryPromise: (s, name, provider, rest...) ->
    if provider?
      @setPromise s, name,
        p = Promise.resolve if provider instanceof AlienCommander
            provider.call name, @model, s, @, rest...
          else
            provider.call? @model, s, @, rest...
      p
    else
      null
  cantPromise: (s, name) ->
    throw new Error "#{@model.name}.#{@name}: Can't promise #{name}"
  promise: (s, name) ->
    @promises[name] ? @tryPromise(arguments...) ? @cantPromise(arguments...)
  promiseNoThrow: ->
    try
      @promise arguments...
    catch error
      Promise.reject error

  setValue: (s, name, value) ->
    @promises[name] = Promise.resolve value
    @cache[name] = value
    @
  addValue: (s, name, value) ->
    @promises[name] ?= Promise.resolve value
    @cache[name] ?= value
    @

###### AlienModelBase #########################################################

class AlienModelBase extends AlienCommander
  constructor: (@app, @master, @name) ->
    @app.decorateWithNewLogger @, @name
    @_inflateIdObjects()
    @_init()
    @

  _init: -> null

# ==== Errors =================================================================

  localizeError: (s, op, fld, loc, error) ->
    f = if loc? then "#{loc}.#{fld}" else fld
    error?.body?.fld = f if f?
    error

  e404: (s, op, fld, loc) ->
    @localizeError s, op, fld, loc,
      status: 404
      type: 'json'
      body:
        code: 'not_found'
  error404: (s, op, fld, loc) -> Mci.promiseError @e404 s, op, fld, loc

  eNotFound: @::e404
  errorNotFound: @::error404

  eForbidden: (s, op, fld, loc) ->
    @localizeError s, op, fld, loc,
      status: 403
      type: 'json'
      body:
        code: 'forbidden'
  errorForbidden: (s, op, fld, loc) -> Mci.promiseError @eForbidden s, op, fld, loc

  eUnauthorized: (s, op, fld, loc) ->
    @localizeError s, op, fld, loc,
      status: 401
      type: 'json'
      body:
        code: 'unauthorized'
  errorUnauthorized: (s, op, fld, loc) -> Mci.promiseError @eUnauthorized s, op, fld, loc

  eBadValue: (s, op, fld, loc) ->
    @localizeError s, op, fld, loc,
      status: 400
      type: 'json'
      body:
        code: 'bad_value'
  errorBadValue: (s, op, fld, loc) -> Mci.promiseError @eBadValue s, op, fld, loc

  eMissingParam: (s, op, fld, loc) ->
    @localizeError s, op, fld, loc,
      status: 400
      type: 'json'
      body:
        code: 'missing_param'
  errorMissingParam: (s, op, fld, loc) -> Mci.promiseError @eMissingParam s, op, fld, loc

# ==== Composite Id ===========================================================

  idFields: ['id']
  parentIdFields: null

  _inflateIdObjects: ->
    for k in [ 'idFields', 'parentIdFields' ]
      @["#{k}AsObject"] = true_object @[k] if @[k]?
    @

  extractId: (s, obj) ->
    if _.isFunction obj.pick
      obj.pick @idFields
    else
      _.pick obj, @idFields

  idAsString: (id_obj, separator = ':') ->
    if @idFields.length == 1 and _.isString(id_obj)
      id_obj
    else
      assert _.isObject(id_obj), 'id_obj is object'
      @idFields.map (f) ->
        assert _.isString(v = id_obj[f]), "id has #{f}"
        assert v.indexOf(separator) < 0, "id.#{f} doesn't contain separator (#{separator})"
        v
      .join separator

  idFromString: (id_str, separator = ':') ->
    assert _.isString(id_str), 'id_str is string'

    id_values = id_str.split separator
    assert.equal id_values.length, @idFields.length, 'id field count'

    id_obj = {}
    id_obj[f] = id_values[i] for f, i in @idFields
    id_obj

# ==== Relations ==============================================================

  # @relations = {}

  @_initRelation: (type, rel_name, model_name, options) ->
    @relations = {} unless @hasOwnProperty 'relations'
    @relations[rel_name] = _.extend
        name: rel_name
        modelName: model_name
        type: type
      , options
    @

  @belongsTo: (rel_name, model_name, foreign_key) ->
    if foreign_key?
      @_initRelation 'belongsTo', rel_name, model_name, foreign_key: foreign_key
    else
      @_initRelation 'belongsTo', rel_name, model_name

  @hasMany: (rel_name, model_name, foreign_key) ->
    if foreign_key?
      @_initRelation 'hasMany', rel_name, model_name, foreign_key: foreign_key
    else
      @_initRelation 'hasMany', rel_name, model_name

  @belongsToMany: (rel_name, model_name, join_table_name) ->
    @_initRelation 'belongsToMany', rel_name, model_name,
      joinTableName: join_table_name

# ==== Hooks ==================================================================

  hooks: @commands
      accessFilter: 'defaultAccessFilter'
      accessGrant: 'defaultAccessGrant'
      check: 'defaultCheck'
      done: 'defaultDone'
      event: 'defaultEvent'
      eventChannel: 'defaultEventChannel'
      importSafeParameters: 'defaultImportSafeParameters'
      importUnsafeParameters: 'defaultImportUnsafeParameters'
      json: 'defaultJson'
      jsonCollection: 'defaultJsonCollection'
      jsonObject: 'defaultJsonObject'
      response: 'defaultResponse'
      sendEvent: 'defaultSendEvent'
    ,
      name: (cmd, this_object, args) -> this_object.name
      what: 'hook'

  # opHook: (hook_name, s, op, rest...)
  opHook: (hook_name, rest...) ->
    hooks = rest[1]?.hooks
    hooks = @hooks unless hooks?.has? hook_name
    hooks.apply hook_name, @, rest

# ==== API ====================================================================

  apiOp: (s, gop, options, safe_params, unsafe_params) ->
    s.info "Model #{@name} op #{gop.name} options", options
    p_safe = if safe_params? then Promise.props safe_params else null
    p_unsafe = if unsafe_params? then Promise.props unsafe_params else null
    Promise.join p_safe, p_unsafe, (safe, unsafe) =>
      s.info "Model #{@name} op #{gop.name} params",
        safe: safe
        unsafe: unsafe

    op = gop.start s, _.defaults model: @, options
    if safe_params?
      @opHook 'importSafeParameters', s, op, safe_params
    if unsafe_params?
      @opHook 'importUnsafeParameters', s, op, unsafe_params

    @opHook 'accessGrant', s, op
    .then => @opHook 'action', s, op
    .then (result) => @opHook 'done', s, op, result
  api: (s, op_name, options, safe_params, unsafe_params) ->
    if (gop = @ops[op_name])?
      @apiOp s, gop, options, safe_params, unsafe_params
    else
      Promise.reject "Model #{@name} doesn't support operation #{op_name}"
  apiSafe: (s, op_name, options, safe_params) ->
    @api s, op_name, options, safe_params, null
  apiUnsafe: (s, op_name, options, unsafe_params) ->
    @api s, op_name, options, null, unsafe_params

  defaultDone: (s, op, result) ->
    Promise.join \
      (@opHook 'response', s, op, result),
      (@opHook 'sendEvent', s, op, result),
      (response, event) => response

  _jsonObjectAccessFilter: (s, json, context, _vars) ->
    Promise.resolve json

  _jsonArrayAccessFilter: (s, json, context, _vars = {}) ->
    Promise.map json, (i) => @_jsonObjectAccessFilter s, i, context, _vars
           .filter (i) -> i?

  jsonAccessFilter: (s, json, context) ->
    if _.isArray json
      @_jsonArrayAccessFilter s, json, context
    else if _.isObject json
      @_jsonObjectAccessFilter s, json, context
    else
      Promise.resolve json

  defaultAccessFilter: (s, op, json, context) ->
    @jsonAccessFilter s, json, context
    .then (ret) =>
      if !ret? and json?
        @errorUnauthorized s, op
      else
        ret

  defaultAccessGrant: (s, op) ->
    Promise.resolve()

# ==== Checkers ===============================================================

  checkers: @commands
      id: 'promiseCheckedId'
      filters: 'promiseCheckedFilters'
      properties: 'promiseCheckedProperties'
    ,
      name: (cmd, this_object, args) -> this_object.name
      what: 'checker'

  # opChecker: (what, s, op, rest...)
  opChecker: (what, rest...) ->
    checkers = rest[1]?.checkers
    checkers = @checkers unless checkers?.has? what
    checkers.apply what, @, rest

  # TODO
  promiseCheckedId: (s, op, p_unsafe_id, unsafe_ps, what, loc) ->
    Promise.resolve(p_unsafe_id).then (unsafe_id) =>
      for k, v of unsafe_id
        unless @idFieldsAsObject[k] and _.isString v
          loc ?= op?.options.loc
          return @errorBadValue s, op, k, loc
      for k in @idFields
        unless unsafe_id[k]?
          loc ?= op?.options.loc
          return @errorMissingParam s, op, k, loc
      unsafe_id

  # TODO
  promiseCheckedFilters: (s, op, p_unsafe_filters, unsafe_ps, what, loc) ->
    Promise.resolve {}

  # TODO
  promiseCheckedProperties: (s, op, p_unsafe_props, unsafe_ps, what, loc) ->
    Promise.resolve p_unsafe_props

  defaultImportSafeParameters: (s, op, safe_ps) ->
    for k, v of safe_ps
      unless op.hasPromise s, k
        if v?.then?
          op.setPromise s, k, v
        else
          op.setValue s, k, v
    @

  defaultImportUnsafeParameters: (s, op, unsafe_params) ->
    needs = _.keys op.needs
    while needs.length > 0
      left = []
      for what in needs when !op.hasPromise s, what
        if (p = @opHook 'check', s, op, unsafe_params, what)?
          op.setPromise s, what, p
        else
          left.push what

      if left.length < needs.length
        needs = left
      else
        s.debug "#{@name}.#{op.name}: Failed checker dependencies. " +
          "I have:", _.keys op.promises
        for what in left
          s.debug "#{what} needs:", op.needs[what]
          op.addPromise s, what,
            Promise.reject "#{@name}.#{op.name}: " +
              "Can't satisfy checker dependencies for #{what}"
        needs = []
    @

  defaultCheck: (s, op, unsafe_ps, what) ->
    deps = op?.needs[what]
    deps = _.keys deps unless deps?.every?
    if (deps.every (dep) -> op.hasPromise s, dep)
      @opChecker what, s, op, unsafe_ps[what], unsafe_ps, what
    else
      null

# ==== Responses ==============================================================

  defaultJsonObject: (s, op, result, context) ->
    Promise.resolve if _.isFunction result?.toJSON
        result.toJSON()
      else
        result

  # TODO move opHook out of map
  defaultJsonCollection: (s, op, result, context) ->
    Promise.all result.map (i) => @opHook 'jsonObject', s, op, i, context

  defaultJson: (s, op, result, context) ->
    if result?
      hook = if result.length? then 'jsonCollection' else 'jsonObject'
      @opHook hook, s, op, result, context
    else
      Promise.resolve null

  # TODO make MCI optional
  defaultResponse: (s, op, result) ->
    context = 'response'
    Promise.resolve @opHook 'json', s, op, result, context
           .then (json) => @opHook 'accessFilter', s, op, json, context
           .then (json) => Mci.jsonResponse op?.responseStatus ? 200, json

# ==== Realtime ===============================================================

  defaultEventChannel: (s, op, result) ->
    channel_components = [@name]
    if op?.isIdInChannel
      if (id = op.getCached s, 'id')?
        channel_components.push.apply channel_components,
          @idFields.map (k) -> id[k]
      else
        s.warn "#{@name} no id for event channel"
    Promise.resolve channel_components.join ':'

  defaultEvent: (s, op, result) ->
    if op?.eventName?
      event =
        model: @name
        event: op.eventName
      event.id = id if (id = op.getCached s, 'id')?

      if result? and op?.isObjectInEvent
        Promise.resolve @opHook 'json', s, op, result, 'event'
        .then (json) =>
          event.object = json if json?
          event
      else
        Promise.resolve event
    else
      Promise.resolve null

  defaultSendEvent: (s, op, result) ->
    Promise.join \
      (@opHook 'eventChannel', s, op, result),
      (@opHook 'event', s, op, result),
      (channel, event) =>
        s.queueRealtimeEvent channel, event if channel? and event?
        event

# ==== Ops ====================================================================

  @Operation: AlienModelOperation

  @makeOps: (parent_ops, specs, options) ->
    specs_ = _.mapValues parent_ops, -> {}
    for name, spec of specs
      if spec
        _.defaultsDeep specs_[name] ?= {}, spec
      else
        delete specs_[name]
    if (common = options?.common)?
      _.defaultsDeep spec, common for name, spec of specs_
    for name, spec of specs_
      spec.name = name unless spec.hasOwnProperty 'name' or parent_ops?[name]?
    if _.isFunction tweak = options?.tweak
      specs_ = tweak specs_, parent_ops, options, @

    Op = @Operation
    _.mapValues specs_, (spec, name) -> Op.create spec, parent_ops?[name]

  # Not added by default, no default implementation
  @defaultOps:
    Read:
      action: 'opReadAction'
      needs:
        id: {}
      isReadonly: true
      isCollection: false
    List:
      action: 'opListAction'
      needs:
        # parentId: {}
        filters: {}
      isReadonly: true
      isCollection: true
    Create:
      action: 'opCreateAction'
      needs:
        properties: {}
      isReadonly: false
      isCollection: false
      responseStatus: 201
      eventName: 'Create'
      isObjectInEvent: true
    Update:
      action: 'opUpdateAction'
      needs:
        id: {}
        properties: {}
      isReadonly: false
      isCollection: false
      eventName: 'Update'
      isIdInChannel: true
      isObjectInEvent: true
    Delete:
      action: 'opDeleteAction'
      needs:
        id: {}
      isReadonly: false
      isCollection: false
      responseStatus: 204
      eventName: 'Delete'
      isIdInChannel: true
      isObjectInEvent: false

  @addOps: (specs, options) ->
    @::ops = @makeOps @::ops, specs, options
    @

  @addDefaultOps: (options) ->
   @addOps _.pickBy(@defaultOps, (op) => @::[op.action]?), options

  ops: {}

module.exports = AlienModelBase
