Promise = require 'bluebird'
CookieJar = require('cookiejar').CookieJar
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
  hooks =
    before: before
    beforeEach: beforeEach
    after: after
    afterEach: afterEach
  _.forEach hooks, (f, n) ->
    k_installed = "#{n}Installed"
    if obj[n]? and !obj.state?[k_installed]
      (obj.state ?= {})[k_installed] = true
      f -> obj[n] @, arguments...
  obj

class AlienTestUtils
  @initialize: ->
    self = @
    run_before_after @

  @beforeEach: (test) ->
    @app?.info "**** BEGIN [#{test.currentTest.fullTitle()}]"

  @afterEach: (test) ->
    @app?.info "**** END [#{test.currentTest.fullTitle()}]"

  constructor: ->
    @constructor.initialize()
    _.defaults @, arguments...
    run_before_after @

  # ---- mocha generic parts above / alien specific parts below ----

  @beforeApp: (cb) ->
    (@_before_app ?= []).push cb
    @

  @_runBeforeApp: (args...) ->
    try
      if @_before_app?
        Promise.all @_before_app.map (i) => i.apply @, args
               .return null
      else
        Promise.resolve()
    catch error
      Promise.reject error

  # TODO make this more extensible, configurable
  @makeApp: (test) ->
    app = (new AlienInvasion mode: 'test')
      .with 'controllers'
      .with 'realtime-ws'
    test.timeout tt if (tt = app.config.test_timeout)?
    app

  @startApp: (app, test) -> app.start()

  @_prepareVars: (test) ->
    app: @app
    port: p = @app.config.express.port
    baseUrl: b = "http://localhost:#{p}"
    wsBaseUrl: ws = b.replace 'http', 'ws'
    rootUrl: "#{b}/"
    realtimeUrl: "#{ws}/realtime"
    webrtcUrl: "#{b}/janus"

  @prepare: (app, test) -> null

  @before: (test) ->
    @_runBeforeApp()
    .then => @makeApp test
    .then (app) =>
      @app = app
      _.defaults @::, @_prepareVars test
      @prepare @app, test
    .then =>
      @startApp @app, test

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

  clearCookies: (from = [ @testAgent, @agent ]) ->
    from = [ from ] unless _.isArray from
    agent?.jar = new CookieJar for agent in from
    @

  extractResult: (res) -> res.body

  localizeError: (error, loc) ->
    if loc?
      if _.isString error
        "#{loc}: #{error}"
      else if _.isObject error
        error.message = "#{loc}: #{error.message}" if _.isString error.message

        if error.loc?
          error.loc = [ loc ].concat error.loc if _.isArray error.loc
        else
          error.loc = [ loc ]

        error
      else
        error
    else
      error

  cmpSuperObj: (got, expected) ->
    !_.find _.keys(expected), (k) -> !_.isEqual got[k], expected[k]
  assertSuperObj: (got, expected, loc) ->
    missed = _.filter _.keys(expected), (k) -> !_.isEqual got[k], expected[k]
    assert.equal missed.length, 0,
      @localizeError "Missing/bad keys: #{missed.join(', ')}", loc
  superObj: (expected, loc) ->
    (res) => @assertSuperObj (@extractResult res), expected, loc

  filterSuperObj: (got_list, expected) ->
    if _.isArray got_list
      _.filter got_list, (item, index, coll) =>
        @cmpSuperObj item, expected
    else
      []

  includesSuperObj: (expected, loc) ->
    (res) =>
      matching = @filterSuperObj (@extractResult res), expected
      assert (matching.length <= 1), @localizeError "Many superobjects", loc
      assert (matching.length > 0), @localizeError "No superobjects", loc
  notIncludesSuperObj: (expected, loc) ->
    (res) =>
      matching = @filterSuperObj (@extractResult res), expected
      assert.equal matching.length, 0, @localizeError "Has superobjects", loc

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
    .then (ws) =>
      new Promise (resolve, reject) =>
        if p?.loc?
          cd ws, resolve, (error) => reject @localizeError error, p.loc
        else
          cb ws, resolve, reject
      .finally ->
        ws?.terminate()
        ws = null

  simpleActionEvent: (p, cb) ->
    if !cb? and _.isFunction p
      cb = p
      p = null
    @wsPromise p, (ws, resolve, reject) =>
      ws.on 'fail', reject
      if p.event?
        ws.on 'event', (msg) =>
          try
            assert _.isString(msg.channel), @localizeError 'Event has channel', p?.loc
            assert msg.data?, @localizeError 'Event has data', p?.loc
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
