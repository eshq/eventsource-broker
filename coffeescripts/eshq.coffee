scripts    = document.getElementsByTagName('script')
channels   = {}

if window.ESHQ_ORIGIN?
  origin = window.ESHQ_ORIGIN
else
  eshqScript = scripts[scripts.length - 1]
  origin     = eshqScript.src.replace(/\/es.js/, '')

unless window.addEventListener?
  window.addEventListener = (name, fn) -> window.attachEvent("on" + name, fn)

# Object.keys polyfill - https://gist.github.com/1034464
`Object.keys=Object.keys||function(o,k,r){r=[];for(k in o)r.hasOwnProperty.call(o,k)&&r.push(k);return r}`

ajaxPost = (options) ->
  xhr = new XMLHttpRequest()
  xhr.open('POST', options.url, true)
  xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded')
  for header, value of options.headers
    value = value() if value && value.call
    xhr.setRequestHeader(header, value)
  xhr.onreadystatechange = options.callback
  xhr.send(options.data)


class Channel
  constructor: (@es) ->
    channels[@es.channel].close() if channels[@es.channel]
    channels[@es.channel] = this
    @listeners = {}
    @boundListeners = {}
    @connect()
    setTimeout (=> @checkConnection()), 10000

  receive: (data) ->
    @lastEvent = new Date().getTime() unless data.originalEvent.type == "error"
    switch data.eshqEvent
      when "open"
        for type in Object.keys(@listeners)
          @sendToFrame("bind", {type: type})
          @boundListeners[type] = true
        @es.onopen(data.originalEvent) if @es.onopen
      when "message"
        type = data.originalEvent.type
        if type == "message"
          @es.onmessage(data.originalEvent) if @es.onmessage          
        else
          @es.lastEventId = data.originalEvent.lastEventId
          cb(data.originalEvent) for cb in @listeners[type] if @listeners[type]
      when "error"
        @es.onerror(data.originalEvent) if @es.onerror

  bind: (type, cb) ->
    @listeners[type] ||= []
    @listeners[type].push(cb)
    @sendToFrame("bind", {type: type}) if @frameWindow && !@boundListeners[type]

  connect: ->
    channel = this
    data = "channel=" + @es.channel
    data += "&presence_id=" + @es.options.presence_id if @es.options.presence_id
    ajaxPost
      url: @es.options.auth_url || "/eshq/socket"
      data: data
      headers: @es.options.auth_headers || {}
      callback: ->
        return if channel.closed
        channel.open(JSON.parse(this.responseText)) if @readyState == 4 && /^20\d$/.test(@status)

  open: (data) ->
    @es.socket_id = data.socket
    if window.postMessage then @openIframe(data) else @openHtmlFile(data)

  close: ->
    @closed = true
    if window.postMessage then @closeIframe() else @closeHtmlFile()
    delete channels[@es.channel]

  openIframe: (data) ->
    @frame.parentNode.removeChild(@frame) if @frame && @frame.parentNode

    iframe = document.createElement("iframe")
    src    = "#{origin}/iframe?channel=#{@es.channel}&socket=#{data.socket}&t=#{new Date().getTime()}"
    src   += "&last-event-id=" + @lastEventId if @lastEventId
    iframe.setAttribute("style", "display: none;")
    iframe.setAttribute("src", src)

    document.body.appendChild(iframe)

    @frame        = iframe
    @frameWindow  = iframe.contentWindow

  closeIframe: ->
    return unless @frame
    document.body.removeChild(@frame)
    @frame = null

  openHtmlFile: (data) ->
    iframe = new ActiveXObject("htmlfile")
    iframe.open()
    iframe.write("<html><head></head></html>")
    iframe.parentWindow.ESHQ = (e) =>
      @openScriptTransport(iframe, data.socket, @lastEventId)
      switch(e.type)
        when "ping"
          @receive({eshqEvent: "ping"})
        when "message"
          @receive({eshqEvent: "message", originalEvent: {type: e.name, id: e.id, data: e.data.join("")}})
        when "open"
          @receive({eshqEvent: "open", originalEvent: {}})
    iframe.close()

    # TODO: handle this better
    @openScriptTransport(iframe, data.socket);
    @receive({eshqEvent: "open", originalEvent: {}})
    @iframe = iframe

  closeHtmlFile: ->
    @iframe.parentWindow.ESHQ = null
    @iframe = null;
    CollectGarbage();

  checkConnection: ->
    return if @closed
    @connect() if new Date().getTime() - @lastEvent > 30000
    setTimeout (=> @checkConnection()), 10000

  sendToFrame: (action, data) ->
    @frameWindow.postMessage(JSON.stringify(
      action: action
      data: data
    ), "*")

  openScriptTransport: (iframe, socket) ->
    head = iframe.getElementsByTagName("head")[0]
    o    = iframe.getElementsByTagName("script")[0]
    o.parentNode.removeChild(o) if o

    script = iframe.createElement("script")
    src  = "#{origin}/eventsource/script.js?socket=#{socket}&t=#{new Date().getTime()}"
    scr += "&last-event-id=#{@lastId}" if @lastId
    script.setAttribute("src", src)
    head.appendChild(script)


class ESHQ
  constructor: (channel, options) ->
    @channel = channel
    @options = options || {}
    new Channel(this)

  onopen: null
  onmessage: null
  onerror: null

  addEventListener: (type, cb) ->
    channels[@channel].bind(type, cb)
  
  send: (msg) ->
    console && console.log && console.log("eshq.send has been deprecated.")

    if window.postMessage
      channels[@channel].sendToFrame("send", msg)
    else
      iframe = document.createElement("iframe")
      uniqueString = "eshq" + new Date().getTime().toString()
      document.body.appendChild(iframe)
      iframe.style.display = "none";
      iframe.contentWindow.name = uniqueString
      form = document.createElement("form")
      form.target = uniqueString
      form.action = origin + "/socket/" + this.sub.socket
      form.method = "POST"
      input = document.createElement("input")
      input.type = "hidden"
      input.name = "data"
      input.value = data
      form.appendChild(input)
      document.body.appendChild(form)
      form.submit()
  close: ->
    channels[@channel].close()



onMessage = (event) ->
  return unless event.origin == origin

  data = JSON.parse(event.data)
  return unless data.eshqEvent

  channel = channels[data.channel]
  return unless channel

  channel.receive(data)


if window.postMessage
  window.addEventListener "message", onMessage, false
else
  window._eshqM = onMessage

window.ESHQ = ESHQ
