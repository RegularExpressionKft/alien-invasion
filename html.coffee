Handlebars = require 'handlebars'
Promise = require 'bluebird'
_ = require 'lodash'
fs = require 'fs'

Mci = require './mci'

Handlebars.registerHelper 'json', JSON.stringify.bind JSON

# TODO Cache templates (monitor changes?)
# TODO Error page
module.exports =
  Handlebars: Handlebars
  renderTemplate: (name, vars, response) ->
    new Promise (resolve, reject) ->
      name += '.html' unless name.match /\.\w{1,5}$/
      fs.readFile "#{process.cwd()}/Templates/#{name}", (error, data) ->
        if error?
          reject error
        else
          try
            template = Handlebars.compile data.toString()
            html = template vars
            resolve Mci.response _.extend
                type: 'html'
                body: html
              , response
          catch e
            reject e
