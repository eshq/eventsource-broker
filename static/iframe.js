// Generated by CoffeeScript 1.3.3
(function() {
  var ajaxPost, channel, evtSrc, lastId, onMessage, openEventSource, sendToParent, socket;

  channel = document.location.search.match(/channel=([^&]+)/)[1];

  socket = document.location.search.match(/socket=([^&]+)/)[1];

  lastId = document.location.search.match(/last-event-id=[^&]+/);

  evtSrc = null;

  sendToParent = function(type, channel, e) {
    return parent.postMessage(JSON.stringify({
      eshqEvent: type,
      channel: channel,
      originalEvent: {
        data: e.data,
        lastEventId: e.lastEventId,
        type: e.type,
        id: e.id
      }
    }), "*");
  };

  ajaxPost = function(path, data, callback) {
    var xhr;
    xhr = new XMLHttpRequest();
    xhr.open('POST', path, true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = callback;
    return xhr.send(data);
  };

  onMessage = function(e) {
    var data;
    data = JSON.parse(e.data);
    switch (data.action) {
      case "send":
        return ajaxPost("/socket/" + socket, "data=" + (encodeURIComponent(data.data)));
      case "bind":
        return evtSrc.addEventListener(data.data.type, (function(e) {
          return sendToParent("message", channel, e);
        }), false);
    }
  };

  openEventSource = function() {
    var src;
    src = "/eventsource?socket=" + socket;
    if (lastId) {
      src += "&" + lastId;
    }
    evtSrc = new EventSource(src);
    if (evtSrc.readyState > 0) {
      sendToParent("open", channel, {});
    } else {
      evtSrc.onopen = function(e) {
        return sendToParent("open", channel, e);
      };
    }
    evtSrc.onerror = function(e) {
      return sendToParent("error", channel, e);
    };
    evtSrc.onmessage = function(e) {
      return sendToParent("message", channel, e);
    };
    return evtSrc.addEventListener("ping", (function(e) {
      return sendToParent("ping", channel, {});
    }), false);
  };

  setTimeout(openEventSource, 0);

  window.addEventListener("message", onMessage, false);

}).call(this);