@echo off
title Zenspace Local Server
echo Starting Zenspace...
start "" "http://localhost:3000/dashboard.html"
node server.js
pause
