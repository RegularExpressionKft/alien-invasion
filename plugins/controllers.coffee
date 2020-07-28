fs = require 'fs'
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
    @controllerClasses = {}
    fs.readdirSync(config.dir).forEach (file) =>
      if !fs.statSync("#{config.dir}/#{file}").isDirectory() &&
         file.match /\.(js|coffee)$/
        basename = file.replace /\.[^.]+$/, ''
        @controllerClasses[basename] ?= require "#{config.dir}/#{basename}"

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
