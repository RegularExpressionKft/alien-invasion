Bookshelf = require 'bookshelf'

default_config =
  knexModule: 'knex'

module.exports = (app, module_name, cfgs...) ->
  app.configureModule module_name, default_config, cfgs...
  Bookshelf app.module app.config[module_name].knexModule
