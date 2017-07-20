Promise = require 'bluebird'
methods = require 'methods'
assert = require 'assert'
_ = require 'lodash'

WebSocket = require 'ws'
supertest = require 'supertest'
request = require 'superagent'

AlienInvasion = require './index.coffee'
AlienWsClient = require 'alien-utils/ws-client'

map_to_object = (list, fn) ->
  ret = {}
  ret[i] = fn i for i in list
  ret

run_before_after = (obj) ->
  if obj.before?
    before ->
      obj.state ?= {}
      unless obj.state.beforeRun
        obj.state.beforeRun = true
        obj.state.beforeValue = obj.before @, arguments...
      obj.state.beforeValue
  if obj.after?
    after ->
      obj.state ?= {}
      unless obj.state.afterRun
        obj.state.afterRun = true
        obj.state.afterValue = obj.after @, arguments...
      obj.state.afterValue
  obj

class AlienTestUtils
  @initialize: -> run_before_after @

  constructor: ->
    @constructor.initialize()
    _.defaults @, arguments...
    run_before_after @

  # ---- mocha generic parts above / alien specific parts below ----

  # TODO make this more extensible, configurable
  @makeApp: (test) ->
    test.timeout 10000
    (new AlienInvasion mode: 'test')
    .with 'controllers'
    .with 'realtime-ws'

  @startApp: (app, test) -> app.start()

  @_prepareVars: (test) ->
    app: @app
    port: p = @app.config.express.port
    baseUrl: b = "http://localhost:#{p}"
    wsBaseUrl: ws = b.replace 'http', 'ws'
    rootUrl: "#{b}/"
    realtimeUrl: "#{ws}/realtime"
    webrtcUrl: "#{b}/janus"

  @before: (test) ->
    @app = @makeApp test
    _.defaults @::, @_prepareVars test
    @startApp @app, test
    null

  @after: ->
    @app.stop()
    null

  before: (test) ->
    Promise.join @_makeTestAgent(test), @_makeAgent(test),
      (test_agent, agent) =>
        @server ?= test_agent
        @request ?= agent
        null

  _makeTestAgent: (test) ->
    @testAgent = supertest.agent @baseUrl
    map_to_object methods, (m) => @_testRequest.bind @, m
  _testRequest: (method, args...) -> @testAgent[method] args...

  _makeAgent: (test) ->
    @agent = request
    map_to_object methods, (m) => @_request.bind @, m
  _request: (method, args...) -> @agent[method] args...

  extractResult: (res) -> res.body

  cmpSuperObj: (got, expected) ->
    !_.find _.keys(expected), (k) -> !_.isEqual got[k], expected[k]
  assertSuperObj: (got, expected) ->
    missed = _.filter _.keys(expected), (k) -> !_.isEqual got[k], expected[k]
    assert.equal missed.length, 0, "Missing/bad keys: #{missed.join(', ')}"
  superObj: (expected) ->
    (res) => @assertSuperObj (@extractResult res), expected

  filterSuperObj: (got_list, expected) ->
    if _.isArray got_list
      _.filter got_list, (item, index, coll) =>
        @cmpSuperObj item, expected
    else
      []

  includesSuperObj: (expected) ->
    (res) =>
      matching = @filterSuperObj (@extractResult res), expected
      assert (matching.length <= 1), "Many superobjects"
      assert (matching.length > 0), "No superobjects"
  notIncludesSuperObj: (expected) ->
    (res) =>
      matching = @filterSuperObj (@extractResult res), expected
      assert.equal matching.length, 0, "Has superobjects"

  promiseWs: Promise.method (p) ->
    p = _.extend
        WebSocket: AlienWsClient
        url: @realtimeUrl
        debug: true
        name: 'CLIENT'
      , p
    ws = if p.url? then new WebSocket p.url, p.protocols else null
    if p.WebSocket?
      ws = new p.WebSocket ws, p.reset
      @app.decorateWithNewLogger ws, p.name if p.debug?
    ws

  wsPromise: (p, cb) ->
    # wsPromise cb
    if !cb? and _.isFunction p
      cb = p
      p = null
    @promiseWs p
    .then (ws) ->
      new Promise (resolve, reject) -> cb ws, resolve, reject
      .finally ->
        ws?.terminate()
        ws = null

  simpleActionEvent: (p, cb) ->
    if !cb? and _.isFunction p
      cb = p
      p = null
    @wsPromise p, (ws, resolve, reject) ->
      ws.on 'fail', reject
      if p.event?
        ws.on 'event', (msg) ->
          try
            assert _.isString(msg.channel), 'event has channel'
            assert msg.data?, 'event has data'
            p.event ws, resolve, reject, msg
          catch error
            reject error
      if p.action?
        event = if p.subscribe? then 'subscribed' else 'wsOpen'
        ws.once event, ->
          try
            p.action ws, resolve, reject
          catch error
            reject error
      ws.subscribe p.subscribe if p.subscribe?
      ws.ignoreBadMessageType = p.ignoreBadMessageType ? true
      if cb?
        cb ws, resolve, reject
      else
        null

module.exports = AlienTestUtils
