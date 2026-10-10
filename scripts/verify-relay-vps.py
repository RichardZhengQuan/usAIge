#!/usr/bin/env python3
"""Exercise the deployed relay with one disposable connection, then remove it."""
import json
from datetime import datetime, timezone
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4

BASE = "https://pmrichq.com/project/usaige/api/v1/"


def send(path, status=200, method="GET", token=None, body=None):
    url = path if path.startswith(BASE) else BASE + path
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    request = Request(url, data=data, headers=headers, method=method)
    try:
        response = urlopen(request, timeout=20)
    except HTTPError as error:
        response = error
    with response:
        assert response.status == status, f"{method} relay request: expected {status}, got {response.status}"
        if status == 204:
            return None
        assert response.headers.get_content_type() == "application/json", "Relay returned a non-JSON response"
        assert response.headers.get("Cache-Control") == "no-store", "Relay response can be cached"
        return json.load(response)


def main():
    assert send("health") == {"status": "ok", "service": "usaige-relay"}
    missing = send(f"channels/{uuid4()}/tools", 404)
    assert missing["code"] == "channel_not_found"
    channel = send("channels", 201, "POST", body={"macName": "Disposable deployment verification"})
    path = "channels/" + channel["channelID"]
    token = channel["uploadToken"]
    removed = False
    try:
        assert send(path + "/tools", token=token) == {"tools": []}
        send(path + "/tools", 401)
        phone = send("pairings/claim", 201, "POST", body={"code": channel["pairingCode"], "deviceName": "Disposable iPhone"})
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        mac_snapshot = {"schemaVersion": 1, "generatedAt": now, "tools": [
            {"id": "chatgpt", "name": "ChatGPT", "symbolName": "sparkles", "limits": [
                {"id": "weekly", "name": "Weekly", "primary": {"remainingPercent": 64, "windowDurationMinutes": 10080}}
            ]}
        ]}
        send(path + "/snapshot", method="PUT", token=token, body=mac_snapshot)
        assert send(path + "/snapshot", token=phone["readToken"])["snapshot"] == mac_snapshot
        pairing = send(path + "/tool-pairings", 201, "POST", token=token)
        tool = send("tool-pairings/claim", 201, "POST", body={"code": pairing["pairingCode"], "toolName": "Disposable remote tool", "symbolName": "sparkles"})
        expected_upload = BASE + path + "/tools/" + tool["toolID"] + "/snapshot"
        assert tool["uploadURL"] == expected_upload, "Generated upload URL has the wrong public API path"
        remote_snapshot = {"schemaVersion": 1, "generatedAt": now, "limits": [
            {"id": "weekly", "name": "Weekly", "primary": {"remainingPercent": 75, "windowDurationMinutes": 10080}}
        ]}
        send(tool["uploadURL"], 401, "PUT", token=token, body=remote_snapshot)
        send(tool["uploadURL"], method="PUT", token=tool["writeToken"], body=remote_snapshot)
        tools = send(path + "/tools", token=token)["tools"]
        assert len(tools) == 1 and tools[0]["snapshot"] == remote_snapshot
        send(path + "/tools/" + tool["toolID"], 204, "DELETE", token=token)
        send(tool["uploadURL"], 401, "PUT", token=tool["writeToken"], body=remote_snapshot)
        assert send(path + "/tools", token=token) == {"tools": []}
        send(path + "/devices/" + phone["deviceID"], 204, "DELETE", token=token)
        send(path + "/snapshot", 401, token=phone["readToken"])
        send(path, 204, "DELETE", token=token)
        removed = True
        assert send(path + "/tools", 404, token=token)["code"] == "channel_not_found"
    finally:
        if not removed:
            send(path, 204, "DELETE", token=token)
    print("PASS: HTTPS health, typed missing connection, Mac/iPhone/remote-tool pairing, authorization, upload/fetch, revocation, and disposable connection cleanup.")


if __name__ == "__main__":
    main()
