Promise = require 'bluebird'
require_all = require 'require-all'
_ = require 'lodash'

AlienPlugin = require '../plugin'

class AlienModelLoader extends AlienPlugin
  defaultConfig:
    bookshelfModule: 'bookshelf'
    bookshelfConfig:
      idAttribute: 'id'
    dir: "#{process.cwd()}/Models"
    filter: /^([0-9A-Za-z].*?)\.(?:js|coffee)$/

  _init: ->
    config = @config()
    @modelMakers = require_all
      dirname: config.dir
      filter: config.filter
      recursive: true
    @models = _.mapValues @modelMakers,
      (Cls, name) => new Cls @app, @, name
    null

  model: (model_name) -> @models[model_name]

  bookshelfModule: -> @app.module @config 'bookshelfModule'

  transaction: (s, cb) ->
    if _.isFunction(s) and !cb?
      cb = s
      s = @app.makeStash()

    error_marker = null
    cb = Promise.method cb
    bookshelf = @bookshelfModule()

    s.emit 'before_begin'
    bookshelf.transaction (trx) ->
               s.debug 'transaction BEGIN'
               s.transaction = trx
               s.emit 'after_begin'
               cb(s).then \
                 ((result) ->
                    s.debug 'transaction will COMMIT'
                    s.emit 'before_commit', result: result
                    s.emit 'before_end', 'commit', result: result
                    result),
                 ((error) ->
                    if s.keep_transaction
                      error_marker = error
                      s.debug 'transaction will COMMIT (failed)'
                      s.emit 'before_commit', error: error
                      s.emit 'before_end', 'commit', error: error
                      null
                    else
                      s.debug 'transaction will ROLLBACK'
                      s.emit 'before_rollback', error: error
                      s.emit 'before_end', 'rollback', error: error
                      Promise.reject error)
    .catch (error) ->
      delete s.transaction
      s.debug 'transaction did ROLLBACK'
      s.emit 'after_rollback', error: error
      s.emit 'after_end', 'rollback', error: error
      Promise.reject error
    .then (result) ->
      delete s.transaction
      if error_marker?
        s.debug 'transaction did COMMIT (failed)'
        s.emit 'after_commit', error: error_marker
        s.emit 'after_end', 'commit', error: error_marker
        Promise.reject error_marker
      else
        s.debug 'transaction did COMMIT'
        s.emit 'after_commit', result: result
        s.emit 'after_end', 'commit', result: result
        result

module.exports = AlienModelLoader
