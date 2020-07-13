Promise = require 'bluebird'
_ = require 'lodash'

AlienModelBase = require './model-base'

###### AlienDbModel ###########################################################

class AlienDbModel extends AlienModelBase
  _init: ->
    ret = super
    @bookshelf = @master.bookshelfModule()
    @bookshelfModel = @bookshelf.model @name, @_makeBookshelf()
    ret

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
    db_options.transacting = s.transaction.trx if s.transaction?
    if (wr = op?.options.withRelated)? and
       (!db_op? or db_op.match /select|refresh/)
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

  getKnex: (s) ->
    s?.transaction?.trx ? @bookshelf.knex

  knex: (s) ->
    knex = @getKnex s
    knex @getBookshelfConfig().tableName

# ---- Relations --------------------------------------------------------------

  # TODO inherited relations
  _getBookshelfRelations: ->
    bookshelf = @bookshelf
    _.mapValues @constructor.relations, (rel) ->
      ->
        if rel.type is 'belongsToMany'
          @[rel.type] bookshelf.model(rel.modelName), rel.joinTableName
        else
          @[rel.type] bookshelf.model(rel.modelName)

# ---- Loaders ----------------------------------------------------------------

  _make404: (s, op, exception) ->
    (error) =>
      if error instanceof exception
        @error404 s, op
      else
        throw error

  _buildQuery: (s, op, db_op, filters, db_options, qb) ->
    if _.isObject filters
      for name, value of filters
        if _.isFunction value
          value.call @, s, op, filters, db_options, qb, name, value
        else if _.isArray value
          qb.where name, 'in', value
        else if _.isObject value
          qb.where name, operator, argument for operator, argument of value
        else
          qb.where name, value
    else
      qb.where @idFields[0], filters

    qb.limit 2 if db_op is 'select-one'

    # s.debug "#{@name} SQL", qb.toString()
    qb

  promiseLoadedDbObjects: (s, op, p_filters, p_db_options) ->
    p_filters ?= op.promise s, 'filters' if op?
    p_db_options = @dbOptions s, op, 'select-many', p_db_options
    Promise.join p_filters, p_db_options,
      (filters, db_options) =>
        @bookshelfModel.query (qb) =>
                         @_buildQuery s, op, 'select-many', filters,
                           db_options, qb
                       .fetchAll db_options

  promiseLoadedDbObject: (s, op, p_id, p_db_options) ->
    p_id ?= op.promise s, 'id' if op?
    p_db_options = @dbOptions s, op, 'select-one', p_db_options
    Promise.join p_id, p_db_options,
      (id, db_options) =>
        @bookshelfModel.query (qb) =>
                         @_buildQuery s, op, 'select-one', id, db_options, qb
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
            p = if !db_object.isNew() and (db_options_.patch ?= true)
                save = _.filter _.keys(db_object.attributes), (k) -> db_object.hasChanged k
                if save.length
                  db_object.save db_object.pick(save), db_options_
                else
                  Promise.resolve db_object
              else
                db_object.save null, db_options_
            p.catch @_make404 s, op, @bookshelfModel.NoRowsUpdatedError

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
                           .catch @_make404 s, op,
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
    p_db_options = @dbOptions s, op, 'delete-one', p_db_options
    Promise.join p_id, p_db_options,
      (id, db_options) =>
        # s.debug "#{@name}.promiseDeletedDbObject", id
        @bookshelfModel.query (qb) =>
                         @_buildQuery s, op, 'delete-one', id, db_options, qb
                       .destroy _.extend require: true, db_options
                       .catch @_make404 s, op,
                         @bookshelfModel.NoRowsDeletedError

  promiseDeletedDbObjects: (s, op, p_filters, p_db_options) ->
    p_filters ?= op.promise s, 'filters' if op?
    p_db_options = @dbOptions s, op, 'delete-many', p_db_options
    Promise.join p_filters, p_db_options,
      (filters, db_options) =>
        @bookshelfModel.query (qb) =>
                         @_buildQuery s, op, 'delete-many', filters,
                           db_options, qb
                       .destroy db_options

# ==== Hooks ==================================================================

  hooks: @::hooks.derive dbOptions: 'defaultDbOptions'

# ==== Responses ==============================================================

  _mapRelationships: (json, fn) ->
    rels = @constructor.relations
    rel_keys = _.keys rels
    map_obj = (obj) ->
      if _.isObject(obj) and
         (rel_keys = rel_keys.filter (k) -> _.has obj, k).length > 0
        obj_ = _.omit obj, rel_keys
        for k in rel_keys
          v = fn k, rels[k], obj[k], obj
          obj_[k] = v if v?
        Promise.props obj_
      else
        Promise.resolve obj

    if _.isArray json
      Promise.map json, map_obj
    else
      map_obj json

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
        Promise.resolve @foreignContext s, op, context
        .then (foreign_context) =>
          for n, v of res_rels
            ret_rel_ps[n] = if my_rels[n]?
              rel_model = @master.model my_rels[n].modelName
              rel_model.foreignJson s, (result.related n), foreign_context
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

  foreignContext: (s, op, context) ->
    "#{@name}#{if op? then ":#{op.name}" else ''}.#{context}"

  # bsmc: bookshelf model or collection
  foreignJson: (s, bsmc, context) ->
    @opHook 'json', s, null, bsmc, context

  _jsonObjectAccessFilter: (s, json_in, context, _vars) ->
    super.then (json_super) =>
      master = @master
      @_mapRelationships json_super, (rel_name, rel, orig_value) ->
        RelModel = master.model rel.modelName
        RelModel.foreignAccessFilter s, orig_value, context

  foreignAccessFilter: (s, json, context) ->
    @jsonAccessFilter s, json, context

# ==== Ops ====================================================================

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

  # ops: @makeOps @::ops, @defaultOps
  # ops: @makeOps @::ops, _.pickBy @defaultOps, (op) => @::[op.action]?
  @addDefaultOps()

module.exports = AlienDbModel
