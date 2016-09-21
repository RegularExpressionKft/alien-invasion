Promise = require 'bluebird'
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

###### AlienModel #############################################################

class AlienModel extends AlienCommander
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
    if (tweak = options?.tweak)?
      specs_ = tweak specs_, parent_ops, options, @

    Op = @Operation
    _.mapValues specs_, (spec, name) -> Op.create spec, parent_ops?[name]

  constructor: (@app, @master, @name) ->
    @bookshelf = @master.bookshelfModule()
    @bookshelfModel = @bookshelf.model @name, @_makeBookshelf()
    @_inflateIdObjects()
    @_init()
    @

  _init: -> null

  error404: (s, op) -> Mci.promiseError status: 404

  make404: (s, op, exception) ->
    (error) =>
      if error instanceof exception
        @error404 s, op
      else
        throw error

# ==== Composite Id ===========================================================

  idFields: ['id']
  parentIdFields: null

  _inflateIdObjects: ->
    for k in [ 'idFields', 'parentIdFields' ]
      @["#{k}AsObject"] = true_object @[k] if @[k]?
    @

  extractId: (s, obj) -> obj.pick @idFields

# ==== Bookshelf ==============================================================
# All parameters checked, safe

  @_bookshelfConfig = {}

  @setBookshelfConfig: (cfg) ->
    unless @hasOwnProperty @_bookshelfConfig
      @_bookshelfConfig = Object.create @_bookshelfConfig
    _.extend @_bookshelfConfig, cfg
    @

  getBookshelfConfig: ->
    _.defaultsDeep {},
      @_getBookshelfRelations(),
      @constructor._bookshelfConfig,
      @master.config 'bookshelfConfig'

  _makeBookshelf: ->
    @bookshelf.Model.extend @getBookshelfConfig()

  defaultDbOptions: (s, op, db_op) ->
    db_options = {}
    db_options.transacting = s.transaction if s.transaction?
    if (wr = op?.options.withRelated)? and
       (!db_op? or db_op.match /^select/)
      db_options.withRelated = wr
    Promise.resolve db_options

  dbOptions: (s, op, db_op, p_db_options) ->
    if p_db_options?
      Promise.join p_db_options, (db_options) =>
        if db_options.alienNoDefaults
          db_options
        else
          @opHook 'dbOptions', s, op, db_op
          .then (defs) -> _.defaults alienNoDefaults: true, db_options, defs
    else
      @opHook 'dbOptions', s, op, db_op

# ---- Relations --------------------------------------------------------------

  # @relations = {}

  @_initRelation: (type, rel_name, model_name) ->
    @relations = {} unless @hasOwnProperty 'relations'
    @relations[rel_name] =
      name: rel_name
      modelName: model_name
      type: type
    @

  @belongsTo: (rel_name, model_name) ->
    @_initRelation 'belongsTo', rel_name, model_name

  @hasMany: (rel_name, model_name) ->
    @_initRelation 'hasMany', rel_name, model_name

  # TODO inherited relations
  _getBookshelfRelations: ->
    bookshelf = @bookshelf
    _.mapValues @constructor.relations, (rel) ->
      -> @[rel.type] bookshelf.model rel.modelName

# ---- Loaders ----------------------------------------------------------------

  _buildLoadManyQuery: (s, op, filters, db_options, qb) ->
    for name, value of filters
      if _.isFunction value
        value.call @, s, op, filters, db_options, qb, name, value
      else if _.isArray value
        qb.where name, 'in', value
      else if _.isObject value
        qb.where name, operator, argument for operator, argument of value
      else
        qb.where name, value
    # s.debug "#{@name} SQL", qb.toString()
    null

  promiseLoadedDbObjects: (s, op, p_filters, p_db_options) ->
    p_filters ?= op.promise s, 'filters' if op?
    p_db_options = @dbOptions s, op, 'select-many', p_db_options
    Promise.join p_filters, p_db_options,
      (filters, db_options) =>
        @bookshelfModel.query (qb) =>
                         @_buildLoadManyQuery s, op, filters, db_options, qb
                       .fetchAll db_options

  promiseLoadedDbObject: (s, op, p_id, p_db_options) ->
    p_id ?= op.promise s, 'id' if op?
    p_db_options = @dbOptions s, op, 'select-one', p_db_options
    Promise.join p_id, p_db_options,
      (id, db_options) =>
        @bookshelfModel.query (qb) =>
                         qb.where id
                           .limit 2
                       .fetchAll db_options
                       .then (objs) =>
                         if objs?.length > 0
                           if objs.length < 2
                             objs.at 0
                           else
                             throw new Error \
                               "Expected one object, got many " +
                               "(model: #{@name})"
                         else
                           @error404 s, op

  _maybeRefreshedDbObject: (s, op, db_op, parent_db_options, p) ->
    refresh = parent_db_options.alienRefresh
    if db_op == 'update-direct'
      refresh ?= parent_db_options.alienLoadOrRefresh
    refresh ?= true

    if refresh
      p_db_options = @dbOptions s, op, "#{db_op}.refresh",
        parent_db_options.alienRefreshOptions ?
          parent_db_options.alienLoadOrRefreshOptions
      Promise.join p, p_db_options, (obj, db_options) ->
        obj.refresh db_options
    else
      p

