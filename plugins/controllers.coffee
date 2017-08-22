require_all = require 'require-all'
_ = require 'lodash'

AlienPlugin = require '../plugin'

class AlienControllerLoader extends AlienPlugin
  defaultConfig:
    dir: "#{process.cwd()}/Controllers"
    filter: /^([0-9A-Za-z].*?)\.(?:js|coffee)$/
    # TODO
    # transportModules: ['express', 'realtime-ws']
    transportModules: ['express']
    modelModule: 'models'

  _init: ->
    config = @config()
    @controllerClasses = require_all
      dirname: config.dir
      filter: config.filter
      recursive: true
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
