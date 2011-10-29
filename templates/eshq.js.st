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

  var Sub = function(es, channel, options) {
    this.es      = es;
    this.channel = channel;
    this.options = options;
  };

  Sub.prototype.dispatch = function(data) {
    this.t = new Date().getTime();
    if (data.eshqEvent !== "ping") {
      this.es._trigger(data.eshqEvent, data.originalEvent);
    }
  };

  Sub.prototype.postMsg = function(action, data) {
    this.frame.contentWindow.postMessage(JSON.stringify({
      action: action,
      data: data
    }), "*");
  };

  Sub.prototype.connect = function() {
    if (this.frame) {
      if (this.frame.parentNode) {
        this.frame.parentNode.removeChild(this.frame);
      } else {
        this.frame = null;
      }
    }
    getSocket(this.channel, {url: this.options.auth_url || "/eshq/socket", presence_id: this.options.presence_id});
  };

  var subs = {};

  var checkSubs = function() {
    for (var channel in subs) {
      if (new Date().getTime() - subs[channel].t > 30000) {
        subs[channel].connect();
      }
    }
  };

  setInterval(checkSubs, 10000);

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

  var eventSourceChannel = function(channel, socket) {
    var iframe = document.createElement("iframe");
    iframe.setAttribute("style", "display: none;");
    iframe.setAttribute("src", origin + "/iframe?channel=" + channel + "&socket=" + socket + "&t=" + new Date().getTime());
    document.body.appendChild(iframe);
    subs[channel].frame = iframe;
    subs[channel].socket = socket;
  };

  var openScriptTransport = function(iframe, socket) {
    var head = iframe.getElementsByTagName("head")[0];
    var o = iframe.getElementsByTagName("script")[0];
    if (o) o.parentNode.removeChild(o);

    var s = iframe.createElement("script");
    s.setAttribute("src", origin + "/eventsource/script.js?socket=" + socket + "&t=" + new Date().getTime());
    head.appendChild(s);
  };

  var scriptTagChannel = function(channel, socket) {
    var iframe = new ActiveXObject("htmlfile");
    iframe.open();
    iframe.write("<html><head></head></html>");
    iframe.parentWindow.ESHQ = function(e) { 
      openScriptTransport(iframe, socket);
      switch(e.type) {
        case "ping":
          sub[channel].dispatch({eshqEvent: "ping"});
          break;
        case "message":
          subs[channel].dispatch({eshqEvent: "message", originalEvent: {type: e.name, id: e.id, data: e.data.join("")}}); 
          break;
        case "comment":
        case "retry":
          break;
        case "open":
          subs[channel].dispatch({eshqEvent: "open", originalEvent: {}});
          break;
      }
    };
    iframe.close();

    // TODO: handle this better
    openScriptTransport(iframe, socket);
    subs[channel].dispatch({eshqEvent: "open", originalEvent: {}});
    subs[channel].frame = iframe;
    subs[channel].socket = socket;
  };

  var openChannel = function(channel, socket) {
    window.postMessage ?
      eventSourceChannel(channel, socket) :
      scriptTagChannel(channel, socket);
  };

  var ESHQ = function(channel, options) {
    if ( !(this instanceof ESHQ)) return new ESHQ(channel, options);

    this.sub = subs[channel] = new Sub(this, channel, options || {});
    this.sub.connect();
  };

  ESHQ.prototype = {
    _listeners: {},
    _trigger: function(type, event) {
      var fn = this["on" + type];
      if (type == "message") {
        var listeners = this._listeners[event.type] || [];
        for (var i=0; i<listeners.lengt; i++) {
          listeners[i].call(null, event);
        }
        if (event.type == "message" && fn) fn.call(null, event);
      } else {
        if (fn) fn.call(null, event);
      }
    },
    onopen: null,
    onmessage: null,
    onerror: null,
    addEventListener: function(type, fn) {
      this._listeners[type] = this._listeners[type] || [];
      this._listeners[type].push(fn);
      if (window.postMessage) {
        this.sub.postMsg("bind");
      }
    },
    send: window.postMessage ? function(data) {
      this.sub.postMsg("send", data);
    } : function(data) {
      var iframe = document.createElement("iframe");
      var uniqueString = new Date().getTime();
      document.body.appendChild(iframe);
      iframe.style.display = "none";
      iframe.contentWindow.name = uniqueString;

      var form = document.createElement("form");
      form.target = uniqueString;
      form.action = origin + "/socket/" + this.sub.socket;
      form.method = "POST";

      var input = document.createElement("input");
      input.type = "hidden";
      input.name = "data";
      input.value = data;
      form.appendChild(input);

      document.body.appendChild(form);
      form.submit();
    }
  };

  window.ESHQ = ESHQ;
})();
