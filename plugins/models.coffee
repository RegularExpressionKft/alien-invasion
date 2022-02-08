Promise = require 'bluebird'
require_source = require 'alien-utils/require-sources'
assert = require 'assert'
_ = require 'lodash'

AlienPlugin = require '../plugin'

class AlienModelLoader extends AlienPlugin
  defaultConfig:
    bookshelfModule: 'bookshelf'
    bookshelfConfig:
      idAttribute: 'id'
    dir: "#{process.cwd()}/Models"

  _init: ->
    config = @config()
    @modelMakers = require_source
      dirname: config.dir
    @models = _.mapValues @modelMakers,
      (Cls, name) => new Cls @app, @, name
    @_alive = true
    null

  start: ->
    @_alive = true
    null

  stop: ->
    @_alive = false
    null

  model: (model_name) -> @models[model_name]

  bookshelfModule: ->
    @bookshelf ?= @app.module @config 'bookshelfModule'

  transaction: (s, cb) ->
    assert @_alive, 'alive'

    if (my_stash = _.isFunction(s) and !cb?)
      cb = s
      s = @app.makeStash()
    cb = Promise.method cb

    s.transaction_seq ?= 0
    seq = s.transaction_seq++
    transaction =
      id: "#{s.id}:#{seq}"
      previous: s.transaction

    traceback = new Error 'Transaction traceback'
    rollback_marker = null

    s.emit 'before_begin', transaction
    bookshelf = @bookshelfModule()
    Promise.resolve bookshelf.transaction (trx) ->
      transaction.trx = trx

      s.debug "transaction #{seq} BEGIN"
      s.transaction = transaction
      s.emit 'after_begin', transaction

      cb(s).then \
        ((result) ->
           transaction.resolve = result

           if transaction.rollback
             transaction.commit = false

             s.debug "transaction #{seq} will ROLLBACK (resolve)"
             s.emit 'before_rollback', transaction
             s.emit 'before_end', transaction

             Promise.reject rollback_marker = new Error 'rollback_marker'
           else
             transaction.commit = true

             s.debug "transaction #{seq} will COMMIT"
             s.emit 'before_commit', transaction
             s.emit 'before_end', transaction

             transaction.result),
        ((error) ->
           transaction.reject = error

           if transaction.commit
             transaction.rollback = false

             s.debug "transaction #{seq} will COMMIT (reject)"
             s.emit 'before_commit', transaction
             s.emit 'before_end', transaction

             null
           else
             transaction.rollback = true

             s.debug "transaction #{seq} will ROLLBACK"
             s.emit 'before_rollback', transaction
             s.emit 'before_end', transaction

             Promise.reject error)
    .then \
      ((_result) ->
        s.transaction = transaction.previous if s.transaction == transaction

        s.debug "transaction #{seq} did COMMIT"
        s.emit 'after_commit', transaction
        s.emit 'after_end', transaction

        if my_stash
          if transaction.reject?
            s.emit 'error', transaction.reject if s.listenerCount('error') > 0
          else
            s.emit 'success', transaction.resolve

        if _.isFunction transaction.chain
          transaction.chain transaction
        else if transaction.reject?
          Promise.reject transaction.reject
        else
          transaction.resolve),
      ((error) ->
        s.transaction = transaction.previous if s.transaction == transaction

        if (transaction.reject? and error == transaction.reject) or
           (rollback_marker? and error == rollback_marker)
          s.debug "transaction #{seq} did ROLLBACK"
        else
          s.warn "transaction #{seq} did ROLLBACK: #{error}", error
        s.emit 'after_rollback', transaction
        s.emit 'after_end', transaction

        if my_stash
          if transaction.reject?
            s.emit 'error', transaction.reject if s.listenerCount('error') > 0
          else
            s.emit 'success', transaction.resolve

        if _.isFunction transaction.chain
          transaction.chain transaction
        else if transaction.reject?
          s.debug 'Transaction rejection traceback:', traceback
          Promise.reject transaction.reject
        else
          transaction.resolve)

  getKnex: (s) ->
    s?.transaction?.trx ? @bookshelfModule().knex

  knexRaw: (s, sql...) ->
    Promise.resolve(
      @getKnex s
      .raw sql...)

  rawSql: (sql...) ->
    @bookshelfModule().knex.raw sql...

module.exports = AlienModelLoader
