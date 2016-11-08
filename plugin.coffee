AlienCommander = require 'alien-utils/commander'
_ = require 'lodash'

class AlienPlugin extends AlienCommander
  constructor: (@app, @moduleName, cfgs...) ->
    @app.decorateWithNewLogger @, @moduleName

    _.defaultsDeep @defaultConfig, @constructor.defaultConfig
    @app.configureModule @moduleName, @defaultConfig, cfgs...

    @_init()

    ['start', 'stop'].forEach (event) =>
      if _.isFunction @[event]
        @app.on event, => @[event].apply @, arguments
      null

    @

  _init: -> null

  config: (cfg_path) ->
    cfg = @app.config[@moduleName]
    if cfg_path? then _.get cfg, cfg_path else cfg

AlienPlugin.alienInit = ->
  obj = Object.create @::
  @apply obj, arguments
  obj

module.exports = AlienPlugin
