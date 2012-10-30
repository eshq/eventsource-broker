// Generated by CoffeeScript 1.3.3
(function() {
  var Channel, ESHQ, ajaxPost, channels, eshqScript, onMessage, origin, scripts;

  scripts = document.getElementsByTagName('script');

  channels = {};

  if (window.ESHQ_ORIGIN != null) {
    origin = window.ESHQ_ORIGIN;
  } else {
    eshqScript = scripts[scripts.length - 1];
    origin = eshqScript.src.replace(/\/es.js/, '');
  }

  if (window.addEventListener == null) {
    window.addEventListener = function(name, fn) {
      return window.attachEvent("on" + name, fn);
    };
  }

  Object.keys=Object.keys||function(o,k,r){r=[];for(k in o)r.hasOwnProperty.call(o,k)&&r.push(k);return r};


  ajaxPost = function(path, data, callback) {
    var xhr;
    xhr = new XMLHttpRequest();
    xhr.open('POST', path, true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = callback;
    return xhr.send(data);
  };

  Channel = (function() {

    function Channel(es) {
      var _this = this;
      this.es = es;
      channels[this.es.channel] = this;
      this.listeners = {};
      this.boundListeners = {};
      this.connect();
      setInterval((function() {
        return _this.checkConnection();
      }), 10000);
    }

    Channel.prototype.receive = function(data) {
      var cb, type, _i, _j, _len, _len1, _ref, _ref1, _results;
      if (data.originalEvent.type !== "error") {
        this.lastEvent = new Date().getTime();
      }
      switch (data.eshqEvent) {
        case "open":
          _ref = Object.keys(this.listeners);
          for (_i = 0, _len = _ref.length; _i < _len; _i++) {
            type = _ref[_i];
            this.sendToFrame("bind", {
              type: type
            });
            this.boundListeners[type] = true;
          }
          if (this.es.onopen) {
            return this.es.onopen(data.originalEvent);
          }
          break;
        case "message":
          type = data.originalEvent.type;
          if (type === "message") {
            if (this.es.onmessage) {
              return this.es.onmessage(data.originalEvent);
            }
          } else {
            this.es.lastEventId = data.originalEvent.lastEventId;
            if (this.listeners[type]) {
              _ref1 = this.listeners[type];
              _results = [];
              for (_j = 0, _len1 = _ref1.length; _j < _len1; _j++) {
                cb = _ref1[_j];
                _results.push(cb(data.originalEvent));
              }
              return _results;
            }
          }
          break;
        case "error":
          if (this.es.onerror) {
            return this.es.onerror(data.originalEvent);
          }
      }
    };

    Channel.prototype.bind = function(type, cb) {
      var _base;
      (_base = this.listeners)[type] || (_base[type] = []);
      this.listeners[type].push(cb);
      if (this.frameWindow && !this.boundListeners[type]) {
        return this.sendToFrame("bind", {
          type: type
        });
      }
    };

    Channel.prototype.connect = function() {
      var channel, data;
      channel = this;
      data = "channel=" + this.es.channel;
      if (this.es.options.presence_id) {
        data += "&presence_id=" + this.es.options.presence_id;
      }
      return ajaxPost(this.es.options.auth_url || "/eshq/socket", data, function() {
        if (this.readyState === 4 && /^20\d$/.test(this.status)) {
          return channel.open(JSON.parse(this.responseText));
        }
      });
    };

    Channel.prototype.open = function(data) {
      this.es.socket_id = data.socket;
      if (window.postMessage) {
        return this.openIframe(data);
      } else {
        return this.openHtmlFile(data);
      }
    };

    Channel.prototype.openIframe = function(data) {
      var iframe, src;
      if (this.frame && this.frame.parentNode) {
        this.frame.parentNode.removeChild(this.frame);
      }
      iframe = document.createElement("iframe");
      src = "" + origin + "/iframe?channel=" + this.es.channel + "&socket=" + data.socket + "&t=" + (new Date().getTime());
      if (this.lastEventId) {
        src += "&last-event-id=" + this.lastEventId;
      }
      iframe.setAttribute("style", "display: none;");
      iframe.setAttribute("src", src);
      document.body.appendChild(iframe);
      this.frame = iframe;
      return this.frameWindow = iframe.contentWindow;
    };

    Channel.prototype.openHtmlFile = function(data) {
      var iframe,
        _this = this;
      iframe = new ActiveXObject("htmlfile");
      iframe.open();
      iframe.write("<html><head></head></html>");
      iframe.parentWindow.ESHQ = function(e) {
        _this.openScriptTransport(iframe, data.socket, _this.lastEventId);
        switch (e.type) {
          case "ping":
            return _this.receive({
              eshqEvent: "ping"
            });
          case "message":
            return _this.receive({
              eshqEvent: "message",
              originalEvent: {
                type: e.name,
                id: e.id,
                data: e.data.join("")
              }
            });
          case "open":
            return _this.receive({
              eshqEvent: "open",
              originalEvent: {}
            });
        }
      };
      iframe.close();
      this.openScriptTransport(iframe, data.socket);
      this.receive({
        eshqEvent: "open",
        originalEvent: {}
      });
      return this.iframe = iframe;
    };

    Channel.prototype.checkConnection = function() {
      if (new Date().getTime() - this.lastEvent > 30000) {
        return this.connect();
      }
    };

    Channel.prototype.sendToFrame = function(action, data) {
      return this.frameWindow.postMessage(JSON.stringify({
        action: action,
        data: data
      }), "*");
    };

    Channel.prototype.openScriptTransport = function(iframe, socket) {
      var head, o, script, src;
      head = iframe.getElementsByTagName("head")[0];
      o = iframe.getElementsByTagName("script")[0];
      if (o) {
        o.parentNode.removeChild(o);
      }
      script = iframe.createElement("script");
      src = "" + origin + "/eventsource/script.js?socket=" + socket + "&t=" + (new Date().getTime());
      if (this.lastId) {
        scr += "&last-event-id=" + this.lastId;
      }
      script.setAttribute("src", src);
      return head.appendChild(script);
    };

    return Channel;

  })();

  ESHQ = (function() {

    function ESHQ(channel, options) {
      this.channel = channel;
      this.options = options || {};
      new Channel(this);
    }

    ESHQ.prototype.onopen = null;

    ESHQ.prototype.onmessage = null;

    ESHQ.prototype.onerror = null;

    ESHQ.prototype.addEventListener = function(type, cb) {
      return channels[this.channel].bind(type, cb);
    };

    ESHQ.prototype.send = function(msg) {
      var form, iframe, input, uniqueString;
      console && console.log && console.log("eshq.send has been deprecated.");
      if (window.postMessage) {
        return channels[this.channel].sendToFrame("send", msg);
      } else {
        iframe = document.createElement("iframe");
        uniqueString = "eshq" + new Date().getTime().toString();
        document.body.appendChild(iframe);
        iframe.style.display = "none";
        iframe.contentWindow.name = uniqueString;
        form = document.createElement("form");
        form.target = uniqueString;
        form.action = origin + "/socket/" + this.sub.socket;
        form.method = "POST";
        input = document.createElement("input");
        input.type = "hidden";
        input.name = "data";
        input.value = data;
        form.appendChild(input);
        document.body.appendChild(form);
        return form.submit();
      }
    };

    return ESHQ;

  })();

  onMessage = function(event) {
    var channel, data;
    if (event.origin !== origin) {
      return;
    }
    data = JSON.parse(event.data);
    if (!data.eshqEvent) {
      return;
    }
    channel = channels[data.channel];
    if (!channel) {
      return;
    }
    return channel.receive(data);
  };

  if (window.postMessage) {
    window.addEventListener("message", onMessage, false);
  } else {
    window._eshqM = onMessage;
  }

  window.ESHQ = ESHQ;

}).call(this);
