Promise = require 'bluebird'
assert = require 'assert'
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

  register: (endpoint_id, cb) ->
    if @endpoints[endpoint_id]?
      throw new Error "Duplicate endpoint: #{endpoint_id}"
    @endpoints[endpoint_id] =
      id: endpoint_id
      cb: cb
      channels: Object.create null
    @
  unregister: (endpoint_id) ->
    federate_unsubscribe = []
    if @endpoints[endpoint_id]?
      for channel_id, channel of @endpoints[endpoint_id].channels
        delete channel[endpoint_id]
        if _.isEmpty channel
          federate_unsubscribe.push channel_id
          delete @channels[channel_id]
      delete @endpoints[endpoint_id]

      unless _.isEmpty federate_unsubscribe
        @federate_unsubscribe federate_unsubscribe
    @

  subscribe: (endpoint_id, channel_ids...) ->
    subscribed = []
    federate_subscribe = []

    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"

    for channel_id in _.flatten channel_ids
      unless endpoint.channels[channel_id]?
        federate_subscribe.push channel_id unless @channels[channel_id]?
        channel = @channels[channel_id] ?= {}
        channel[endpoint_id] = endpoint
        endpoint.channels[channel_id] = channel
        subscribed.push channel_id

    unless _.isEmpty federate_subscribe
      @federate_subscribe federate_subscribe

    subscribed

  promiseSubscribe: (endpoint_id, channel_ids...) ->
    subscribed = []
    federate_subscribe = []

    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"

    for channel_id in _.flatten channel_ids
      unless endpoint.channels[channel_id]?
        federate_subscribe.push channel_id unless @channels[channel_id]?
        channel = @channels[channel_id] ?= {}
        channel[endpoint_id] = endpoint
        endpoint.channels[channel_id] = channel
        subscribed.push channel_id

    if _.isEmpty federate_subscribe
      Promise.resolve subscribed
    else
      @federate_subscribe federate_subscribe, subscribed

  unsubscribe: (endpoint_id, channel_ids...) ->
    unsubscribed = []
    federate_unsubscribe = []

    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"

    channels = endpoint.channels
    for channel_id in _.flatten channel_ids
      channel = channels[channel_id]
      if channel?
        delete channels[channel_id]
        delete channel[endpoint_id]
        if _.isEmpty channel
          federate_unsubscribe.push channel_id
          delete @channels[channel_id]
        unsubscribed.push channel_id

    unless _.isEmpty federate_unsubscribe
      @federate_unsubscribe federate_unsubscribe

    unsubscribed

  unsubscribeAll: (endpoint_id) ->
    unsubscribed = []
    federate_unsubscribe = []

    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"

    channels = endpoint.channels
    for channel_id in _.keys channels
      channel = channels[channel_id]
      if channel?
        delete channels[channel_id]
        delete channel[endpoint_id]
        if _.isEmpty channel
          federate_unsubscribe.push channel_id
          delete @channels[channel_id]
        unsubscribed.push channel_id

    unless _.isEmpty federate_unsubscribe
      @federate_unsubscribe federate_unsubscribe

    unsubscribed

  listSubscriptions: (endpoint_id) ->
    endpoint = @endpoints[endpoint_id] ?
      throw new Error "Unknown endpoint: #{endpoint_id}"
    _.keys endpoint.channels

  federate_in: (channel_ids, messages) ->
    for channel_id in channel_ids
      for endpoint_id, endpoint of @channels[channel_id]
        try
          endpoint.cb channel_id, messages...
        catch error
          @app.error "Backplane #{endpoint_id} exception:", error
    null

  publish: (channel_ids, messages...) ->
    channel_ids = [ channel_ids ] unless _.isArray channel_ids
    if @federate_out channel_ids, messages
      null
    else
      @federate_in channel_ids, messages

  # override me
  federate_out: (channel_ids, messages) -> null
  federate_subscribe: (channel_ids, subscribed) -> Promise.resolve subscribed
  federate_unsubscribe: (channel_ids, unsubscribed) -> Promise.resolve unsubscribed

module.exports = AlienBackplane
