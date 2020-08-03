require_source = require 'alien-utils/require-sources'
_ = require 'lodash'

AlienPlugin = require '../plugin'

class AlienControllerLoader extends AlienPlugin
  defaultConfig:
    dir: "#{process.cwd()}/Controllers"
    # TODO
    # transportModules: ['express', 'realtime-ws']
    transportModules: ['express']
    modelModule: 'models'

  _init: ->
    config = @config()
    @controllerClasses = require_source
      dirname: config.dir
    @controllers = _.mapValues @controllerClasses,
      (CtrlClass, ctrl_name) =>
        ctrl = Object.create CtrlClass::
        CtrlClass.call ctrl, @app, @, ctrl_name
        ctrl
    null

  controller: (controller_name) -> @controllers[controller_name]

  transportModules: ->
    @app.module m for m in @config 'transportModules'

module.exports = AlienControllerLoader
