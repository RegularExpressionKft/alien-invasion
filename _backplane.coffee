_ = require 'lodash'

class AlienBackplane
  constructor: (@app) ->
    # @endpoints[endpoint_id] =
    #   id: 'uniqueString'
    #   channels:
    #     channel_id: @channels[channel_id]
    @endpoints = Object.create null

    # @channels[channel_id] =
    #   endpoint_id: @endpoints[endpoint_id]
    @channels = Object.create null

  _unsubscribe: (channel_id, endpoint_id) ->
    endpoints = @channels[channel_id]
    delete endpoints[endpoint_id]
    delete @channels[c] if _.isEmpty endpoints
    null

  register: (endpoint_id, cb) ->
    if @endpoints[endpoint_id]?
      throw new Error "Duplicate endpoint: #{endpoint_id}"
    @endpoints[endpoint_id] =
      id: endpoint_id
      cb: cb
      channels: Object.create null
    @
  unregister: (endpoint_id) ->
    if @endpoints[endpoint_id]?
      for channel_id, channel of @endpoints[endpoint_id].channels
        delete channel[endpoint_id]
        delete @channels[channel_id] if _.isEmpty channel
      delete @endpoints[endpoint_id]
    @

  subscribe: (endpoint_id, channel_ids...) ->
    subscribed = []
    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"
    for channel_id in _.flatten channel_ids
      unless endpoint.channels[channel_id]?
        channel = @channels[channel_id] ?= {}
        channel[endpoint_id] = endpoint
        endpoint.channels[channel_id] = channel
        subscribed.push channel_id
    subscribed
  unsubscribe: (endpoint_id, channel_ids...) ->
    unsubscribed = []
    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"
    channels = endpoint.channels
    for channel_id in _.flatten channel_ids
      channel = channels[channel_id]
      if channel?
        delete channels[channel_id]
        delete channel[endpoint_id]
        delete @channels[channel_id] if _.isEmpty channel
        unsubscribed.push channel_id
    unsubscribed
  unsubscribeAll: (endpoint_id) ->
    unsubscribed = []
    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"
    channels = endpoint.channels
    for channel_id in _.keys channels
      channel = channels[channel_id]
      if channel?
        delete channels[channel_id]
        delete channel[endpoint_id]
        delete @channels[channel_id] if _.isEmpty channel
        unsubscribed.push channel_id
    unsubscribed
  listSubscriptions: (endpoint_id) ->
    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"
    _.keys endpoint.channels

  publish: (channel_ids, args...) ->
    channel_ids = [ channel_ids ] unless _.isArray channel_ids
    for channel_id in channel_ids
      for endpoint_id, endpoint of @channels[channel_id]
        try
          endpoint.cb arguments...
        catch error
          @app.error "Backplane #{endpoint_id} exception:", error
    null

module.exports = AlienBackplane
