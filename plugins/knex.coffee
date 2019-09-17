Knex = require 'knex'

default_config =
  client     : 'pg'
  connection :
    host     : '127.0.0.1'
    user     : 'testuser'
#   password : ''
    database : 'testdb'
    charset  : 'utf8'

module.exports = (app, module_name, cfgs...) ->
  app.configureModule module_name, default_config, cfgs...

  knex = Knex app.config[module_name]
  app.patch 'stop', 'knex', -> knex.destroy()

  knex