# ---- Create -----------------------------------------------------------------

  promiseCreatedDbObject: (s, op, p_properties, p_db_options) ->
    db_op = 'insert'
    p_properties ?= op.promise s, 'properties' if op?
    p_db_options = @dbOptions s, op, db_op, p_db_options
    Promise.join p_properties, p_db_options,
      (properties, db_options) =>
        # s.debug "#{@name}.promiseCreatedDbObject:pre", properties
        @_maybeRefreshedDbObject s, op, db_op, db_options,
          @bookshelfModel.forge properties
                         .save null, _.extend method: 'insert', db_options
        # .then (obj) =>
        #   s.debug "#{@name}.promiseCreatedDbObject:post",
        #     obj.toJSON()
        #   obj

# ---- Update -----------------------------------------------------------------

  # TODO/BUG composite key unsafe
  # Not really fixable until bookshelf is fixed.
  promiseSavedDbObject: (s, op, p_db_object, p_db_options) ->
    db_op = 'update-loaded'
    @dbOptions s, op, db_op, p_db_options
    .then (db_options) =>
      @_maybeRefreshedDbObject s, op, db_op, db_options,
        Promise.join p_db_object,
          (db_object) =>
            db_options_ = _.extend require: true, db_options
            if !db_object.isNew() and (db_options_.patch ?= true)
              save = _.filter db_object.keys(), (k) -> db_object.hasChanged k
              save = @bookshelfModel.idAttribute unless save.length > 0
              save = db_object.pick save
            else
              save = null
            # s.debug "#{@name}.promiseSavedDbObject", db_object
            db_object.save save, db_options_
                     .catch @make404 s, op, @bookshelfModel.NoRowsUpdatedError

  _directUpdateDbObject: (s, op, p_id, p_properties, p_db_options) ->
    db_op = 'update-direct'
    @dbOptions s, op, db_op, p_db_options
    .then (db_options) =>
      @_maybeRefreshedDbObject s, op, db_op, db_options,
        Promise.join p_id, p_properties,
          (id, properties) =>
            # s.debug "#{@name}.promiseUpdatedDbObject",
            #   id: id,
            #   properties: properties
            @bookshelfModel.forge id
                           .save properties, _.extend
                               patch: true
                               require: true
                             , db_options
                           .catch @make404 s, op,
                             @bookshelfModel.NoRowsUpdatedError

  _loadUpdateDbObject: (s, op, p_id, p_properties, p_db_options) ->
    @dbOptions s, op, 'update-loaded', p_db_options
    .then (db_options) =>
      p_obj = @promiseLoadedDbObject s, op, p_id,
                db_options.alienLoadOptions ?
                  db_options.alienLoadOrRefreshOptions
      p_obj = Promise.join p_obj, p_properties,
        (obj, properties) -> obj.set properties
      @promiseSavedDbObject s, op, p_obj, db_options

  promiseUpdatedDbObject: (s, op, p_id, p_properties, p_db_options) ->
    if op?
      p_id ?= op.promise s, 'id'
      p_properties ?= op.promise s, 'properties'
    if @idFields.length > 1
      @_loadUpdateDbObject s, op, p_id, p_properties, p_db_options
    else
      @_directUpdateDbObject s, op, p_id, p_properties, p_db_options

  promiseDeletedDbObject: (s, op, p_id, p_db_options) ->
    p_id ?= op.promise s, 'id' if op?
    p_db_options = @dbOptions s, op, 'delete', p_db_options
    Promise.join p_id, p_db_options,
      (id, db_options) =>
        # s.debug "#{@name}.promiseDeletedDbObject", id
        @bookshelfModel.where id
                       .destroy _.extend require: true, db_options
                       .catch @make404 s, op,
                         @bookshelfModel.NoRowsDeletedError

