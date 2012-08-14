channel = document.location.search.match(/channel=([^&]+)/)[1]
socket  = document.location.search.match(/socket=([^&]+)/)[1]
lastId  = document.location.search.match(/last-event-id=[^&]+/)
evtSrc  = null

sendToParent = (type, channel, e) ->
  parent.postMessage(JSON.stringify(
    eshqEvent: type
    channel: channel
    originalEvent:
      data: e.data
      lastEventId: e.lastEventId
      type: e.type
      id: e.id
  ), "*")

onMessage = (e) ->
  data = JSON.parse(e.data);
  switch(data.action)
    when "send"
      ajaxPost("/socket/#{socket}", "data=#{encodeURIComponent(data.data)}")
    when "bind"
      console.log("Binding event of type %s", data.data.type)
      evtSrc.addEventListener(data.data.type, ((e)  ->
        sendToParent("message", channel, e)
      ), false)

openEventSource = ->
  src = "/eventsource?socket=" + socket
  src += "&" + lastId if lastId

  evtSrc = new EventSource(src)
  if evtSrc.readyState > 0
    sendToParent("open", channel, {})
  else
    evtSrc.onopen  = (e) -> sendToParent("open", channel, e)

  evtSrc.onerror   = (e) -> sendToParent("error", channel, e)
  evtSrc.onmessage = (e) -> sendToParent("message", channel, e)
  evtSrc.addEventListener("ping", ((e) -> sendToParent("ping", channel, {})), false)

# Wrap in a timeout to avoid loading spinner in chrome
setTimeout openEventSource, 0

window.addEventListener("message", onMessage, false)