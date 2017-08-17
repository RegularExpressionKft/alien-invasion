uuid = require 'uuid'
_ = require 'lodash'

AlienWs = require 'alien-utils/ws-alien'

AlienPlugin = require '../plugin'

# TODO machine readable errors

class AlienRealtimeWsClient extends AlienWs
  constructor: ->
    ret = super
    @active = true
    @app.backplane.register @id, @_onBpEvent
                  .subscribe @id, "RealtimeWs:#{@id}"
    @on e, @_deactivate for e in [ 'wsClosing', 'wsClosed' ]
    return ret

  messageTypes: @::messageTypes.derive
    subscribe: (msg) -> @subscribe @_checkChannels msg
    unsubscribe: (msg) -> @unsubscribe @_checkChannels msg

  subscribe: (channels) ->
    subscribed = @app.backplane.subscribe @id, channels
    @debug 'subscribed', subscribed
    @sendJSON
      type: 'subscribed'
      channels: subscribed
    subscribed

  unsubscribe: (channels) ->
    unsubscribed = @app.backplane.unsubscribe @id, channels
    @debug 'unsubscribed', unsubscribed
    @sendJSON
      type: 'unsubscribed'
      channels: unsubscribed
    unsubscribed

  _deactivate: ->
    if @active
      @active = false
      @app.backplane.unregister @id
      @emit 'close', @
    null

  _onBpEvent: (channel, json) =>
    @sendEvent channel, json

  sendEvent: (channel, json) ->
    # TODO websocket authentication
    # if json.model? and (model = @app.plugin('models').model json.model)?
    #   model.opHook 'accessFilter', TODO.s, TODO.op, json, 'event'
    #        .then (json) =>
    #          @sendJSON
    #            type: 'event'
    #            channel: channel
    #            data: json
    # else
    #   @sendJSON
    #     type: 'event'
    #     channel: channel
    #     data: json
    @sendJSON
      type: 'event'
      channel: channel
      data: json
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
