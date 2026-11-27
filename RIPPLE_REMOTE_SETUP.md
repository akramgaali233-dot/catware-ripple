# Ripple external inference setup

This version keeps the Roblox script lightweight. The neural network runs in Python with ONNX Runtime on the same PC.

## 1. Install the Python dependencies

```powershell
python -m pip install numpy onnxruntime
```

## 2. Start the local service

Run this from the folder containing the server and the Ripple-RLBot checkout:

```powershell
python ripple_inference_server.py --model ..\..\work\Ripple-RLBot\bots\v1.1\ripple-v1.1.onnx --port 8765
```

Keep that window running. Check that `http://127.0.0.1:8765/health` returns `ok: true`.

## 3. Load the lightweight Roblox adapter

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/akramgaali233-dot/catware-ripple/main/catware_ripple_remote.lua"))()
```

Enable `RippleBot` only after the local service is running. The executor must expose a `request`, `http_request`, or `syn.request` function for POST requests.

Use this only in your own Turbo Soccer test environment. Ripple remains licensed CC BY-NC-SA 4.0 with attribution to Rolv-Arild/Ripple-RLBot.
