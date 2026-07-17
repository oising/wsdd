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

wsdd.args = argparse.Namespace(relay_ttl=4, onvif_debug=True, onvif_color="never")
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

large_payload = "<Envelope>" + ("<Scope>onvif://www.onvif.org/type/video_encoder</Scope>" * 100) + "</Envelope>"
large_envelope = relay.build_envelope("multicast", large_payload, {})
assert large_envelope["payload_encoding"] == "deflate"
assert relay.decode_payload(large_envelope) == large_payload

tampered = bytearray(encoded)
tampered[-2] = ord("x")
try:
    relay.decode_envelope(bytes(tampered))
except ValueError:
    pass
else:
    raise AssertionError("tampered relay packet was accepted")

pong = relay.build_envelope("pong", "pong", {"request_packet_id": envelope["packet_id"]})
decoded_pong = relay.decode_envelope(relay.encode_envelope(pong))
assert decoded_pong["type"] == "pong"
assert decoded_pong["source"]["request_packet_id"] == envelope["packet_id"]

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

tree = wsdd.ETfromString("""<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope
  xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
  xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
  xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <soap:Header>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>
    <wsa:MessageID>urn:uuid:onvif-probe</wsa:MessageID>
  </soap:Header>
  <soap:Body>
    <wsd:Probe>
      <wsd:Types>dn:NetworkVideoTransmitter</wsd:Types>
      <wsd:Scopes>onvif://www.onvif.org/type/video_encoder</wsd:Scopes>
    </wsd:Probe>
  </soap:Body>
</soap:Envelope>""")
types = wsdd.ONVIFDebugLogger.collect_text(tree, "Types")
scopes = wsdd.ONVIFDebugLogger.collect_text(tree, "Scopes")
assert wsdd.ONVIFDebugLogger.contains_onvif_marker(types + scopes)
assert wsdd.ONVIFDebugLogger.enabled()
assert wsdd.ONVIFDebugLogger.prefix("relay-local-multicast-capture", "detected", "urn:uuid:a").startswith(
    "[ONVIF LOCAL S")
assert wsdd.ONVIFDebugLogger.prefix("relay-local-multicast-capture", "detected", "urn:uuid:a", "Hello").startswith(
    "[ONVIF LOCAL Hello S")
assert wsdd.ONVIFDebugLogger.prefix("relay-local-unicast-reply-capture", "detected", "urn:uuid:a").startswith(
    "[ONVIF LOCAL S")
assert wsdd.ONVIFDebugLogger.prefix("relay-remote-multicast-rebroadcast", "detected", "urn:uuid:a").startswith(
    "[ONVIF REMOTE S")
assert wsdd.ONVIFDebugLogger.prefix(
    "relay-remote-multicast-rebroadcast", "detected", "urn:uuid:a", "Probe").startswith("[ONVIF REMOTE Probe S")
assert wsdd.ONVIFDebugLogger.prefix("relay-remote-reply-deliver", "detected", "urn:uuid:a").startswith(
    "[ONVIF REMOTE S")
assert wsdd.ONVIFDebugLogger.prefix("relay-unicast-forward-multicast", "wsd", "urn:uuid:a").startswith("[WSD TX S")
assert wsdd.ONVIFDebugLogger.prefix(
    "relay-unicast-forward-multicast", "wsd", "urn:uuid:a", "ResolveMatches").startswith(
        "[WSD TX ResolveMatches S")
assert wsdd.ONVIFDebugLogger.prefix("relay-unicast-receive-multicast", "wsd", "urn:uuid:a").startswith("[WSD RX S")
assert wsdd.ONVIFDebugLogger.prefix("socket-receive", "detected", "urn:uuid:a").startswith("[ONVIF LOCAL S")
assert wsdd.ONVIFDebugLogger.prefix("wsd-handle-message", "detected", "urn:uuid:a").startswith("[ONVIF LOCAL S")
assert wsdd.ONVIFDebugLogger.sequence_label("urn:uuid:a") == wsdd.ONVIFDebugLogger.sequence_label("urn:uuid:a")
assert wsdd.ONVIFDebugLogger.sequence_label("urn:uuid:a").startswith("S")
assert wsdd.ONVIFDebugLogger.action_verb("http://schemas.xmlsoap.org/ws/2005/04/discovery/Resolve") == "Resolve"
PY
