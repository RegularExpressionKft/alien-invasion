webpack = require 'webpack'
webpack_config = require "#{process.cwd()}/webpack-config"

AlienPlugin = require '../plugin'

class WebpackCompiler extends AlienPlugin
  defaultConfig:
    watch: aggregateTimeout: 300

    compiler:
      colors : true
      chunks : false

  _init: ->
    config = @config 'webpack'
    webpack_compiler = webpack webpack_config

    @debug 'Starting watch...'

    webpack_compiler.watch @config('watch'), (err, stats) =>
      if err
        @error err
      else
        stats_json = stats.toJson()

        if stats_json.errors.length
          @error stats_json.errors
        else
          @warn stats_json.warnings if stats_json.warnings.length
          @info 'Compilation successful',
            stats.toString @config 'compiler'

module.exports = WebpackCompiler
