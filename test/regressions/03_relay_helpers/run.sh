#!/bin/bash

set -e

python3 - <<'PY'
import argparse
import importlib.util
import logging
import os
import pathlib

module_path = pathlib.Path(os.environ["WSDD_SCRIPT"])
spec = importlib.util.spec_from_file_location("wsdd", module_path)
wsdd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wsdd)

wsdd.args = argparse.Namespace(relay_ttl=4)
wsdd.logger = logging.getLogger("wsdd-test")

relay = object.__new__(wsdd.WSDRelay)
relay.secret = b"shared"
relay.relay_id = "relay-a"
relay.xaddr_maps = [("http://192.168.10.", "http://100.96.0.20/camera/")]

envelope = relay.build_envelope(
    "multicast",
    "<packet/>",
    {"address": "192.168.1.5", "port": 3702, "interface": "eth0"})
encoded = relay.encode_envelope(envelope)
decoded = relay.decode_envelope(encoded)
assert decoded["type"] == "multicast"
assert decoded["payload_b64"] == envelope["payload_b64"]

tampered = bytearray(encoded)
tampered[-2] = ord("x")
try:
    relay.decode_envelope(bytes(tampered))
except ValueError:
    pass
else:
    raise AssertionError("tampered relay packet was accepted")

xml = """<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope
  xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
  xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery">
  <soap:Header>
    <wsa:MessageID>urn:uuid:probe</wsa:MessageID>
  </soap:Header>
  <soap:Body>
    <wsd:ProbeMatches>
      <wsd:ProbeMatch>
        <wsd:XAddrs>http://192.168.10.5/onvif/device_service http://10.0.0.5/keep</wsd:XAddrs>
      </wsd:ProbeMatch>
    </wsd:ProbeMatches>
  </soap:Body>
</soap:Envelope>"""

rewritten = relay.rewrite_xaddrs(xml)
assert "http://100.96.0.20/camera/5/onvif/device_service" in rewritten
assert "http://10.0.0.5/keep" in rewritten
assert relay.rewrite_xaddrs("<not-xml") == "<not-xml"
PY
