(function() {
  var origin = "$origin$";

	if (typeof(window.addEventListener) == "undefined") {
		window.addEventListener = function(name, fn) {
			window.attachEvent("on" + name, fn);
		};
	}

  var post = function(path, data, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', path, true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = callback;
    xhr.send(data);
  };

  var Sub = function(es) {
    this.es      = es;
  };

  Sub.prototype.dispatch = function(data) {
    this.es._trigger(data.eshqEvent, data.originalEvent);
  };

  var subs = {};

  var onMessage = function(event) {
    if (event.origin !== origin) { return; }

    var data = JSON.parse(event.data);
    if (!data.eshqEvent) { return; }

    var sub = subs[data.channel];
    if (!sub) { return; }

    sub.dispatch(data);
  };

  if (window.postMessage) {
    window.addEventListener("message", onMessage, false);
  } else {
    window._eshqM = onMessage;
  }

  var getSocket = function(channel, options) {
    var data = "channel=" + channel;
    if (options.presence_id) {
      data += "&presence_id=" + options.presence_id;
    }
    post(options.url, data, function() {
      if (this.readyState == 4 && this.status == 200) {
        var resp = JSON.parse(this.responseText);
        openChannel(channel, resp.socket);
      }
    });
  };

  var openChannel = function(channel, socket) {
      var iframe = document.createElement("iframe"),
          action = window.postMessage ? "/iframe" : "/eventsource/iframe";
      iframe.setAttribute("style", "display: none;");
      iframe.setAttribute("src", origin + action + "?channel=" + channel + "&socket=" + socket + "&t=" + new Date().getTime());
      document.body.appendChild(iframe);
      subs[channel].frame = iframe;
  };

  var ESHQ = function(channel, options) {
    if ( !(this instanceof ESHQ)) return new ESHQ(channel, options);

    this.sub = subs[channel] = new Sub(this, channel, options || {});
    getSocket(channel, {url: options.auth_url || "/eshq/socket", presence_id: options.presence_id});
  };

  ESHQ.prototype = {
    _listeners: {},
    _trigger: function(type, event) {
      var fn = this["on" + type];
      if (fn) fn.call(null, event);
      if (type == "message") {
        var listeners = this._listeners[event.type] || [];
        for (var i=0; i<listeners.lengt; i++) {
          listeners[i].call(null, event);
        }
      }
    },
    onopen: null,
    onmessage: null,
    onerror: null,
    addEventListener: function(type, fn) {
      this._listeners[type] = this._listeners[type] || [];
      this._listeners[type].push(fn);
    },
    send: function(data) {
      this.sub.frame.contentWindow.postMessage(data, "*");
    }
  };

  window.ESHQ = ESHQ;
})();
