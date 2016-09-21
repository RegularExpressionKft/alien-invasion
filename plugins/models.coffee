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
    bookshelf = @bookshelfModule()
    bookshelf.transaction (trx) ->
               s.debug 'transaction BEGIN'
               s.transaction = trx
               s.emit 'begin'
               cb s
             .then \
               ((result) ->
                  s.debug 'transaction COMMIT'
                  delete s.transaction
                  s.emit 'commit'
                  result),
               ((error) ->
                  s.debug 'transaction ROLLBACK'
                  delete s.transaction
                  s.emit 'rollback'
                  Promise.reject error)

module.exports = AlienModelLoader
