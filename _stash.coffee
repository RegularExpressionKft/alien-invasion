EventEmitter = require 'events'
_ = require 'lodash'

class AlienStash extends EventEmitter
  constructor: (args...) ->
    if args.length > 0
      args.unshift @
      _.extend.apply _, args
    else
      @

  queueRealtimeEvent: (args...) ->
    @queuedRealtimeEvents ?= []
    @queuedRealtimeEvents.push args
    @
  submitRealtimeEvents: ->
    # TODO @app?
    if @queuedRealtimeEvents?
      for e in @queuedRealtimeEvents
        @app.publish e
      delete @queuedRealtimeEvents
    @

# AlienStash.create = (args...) ->
#   args.unshift @
#   new (Function.prototype.bind.apply @, args)
AlienStash.create = ->
  obj = Object.create @::
  @apply obj, arguments
  obj

module.exports = AlienStash
