uuid = require 'uuid'
_ = require 'lodash'

AlienWs = require 'alien-utils/ws-alien'

AlienPlugin = require '../plugin'

# TODO machine readable errors

class AlienRealtimeWsClient extends AlienWs
  constructor: ->
    ret = super
    @active = true
    @_bpId = "RealtimeWs:#{@id}"
    @app.backplane.register @_bpId, @_onBpEvent
                  .subscribe @_bpId, @_bpId
    @on e, @_deactivate for e in [ 'wsClosing', 'wsClosed' ]
    return ret

  messageTypes: @::messageTypes.derive
    subscribe: (msg) -> @subscribe @_checkChannels msg
    unsubscribe: (msg) -> @unsubscribe @_checkChannels msg

  subscribe: (channels) ->
    subscribed = @app.backplane.subscribe @_bpId, channels
    @debug 'subscribed', subscribed
    @sendJSON
      type: 'subscribed'
      channels: subscribed
    subscribed

  unsubscribe: (channels) ->
    unsubscribed = @app.backplane.unsubscribe @_bpId, channels
    @debug 'unsubscribed', unsubscribed
    @sendJSON
      type: 'unsubscribed'
      channels: unsubscribed
    unsubscribed

  _deactivate: ->
    if @active
      @active = false
      @app.backplane.unregister @_bpId
      @emit 'close', @
    null

  _onBpEvent: (channel, msg) =>
    @sendEvent channel, msg

  sendEvent: (channel, msg) ->
    # TODO websocket authentication
    # if msg.model? and (model = @app.plugin('models').model msg.model)?
    #   model.opHook 'accessFilter', TODO.s, TODO.op, msg, 'event'
    #        .then (filtered_msg) =>
    #          if filtered_msg?
    #            @sendJSON
    #              type: 'event'
    #              channel: channel
    #              data: filtered_msg
    # else
    #   @sendJSON
    #     type: 'event'
    #     channel: channel
    #     data: msg
    @sendJSON
      type: 'event'
      channel: channel
      data: msg
    null

  _checkChannels: (msg) ->
    error = if !_.isArray msg.channels or !msg.channels.every _.isString
      'msg.channels should be an array of strings.'
    else if !_.isEmpty _.omit msg, ['type', 'channels']
      'msg should only contain type, channels'

    if error?
      error = new Error error
      error.pkt = msg
      @fail error
    msg.channels

class AlienRealtimeWs extends AlienPlugin
  defaultConfig:
    wsModule: 'ws-server'
    uri: '/realtime'

  Client: AlienRealtimeWsClient

  wsModule: -> @app.module @config 'wsModule'

  _init: ->
    @wsModule().addRoute (@config 'uri'),
      handler: @onServerConnection
      check: @_checkConnection
    null

  _checkConnection: => @checkConnection arguments...

  checkConnection: (path, info) ->
    true

  onServerConnection: (wsc, params) =>
    client = @Client.fromAlienServer @, wsc, params
    @emit 'connect', client
    @sendIdPacket client
    null

  sendIdPacket: (client) ->
    id_packet =
      type: 'server'
      protocol: 'alienWs/0'
      wsId: client.id
    @emit 'assemble_id_packet', id_packet, client
    client.sendJSON id_packet unless _.isEmpty id_packet
    @

module.exports = AlienRealtimeWs
