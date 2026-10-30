#!/usr/bin/env python3
"""Outcome check of the OpenAI Realtime protocol CrownTalk uses (run on the Mac, real endpoint):
a spoken question streamed as 24 kHz PCM yields a transcript, a spoken reply and its text."""
import base64, json, os, pathlib, subprocess, sys, time, wave
import websocket

MODEL = "gpt-realtime-2.1"
VOICE = "marin"
SAMPLE_RATE = 24_000
CHUNK_SECONDS = 0.1
REPO = pathlib.Path(__file__).resolve().parent.parent
QUESTION_M4A = REPO / "build/audio/question.m4a"
QUESTION_WAV = REPO / "build/audio/question-24k.wav"

key = next(l.split("=", 1)[1].strip().strip('"') for l in open(REPO / ".env") if "OPENAI_API_KEY=" in l)
QUESTION_M4A.parent.mkdir(parents=True, exist_ok=True)
if not QUESTION_M4A.exists():
    subprocess.run(["say", "-o", QUESTION_M4A, "--file-format=m4af", "--data-format=aac",
                    "What is the tallest mountain in Europe? Answer in one sentence."], check=True)
subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", QUESTION_M4A, QUESTION_WAV], check=True)
pcm = wave.open(str(QUESTION_WAV)).readframes(10**9) + bytes(SAMPLE_RATE * 2)  # 1 s trailing silence for VAD

socket = websocket.create_connection(f"wss://api.openai.com/v1/realtime?model={MODEL}",
                                     header=[f"Authorization: Bearer {key}"])
send = lambda event: socket.send(json.dumps(event))
send({"type": "session.update", "session": {
    "type": "realtime", "instructions": "Answer briefly.", "output_modalities": ["audio"],
    "audio": {
        "input": {"format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                  "transcription": {"model": "gpt-4o-mini-transcribe"},
                  "turn_detection": {"type": "server_vad", "silence_duration_ms": 500}},
        "output": {"format": {"type": "audio/pcm", "rate": SAMPLE_RATE}, "voice": VOICE}}}})
chunk = int(SAMPLE_RATE * 2 * CHUNK_SECONDS)
for offset in range(0, len(pcm), chunk):
    send({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm[offset:offset + chunk]).decode()})
sent = time.time()
audio_bytes, reply, transcript, first_audio = 0, "", "", None
while True:
    event = json.loads(socket.recv())
    kind = event["type"]
    if kind not in ("response.output_audio.delta", "response.output_audio_transcript.delta"):
        print(f"{time.time() - sent:5.2f}s {kind}")
    if kind == "error": sys.exit(f"error: {event}")
    if kind == "response.output_audio.delta":
        first_audio = first_audio or time.time() - sent
        audio_bytes += len(base64.b64decode(event["delta"]))
    if kind == "response.output_audio_transcript.delta": reply += event["delta"]
    if kind == "conversation.item.input_audio_transcription.completed": transcript = event["transcript"]
    if kind == "response.done": break
time.sleep(1)  # transcription may complete after the response
print(f"transcript: {transcript}\nreply: {reply}\naudio: {audio_bytes} bytes, first after {first_audio:.2f}s")
sys.exit(0 if audio_bytes and "Elbrus" in reply else 1)
