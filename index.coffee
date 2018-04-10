EventEmitter = require 'events'
_ = require 'lodash'

AlienConfig = require 'alien-utils/config'
AlienLogger = require 'alien-utils/logger'
PluginUtils = require 'alien-utils/plugin-utils'

AlienBackplane = require './_backplane'
AlienStash = require './_stash'

# Duplicated in alien-utils/config
# TODO DRY
optional = (req) ->
  try
    ret = require req
  catch e
    throw e unless (e.code == 'MODULE_NOT_FOUND') &&
                   (("#{e}".indexOf req) >= 0)
  ret

class AlienInvasion extends EventEmitter
  @Backplane: AlienBackplane
  @Logger: AlienLogger
  @Stash: AlienStash

  constructor: (user_config, options) ->
    _.extend @, options
    @_initModules()

    @config = AlienConfig user_config
    @mode = @config.mode

    @_initLogger()
    @_initStash()
    @_initBackplane()

    return @

  # ==== Logger

  _initLogger: ->
    @Logger ?= @constructor.Logger
    logger_config = @config.logger ?= {}
    logger_config.mode ?= @mode
    (@Logger.init logger_config).decorate @
    null

  createLogger: (id) ->
    new @Logger id

  decorateWithNewLogger: (object, id) ->
    (@createLogger id).decorate object

  # ==== Stash

  _initStash: ->
    @Stash = class AppStash extends @constructor.Stash
    @Stash::app = @
    null

  makeStash: ->
    stash = @Stash.create arguments...
    cb = _.once -> @submitRealtimeEvents()
    (stash.logger ? @createLogger stash.id).decorate stash
                                           .on 'after_commit', cb
                                           .on 'success', cb

  # ==== Backplane

  _initBackplane: ->
    @backplane = new @constructor.Backplane @
    null

  publish: (e) ->
    @backplane.publish.apply @backplane,
      if _.isArray e then e else arguments

  # ==== Plugins / Modules

  _initModules: ->
    @plugins = {}
    @modules = {}
    null

  configureModule: (name, def_cfg, user_cfgs...) ->
    c = @config[name] ?= {}
    _.extend c, user_cfgs... if user_cfgs.length > 0
    _.defaultsDeep c, def_cfg if def_cfg?
    c

  loadPlugin: (plugin_name) ->
    @debug? "Loading plugin #{plugin_name}"
    # TODO config path
    (optional "#{process.cwd()}/plugins/#{plugin_name}") ?
      (optional "./plugins/#{plugin_name}") ?
      throw new Error "No plugin: #{plugin_name}"

  _initPlugin: (plugin, args...) ->
    if (_.isObject plugin) && plugin.alienInit?
      if _.isFunction plugin.alienInit
        plugin.alienInit args...
      else
        plugin.alienInit
    else if _.isFunction plugin
      plugin args...
    else
      plugin

  # plugin: (plugin_name, module_name, args...) ->
  plugin: (args...) ->
    plugin_name = args.shift()
    module_name = if _.isString args[0] then args.shift() else plugin_name
    plugin = @plugins[plugin_name] ?= @loadPlugin plugin_name
    @_initPlugin plugin, @, module_name, args...

  # module: (module_name, plugin_name, args...) ->
  module: (module_name, args...) ->
    plugin_name = if _.isString args[0] then args.shift() else module_name
    @modules[module_name] ?=
      @plugin plugin_name, module_name, args...

  with: ->
    @module.apply @, arguments
    @

  # ==== Patch

  patch: PluginUtils::patch
  _pluggableAction: PluginUtils::pluggableAction

  # ==== Events

  # _action: (action, args...) ->
  _action: (action) ->
    @debug "action #{action} begin", _.keys @_patches?[action]
    @_pluggableAction arguments...
    .tap (result) =>
      @emit action, result
      @debug "action #{action} end", result

  start: (args...) -> @_action 'start', args...
  stop: (args...) -> @_action 'stop', args...
  reset: (args...) -> @_action 'reset', args...

module.exports = AlienInvasion
