const http = require("http");
const WebSocket = require("ws");

const PORT = process.env.PORT || 10000;
const HOST = "0.0.0.0";
const HEARTBEAT_INTERVAL_MS = 30000;

// roomId => Set<WebSocket>
const rooms = new Map();

// socket => { roomId, peerId, role, deviceId, joinedAt }
const peers = new Map();

function roleFamily(role) {
  if (role === "camera" || role === "monitor") {
    return "live";
  }
  if (role === "geo-position" || role === "geo-monitor") {
    return "geo";
  }
  return null;
}

function maxPeersForRole(role) {
  switch (role) {
    case "geo-position":
      return 2;
    case "geo-monitor":
    case "camera":
    case "monitor":
      return 1;
    default:
      return 0;
  }
}

function snapshotRoom(roomId) {
  const room = rooms.get(roomId);
  if (!room) {
    return [];
  }

  return [...room]
    .map((client) => peers.get(client))
    .filter(Boolean);
}

function resolvePresence(roomId, deviceId) {
  const roomPeers = snapshotRoom(roomId);
  const matchingPeers =
    deviceId && deviceId.trim().length > 0
      ? roomPeers.filter((peer) => peer.deviceId === deviceId)
      : roomPeers;

  return {
    roomId,
    deviceId: deviceId || null,
    online: matchingPeers.length > 0,
    activePeers: matchingPeers.length,
    peers: matchingPeers.map((peer) => ({
      peerId: peer.peerId,
      role: peer.role,
      deviceId: peer.deviceId || null,
      joinedAt: peer.joinedAt,
    })),
  };
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  if (req.url === "/") {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Hello Aether!");
    return;
  }

  const requestUrl = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  if (requestUrl.pathname === "/presence") {
    const roomId = requestUrl.searchParams.get("roomId")?.trim();
    const deviceId = requestUrl.searchParams.get("deviceId")?.trim();

    if (!roomId) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Missing roomId" }));
      return;
    }

    res.writeHead(200, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    });
    res.end(JSON.stringify(resolvePresence(roomId, deviceId)));
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "Not found" }));
});

const wss = new WebSocket.Server({
  server,
  path: "/ws",
});

function safeSend(ws, data) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data));
  }
}

function broadcastToRoomExcept(roomId, sender, message) {
  const room = rooms.get(roomId);
  if (!room) return;

  for (const client of room) {
    if (client !== sender && client.readyState === WebSocket.OPEN) {
      safeSend(client, message);
    }
  }
}

function removePeer(ws) {
  const info = peers.get(ws);
  if (!info) return;

  const { roomId, peerId, deviceId } = info;
  const room = rooms.get(roomId);

  if (room) {
    room.delete(ws);

    if (room.size === 0) {
      rooms.delete(roomId);
    }
  }

  peers.delete(ws);
  console.log(
    `Peer disconnected: ${peerId || "unknown"} from room ${roomId || "unknown"} device=${deviceId || "unknown"}`
  );
}

function replaceRoomPeer(room, existingSocket) {
  if (!room.has(existingSocket)) return;
  try {
    existingSocket.close(4000, "Replaced by a newer session");
  } catch (err) {
    console.error("Failed to close replaced socket:", err);
  } finally {
    removePeer(existingSocket);
  }
}

wss.on("connection", (ws, req) => {
  console.log("New WS connection");
  ws.isAlive = true;

  ws.on("pong", () => {
    ws.isAlive = true;
  });

  ws.on("message", (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      const { type, payload } = msg || {};

      if (!type) {
        safeSend(ws, {
          type: "error",
          payload: { message: "Missing message type" },
        });
        return;
      }

      if (type === "join") {
        const roomId = payload?.roomId;
        const peerId = payload?.peerId || `peer-${Math.random().toString(36).slice(2, 8)}`;
        const role = payload?.role || "unknown";
        const deviceId = payload?.deviceId?.trim();

        if (!roomId) {
          safeSend(ws, {
            type: "error",
            payload: { message: "Missing roomId in join payload" },
          });
          return;
        }

        if (!["camera", "monitor", "geo-position", "geo-monitor"].includes(role)) {
          safeSend(ws, {
            type: "error",
            payload: { message: "Invalid role in join payload" },
          });
          return;
        }

        removePeer(ws);

        if (!rooms.has(roomId)) {
          rooms.set(roomId, new Set());
        }

        const room = rooms.get(roomId);
        const roomPeers = [...room].map((client) => peers.get(client)).filter(Boolean);

        const existingSameDeviceSocket =
          deviceId && deviceId.length > 0
            ? [...room].find((client) => {
                const peer = peers.get(client);
                return peer?.role === role && peer.deviceId === deviceId;
              })
            : null;
        if (existingSameDeviceSocket) {
          replaceRoomPeer(room, existingSameDeviceSocket);
        }

        const existingSameRoleSocket = [...room].find((client) => peers.get(client)?.role === role);
        const shouldReplaceSameRolePeer = role !== "geo-position";
        if (existingSameRoleSocket && shouldReplaceSameRolePeer) {
          replaceRoomPeer(room, existingSameRoleSocket);
        }

        const refreshedRoomPeers = [...room].map((client) => peers.get(client)).filter(Boolean);

        const incomingFamily = roleFamily(role);
        if (
          incomingFamily == null ||
          refreshedRoomPeers.some((peer) => roleFamily(peer.role) !== incomingFamily)
        ) {
          safeSend(ws, {
            type: "error",
            payload: { message: "This room is reserved for a different pairing type" },
          });
          return;
        }

        const sameRoleCount = refreshedRoomPeers.filter((peer) => peer.role === role).length;
        if (sameRoleCount >= maxPeersForRole(role)) {
          safeSend(ws, {
            type: "error",
            payload: { message: `Room already has the maximum number of ${role} peers` },
          });
          return;
        }

        const familyPeerCount = refreshedRoomPeers.filter(
          (peer) => roleFamily(peer.role) === incomingFamily
        ).length;
        const maxFamilyPeers = incomingFamily === "geo" ? 3 : 2;
        if (familyPeerCount >= maxFamilyPeers) {
          safeSend(ws, {
            type: "error",
            payload: { message: "Room is already full" },
          });
          return;
        }

        room.add(ws);
        peers.set(ws, {
          roomId,
          peerId,
          role,
          deviceId: deviceId || null,
          joinedAt: Date.now(),
        });

        console.log(
          `Peer joined room=${roomId} peerId=${peerId} role=${role} device=${deviceId || "unknown"}`
        );

        safeSend(ws, {
          type: "control",
          payload: {
            action: "session-joined",
            roomId,
            peerId,
            role,
          },
        });

        for (const peer of refreshedRoomPeers) {
          safeSend(ws, {
            type: "join",
            payload: {
              roomId,
              peerId: peer.peerId,
              role: peer.role,
            },
          });
        }

        broadcastToRoomExcept(roomId, ws, {
          type: "join",
          payload: { roomId, peerId, role },
        });

        return;
      }

      const peerInfo = peers.get(ws);
      if (!peerInfo) {
        console.warn(`Ignoring ${type} before join completed`);
        return;
      }

      const { roomId, peerId } = peerInfo;

      switch (type) {
        case "secure-signal":
          broadcastToRoomExcept(roomId, ws, {
            type,
            payload,
          });
          console.log(`Relayed ${type} in room=${roomId} from=${peerId}`);
          break;

        case "offer":
        case "answer":
        case "ice-candidate":
        case "control":
        case "data":
          broadcastToRoomExcept(roomId, ws, {
            type,
            payload: {
              ...payload,
              fromPeerId: peerId,
              roomId,
            },
          });
          console.log(`Relayed ${type} in room=${roomId} from=${peerId}`);
          break;

        default:
          safeSend(ws, {
            type: "error",
            payload: { message: `Unsupported message type: ${type}` },
          });
      }
    } catch (err) {
      console.error("Invalid message:", err);
      safeSend(ws, {
        type: "error",
        payload: { message: "Invalid JSON" },
      });
    }
  });

  ws.on("close", () => {
    removePeer(ws);
  });

  ws.on("error", (err) => {
    console.error("Socket error:", err);
    removePeer(ws);
  });
});

// server.listen(PORT, "192.168.0.108", () => {
//   console.log(`Signaling server running on http://192.168.0.108:${PORT}`);
//   console.log(`WebSocket endpoint: ws://192.168.0.108:${PORT}/ws`);
// });

server.listen(PORT, HOST, () => {
  console.log(`Signaling server running on http://${HOST}:${PORT}`);
  console.log(`WebSocket endpoint: /ws`);
});

const heartbeatInterval = setInterval(() => {
  for (const client of wss.clients) {
    if (client.isAlive === false) {
      removePeer(client);
      client.terminate();
      continue;
    }

    client.isAlive = false;
    try {
      client.ping();
    } catch (error) {
      console.error("Failed to ping client:", error);
      removePeer(client);
      client.terminate();
    }
  }
}, HEARTBEAT_INTERVAL_MS);

wss.on("close", () => {
  clearInterval(heartbeatInterval);
});
