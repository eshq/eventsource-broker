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

  var Sub = function(channel, options) {
    for (var i in options) {
      this[i] = options[i];
    };
    this.channel = channel;
  }

  var subs = {};

  var onMessage = function(event) {
    if (event.origin !== origin) { return; }

    var data = JSON.parse(event.data);
    if (!data.eshqEvent) { return; }

    var sub = subs[data.channel];
    if (!sub) { return; }

    if (sub[data.eshqEvent]) { sub[data.eshqEvent].call(null, data.originalEvent); }
  };

  window.addEventListener("message", onMessage, false);

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
      var iframe = document.createElement("iframe");
      iframe.setAttribute("style", "display: none;");
      iframe.setAttribute("src", origin + "/iframe?channel=" + channel + "&socket=" + socket + "&t=" + new Date().getTime());
      document.body.appendChild(iframe);
      subs[channel].frame = iframe;
  };

  window.eshq = {
    open: function(channel, options) {
      subs[channel] = new Sub(channel, options || {});
      getSocket(channel, {url: options.auth_url || "/eshq/socket", presence_id: options.presence_id});
    },
    send: function(channel, data) {
      var sub = subs[channel];
      if (!sub) throw "You must open a channel before sending to it";

      sub.frame.contentWindow.postMessage(data, "*");
    }
  };
})();