# ==== Hooks ==================================================================

  hooks: @commands
      check: 'defaultCheck'
      dbOptions: 'defaultDbOptions'
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
    @opHook 'action', s, op
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
    checkers = rest[1]?.hooks
    checkers = @checkers unless hooks?.has? what
    checkers.apply what, @, rest

  # TODO
  promiseCheckedId: (s, op, p_unsafe_id, unsafe_ps, what, loc) ->
    p_unsafe_id.then (unsafe_id) =>
      for k, v of unsafe_id
        unless @idFieldsAsObject[k] and _.isString v
          loc ?= op?.options.loc
          return Mci.promiseError
            status: 400
            type: 'json'
            body:
              code: 'bad_value'
              fld: if loc? then "#{loc}.#{k}" else k
      for k in @idFields
        unless unsafe_id[k]?
          loc ?= op?.options.loc
          return Mci.promiseError
            status: 400
            type: 'json'
            body:
              code: 'missing_param'
              fld: if loc? then "#{loc}.#{k}" else k
      unsafe_id

  # TODO
  promiseCheckedFilters: (s, op, p_unsafe_filters, unsafe_ps, what, loc) ->
    Promise.resolve {}

  # TODO
  promiseCheckedProperties: (s, op, p_unsafe_props, unsafe_ps, what, loc) ->
    p_unsafe_props

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

  # bookshelf.relations is undocumented / private
  defaultJsonObject: (s, op, result, context) ->
    if result?.toJSON?
      opts =
        alienModel: @
        alienStash: s
        alienOp: op
        alienContext: context
      my_rels = @constructor.relations
      res_rels = result.relations ? {}
      if _.keys(res_rels).some((r) -> my_rels[r]?)
        ret_rel_ps = {}
        ret = result.toJSON _.extend shallow: true, opts
        for n, v of res_rels
          ret_rel_ps[n] = if my_rels[n]?
            rel_model = @master.model my_rels[n].modelName
            rel_model.foreignJson s, op, (result.related n), context
          else
            v.toJSON opts
        Promise.props ret_rel_ps
               .then (ret_rels) ->
                 ret[n] = v for n, v of ret_rels when v? and !_.isEmpty v
                 ret
      else
        Promise.resolve result.toJSON opts
    else
      Promise.resolve result

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
    Promise.resolve @opHook 'json', s, op, result, 'response'
           .then (json) =>
             Mci.jsonResponse op.responseStatus ? 200, json

  # bsmc: bookshelf model or collection
  foreignJson: (s, xop, bsmc, xcontext) ->
    model_name = xop?.model?.name ? 'foreignModel'
    @opHook 'json', s, null, bsmc, "#{model_name}.#{xcontext}"

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
        @opHook 'json', s, op, result, 'event'
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

  ops: @makeOps null,
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

  opReadAction: (s, op, id, db_options) ->
    p = @promiseLoadedDbObject s, op,
      (id ? op.promise s, 'id'),
      db_options
    if op?
      p.then (obj) ->
        op.addCached 'object', obj
        obj
    else
      p

  opListAction: (s, op, filters, db_options) ->
    @promiseLoadedDbObjects s, op,
      (filters ? op.promise s, 'filters'),
      db_options

  opCreateAction: (s, op, properties, db_options) ->
    p = @promiseCreatedDbObject s, op,
      (properties ? op.promise s, 'properties'),
      db_options
    if op?
      p.then (obj) =>
        op.setValue s, 'id', @extractId s, obj
        op.setCached s, 'object', obj
        obj
    else
      p

  opUpdateAction: (s, op, id, properties, db_options) ->
    p = @promiseUpdatedDbObject s, op,
      (id ? op.promise s, 'id'),
      (properties ? op.promise s, 'properties'),
      db_options
    if op?
      p.then (obj) ->
        op.setCached s, 'object', obj
        obj
    else
      p

  # TODO cache?
  opDeleteAction: (s, op, id, db_options) ->
    @promiseDeletedDbObject s, op,
      (id ? op.promise s, 'id'),
      db_options

module.exports = AlienModel
