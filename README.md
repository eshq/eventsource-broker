EvenSource Broker
=================

A simple bridge between EventSource and an AMQP fanout exchange.

EventSource is a new browser standard released as part of the HTML5
spec.

It lets the browser send a never-ending HTTP request to a server and
provides a javascript API for binding to events pushed from the server.

EventSource is very handy when you don't need the full bidirectional
communication that Websockets offers. it plays well with load-balancers,
intermediary proxies and HTTPS termination.

This library sets up an EventSource that clients can connect to
specifying a channel to listen to in the query string. The server
connects to a fanout AMQP exchange and routes AMQP messages as events to
the javascript clients.

MongoDB is used to store user and connection information.

The server expects the AMQP messages to be JSON following the format:

    {
        "channel": "some-channel", // Required
        "data": "{/"msg/": /"data/"}", // Required
        "id": "event-id", // optional
        "name": "event-name" // optional
    }

To open connections to a channel a user with an key and a secret is
expected to exist in the database. Before opening a connection a socket
id must be aquired from by calling POST /socket

A simple example of how to interact with this API can be found in the
[https://github.com/eshq/eshq-gem](eshq ruby gem).

Installation
============

Clone the repository, cd to the root of it and execute

    cabal install

Eventsource Broker depends on MongoDB and RabbitMQ. Make sure everything is configured right in config/app.cfg and then run with:

    eventsource-broker -p <port>

License
=======

Copyright (c)2011, Mathias Biilmann <info@mathias-biilmann.net>

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Mathias Biilman <info@mathias-biilmann.net>
      nor the names of other contributors may be used to endorse or
      promote products derived from this software without specific prior
      written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE
