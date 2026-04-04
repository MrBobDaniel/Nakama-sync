const express = require('express');
const http = require('http');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
  }
});

// Stateless Map to keep track of simple room-based peers
const rooms = new Map();

io.on('connection', (socket) => {
  console.log(`[+] Client connected: ${socket.id}`);

  // Join a specified room (e.g., walkie-talkie channel)
  socket.on('join', (roomId) => {
    socket.join(roomId);

    if (!rooms.has(roomId)) {
      rooms.set(roomId, new Set());
    }

    const peers = rooms.get(roomId);
    const existingPeers = Array.from(peers);
    peers.add(socket.id);

    socket.emit('room-peers', existingPeers);
    socket.to(roomId).emit('peer-joined', socket.id);
    console.log(`Client ${socket.id} joined room ${roomId}`);
  });

  // Relay WebRTC SDP Offers/Answers/ICECandidates
  socket.on('signal', (data) => {
    const { target, signalData } = data;
    // target is the receiving peer's socket.id
    io.to(target).emit('signal', {
      sender: socket.id,
      signalData
    });
  });

  socket.on('disconnect', () => {
    console.log(`[-] Client disconnected: ${socket.id}`);
    rooms.forEach((peers, roomId) => {
      if (peers.has(socket.id)) {
        peers.delete(socket.id);
        socket.to(roomId).emit('peer-left', socket.id);
      }
    });
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`[🚀] Nakama Signaling Server running on port ${PORT}`);
});
